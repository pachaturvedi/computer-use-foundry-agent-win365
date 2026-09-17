#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [guid]$TenantId,
    [ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')][Parameter(Mandatory)][string]$AgentUserPrincipalName,
    [string]$AgentName,
    [string]$AgentVersion,
    [guid]$PoolId = [guid]::Empty,
    [string]$PoolIdOrUrl,
    [string]$PoolDisplayName,
    [string]$PoolDescription,
    [guid]$PoolBillingPlanId = [guid]::Empty,
    [ValidateSet('payAsYouGo')][string]$PoolBillingType = 'payAsYouGo',
    [string]$PoolGeographicLocationType,
    [string]$PoolRegionGroup,
    [string[]]$PoolRegions,
    [string]$PoolImageId,
    [ValidateSet('gallery', 'custom')][string]$PoolImageType = 'gallery',
    [string]$PoolOsLocale = 'en-US',
    [ValidateRange(1, 200)][int]$PoolMinimumCount = 1,
    [ValidateRange(1, 200)][int]$PoolMaximumCount = 1,
    [switch]$PoolEnableSingleSignOn,
    [guid]$HostedRuntimeIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeHostedRuntimeFederation,
    [guid]$ViewerManagedIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeViewerFederation,
    [switch]$BillingConfirmed,
    [switch]$UseDeviceCode,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$ConfirmResourceChanges,
    [switch]$SkipPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This W365 setup flow is Windows-only. Use PowerShell 7.4 or later on Windows.'
}
if (!$ConfirmResourceChanges) {
    throw 'This W365 setup flow can create or update Intune pools, Graph assignments, azd environment state, and hosted agent versions. Review the plan, then rerun with -ConfirmResourceChanges.'
}

function Invoke-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0:HH:mm:ss}] {1}' -f [DateTimeOffset]::Now, $Message)
}

function Get-AzdCommand {
    $azdPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command azd -All -ErrorAction SilentlyContinue)) {
        if ($null -ne $command -and !$azdPaths.Contains($command.Source)) {
            $azdPaths.Add($command.Source)
        }
    }
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Azure Dev CLI\azd.exe'),
        (Join-Path $env:ProgramFiles 'Azure Dev CLI\azd.exe')
    )) {
        if (![string]::IsNullOrWhiteSpace($path) -and (Test-Path $path) -and !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    $azdCandidates = $azdPaths |
        ForEach-Object {
            $versionOutput = & $_ version 2>$null
            if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'azd version\s+(\d+\.\d+\.\d+)') {
                [pscustomobject]@{ Path = $_; Version = [version]$Matches[1] }
            }
        } |
        Sort-Object Version -Descending

    return $azdCandidates | Where-Object Version -ge ([version]'1.32.0') | Select-Object -First 1
}

function Invoke-Azd {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    Write-Host ('[{0:HH:mm:ss}] [COMMAND] azd {1}' -f [DateTimeOffset]::Now, ($Arguments -join ' '))
    $output = & $Azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }

    return $output
}

function Get-AzdValue {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string]$Name
    )

    return (Invoke-Azd -Azd $Azd -Arguments @('env', 'get-value', $Name) -CaptureOutput)
}

function Resolve-TenantId {
    param([Parameter(Mandatory)]$Azd)

    if ($null -ne $TenantId -and $TenantId -ne [guid]::Empty) {
        return $TenantId
    }

    foreach ($name in @('W365_TENANT_ID', 'AZURE_TENANT_ID')) {
        $value = Get-AzdValue -Azd $Azd -Name $name
        $parsed = [guid]::Empty
        if ([guid]::TryParse($value, [ref]$parsed) -and $parsed -ne [guid]::Empty) {
            return $parsed
        }
    }

    throw 'TenantId is required when the azd environment does not already contain AZURE_TENANT_ID or W365_TENANT_ID.'
}

$root = Split-Path $PSScriptRoot
$azd = Get-AzdCommand
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}

Push-Location $root
try {
    if ($Environment) {
        Invoke-Step "Selecting azd environment '$Environment'."
        Invoke-Azd -Azd $azd -Arguments @('env', 'select', $Environment) | Out-Null
    }

    & (Join-Path $PSScriptRoot 'Test-AzdPrerequisites.ps1') -RequireLogin
    if ($LASTEXITCODE -ne 0) {
        throw 'azd prerequisite validation failed.'
    }

    $environmentName = Get-AzdValue -Azd $azd -Name 'AZURE_ENV_NAME'
    $projectEndpoint = Get-AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_ENDPOINT'
    if ([string]::IsNullOrWhiteSpace($projectEndpoint)) {
        throw 'FOUNDRY_PROJECT_ENDPOINT is empty. Deploy the Foundry bootstrap before running W365 setup.'
    }

    $resolvedAgentName = if (![string]::IsNullOrWhiteSpace($AgentName)) {
        $AgentName
    }
    else {
        $configuredAgentName = Get-AzdValue -Azd $azd -Name 'FOUNDRY_AGENT_NAME'
        if ([string]::IsNullOrWhiteSpace($configuredAgentName)) {
            'win365-desktop-agent'
        }
        else {
            $configuredAgentName
        }
    }

    $resolvedAgentVersion = if (![string]::IsNullOrWhiteSpace($AgentVersion)) {
        $AgentVersion
    }
    else {
        Get-AzdValue -Azd $azd -Name 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedAgentVersion)) {
        throw 'AGENT_WIN365_DESKTOP_AGENT_VERSION is empty. Deploy the hosted agent before running W365 setup.'
    }

    $resolvedTenantId = Resolve-TenantId -Azd $azd
    Invoke-Step "Discovering Foundry identity for agent '$resolvedAgentName' version '$resolvedAgentVersion'."
    $identityResult = @(& (Join-Path $PSScriptRoot 'Get-FoundryIdentity.ps1') `
        -ProjectEndpoint $projectEndpoint `
        -AgentName $resolvedAgentName `
        -AgentVersion $resolvedAgentVersion `
        -TenantId $resolvedTenantId)
    if ($LASTEXITCODE -ne 0) {
        throw 'Foundry identity discovery failed.'
    }
    $identity = $identityResult | Select-Object -Last 1
    if ($null -eq $identity) {
        throw 'Foundry identity discovery returned no result.'
    }
    $discoveredTenantId = [guid]::Empty
    $discoveredBlueprintId = [guid]::Empty
    $discoveredAgentIdentityId = [guid]::Empty
    if (![guid]::TryParse([string]$identity.TenantId, [ref]$discoveredTenantId) -or $discoveredTenantId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid tenant ID.'
    }
    if (![guid]::TryParse([string]$identity.BlueprintId, [ref]$discoveredBlueprintId) -or $discoveredBlueprintId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid blueprint ID.'
    }
    if (![guid]::TryParse([string]$identity.AgentIdentityId, [ref]$discoveredAgentIdentityId) -or $discoveredAgentIdentityId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid agent identity ID.'
    }

    Invoke-Step "Running W365 setup for azd environment '$environmentName'."
    $setupArguments = @{
        TenantId = $discoveredTenantId
        BlueprintId = $discoveredBlueprintId
        AgentIdentityId = $discoveredAgentIdentityId
        AgentUserPrincipalName = $AgentUserPrincipalName
        BillingConfirmed = $BillingConfirmed
        GraphClientTimeoutSeconds = $GraphClientTimeoutSeconds
        Confirm = $false
    }
    foreach ($name in @(
        'PoolId', 'PoolIdOrUrl', 'PoolDisplayName', 'PoolDescription', 'PoolBillingPlanId', 'PoolBillingType',
        'PoolGeographicLocationType', 'PoolRegionGroup', 'PoolRegions', 'PoolImageId', 'PoolImageType',
        'PoolOsLocale', 'PoolMinimumCount', 'PoolMaximumCount', 'HostedRuntimeIdentityObjectId',
        'ViewerManagedIdentityObjectId')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $setupArguments[$name] = $PSBoundParameters[$name]
        }
    }
    foreach ($switchName in @('PoolEnableSingleSignOn', 'AuthorizeHostedRuntimeFederation', 'AuthorizeViewerFederation', 'UseDeviceCode')) {
        if ($PSBoundParameters.ContainsKey($switchName) -and $PSBoundParameters[$switchName]) {
            $setupArguments[$switchName] = $true
        }
    }
    & (Join-Path $PSScriptRoot 'Setup-W365.ps1') @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'W365 setup failed.'
    }

    Invoke-Step 'Redeploying the hosted agent with the persisted W365 configuration.'
    $deployArguments = @{
        Mode = 'DeployAgent'
        Environment = $environmentName
        ConfirmResourceChanges = $true
    }
    if ($SkipPackage) {
        $deployArguments.SkipPackage = $true
    }
    & (Join-Path $PSScriptRoot 'Invoke-AzdDeployment.ps1') @deployArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Hosted agent redeployment failed.'
    }
}
finally {
    Pop-Location
}