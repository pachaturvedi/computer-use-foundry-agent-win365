#Requires -Version 7.4
<#
.SYNOPSIS
Creates or reconciles the viewer OIDC application and its managed-identity federation.

.DESCRIPTION
Configures the single-tenant web application and exact callback URI. The default
managed_identity mode reconciles a federated identity credential for the deployed
viewer UAMI. The explicit client_secret mode leaves federation untouched and
expects Set-ViewerSecrets.ps1 -OidcOnly to provision the legacy credential.

.OUTPUTS
Persists only non-secret viewer and operator identifiers plus ownership metadata.

.NOTES
Mutating Graph workflow. Existing unrelated application settings and credentials are preserved.
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ApplicationName,
    [guid]$OperatorObjectId = [guid]::Empty,
    [switch]$UseDeviceCode,
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
. (Join-Path $PSScriptRoot 'GraphSignIn.ps1')
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
    if ($LASTEXITCODE -ne 0) { throw "Unable to select azd environment '$Environment'." }
}

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name, [switch]$AllowMissing)
    $value = (& azd env get-value $Name 2>$null | Out-String).Trim().Trim('"')
    if (!$AllowMissing -and [string]::IsNullOrWhiteSpace($value)) {
        throw "The selected azd environment does not contain $Name."
    }
    return $value
}

function Invoke-ViewerGraph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    $uri = if ($Path.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        [uri]$Path
    } else { [uri]"https://graph.microsoft.com/$Path" }
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

$environmentName = Get-AzdValue 'AZURE_ENV_NAME'
$repositoryRoot = Split-Path $PSScriptRoot
$manifestPath = Get-ViewerOwnershipManifestPath -RepositoryRoot $repositoryRoot -EnvironmentName $environmentName
$tenantId = [guid](Get-AzdValue 'AZURE_TENANT_ID')
$viewerPublicUrl = Get-AzdValue 'VIEWER_PUBLIC_URL'
$oidcMode = (Get-AzdValue 'VIEWER_OIDC_CREDENTIAL_MODE' -AllowMissing)
if ([string]::IsNullOrWhiteSpace($oidcMode)) { $oidcMode = 'managed_identity' }
$oidcMode = $oidcMode.Trim().ToLowerInvariant()
if ($oidcMode -notin @('managed_identity', 'client_secret')) {
    throw 'VIEWER_OIDC_CREDENTIAL_MODE must be managed_identity or client_secret.'
}
$viewerPrincipalId = [guid]::Empty
if ($oidcMode -eq 'managed_identity' -and
    (![guid]::TryParse((Get-AzdValue 'VIEWER_IDENTITY_PRINCIPAL_ID'), [ref]$viewerPrincipalId) -or
    $viewerPrincipalId -eq [guid]::Empty)) {
    throw 'Viewer OIDC federation requires the deployed VIEWER_IDENTITY_PRINCIPAL_ID.'
}
$resourcePrefix = Get-AzdValue 'RESOURCE_PREFIX'
$redirectUri = Get-ViewerOidcRedirectUri -ViewerPublicUrl $viewerPublicUrl
if ([string]::IsNullOrWhiteSpace($ApplicationName)) { $ApplicationName = "$resourcePrefix-viewer" }

$connectArguments = @{
    TenantId = $tenantId
    Scopes = @('Application.ReadWrite.All', 'User.Read')
    ContextScope = 'Process'
    NoWelcome = $true
}
if ($UseDeviceCode) {
    Write-W365DeviceCodeGuidance -Purpose 'to configure viewer sign-in' `
        -RequiredAccess 'Application Administrator or Cloud Application Administrator, to create the viewer app registration' `
        -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
}
$context = Connect-W365GraphContext -ConnectParameters $connectArguments `
    -UseDeviceCode:$UseDeviceCode -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
if ($null -eq $context -or $context.TenantId -ne $tenantId.ToString() -or
    $context.AuthType -ne 'Delegated' -or 'Application.ReadWrite.All' -notin @($context.Scopes)) {
    throw 'A delegated Application.ReadWrite.All Microsoft Graph context in the selected tenant is required.'
}

$configuredClientId = Get-AzdValue 'VIEWER_CLIENT_ID' -AllowMissing
$application = $null
$applicationCreated = $false
if (![string]::IsNullOrWhiteSpace($configuredClientId)) {
    $filter = [uri]::EscapeDataString("appId eq '$configuredClientId'")
    $matches = @((Invoke-ViewerGraph GET "v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,web,federatedIdentityCredentials").value)
    if ($matches.Count -ne 1) { throw "VIEWER_CLIENT_ID '$configuredClientId' did not resolve to exactly one application." }
    $application = $matches[0]
}
else {
    $escapedName = $ApplicationName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $matches = @((Invoke-ViewerGraph GET "v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,web,federatedIdentityCredentials").value)
    if ($matches.Count -gt 1) { throw "Multiple applications named '$ApplicationName' exist. Set VIEWER_CLIENT_ID explicitly." }
    if ($matches.Count -eq 1) { $application = $matches[0] }
}

if ($null -eq $application) {
    $application = Invoke-ViewerGraph POST 'v1.0/applications' @{
        displayName = $ApplicationName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @($redirectUri)
            implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false }
        }
    }
    $applicationCreated = $true
}
else {
    Invoke-ViewerGraph PATCH "v1.0/applications/$($application.id)" @{
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @($redirectUri)
            implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false }
        }
    } | Out-Null
}

$spFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipals = @((Invoke-ViewerGraph GET "v1.0/servicePrincipals?`$filter=$spFilter&`$select=id,appId").value)
if ($servicePrincipals.Count -gt 1) { throw "Multiple service principals exist for viewer app '$($application.appId)'." }
$servicePrincipalCreated = $servicePrincipals.Count -eq 0
$servicePrincipalId = if ($servicePrincipalCreated) {
    [string](Invoke-ViewerGraph POST 'v1.0/servicePrincipals' @{ appId = $application.appId }).id
} else { [string]$servicePrincipals[0].id }

if ($OperatorObjectId -eq [guid]::Empty) {
    $OperatorObjectId = [guid](Invoke-ViewerGraph GET 'v1.0/me?$select=id').id
}

$ficCreated = $false
if ($oidcMode -eq 'managed_identity') {
    $ficName = "w365-viewer-$viewerPrincipalId"
    $issuer = "https://login.microsoftonline.com/$tenantId/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $ficResult = Invoke-ViewerGraph GET "v1.0/applications/$($application.id)/federatedIdentityCredentials"
    $fics = @($ficResult.value)
    $exact = @($fics | Where-Object {
        [string]$_.issuer -eq $issuer -and [string]$_.subject -eq $viewerPrincipalId.ToString() -and
        @($_.audiences) -contains $audience
    })
    $named = @($fics | Where-Object { [string]$_.name -eq $ficName })
    if ($named.Count -gt 1 -or $exact.Count -gt 1) { throw 'Viewer federation is ambiguous; refusing to modify credentials.' }
    if ($named.Count -eq 1) {
        if ($exact.Count -ne 1 -or [string]$named[0].id -ne [string]$exact[0].id) {
            throw "Viewer federation '$ficName' conflicts with the deployed viewer identity."
        }
        $fic = $exact[0]
    }
    elseif ($exact.Count -eq 1) {
        $fic = $exact[0]
    }
    else {
        $fic = Invoke-ViewerGraph POST "v1.0/applications/$($application.id)/federatedIdentityCredentials" @{
            name = $ficName
            issuer = $issuer
            subject = $viewerPrincipalId.ToString()
            audiences = @($audience)
            description = 'Viewer UAMI secretless OIDC client assertion'
        }
        $ficCreated = $true
    }
}

$environmentValues = [ordered]@{
    VIEWER_CLIENT_ID = [string]$application.appId
    VIEWER_OIDC_CREDENTIAL_MODE = $oidcMode
    OPERATOR_TENANT_ID = $tenantId.ToString()
    OPERATOR_OBJECT_ID = $OperatorObjectId.ToString()
}
if ($oidcMode -eq 'managed_identity') {
    $environmentValues['VIEWER_FEDERATION_NAME'] = $ficName
    $environmentValues['VIEWER_FEDERATION_ISSUER'] = $issuer
    $environmentValues['VIEWER_FEDERATION_SUBJECT'] = $viewerPrincipalId.ToString()
}
foreach ($entry in $environmentValues.GetEnumerator()) {
    & azd env set $entry.Key $entry.Value
    if ($LASTEXITCODE -ne 0) { throw "Unable to persist $($entry.Key)." }
}

$manifest = Read-W365OwnershipManifest -Path $manifestPath -AllowMissing
if ($null -eq $manifest) { $manifest = [ordered]@{} }
$manifest['schemaVersion'] = 2
$manifest['environmentName'] = $environmentName
$manifest['application'] = [ordered]@{
    objectId = [string]$application.id
    appId = [string]$application.appId
    displayName = [string]$application.displayName
    disposition = if ($applicationCreated) { 'created' } else { 'reused' }
    redirectUri = $redirectUri
    servicePrincipal = [ordered]@{
        objectId = $servicePrincipalId
        disposition = if ($servicePrincipalCreated) { 'created' } else { 'reused' }
    }
}
$manifest['operator'] = [ordered]@{ tenantId = $tenantId.ToString(); objectId = $OperatorObjectId.ToString() }
$manifest['oidcCredentialMode'] = $oidcMode
if ($oidcMode -eq 'managed_identity') {
    $manifest['graph'] = [ordered]@{
        federatedIdentityCredentials = [ordered]@{
            $ficName = [ordered]@{
                id = [string]$fic.id
                name = $ficName
                issuer = $issuer
                subject = $viewerPrincipalId.ToString()
                audience = $audience
                disposition = if ($ficCreated) { 'created' } else { 'reused' }
            }
        }
    }
}
$manifest['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force | Out-Null
Write-W365OwnershipManifest -Path $manifestPath -Manifest $manifest

Write-Host "Viewer OIDC application '$($application.appId)' is configured for $redirectUri using '$oidcMode' mode."
