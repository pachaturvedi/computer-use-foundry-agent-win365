#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [guid]$TenantId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{1,14}$')]
    [string]$Prefix,
    [ValidatePattern('^[a-z][a-z0-9-]{0,6}[a-z0-9]$')]
    [string]$Environment = 'dev',
    [string]$Location,
    [switch]$DeployViewer,
    [switch]$SkipPreview,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This greenfield initializer is Windows-only.'
}

$root = Split-Path $PSScriptRoot
$azd = Get-Command azd -ErrorAction SilentlyContinue
if (!$azd) {
    throw 'Azure Developer CLI is required.'
}

$configScriptPath = Join-Path $PSScriptRoot 'DeploymentConfig.ps1'
. $configScriptPath

$deploymentConfig = Get-DeploymentConfig -RepositoryRoot $root -ConfigPath $ConfigPath
$ConfigPath = $deploymentConfig.Path
$localConfigPath = $deploymentConfig.LocalOverridePath
$config = $deploymentConfig.Values

$resolvedLocation = if ([string]::IsNullOrWhiteSpace($Location)) {
    [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_LOCATION' -DefaultValue $config.foundry.location)
}
else {
    $Location
}

$foundryProjectEndpoint = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_PROJECT_ENDPOINT' -DefaultValue $config.foundry.projectEndpoint)
$agentName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_AGENT_NAME' -DefaultValue $config.foundry.agentName)
$agentDisplayName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_AGENT_DISPLAY_NAME' -DefaultValue $config.foundry.agentDisplayName)
$agentDescription = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_AGENT_DESCRIPTION' -DefaultValue $config.foundry.agentDescription)
$modelDeploymentName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'AZURE_AI_MODEL_DEPLOYMENT_NAME' -DefaultValue $config.foundry.modelDeploymentName)
$modelName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_NAME' -DefaultValue $config.foundry.modelName)
$modelVersion = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_VERSION' -DefaultValue $config.foundry.modelVersion)
$modelSkuName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_SKU_NAME' -DefaultValue $config.foundry.modelSkuName)
$modelSkuCapacity = Get-DeploymentConfiguredValue -EnvironmentName 'FOUNDRY_MODEL_SKU_CAPACITY' -DefaultValue ([int]$config.foundry.modelSkuCapacity)
$deployState = Get-DeploymentConfiguredValue -EnvironmentName 'DEPLOY_STATE' -DefaultValue ([bool]$config.state.deploy)
$deployViewerByDefault = Get-DeploymentConfiguredValue -EnvironmentName 'DEPLOY_VIEWER' -DefaultValue ([bool]$config.viewer.deploy)
$resolvedDeployViewer = if ($DeployViewer.IsPresent) { $true } else { [bool]$deployViewerByDefault }
$viewerLiveEnabled = Get-DeploymentConfiguredValue -EnvironmentName 'VIEWER_LIVE_ENABLED' -DefaultValue ([bool]$config.viewer.liveEnabled)
$viewerImageName = [string](Get-DeploymentConfiguredValue -EnvironmentName 'VIEWER_IMAGE_NAME' -DefaultValue $config.viewer.imageName)
$screenShareAppUrl = [string](Get-DeploymentConfiguredValue -EnvironmentName 'SCREENSHARE_APP_URL' -DefaultValue $config.viewer.screenShareAppUrl)

$resourcePrefix = "$Prefix-$Environment".ToLowerInvariant()
$environmentName = $resourcePrefix
$compactPrefix = $resourcePrefix.Replace('-', '')
$hashInput = "$SubscriptionId|$resourcePrefix|$resolvedLocation"
$hashBytes = [Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($hashInput))
$suffix = [Convert]::ToHexString($hashBytes)[0..5] -join ''
$suffix = $suffix.ToLowerInvariant()

$values = [ordered]@{
    AZURE_RESOURCE_GROUP = "$resourcePrefix-$($config.foundry.resourceGroupSuffix)"
    AZURE_AI_ACCOUNT_NAME = "$compactPrefix$($config.foundry.accountNameSuffix)$suffix"
    AZURE_AI_PROJECT_NAME = "$resourcePrefix-$($config.foundry.projectNameSuffix)"
    FOUNDRY_PROJECT_ENDPOINT = $foundryProjectEndpoint
    FOUNDRY_PROJECT_OWNERSHIP = if ([string]::IsNullOrWhiteSpace($foundryProjectEndpoint)) { 'managed' } else { 'existing' }
    FOUNDRY_AGENT_NAME = $agentName
    FOUNDRY_AGENT_DISPLAY_NAME = $agentDisplayName
    FOUNDRY_AGENT_DESCRIPTION = $agentDescription
    AZURE_AI_MODEL_DEPLOYMENT_NAME = $modelDeploymentName
    FOUNDRY_MODEL_NAME = $modelName
    FOUNDRY_MODEL_VERSION = $modelVersion
    FOUNDRY_MODEL_SKU_NAME = $modelSkuName
    FOUNDRY_MODEL_SKU_CAPACITY = [string]$modelSkuCapacity
    RESOURCE_PREFIX = $resourcePrefix
    DEPLOY_STATE = $deployState.ToString().ToLowerInvariant()
    STATE_RESOURCE_GROUP_NAME = "$resourcePrefix-$($config.state.resourceGroupSuffix)"
    STATE_AGENT_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000000'
    DEPLOY_VIEWER = $resolvedDeployViewer.ToString().ToLowerInvariant()
    VIEWER_LIVE_ENABLED = ([bool]$viewerLiveEnabled).ToString().ToLowerInvariant()
    VIEWER_RESOURCE_GROUP_NAME = "$resourcePrefix-$($config.viewer.resourceGroupSuffix)"
    VIEWER_IMAGE_NAME = $viewerImageName
    SCREENSHARE_APP_URL = $screenShareAppUrl
    W365_ENABLED = 'false'
}
if ($PSBoundParameters.ContainsKey('TenantId')) {
    $values.AZURE_TENANT_ID = $TenantId
}

Push-Location $root
try {
    & $azd.Source env new $environmentName `
        --subscription $SubscriptionId `
        --location $resolvedLocation `
        --no-prompt
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create azd environment $environmentName."
    }

    foreach ($entry in $values.GetEnumerator()) {
        & $azd.Source env set $entry.Key ([string]$entry.Value)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to set azd environment value $($entry.Key)."
        }
    }

    Write-Host ''
    Write-Host "Greenfield environment '$environmentName' is configured."
    Write-Host "  Resource prefix:        $resourcePrefix"
    Write-Host "  Azure location:         $resolvedLocation"
    Write-Host "  Foundry resource group: $($values.AZURE_RESOURCE_GROUP)"
    Write-Host "  Foundry account:        $($values.AZURE_AI_ACCOUNT_NAME)"
    Write-Host "  Foundry project:        $($values.AZURE_AI_PROJECT_NAME)"
    Write-Host "  Hosted agent name:      $($values.FOUNDRY_AGENT_NAME)"
    Write-Host "  Model deployment:       $($values.AZURE_AI_MODEL_DEPLOYMENT_NAME)"
    Write-Host "  Model name/version:     $($values.FOUNDRY_MODEL_NAME) / $($values.FOUNDRY_MODEL_VERSION)"
    Write-Host "  Model SKU:              $($values.FOUNDRY_MODEL_SKU_NAME) x $($values.FOUNDRY_MODEL_SKU_CAPACITY)"
    Write-Host "  W365 bootstrap mode:    $($values.W365_ENABLED)"
    if (![string]::IsNullOrWhiteSpace($values.FOUNDRY_PROJECT_ENDPOINT)) {
        Write-Host "  Existing project:       $($values.FOUNDRY_PROJECT_ENDPOINT)"
    }
    if ($resolvedDeployViewer) {
        Write-Host "  Viewer resource group:  $($values.VIEWER_RESOURCE_GROUP_NAME)"
    }
    Write-Host "  Defaults file:          $ConfigPath"
    if (Test-Path -LiteralPath $localConfigPath) {
        Write-Host "  Local override file:    $localConfigPath"
    }

    if (!$SkipPreview) {
        $previousUserAgent = $env:AZURE_DEV_USER_AGENT
        $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
        try {
            Write-Host ''
            Write-Host 'Previewing Azure resource changes (azd provision foundry --preview --no-prompt)'
            & $azd.Source provision foundry --preview --no-prompt
            if ($LASTEXITCODE -ne 0) {
                throw 'Greenfield provisioning preview failed.'
            }
        }
        finally {
            $env:AZURE_DEV_USER_AGENT = $previousUserAgent
        }
    }

    Write-Host ''
    Write-Host 'Review the preview, then deploy everything with:'
    Write-Host '  azd up --no-prompt'
    Write-Host ''
    Write-Host 'Override defaults with either:'
    Write-Host '  1. config\deployment.local.json'
    Write-Host '  2. environment variables such as AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL_VERSION'
}
finally {
    Pop-Location
}
