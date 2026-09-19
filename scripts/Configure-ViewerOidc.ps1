#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ApplicationName,
    [guid]$OperatorObjectId = [guid]::Empty,
    [ValidateRange(1, 365)][int]$CredentialLifetimeDays = 90,
    [ValidateRange(1, 90)][int]$RotateBeforeDays = 14,
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')

foreach ($command in @('az', 'azd')) {
    if (!(Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required."
    }
}
if (!(Get-Command Connect-MgGraph -ErrorAction SilentlyContinue) -or
    !(Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}

if (![string]::IsNullOrWhiteSpace($Environment)) {
    & azd env select $Environment | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select azd environment '$Environment'."
    }
}

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name, [switch]$AllowMissing)

    $value = (& azd env get-value $Name 2>$null | Out-String).Trim().Trim('"')
    if (!$AllowMissing -and [string]::IsNullOrWhiteSpace($value)) {
        throw "The selected azd environment does not contain $Name."
    }
    return $value
}

$environmentName = Get-AzdValue 'AZURE_ENV_NAME'
$tenantId = [guid](Get-AzdValue 'AZURE_TENANT_ID')
$viewerPublicUrl = Get-AzdValue 'VIEWER_PUBLIC_URL'
$vaultName = Get-AzdValue 'VIEWER_KEY_VAULT_NAME'
$resourcePrefix = Get-AzdValue 'RESOURCE_PREFIX'
$redirectUri = Get-ViewerOidcRedirectUri -ViewerPublicUrl $viewerPublicUrl
if ([string]::IsNullOrWhiteSpace($ApplicationName)) {
    $ApplicationName = "$resourcePrefix-viewer"
}

$connectArguments = @{
    TenantId = $tenantId
    Scopes = @('Application.ReadWrite.All', 'User.Read')
    ContextScope = 'Process'
    NoWelcome = $true
}
if ($UseDeviceCode) {
    $connectArguments.UseDeviceCode = $true
}
Connect-MgGraph @connectArguments
$context = Get-MgContext
if ($null -eq $context -or
    $context.TenantId -ne $tenantId.ToString() -or
    $context.AuthType -ne 'Delegated' -or
    'Application.ReadWrite.All' -notin @($context.Scopes)) {
    throw 'A delegated Application.ReadWrite.All Microsoft Graph context in the selected tenant is required.'
}

function Invoke-ViewerGraph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )

    $uri = if ($Path.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        [uri]$Path
    }
    else {
        [uri]"https://graph.microsoft.com/$Path"
    }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'graph.microsoft.com') {
        throw 'Viewer OIDC Graph request resolved outside graph.microsoft.com.'
    }

    $request = @{
        Method = $Method
        Uri = $uri
        OutputType = 'Hashtable'
        Headers = @{ 'OData-Version' = '4.0' }
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
        $request.ContentType = 'application/json'
    }
    return Invoke-MgGraphRequest @request
}

$configuredClientId = Get-AzdValue 'VIEWER_CLIENT_ID' -AllowMissing
$application = $null
if (![string]::IsNullOrWhiteSpace($configuredClientId)) {
    $filter = [uri]::EscapeDataString("appId eq '$configuredClientId'")
    $result = Invoke-ViewerGraph GET "v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,passwordCredentials"
    $matches = @($result.value)
    if ($matches.Count -ne 1) {
        throw "VIEWER_CLIENT_ID '$configuredClientId' did not resolve to exactly one application."
    }
    $application = $matches[0]
}
else {
    $escapedName = $ApplicationName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $result = Invoke-ViewerGraph GET "v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,passwordCredentials"
    $matches = @($result.value)
    if ($matches.Count -gt 1) {
        throw "Multiple applications named '$ApplicationName' exist. Set VIEWER_CLIENT_ID explicitly."
    }
    if ($matches.Count -eq 1) {
        $application = $matches[0]
    }
}

if ($null -eq $application) {
    $application = Invoke-ViewerGraph POST 'v1.0/applications' @{
        displayName = $ApplicationName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @($redirectUri)
            implicitGrantSettings = @{
                enableAccessTokenIssuance = $false
                enableIdTokenIssuance = $false
            }
        }
    }
}
else {
    Invoke-ViewerGraph PATCH "v1.0/applications/$($application.id)" @{
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @($redirectUri)
            implicitGrantSettings = @{
                enableAccessTokenIssuance = $false
                enableIdTokenIssuance = $false
            }
        }
    } | Out-Null
}

$spFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipals = @((Invoke-ViewerGraph GET "v1.0/servicePrincipals?`$filter=$spFilter&`$select=id,appId").value)
if ($servicePrincipals.Count -gt 1) {
    throw "Multiple service principals exist for viewer app '$($application.appId)'."
}
if ($servicePrincipals.Count -eq 0) {
    Invoke-ViewerGraph POST 'v1.0/servicePrincipals' @{ appId = $application.appId } | Out-Null
}

if ($OperatorObjectId -eq [guid]::Empty) {
    $me = Invoke-ViewerGraph GET 'v1.0/me?$select=id'
    $OperatorObjectId = [guid]$me.id
}

$secretName = 'w365-viewer-client-secret'
$storedKeyId = (& az keyvault secret show `
    --name $secretName `
    --vault-name $vaultName `
    --query tags.entraCredentialKeyId `
    --output tsv 2>$null | Out-String).Trim()
$passwordCredentials = if ($application -is [System.Collections.IDictionary] -and
    $application.Contains('passwordCredentials')) {
    @($application.passwordCredentials)
}
else {
    @()
}
$credential = @($passwordCredentials | Where-Object {
    [string]$_.keyId -eq $storedKeyId
}) | Select-Object -First 1
$rotationRequired = $null -eq $credential -or
    [DateTimeOffset]$credential.endDateTime -le [DateTimeOffset]::UtcNow.AddDays($RotateBeforeDays)

$credentialKeyId = $storedKeyId
if ($rotationRequired) {
    $start = [DateTimeOffset]::UtcNow
    $end = $start.AddDays($CredentialLifetimeDays)
    $newCredential = $null
    try {
        $newCredential = Invoke-ViewerGraph POST "v1.0/applications/$($application.id)/addPassword" @{
            passwordCredential = @{
                displayName = 'win365-viewer-oidc'
                startDateTime = $start.ToString('o')
                endDateTime = $end.ToString('o')
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$newCredential.secretText) -or
            [string]::IsNullOrWhiteSpace([string]$newCredential.keyId)) {
            throw 'Microsoft Graph did not return the new viewer credential.'
        }

        $vaultUri = (& az keyvault show --name $vaultName --query properties.vaultUri --output tsv).Trim()
        $vaultToken = (& az account get-access-token `
            --tenant $tenantId `
            --resource https://vault.azure.net `
            --query accessToken `
            --output tsv).Trim()
        if ([string]::IsNullOrWhiteSpace($vaultUri) -or [string]::IsNullOrWhiteSpace($vaultToken)) {
            throw 'Unable to resolve Key Vault or acquire its data-plane token.'
        }

        $secretBody = @{
            value = [string]$newCredential.secretText
            contentType = 'application/x-entra-client-secret'
            attributes = @{
                enabled = $true
                exp = $end.ToUnixTimeSeconds()
            }
            tags = @{
                managedBy = 'computer-use-foundry-agent-win365'
                entraApplicationObjectId = [string]$application.id
                entraApplicationClientId = [string]$application.appId
                entraCredentialKeyId = [string]$newCredential.keyId
                entraCredentialExpiresUtc = $end.ToString('o')
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Invoke-RestMethod `
            -Method Put `
            -Uri "$($vaultUri.TrimEnd('/'))/secrets/$secretName`?api-version=7.4" `
            -Headers @{ Authorization = "Bearer $vaultToken" } `
            -ContentType 'application/json' `
            -Body $secretBody | Out-Null
        $credentialKeyId = [string]$newCredential.keyId
    }
    catch {
        if ($null -ne $newCredential -and
            ![string]::IsNullOrWhiteSpace([string]$newCredential.keyId)) {
            try {
                Invoke-ViewerGraph POST "v1.0/applications/$($application.id)/removePassword" @{
                    keyId = [string]$newCredential.keyId
                } | Out-Null
            }
            catch {
                Write-Warning "Unable to remove unstored viewer credential key '$($newCredential.keyId)'."
            }
        }
        throw
    }
    finally {
        if ($null -ne $newCredential) {
            $newCredential.secretText = $null
        }
        $secretBody = $null
        $vaultToken = $null
    }
}

$environmentValues = [ordered]@{
    VIEWER_CLIENT_ID = [string]$application.appId
    OPERATOR_TENANT_ID = $tenantId.ToString()
    OPERATOR_OBJECT_ID = $OperatorObjectId.ToString()
}
foreach ($entry in $environmentValues.GetEnumerator()) {
    & azd env set $entry.Key $entry.Value
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to persist $($entry.Key)."
    }
}

$manifestPath = Join-Path (Split-Path $PSScriptRoot) ".azure\$environmentName\viewer-ownership.json"
New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force | Out-Null
[ordered]@{
    schemaVersion = 1
    environmentName = $environmentName
    application = [ordered]@{
        objectId = [string]$application.id
        appId = [string]$application.appId
        displayName = [string]$application.displayName
        redirectUri = $redirectUri
        credentialKeyId = $credentialKeyId
    }
    operator = [ordered]@{
        tenantId = $tenantId.ToString()
        objectId = $OperatorObjectId.ToString()
    }
    updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath

Write-Host "Viewer OIDC application '$($application.appId)' is configured for $redirectUri."
Write-Host "The OIDC credential is stored as '$secretName' in Key Vault '$vaultName'."
