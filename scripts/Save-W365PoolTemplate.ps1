#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PoolIdOrUrl,
    [string]$PoolDisplayName,
    [string]$PoolDescription,
    [string]$OutputPath,
    [guid]$TenantId = [guid]::Empty,
    [switch]$UseDeviceCode,
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 2,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!$IsWindows) {
    throw 'This helper is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')

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

function Test-GraphContext {
    param(
        $Context,
        [guid]$RequiredTenantId,
        [string[]]$RequiredScopes
    )

    if ($null -eq $Context) {
        return $false
    }
    if ($RequiredTenantId -ne [guid]::Empty -and $Context.TenantId -ne $RequiredTenantId.ToString()) {
        return $false
    }
    if ($Context.AuthType -ne 'Delegated') {
        return $false
    }

    $missingScopes = @($RequiredScopes | Where-Object { $_ -notin $Context.Scopes })
    return @($missingScopes).Count -eq 0
}

function Test-IsDeviceCodeTimeoutError {
    param([Parameter(Mandatory)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    return $message -match 'Authentication timed out after 120 seconds due to inactivity'
}

function Connect-GraphWithRetries {
    param(
        [Parameter(Mandatory)][hashtable]$ConnectParameters,
        [switch]$UseDeviceCode,
        [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts
    )

    if ($UseDeviceCode) {
        Write-Host ''
        Write-Host 'Microsoft Graph sign-in is required to read the source W365 pool.'
        Write-Host 'When the device code appears, open https://login.microsoft.com/device,'
        Write-Host 'enter the displayed code, and complete sign-in within 120 seconds.'
        Write-Host 'This command waits for the authentication result.'
        Write-Host ''

        for ($attempt = 1; $attempt -le $DeviceCodeMaxAttempts; $attempt++) {
            try {
                if ($DeviceCodeMaxAttempts -gt 1) {
                    Write-Host "Starting Microsoft Graph device-code sign-in attempt $attempt of $DeviceCodeMaxAttempts..."
                }

                Connect-MgGraph @ConnectParameters
                return Get-MgContext
            }
            catch {
                if (!(Test-IsDeviceCodeTimeoutError -ErrorRecord $_) -or $attempt -eq $DeviceCodeMaxAttempts) {
                    throw
                }

                Write-Warning 'Microsoft Graph device-code sign-in timed out. Retrying with a fresh code...'
            }
        }
    }

    try {
        Connect-MgGraph @ConnectParameters
        return Get-MgContext
    }
    catch {
        $deviceCodeParameters = @{}
        foreach ($entry in $ConnectParameters.GetEnumerator()) {
            $deviceCodeParameters[$entry.Key] = $entry.Value
        }

        $deviceCodeParameters.UseDeviceCode = $true
        Connect-MgGraph @deviceCodeParameters
        return Get-MgContext
    }
}

function Graph([string]$Method, [string]$Path) {
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://graph.microsoft.com/$Path" }
    if (!([uri]$uri).Host.Equals('graph.microsoft.com')) {
        throw 'Graph request resolved to an unexpected origin.'
    }

    Invoke-MgGraphRequest -Method $Method -Uri $uri -OutputType Hashtable -Headers @{ 'OData-Version' = '4.0' }
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
        $connectParameters.UseDeviceCode = $true
    }

    try {
        $context = Connect-GraphWithRetries -ConnectParameters $connectParameters -UseDeviceCode:$UseDeviceCode -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
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
