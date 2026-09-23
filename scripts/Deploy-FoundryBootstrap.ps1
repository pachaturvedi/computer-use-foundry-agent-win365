#Requires -Version 7.4
<#
.SYNOPSIS
Runs the staged Foundry bootstrap deployment workflow.

.DESCRIPTION
Initializes or selects a managed environment, provisions Foundry, publishes the disabled bootstrap agent, optionally performs approved W365 setup, and can include the viewer bootstrap.


Key inputs: Subscription, tenant, prefix, environment, deployment configuration, optional W365 pool/profile values, and explicit mutation switches.

.OUTPUTS
Deployment progress, azd environment state, ownership manifests, and hosted-agent version outputs.

.NOTES
Billable and tenant-mutating. Preview is the default unless explicitly skipped and resource changes are confirmed.
#>
[CmdletBinding()]
param(
    [guid]$SubscriptionId,
    [guid]$TenantId,
    [ValidatePattern('^[a-z][a-z0-9]{1,14}$')]
    [string]$Prefix,
    [ValidatePattern('^[a-z][a-z0-9-]{0,6}[a-z0-9]$')]
    [string]$Environment = 'dev',
    [string]$Location,
    [string]$ConfigPath,
    [ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')]
    [string]$AgentUserPrincipalName,
    [guid]$PoolId = [guid]::Empty,
    [string]$PoolIdOrUrl,
    [string]$PoolDisplayName,
    [string]$PoolDescription,
    [guid]$PoolBillingPlanId = [guid]::Empty,
    [ValidateSet('payAsYouGo')]
    [string]$PoolBillingType = 'payAsYouGo',
    [string]$PoolGeographicLocationType,
    [string]$PoolRegionGroup,
    [string[]]$PoolRegions,
    [string]$PoolImageId,
    [ValidateSet('gallery', 'custom')]
    [string]$PoolImageType = 'gallery',
    [string]$PoolOsLocale = 'en-US',
    [ValidateRange(1, 200)]
    [int]$PoolMinimumCount = 1,
    [ValidateRange(1, 200)]
    [int]$PoolMaximumCount = 1,
    [switch]$PoolEnableSingleSignOn,
    [guid]$HostedRuntimeIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeHostedRuntimeFederation,
    [guid]$ViewerManagedIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeViewerFederation,
    [switch]$BillingConfirmed,
    [switch]$UseDeviceCode,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$DeployViewer,
    [switch]$SkipPreview,
    [switch]$ConfirmResourceChanges,
    [switch]$SkipPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This deployment workflow is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

$root = Split-Path $PSScriptRoot
$configScriptPath = Join-Path $PSScriptRoot 'DeploymentConfig.ps1'
. $configScriptPath
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
$scriptBoundParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $scriptBoundParameters[$entry.Key] = $entry.Value
}

function Invoke-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0:HH:mm:ss}] {1}' -f [DateTimeOffset]::Now, $Message)
}

function Invoke-CheckedScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    & $Path @Parameters
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Path)) failed with exit code $LASTEXITCODE."
    }
}

function Invoke-OptionalW365Setup {
    param([string]$TargetEnvironment)

    $w365ArgumentNames = @(
        'AgentUserPrincipalName', 'PoolId', 'PoolIdOrUrl', 'PoolDisplayName', 'PoolDescription', 'PoolBillingPlanId',
        'PoolBillingType', 'PoolGeographicLocationType', 'PoolRegionGroup', 'PoolRegions', 'PoolImageId',
        'PoolImageType', 'PoolOsLocale', 'PoolMinimumCount', 'PoolMaximumCount', 'PoolEnableSingleSignOn',
        'HostedRuntimeIdentityObjectId', 'AuthorizeHostedRuntimeFederation', 'ViewerManagedIdentityObjectId',
        'AuthorizeViewerFederation', 'BillingConfirmed', 'UseDeviceCode', 'GraphClientTimeoutSeconds'
    )
    $setupRequested = @($w365ArgumentNames | Where-Object { $scriptBoundParameters.ContainsKey($_) }).Count -gt 0
    if (!$setupRequested) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($AgentUserPrincipalName)) {
        throw 'AgentUserPrincipalName is required when stitching W365 setup into the deployment flow.'
    }
    if (!$ConfirmResourceChanges) {
        throw 'W365 setup can create or update Intune, Entra, and hosted agent resources. Review the plan, then rerun with -ConfirmResourceChanges.'
    }
    if (!$BillingConfirmed) {
        throw 'W365 setup requires -BillingConfirmed before it can create or update an agent pool.'
    }

    Invoke-Step 'Discovering the deployed Foundry identity and completing W365 setup.'
    $w365ScriptPath = Join-Path $PSScriptRoot 'Invoke-W365SetupFlow.ps1'
    $w365Arguments = @{
        AgentUserPrincipalName = $AgentUserPrincipalName
        ConfirmResourceChanges = $true
    }
    if (![string]::IsNullOrWhiteSpace($TargetEnvironment)) {
        $w365Arguments.Environment = $TargetEnvironment
    }
    if ($scriptBoundParameters.ContainsKey('TenantId')) {
        $w365Arguments.TenantId = $TenantId
    }
    if ($SkipPackage) {
        $w365Arguments.SkipPackage = $true
    }
    foreach ($name in $w365ArgumentNames) {
        if ($name -eq 'AgentUserPrincipalName') {
            continue
        }
        if ($scriptBoundParameters.ContainsKey($name)) {
            $w365Arguments[$name] = $scriptBoundParameters[$name]
        }
    }

    Invoke-CheckedScript -Path $w365ScriptPath -Parameters $w365Arguments
}

$deploymentConfig = Get-DeploymentConfig -RepositoryRoot $root -ConfigPath $ConfigPath
$resolvedConfigPath = $deploymentConfig.Path
$config = $deploymentConfig.Values
$resolvedLocation = if ([string]::IsNullOrWhiteSpace($Location)) {
    [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_LOCATION' -DefaultValue $config.foundry.location)
}
else {
    $Location
}
$projectEndpoint = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_PROJECT_ENDPOINT' -DefaultValue $config.foundry.projectEndpoint)

$initializerPath = Join-Path $PSScriptRoot 'Initialize-Greenfield.ps1'
$deploymentPath = Join-Path $PSScriptRoot 'Invoke-AzdDeployment.ps1'
$targetEnvironment = if (![string]::IsNullOrWhiteSpace($Prefix)) {
    ("$Prefix-$Environment".ToLowerInvariant())
}
else {
    $null
}

if ([string]::IsNullOrWhiteSpace($projectEndpoint)) {
    if ($SubscriptionId -eq [guid]::Empty) {
        throw 'SubscriptionId is required when creating a new Foundry account and project.'
    }
    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        throw 'Prefix is required when creating a new Foundry account and project.'
    }

    Invoke-Step 'Configuring a new greenfield azd environment for Foundry provisioning.'
    $initializerArguments = @{
        SubscriptionId = $SubscriptionId
        Prefix = $Prefix
        Environment = $Environment
        Location = $resolvedLocation
        ConfigPath = $resolvedConfigPath
    }
    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $initializerArguments.TenantId = $TenantId
    }
    if ($DeployViewer) {
        $initializerArguments.DeployViewer = $true
    }
    if ($SkipPreview) {
        $initializerArguments.SkipPreview = $true
    }
    Invoke-CheckedScript -Path $initializerPath -Parameters $initializerArguments

    Invoke-Step 'Provisioning the new Foundry account and project.'
    $provisionArguments = @{
        Mode = 'ProvisionFoundry'
        Environment = $targetEnvironment
        ConfigPath = $resolvedConfigPath
    }
    if ($ConfirmResourceChanges) {
        $provisionArguments.ConfirmResourceChanges = $true
    }
    if ($SkipPackage) {
        $provisionArguments.SkipPackage = $true
    }
    Invoke-CheckedScript -Path $deploymentPath -Parameters $provisionArguments

    Invoke-Step 'Deploying the hosted agent into the provisioned Foundry project.'
    $deploymentArguments = @{
        Mode = 'DeployAgent'
        Environment = $targetEnvironment
        ConfigPath = $resolvedConfigPath
    }
    if ($ConfirmResourceChanges) {
        $deploymentArguments.ConfirmResourceChanges = $true
    }
    if ($SkipPackage) {
        $deploymentArguments.SkipPackage = $true
    }
    Invoke-CheckedScript -Path $deploymentPath -Parameters $deploymentArguments
    Invoke-OptionalW365Setup -TargetEnvironment $targetEnvironment
    return
}

Invoke-Step 'Using an existing Foundry project endpoint; deploying only a new hosted agent version.'
$existingArguments = @{ Mode = 'DeployAgent'; ConfigPath = $resolvedConfigPath }
if ($targetEnvironment) {
    $existingArguments.Environment = $targetEnvironment
}
if ($ConfirmResourceChanges) {
    $existingArguments.ConfirmResourceChanges = $true
}
if ($SkipPackage) {
    $existingArguments.SkipPackage = $true
}
Invoke-CheckedScript -Path $deploymentPath -Parameters $existingArguments
Invoke-OptionalW365Setup -TargetEnvironment $targetEnvironment