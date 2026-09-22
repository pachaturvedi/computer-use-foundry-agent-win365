#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Resolve-AzdUpFlag {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$DefaultValue,
        [switch]$AllowProcessValue
    )

    if ($EnvironmentValues.Contains($Name) -and
        ![string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$Name])) {
        $value = [string]$EnvironmentValues[$Name]
    }
    elseif ($AllowProcessValue -and
        ![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, 'Process'))) {
        $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    else {
        return $DefaultValue
    }

    if ($value -notin @('true', 'false')) {
        throw "Expected $Name to be true or false; received '$value'."
    }
    return $value -eq 'true'
}

function Get-AzdUpValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
        [Parameter(Mandatory)][string]$Name
    )

    if ($EnvironmentValues.Contains($Name) -and
        ![string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$Name])) {
        return [string]$EnvironmentValues[$Name]
    }

    return [string][Environment]::GetEnvironmentVariable($Name, 'Process')
}

$root = $RepositoryRoot
$resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $root 'config\deployment.defaults.json'
}
else {
    $ConfigPath
}
$config = Read-DeploymentConfigFile -Path $resolvedConfigPath
$environmentName = if (![string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
    $env:AZURE_ENV_NAME
}
else {
    '<azd-environment>'
}
$environmentValues = @{}
$environmentPath = Join-Path $root ".azure\$environmentName\.env"
if ($environmentName -ne '<azd-environment>' -and
    (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    $environmentValues = Read-AzdEnvironmentFile -Path $environmentPath
}
$resourcePrefix = [string](Get-DeploymentConfiguredValue -EnvironmentName 'RESOURCE_PREFIX' -DefaultValue $environmentName)
$resourceGroupName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_RESOURCE_GROUP' -DefaultValue "$resourcePrefix-$($config.foundry.resourceGroupSuffix)")
$generatedProjectName = "$resourcePrefix-$($config.foundry.projectNameSuffix)"
if ($generatedProjectName.Length -gt 64) {
    $generatedProjectName = $generatedProjectName.Substring(0, 64)
}
$projectName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_AI_PROJECT_NAME' -DefaultValue $generatedProjectName)
$accountName = [Environment]::GetEnvironmentVariable('AZURE_AI_ACCOUNT_NAME')
if ([string]::IsNullOrWhiteSpace($accountName)) {
    $subscriptionId = ($env:AZURE_SUBSCRIPTION_ID -replace '-', '').ToLowerInvariant()
    $subscriptionSuffix = if ($subscriptionId.Length -ge 10) {
        $subscriptionId.Substring(0, 10)
    }
    else {
        '<subscription-suffix>'
    }
    $compactPrefix = $resourcePrefix.Replace('-', '')
    $accountPrefix = $compactPrefix.Substring(0, [Math]::Min($compactPrefix.Length, 12))
    $accountName = "$accountPrefix$($config.foundry.accountNameSuffix)$subscriptionSuffix".ToLowerInvariant()
}
$modelDeploymentName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_AI_MODEL_DEPLOYMENT_NAME' -DefaultValue $config.foundry.modelDeploymentName)
$modelName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_NAME' -DefaultValue $config.foundry.modelName)
$modelVersion = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_VERSION' -DefaultValue $config.foundry.modelVersion)
$modelSkuName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_SKU_NAME' -DefaultValue $config.foundry.modelSkuName)
$modelSkuCapacity = Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_SKU_CAPACITY' -DefaultValue ([int]$config.foundry.modelSkuCapacity)
$projectOwnership = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_PROJECT_OWNERSHIP' -DefaultValue 'managed')
if ($projectOwnership -eq 'existing') {
    $requiredExistingProjectValues = @(
        'AZURE_AI_ACCOUNT_NAME',
        'AZURE_AI_PROJECT_NAME',
        'FOUNDRY_PROJECT_ENDPOINT',
        'AZURE_AI_PROJECT_ID',
        'AZD_FOUNDRY_RESOURCE_GROUP_ID',
        'AZURE_FOUNDRY_RESOURCE_GROUP'
    )
    $missingExistingProjectValues = @(
        $requiredExistingProjectValues |
            Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
    )
    if ($missingExistingProjectValues.Count -gt 0) {
        throw "Existing-project mode requires these azd environment values: $($missingExistingProjectValues -join ', ')."
    }
}
$freshManagedEnvironment = $projectOwnership -eq 'managed'
$enableW365 = Resolve-AzdUpFlag `
    -EnvironmentValues $environmentValues `
    -Name 'ENABLE_W365' `
    -DefaultValue ($freshManagedEnvironment -and [bool]$config.freshDeployment.enableW365) `
    -AllowProcessValue
$deployViewer = Resolve-AzdUpFlag `
    -EnvironmentValues $environmentValues `
    -Name 'DEPLOY_VIEWER' `
    -DefaultValue ($enableW365 -and [bool]$config.freshDeployment.deployViewer)
$deployState = Resolve-AzdUpFlag `
    -EnvironmentValues $environmentValues `
    -Name 'DEPLOY_STATE' `
    -DefaultValue $false
$w365Enabled = Resolve-AzdUpFlag `
    -EnvironmentValues $environmentValues `
    -Name 'W365_ENABLED' `
    -DefaultValue $false
if ($enableW365 -and !$w365Enabled) {
    $setupConfig = (Get-DeploymentConfig -RepositoryRoot $root -ConfigPath $resolvedConfigPath).Values
    $w365Config = if ($setupConfig.ContainsKey('w365') -and $setupConfig.w365 -is [hashtable]) {
        $setupConfig.w365
    }
    else {
        @{}
    }
    $existingPool = Get-AzdUpValue -EnvironmentValues $environmentValues -Name 'W365_POOL_ID'
    if ([string]::IsNullOrWhiteSpace($existingPool) -and $w365Config.ContainsKey('poolId')) {
        $existingPool = [string]$w365Config.poolId
    }
    if ([string]::IsNullOrWhiteSpace($existingPool) -and $w365Config.ContainsKey('poolIdOrUrl')) {
        $existingPool = [string]$w365Config.poolIdOrUrl
    }
    $billingPlanId = Get-AzdUpValue -EnvironmentValues $environmentValues -Name 'W365_POOL_BILLING_PLAN_ID'
    if ([string]::IsNullOrWhiteSpace($billingPlanId) -and $w365Config.ContainsKey('poolBillingPlanId')) {
        $billingPlanId = [string]$w365Config.poolBillingPlanId
    }
    $parsedBillingPlanId = [guid]::Empty
    if ([string]::IsNullOrWhiteSpace($existingPool) -and
        (![guid]::TryParse($billingPlanId, [ref]$parsedBillingPlanId) -or
            $parsedBillingPlanId -eq [guid]::Empty)) {
        throw @"
Fresh Windows 365 setup requires an existing pool or a tenant billing-plan GUID before Azure changes begin.
Run:
  pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 -TenantId "<tenant-guid>" -UseDeviceCode -Configure
or set:
  azd env set W365_POOL_BILLING_PLAN_ID "<billing-plan-guid>" --environment "$environmentName"
Set ENABLE_W365=false to deploy only the Foundry bootstrap.
"@
    }
}

Write-Host ''
Write-Host 'Starting azd up for this sample.'
Write-Host ''
Write-Host 'Resolved deployment defaults:'
@(
    [pscustomobject]@{ Setting = 'Environment'; Value = $environmentName }
    [pscustomobject]@{ Setting = 'Resource prefix'; Value = $resourcePrefix }
    [pscustomobject]@{ Setting = 'Resource group'; Value = $resourceGroupName }
    [pscustomobject]@{ Setting = 'Foundry account'; Value = $accountName }
    [pscustomobject]@{ Setting = 'Foundry project'; Value = $projectName }
    [pscustomobject]@{ Setting = 'Project ownership'; Value = $projectOwnership }
    [pscustomobject]@{ Setting = 'Model deployment'; Value = $modelDeploymentName }
    [pscustomobject]@{ Setting = 'Model'; Value = "$modelName ($modelVersion)" }
    [pscustomobject]@{ Setting = 'Model SKU'; Value = $modelSkuName }
    [pscustomobject]@{ Setting = 'Model capacity'; Value = "$($modelSkuCapacity)K TPM" }
    [pscustomobject]@{ Setting = 'Blob session state'; Value = $(if ($deployState) { 'Enabled' } elseif ($enableW365) { 'Enabled after Foundry identity discovery' } else { 'Disabled; credential vault still created' }) }
    [pscustomobject]@{ Setting = 'Viewer'; Value = $(if ($deployViewer) { 'Enabled after shared state is ready' } else { 'Disabled' }) }
    [pscustomobject]@{ Setting = 'Windows 365'; Value = $(if ($w365Enabled) { 'Enabled' } elseif ($enableW365) { 'Set up after bootstrap approval' } else { 'Disabled' }) }
) | Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'azd may print unlabeled "Skipped: Didn''t find new changes" rows while it checks'
Write-Host 'cached package and provisioning inputs. These rows are informational, not failures.'
Write-Host 'The labeled deployment plan below explains which sample resources will be created,'
Write-Host 'reused, or skipped and why.'
Write-Host ''
