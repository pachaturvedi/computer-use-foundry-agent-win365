#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "deployment-visibility-$([guid]::NewGuid())"
$environmentName = 'sample-dev'
$environmentDirectory = Join-Path $tempRoot ".azure\$environmentName"
$tracked = @(
    'AZURE_ENV_NAME',
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_LOCATION',
    'RESOURCE_PREFIX',
    'FOUNDRY_PROJECT_ENDPOINT',
    'AZURE_AI_PROJECT_NAME',
    'DEPLOY_STATE',
    'STATE_RESOURCE_GROUP_NAME',
    'STATE_STORAGE_ACCOUNT_NAME',
    'DEPLOY_VIEWER',
    'VIEWER_RESOURCE_GROUP_NAME',
    'VIEWER_APP_NAME',
    'W365_KEY_VAULT_NAME',
    'ENABLE_W365',
    'W365_ENABLED',
    'W365_POOL_ID',
    'SAMPLE_LOG_LEVEL'
)
$saved = @{}
foreach ($name in $tracked) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $env:AZURE_ENV_NAME = $environmentName
    $env:AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
    $env:AZURE_LOCATION = 'eastus'
    $env:RESOURCE_PREFIX = 'sample-dev'
    $env:FOUNDRY_PROJECT_ENDPOINT = 'https://foundry.example.com'
    $env:AZURE_AI_PROJECT_NAME = 'sample-project'
    $env:DEPLOY_STATE = 'true'
    $env:STATE_RESOURCE_GROUP_NAME = 'sample-dev-rg'
    $env:STATE_STORAGE_ACCOUNT_NAME = ''
    $env:DEPLOY_VIEWER = 'false'
    $env:VIEWER_RESOURCE_GROUP_NAME = 'sample-dev-rg'
    $env:VIEWER_APP_NAME = ''
    $env:W365_KEY_VAULT_NAME = ''
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $env:W365_POOL_ID = ''
    $env:SAMPLE_LOG_LEVEL = 'summary'

    $plan = & (Join-Path $root 'scripts\Show-DeploymentPlan.ps1') 6>&1 | Out-String
    if ($plan -notmatch 'Credential vault\s+Create' -or
        $plan -notmatch 'Shared state\s+Create' -or
        $plan -notmatch 'Viewer\s+Skip' -or
        $plan -notmatch 'DEPLOY_VIEWER=false') {
        throw "Deployment plan did not explain create/reuse/skip decisions: $plan"
    }

    New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'AZURE_RESOURCE_GROUP="sample-dev-rg"',
        'AZURE_AI_PROJECT_NAME="sample-project"',
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_ENDPOINT="https://agent.example.com"',
        'STATE_RESOURCE_GROUP_NAME="sample-dev-rg"',
        'W365_KEY_VAULT_NAME="sample-dev-kv"',
        'DEPLOY_STATE="true"',
        'STATE_STORAGE_ACCOUNT_NAME="samplestorage"',
        'DEPLOY_VIEWER="false"',
        'VIEWER_RESOURCE_GROUP_NAME="sample-dev-rg"',
        'W365_ENABLED="true"',
        'W365_POOL_ID="22222222-2222-2222-2222-222222222222"'
    )
    $summary = & (Join-Path $root 'scripts\Show-DeploymentSummary.ps1') `
        -RepositoryRoot $tempRoot `
        -Environment $environmentName 6>&1 | Out-String
    if ($summary -notmatch 'sample-dev-kv' -or
        $summary -notmatch 'samplestorage' -or
        $summary -notmatch 'ACA viewer.+Skipped' -or
        $summary -match '(?i)secret-value|access-token') {
        throw "Deployment summary was incomplete or unsafe: $summary"
    }

    $foundryBicep = Get-Content -LiteralPath (Join-Path $root 'infra\foundry\main.bicep') -Raw
    $stateBicep = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.bicep') -Raw
    $viewerBicep = Get-Content -LiteralPath (Join-Path $root 'infra\viewer\main.bicep') -Raw
    $planScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Show-DeploymentPlan.ps1') -Raw
    $viewerDeployScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Deploy-ViewerBootstrap.ps1') -Raw
    $stateParameters = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.parameters.json') -Raw
    $viewerParameters = Get-Content -LiteralPath (Join-Path $root 'infra\viewer\main.parameters.json') -Raw
    if ($foundryBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@" -or
        $stateBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@[^']+' existing" -or
        $viewerBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@[^']+' existing" -or
        $stateBicep -match 'resource stateResourceGroup' -or
        $viewerBicep -match 'resource viewerResourceGroup' -or
        $viewerBicep -notmatch "resource existingManagedEnvironment 'Microsoft.App/managedEnvironments@[^']+' existing" -or
        $viewerBicep -notmatch 'var createManagedEnvironment = empty\(viewerManagedEnvironmentResourceId\)' -or
        $viewerBicep -notmatch 'if \(viewerEnabled && !createManagedEnvironment\)' -or
        $viewerBicep -notmatch 'createManagedEnvironment: createManagedEnvironment' -or
        $viewerBicep -notmatch 'location: createManagedEnvironment \? location : existingManagedEnvironment!\.location' -or
        $planScript -notmatch 'Assert-ViewerAzureCliPrerequisites' -or
        $viewerDeployScript -notmatch 'Assert-ViewerAzureCliPrerequisites' -or
        $stateParameters -notmatch '"resourceGroupName": \{ "value": "\$\{AZURE_RESOURCE_GROUP\}" \}' -or
        $viewerParameters -notmatch '"resourceGroupName": \{ "value": "\$\{AZURE_RESOURCE_GROUP\}" \}') {
        throw 'Infrastructure layers do not consistently reuse one AZURE_RESOURCE_GROUP.'
    }
}
finally {
    foreach ($name in $tracked) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Deployment visibility offline tests passed.'
