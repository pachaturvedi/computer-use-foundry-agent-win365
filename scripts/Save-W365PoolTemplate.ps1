#Requires -Version 7.4
<#
.SYNOPSIS
Captures an existing W365 agent pool as a reusable local template.

.DESCRIPTION
Resolves a pool ID or Intune URL, reads the pool and related tenant metadata through delegated Graph, and writes non-secret creation settings to ignored deployment configuration.


Key inputs: PoolIdOrUrl and PoolDisplayName are required; description, output path, tenant, device-code, retry, and timeout options are optional.

.OUTPUTS
An updated local deployment profile containing non-secret pool settings.

.NOTES
Read-only against W365/Graph and writes only local configuration. It never adopts, clones, or mutates the source pool.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PoolIdOrUrl,
    [string]$PoolDisplayName,
    [string]$PoolDescription,
    [string]$OutputPath,
    [guid]$TenantId = [guid]::Empty,
    [switch]$UseDeviceCode,
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 3,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!$IsWindows) {
    throw 'This helper is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'GraphSignIn.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function TryParse-GuidValue {
    param([string]$Value)

    $parsed = [guid]::Empty
    if ([guid]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return [guid]::Empty
}

function Resolve-PoolId {
    param([Parameter(Mandatory)][string]$Value)

    $parsed = TryParse-GuidValue $Value
    if ($parsed -ne [guid]::Empty) {
        return $parsed
    }

    if ($Value -match 'poolId/([0-9a-fA-F-]{36})') {
        return [guid]$Matches[1]
    }

    throw 'PoolIdOrUrl must be a pool GUID or an Intune pool URL containing poolId/<guid>.'
}

function Graph([string]$Method, [string]$Path) {
    Invoke-W365GraphRequest -Method $Method -Path $Path
}

$scopes = @('CloudPC.Read.All')
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$context = Get-MgContext
if (!(Test-GraphContext -Context $context -RequiredTenantId $TenantId -RequiredScopes $scopes)) {
    $connectParameters = @{
        Scopes = $scopes
        ClientTimeout = $GraphClientTimeoutSeconds
        ContextScope = 'Process'
        NoWelcome = $true
    }
    if ($TenantId -ne [guid]::Empty) {
        $connectParameters.TenantId = $TenantId
    }

    if ($UseDeviceCode) {
        Write-W365DeviceCodeGuidance `
            -Purpose 'to read the source W365 pool' `
            -RequiredAccess 'Cloud PC Reader; no write access is used' `
            -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
    }

    try {
        $context = Connect-W365GraphContext -ConnectParameters $connectParameters -UseDeviceCode:$UseDeviceCode -FallbackToDeviceCode -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
    }
    catch {
        throw @"
Direct delegated Microsoft Graph sign-in failed.
The signed-in tenant administrator must consent to CloudPC.Read.All.
Rerun this helper with -UseDeviceCode and complete the displayed code promptly.
Azure CLI tokens are intentionally not used for Microsoft Graph discovery.

$($_.Exception.Message)
"@
    }
}

if ($context.AuthType -ne 'Delegated') {
    throw 'A delegated Graph connection is required.'
}

$missingScopes = @($scopes | Where-Object { $_ -notin $context.Scopes })
if ($missingScopes.Count -gt 0) {
    throw "Missing Graph scopes: $($missingScopes -join ', ')."
}

$resolvedPoolId = Resolve-PoolId -Value $PoolIdOrUrl
$pool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$resolvedPoolId"
if ($pool['@odata.type'] -ne '#microsoft.graph.cloudPcAgentPool') {
    throw 'Resolved object is not a Cloud PC agent pool.'
}

$regionGroups = @($pool.networkConfiguration.regionGroups)
if ($regionGroups.Count -ne 1) {
    throw 'The source pool does not expose exactly one region group.'
}
$regionGroup = $regionGroups[0]

$repositoryRoot = Split-Path $PSScriptRoot
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $repositoryRoot 'config\deployment.local.json'
}
elseif ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
}
else {
    Join-Path $repositoryRoot $OutputPath
}

$localConfig = @{}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    $localConfig = Read-DeploymentConfigFile -Path $resolvedOutputPath
}

$localConfig['w365'] = [ordered]@{
    poolDisplayName = if (![string]::IsNullOrWhiteSpace($PoolDisplayName)) { $PoolDisplayName } else { [string]$pool.displayName }
    poolDescription = if ($PSBoundParameters.ContainsKey('PoolDescription')) { $PoolDescription } else { [string]$pool.description }
    poolBillingPlanId = [string]$pool.billingConfiguration.billingPlanId
    poolBillingType = [string]$pool.billingConfiguration.billingType
    poolGeographicLocationType = [string]$pool.networkConfiguration.geographicLocationType
    poolRegionGroup = [string]$regionGroup.regionGroup
    poolRegions = @($regionGroup.regions | ForEach-Object { [string]$_ })
    poolImageId = [string]$pool.cloudPcConfiguration.imageId
    poolImageType = [string]$pool.cloudPcConfiguration.imageType
    poolOsLocale = [string]$pool.cloudPcConfiguration.osLocale
    poolMinimumCount = [int]$pool.scalingPolicy.minimumCount
    poolMaximumCount = [int]$pool.scalingPolicy.maximumCount
    poolEnableSingleSignOn = [bool]$pool.capabilities.enableSingleSignOn
    poolTemplateSourceId = $resolvedPoolId.ToString()
}

$directory = Split-Path -Parent $resolvedOutputPath
if (![string]::IsNullOrWhiteSpace($directory) -and !(Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory | Out-Null
}

$localConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutputPath

Write-Output "Saved reusable W365 pool template to $resolvedOutputPath"
Write-Output "Template source pool: $resolvedPoolId"
Write-Output "Template display name: $($localConfig.w365.poolDisplayName)"
