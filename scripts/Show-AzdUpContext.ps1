#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$root = Split-Path $PSScriptRoot
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
    [pscustomobject]@{ Setting = 'Blob session state'; Value = $(if ($env:DEPLOY_STATE -eq 'true') { 'Enabled' } else { 'Disabled for bootstrap; credential vault still created' }) }
    [pscustomobject]@{ Setting = 'Viewer'; Value = $(if ($env:DEPLOY_VIEWER -eq 'true') { 'Enabled' } else { 'Disabled for bootstrap' }) }
    [pscustomobject]@{ Setting = 'Windows 365'; Value = $(if ($env:W365_ENABLED -eq 'true') { 'Enabled' } else { 'Disabled for bootstrap' }) }
) | Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'azd may print unlabeled "Skipped: Didn''t find new changes" rows while it checks'
Write-Host 'cached package and provisioning inputs. These rows are informational, not failures.'
Write-Host 'The labeled deployment plan below explains which sample resources will be created,'
Write-Host 'reused, or skipped and why.'
Write-Host ''
