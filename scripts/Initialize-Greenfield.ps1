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
    [switch]$EnableW365,
    [ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')]
    [string]$AgentUserPrincipalName,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')]
    [string]$AgentUserDomain,
    [switch]$DeployViewer,
    [switch]$SkipPreview,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($EnableW365) {
    throw 'Fresh greenfield initialization cannot enable W365. Deploy the disabled bootstrap first, provision shared Blob state for its discovered principal, and then run Invoke-W365SetupFlow.ps1.'
}
if (!$IsWindows) {
    throw 'This greenfield initializer is Windows-only.'
}
if (![string]::IsNullOrWhiteSpace($AgentUserDomain)) {
    $normalizedAgentUserDomain = $AgentUserDomain.Trim().TrimEnd('.').ToLowerInvariant()
    if (!$normalizedAgentUserDomain.Contains('.') -or
        [Uri]::CheckHostName($normalizedAgentUserDomain) -ne [UriHostNameType]::Dns) {
        throw "AgentUserDomain '$AgentUserDomain' is not a valid DNS domain name."
    }
    $AgentUserDomain = $normalizedAgentUserDomain
}
if (![string]::IsNullOrWhiteSpace($AgentUserPrincipalName) -and
    ![string]::IsNullOrWhiteSpace($AgentUserDomain) -and
    !$AgentUserPrincipalName.EndsWith("@$AgentUserDomain", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'AgentUserPrincipalName and AgentUserDomain must identify the same tenant domain.'
}

$root = Split-Path $PSScriptRoot
$azd = Get-Command azd -ErrorAction SilentlyContinue
if (!$azd) {
    throw 'Azure Developer CLI is required.'
}

$configScriptPath = Join-Path $PSScriptRoot 'DeploymentConfig.ps1'
. $configScriptPath
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

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
$viewerManagedEnvironmentResourceId = [string](Get-DeploymentConfiguredValue -EnvironmentName 'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID' -DefaultValue $config.viewer.managedEnvironmentResourceId)
$viewerLogAnalyticsEnabled = Get-DeploymentConfiguredValue -EnvironmentName 'VIEWER_LOG_ANALYTICS_ENABLED' -DefaultValue ([bool]$config.viewer.logAnalyticsEnabled)
$viewerClientId = [string](Get-DeploymentConfiguredValue -EnvironmentName 'VIEWER_CLIENT_ID' -DefaultValue $config.viewer.clientId)
$operatorTenantId = [string](Get-DeploymentConfiguredValue -EnvironmentName 'OPERATOR_TENANT_ID' -DefaultValue $config.viewer.operatorTenantId)
$operatorObjectId = [string](Get-DeploymentConfiguredValue -EnvironmentName 'OPERATOR_OBJECT_ID' -DefaultValue $config.viewer.operatorObjectId)
$screenShareSdkUrl = [string](Get-DeploymentConfiguredValue -EnvironmentName 'SCREENSHARE_SDK_URL' -DefaultValue $config.viewer.screenShareSdkUrl)
$screenShareFrameOrigins = [string](Get-DeploymentConfiguredValue -EnvironmentName 'SCREENSHARE_FRAME_ORIGINS' -DefaultValue $config.viewer.screenShareFrameOrigins)
$screenShareAppUrl = [string](Get-DeploymentConfiguredValue -EnvironmentName 'SCREENSHARE_APP_URL' -DefaultValue $config.viewer.screenShareAppUrl)
$blueprintCredentialMode = [string](Get-DeploymentConfiguredValue -EnvironmentName 'W365_BLUEPRINT_CREDENTIAL_MODE' -DefaultValue $config.w365.blueprintCredentialMode)
$sampleLogLevel = [string](Get-DeploymentConfiguredValue -EnvironmentName 'SAMPLE_LOG_LEVEL' -DefaultValue $config.logging.level)
if ($sampleLogLevel -notin @('summary', 'verbose', 'debug')) {
    throw "SAMPLE_LOG_LEVEL must be summary, verbose, or debug; received '$sampleLogLevel'."
}

$resourcePrefix = "$Prefix-$Environment".ToLowerInvariant()
$environmentName = $resourcePrefix
$compactPrefix = $resourcePrefix.Replace('-', '')
$accountPrefix = $compactPrefix.Substring(0, [Math]::Min($compactPrefix.Length, 12))
$subscriptionSuffix = $SubscriptionId.ToString('N').Substring(0, 10).ToLowerInvariant()

$values = [ordered]@{
    AZURE_RESOURCE_GROUP = "$resourcePrefix-$($config.foundry.resourceGroupSuffix)"
    AZURE_AI_ACCOUNT_NAME = "$accountPrefix$($config.foundry.accountNameSuffix)$subscriptionSuffix"
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
    STATE_RESOURCE_GROUP_NAME = "$resourcePrefix-$($config.foundry.resourceGroupSuffix)"
    STATE_AGENT_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000000'
    DEPLOY_VIEWER = $resolvedDeployViewer.ToString().ToLowerInvariant()
    VIEWER_LIVE_ENABLED = ([bool]$viewerLiveEnabled).ToString().ToLowerInvariant()
    VIEWER_RESOURCE_GROUP_NAME = "$resourcePrefix-$($config.foundry.resourceGroupSuffix)"
    VIEWER_IMAGE_NAME = $viewerImageName
    VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID = $viewerManagedEnvironmentResourceId
    VIEWER_LOG_ANALYTICS_ENABLED = ([bool]$viewerLogAnalyticsEnabled).ToString().ToLowerInvariant()
    VIEWER_CLIENT_ID = $viewerClientId
    OPERATOR_TENANT_ID = $operatorTenantId
    OPERATOR_OBJECT_ID = $operatorObjectId
    SCREENSHARE_SDK_URL = $screenShareSdkUrl
    SCREENSHARE_FRAME_ORIGINS = $screenShareFrameOrigins
    SCREENSHARE_APP_URL = $screenShareAppUrl
    W365_BLUEPRINT_CREDENTIAL_MODE = $blueprintCredentialMode
    SAMPLE_LOG_LEVEL = $sampleLogLevel
    ENABLE_W365 = 'false'
    W365_ENABLED = 'false'
}
if (![string]::IsNullOrWhiteSpace($AgentUserPrincipalName)) {
    $values.W365_AGENT_USER_PRINCIPAL_NAME = $AgentUserPrincipalName
}
if (![string]::IsNullOrWhiteSpace($AgentUserDomain)) {
    $values.W365_AGENT_USER_DOMAIN = $AgentUserDomain
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
    Write-Host "  W365 setup requested:   $($values.ENABLE_W365)"
    Write-Host "  Deployment log level:   $($values.SAMPLE_LOG_LEVEL)"
    if (![string]::IsNullOrWhiteSpace($values.FOUNDRY_PROJECT_ENDPOINT)) {
        Write-Host "  Existing project:       $($values.FOUNDRY_PROJECT_ENDPOINT)"
    }
    Write-Host "  Environment resources:  $($values.AZURE_RESOURCE_GROUP)"
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
    Write-Host 'Review the preview, then deploy the disabled Foundry bootstrap in stages:'
    Write-Host "  pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Environment '$environmentName' -Mode Validate"
    Write-Host "  pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Environment '$environmentName' -Mode ProvisionFoundry -ConfirmResourceChanges"
    Write-Host "  pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Environment '$environmentName' -Mode DeployAgent -ConfirmResourceChanges"
    Write-Host "  azd ai agent doctor --environment '$environmentName'"
    Write-Host 'Do not enable W365 until the deployed agent principal has shared Blob state and the phase-2 prerequisites are complete.'
    Write-Host ''
    Write-Host 'Override defaults with either:'
    Write-Host '  1. config\deployment.local.json'
    Write-Host '  2. environment variables such as AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL_VERSION'
}
finally {
    Pop-Location
}
