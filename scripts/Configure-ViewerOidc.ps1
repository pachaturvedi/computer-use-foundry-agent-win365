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
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

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

function Get-ManifestValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object -or !($Object -is [System.Collections.IDictionary]) -or !$Object.Contains($Name)) {
        return $null
    }

    return $Object[$Name]
}

$environmentName = Get-AzdValue 'AZURE_ENV_NAME'
$repositoryRoot = Split-Path $PSScriptRoot
$manifestPath = Get-ViewerOwnershipManifestPath -RepositoryRoot $repositoryRoot -EnvironmentName $environmentName
$viewerManifest = Read-W365OwnershipManifest -Path $manifestPath -AllowMissing
$tenantId = [guid](Get-AzdValue 'AZURE_TENANT_ID')
$viewerPublicUrl = Get-AzdValue 'VIEWER_PUBLIC_URL'
$vaultName = Get-AzdValue 'W365_KEY_VAULT_NAME' -AllowMissing
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    $vaultName = Get-AzdValue 'VIEWER_KEY_VAULT_NAME'
}
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
    $connectArguments.InformationAction = 'Continue'
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
$applicationCreated = $false
Write-SampleVerbose -Component 'viewer-oidc' -Message 'Resolving the viewer OIDC application.'
Write-SampleDebug -Component 'viewer-oidc' -Message "Configured client ID exists: $(![string]::IsNullOrWhiteSpace($configuredClientId))."
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
    Write-SampleVerbose -Component 'viewer-oidc' -Message "Creating single-tenant application '$ApplicationName'."
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
    $applicationCreated = $true
}
else {
    Write-SampleVerbose -Component 'viewer-oidc' -Message "Reconciling application '$($application.appId)' and its exact redirect URI."
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
$servicePrincipalCreated = $false
$servicePrincipalId = ''
if ($servicePrincipals.Count -gt 1) {
    throw "Multiple service principals exist for viewer app '$($application.appId)'."
}
if ($servicePrincipals.Count -eq 0) {
    Write-SampleVerbose -Component 'viewer-oidc' -Message 'Creating the application service principal.'
    $servicePrincipal = Invoke-ViewerGraph POST 'v1.0/servicePrincipals' @{ appId = $application.appId }
    $servicePrincipalId = [string]$servicePrincipal.id
    $servicePrincipalCreated = $true
}
else {
    $servicePrincipalId = [string]$servicePrincipals[0].id
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
$credentialCreated = $false
if ($rotationRequired) {
    Write-SampleVerbose -Component 'viewer-oidc' -Message 'Creating a short-lived OIDC credential and storing it directly in Key Vault.'
    Write-SampleDebug -Component 'viewer-oidc' -Message "CredentialLifetimeDays=$CredentialLifetimeDays; RotateBeforeDays=$RotateBeforeDays."
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

        $vaultUri = (& az keyvault show --name $vaultName --query properties.vaultUri --output tsv | Out-String).Trim()
        $vaultToken = (& az account get-access-token `
            --tenant $tenantId `
            --resource https://vault.azure.net `
            --query accessToken `
            --output tsv | Out-String).Trim()
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
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try {
                Invoke-RestMethod `
                    -Method Put `
                    -Uri "$($vaultUri.TrimEnd('/'))/secrets/$secretName`?api-version=7.4" `
                    -Headers @{ Authorization = "Bearer $vaultToken" } `
                    -ContentType 'application/json' `
                    -Body $secretBody | Out-Null
                break
            }
            catch {
                if ($attempt -eq 6) {
                    throw
                }
                Write-SampleVerbose -Component 'viewer-oidc' -Message "Waiting for Key Vault RBAC propagation ($attempt/6)."
                Write-SampleDebug -Component 'viewer-oidc' -Message $_.Exception.Message
                Start-Sleep -Seconds 10
            }
        }
        $credentialKeyId = [string]$newCredential.keyId
        $credentialCreated = $true
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
else {
    Write-SampleVerbose -Component 'viewer-oidc' -Message 'Existing Key Vault-bound OIDC credential remains healthy; rotation skipped.'
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

New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force | Out-Null
if ($null -eq $viewerManifest) {
    $viewerManifest = [ordered]@{}
}
$previousApplication = Get-ManifestValue -Object $viewerManifest -Name 'application'
$previousCredential = Get-ManifestValue -Object $previousApplication -Name 'credential'
$previousServicePrincipal = Get-ManifestValue -Object $previousApplication -Name 'servicePrincipal'

$applicationDisposition = if ($applicationCreated -or
    ([string](Get-ManifestValue -Object $previousApplication -Name 'objectId') -eq [string]$application.id -and
        [string](Get-ManifestValue -Object $previousApplication -Name 'disposition') -eq 'created')) {
    'created'
}
else {
    'reused'
}
$servicePrincipalDisposition = if ($servicePrincipalCreated -or
    ([string](Get-ManifestValue -Object $previousServicePrincipal -Name 'objectId') -eq $servicePrincipalId -and
        [string](Get-ManifestValue -Object $previousServicePrincipal -Name 'disposition') -eq 'created')) {
    'created'
}
else {
    'reused'
}
$credentialDisposition = if ($credentialCreated -or
    ([string](Get-ManifestValue -Object $previousCredential -Name 'keyId') -eq $credentialKeyId -and
        [string](Get-ManifestValue -Object $previousCredential -Name 'disposition') -eq 'created')) {
    'created'
}
else {
    'reused'
}

$viewerManifest['schemaVersion'] = 1
$viewerManifest['environmentName'] = $environmentName
$viewerManifest['application'] = [ordered]@{
    objectId = [string]$application.id
    appId = [string]$application.appId
    displayName = [string]$application.displayName
    disposition = $applicationDisposition
    redirectUri = $redirectUri
    credentialKeyId = $credentialKeyId
    credential = [ordered]@{
        keyId = $credentialKeyId
        disposition = $credentialDisposition
    }
    servicePrincipal = [ordered]@{
        objectId = $servicePrincipalId
        disposition = $servicePrincipalDisposition
    }
}
$viewerManifest['operator'] = [ordered]@{
    tenantId = $tenantId.ToString()
    objectId = $OperatorObjectId.ToString()
}
$viewerManifest['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
Write-W365OwnershipManifest -Path $manifestPath -Manifest $viewerManifest

Write-Host "Viewer OIDC application '$($application.appId)' is configured for $redirectUri."
Write-Host "The OIDC credential is stored as '$secretName' in Key Vault '$vaultName'."
