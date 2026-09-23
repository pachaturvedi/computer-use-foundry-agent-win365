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
    $greenfieldRejected = $false
    try {
        & (Join-Path $root 'scripts\Initialize-Greenfield.ps1') `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -Prefix 'sample' `
            -EnableW365 `
            -SkipPreview
    }
    catch {
        $greenfieldRejected = $_.Exception.Message -match 'cannot enable W365'
    }
    if (!$greenfieldRejected) {
        throw 'Greenfield initialization accepted unsafe one-shot W365 enablement.'
    }

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
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="42"',
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
        $summary -notmatch 'Verify the active hosted-agent deployment' -or
        $summary -notmatch 'azd ai agent show win365-desktop-agent --environment sample-dev' -or
        $summary -notmatch 'Run the repository invoice scenario in a fresh session' -or
        $summary -notmatch [regex]::Escape('$task = Get-Content .\samples\prompts\invoice-processing-direct.txt -Raw') -or
        $summary -notmatch 'azd ai agent invoke win365-desktop-agent --environment sample-dev --version 42 --new-session --new-conversation --timeout 1200 \$task' -or
        $summary -notmatch 'Optional after the smoke test succeeds' -or
        $summary -notmatch 'azd ai agent eval generate --agent win365-desktop-agent --environment sample-dev' -or
        $summary -match '(?i)secret-value|access-token') {
        throw "Deployment summary was incomplete or unsafe: $summary"
    }

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'AZURE_RESOURCE_GROUP="sample-dev-rg"',
        'AZURE_AI_PROJECT_NAME="sample-project"',
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_ENDPOINT="https://agent.example.com"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="43"',
        'ENABLE_W365="false"',
        'DEPLOY_STATE="false"',
        'DEPLOY_VIEWER="false"',
        'W365_ENABLED="false"'
    )
    $bootstrapSummary = & (Join-Path $root 'scripts\Show-DeploymentSummary.ps1') `
        -RepositoryRoot $tempRoot `
        -Environment $environmentName 6>&1 | Out-String
    if ($bootstrapSummary -notmatch 'Verify the W365-disabled bootstrap agent' -or
        $bootstrapSummary -notmatch 'azd ai agent show win365-desktop-agent --environment sample-dev' -or
        $bootstrapSummary -notmatch 'azd env set ENABLE_W365 true --environment sample-dev' -or
        $bootstrapSummary -notmatch [regex]::Escape('azd up --environment sample-dev') -or
        $bootstrapSummary -match 'Run the repository invoice scenario') {
        throw "Foundry-only deployment summary was incomplete or misleading: $bootstrapSummary"
    }

    $foundryBicep = Get-Content -LiteralPath (Join-Path $root 'infra\foundry\main.bicep') -Raw
    $stateBicep = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.bicep') -Raw
    $keyVaultBicep = Get-Content -LiteralPath (Join-Path $root 'infra\state\keyvault.bicep') -Raw
    $viewerBicep = Get-Content -LiteralPath (Join-Path $root 'infra\viewer\main.bicep') -Raw
    $viewerFoundationBicep = Get-Content -LiteralPath (Join-Path $root 'infra\viewer-foundation.bicep') -Raw
    $viewerAppBicep = Get-Content -LiteralPath (Join-Path $root 'infra\viewer.bicep') -Raw
    $azureYaml = Get-Content -LiteralPath (Join-Path $root 'azure.yaml') -Raw
    $upContextScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Show-AzdUpContext.ps1') -Raw
    $postUpScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Complete-AzdUp.ps1') -Raw
    $phaseTwoScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Initialize-AzdUpPhaseTwo.ps1') -Raw
    $planScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Show-DeploymentPlan.ps1') -Raw
    $viewerDeployScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Deploy-ViewerBootstrap.ps1') -Raw
    $deploymentScriptPath = Join-Path $root 'scripts\Invoke-AzdDeployment.ps1'
    $deploymentScript = Get-Content -LiteralPath $deploymentScriptPath -Raw
    $initializerScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Initialize-Greenfield.ps1') -Raw
    $w365SetupFlow = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-W365SetupFlow.ps1') -Raw
    $foundryParameters = Get-Content -LiteralPath (Join-Path $root 'infra\foundry\main.parameters.json') -Raw
    $stateParameters = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.parameters.json') -Raw
    $viewerParameters = Get-Content -LiteralPath (Join-Path $root 'infra\viewer\main.parameters.json') -Raw
    $deploymentGuide = Get-Content -LiteralPath (Join-Path $root 'docs\DEPLOYMENT.md') -Raw
    $azdDownCommand = Get-Command (Join-Path $root 'scripts\Invoke-AzdDown.ps1')
    if ($azdDownCommand.Parameters.Keys -notcontains 'EnvironmentName' -or
        $azdDownCommand.Parameters.Keys -notcontains 'Purge' -or
        $azdDownCommand.Parameters.Keys -notcontains 'Force' -or
        $azdDownCommand.Parameters.Keys -contains 'ConfirmResourceChanges' -or
        $deploymentGuide -match 'Invoke-AzdDown\.ps1\s+`\r?\n\s+-Environment\s' -or
        $deploymentGuide -notmatch 'Invoke-AzdDown\.ps1\s+`\r?\n\s+-EnvironmentName\s' -or
        $deploymentGuide -notmatch '(?ms)Invoke-AzdDown\.ps1\s+`.*?-Purge\s+`.*?-Force') {
        throw 'Deployment teardown guidance does not use the exact EnvironmentName, Purge, and Force parameters.'
    }
    if ($foundryBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@" -or
        $stateBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@[^']+' existing" -or
        $viewerBicep -notmatch "resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@[^']+' existing" -or
        $stateBicep -match 'resource stateResourceGroup' -or
        $viewerBicep -match 'resource viewerResourceGroup' -or
        $viewerBicep -notmatch "resource existingManagedEnvironment 'Microsoft.App/managedEnvironments@[^']+' existing" -or
        $viewerBicep -notmatch 'var createManagedEnvironment = empty\(viewerManagedEnvironmentResourceId\)' -or
        $viewerBicep -notmatch 'if \(viewerEnabled && !createManagedEnvironment\)' -or
        $viewerBicep -notmatch 'createManagedEnvironment: createManagedEnvironment' -or
        $viewerBicep -notmatch "enableLogAnalytics: toLower\(viewerLogAnalyticsEnabled\) == 'true'" -or
        $viewerBicep -notmatch 'location: createManagedEnvironment \? location : existingManagedEnvironment!\.location' -or
        $viewerFoundationBicep -notmatch "destination: 'none'" -or
        $viewerFoundationBicep -notmatch 'createManagedEnvironment && enableLogAnalytics' -or
        $viewerAppBicep -notmatch "name: 'W365_ENABLED', value: w365Enabled \? 'true' : 'false'" -or
        $viewerAppBicep -notmatch "name: 'VIEWER_LIVE_ENABLED', value: viewerLiveEnabled \? 'true' : 'false'" -or
        $azureYaml -notmatch 'VIEWER_LIVE_ENABLED: \$\{VIEWER_LIVE_ENABLED:-false\}' -or
        $azureYaml -notmatch '(?ms)^\s{2}preup:\s+windows:.*Show-AzdUpContext\.ps1' -or
        $azureYaml -notmatch '(?ms)^\s{2}predown:\s+windows:.*Remove-W365Resources\.ps1 -UseDeviceCode -ConfirmViewerOnlyCleanup' -or
        $azureYaml -notmatch '(?ms)^\s{2}postup:\s+windows:.*Complete-AzdUp\.ps1' -or
        $upContextScript -notmatch 'Resolved deployment defaults' -or
        $upContextScript -notmatch 'Model capacity' -or
        $upContextScript -notmatch 'Enabled after Foundry identity discovery' -or
        $upContextScript -notmatch 'Non-interactive Windows 365 setup requires' -or
        $upContextScript -notmatch 'Read-DeploymentConfigFile' -or
        $upContextScript -notmatch 'Get-DeploymentConfig\s+-RepositoryRoot' -or
        $upContextScript -notmatch 'Existing-project mode requires these azd environment values' -or
        $upContextScript -notmatch '\$generatedProjectName\.Substring\(0, 64\)' -or
        $upContextScript -notmatch 'informational, not failures' -or
        $postUpScript -notmatch 'Initialize-AzdUpPhaseTwo\.ps1' -or
        $postUpScript -notmatch 'Resolve-AzdUpProvisioningProfile\.ps1' -or
        $postUpScript -notmatch 'viewerLiveActivated -or' -or
        $phaseTwoScript -notmatch 'STATE_AGENT_PRINCIPAL_ID = \$agentPrincipalId\.ToString\(\)' -or
        $phaseTwoScript -notmatch "'provision', 'state'" -or
        $phaseTwoScript -notmatch "'provision', 'viewer'" -or
        $phaseTwoScript.IndexOf("'provision', 'state'") -gt $phaseTwoScript.IndexOf("'provision', 'viewer'") -or
        $planScript -notmatch 'Assert-ViewerAzureCliPrerequisites' -or
        $viewerDeployScript -notmatch 'Assert-ViewerAzureCliPrerequisites' -or
        $viewerDeployScript -notmatch 'Waiting up to five minutes for the ACA viewer to become healthy' -or
        $viewerDeployScript -notmatch "Component 'viewer-health'" -or
        $viewerDeployScript -notmatch 'Invoke-RestMethod.+-Verbose:\$false' -or
        $viewerDeployScript -notmatch 'Get-ViewerImageBuildHash' -or
        $viewerDeployScript -notmatch 'acr repository show-tags' -or
        $viewerDeployScript -notmatch 'Reusing unchanged viewer image' -or
        $viewerDeployScript -notmatch 'base-image-refresh' -or
        $viewerDeployScript -notmatch 'build-\$\(\$buildHash\.Substring\(0, 12\)\)' -or
        $deploymentScript -notmatch '(?ms)^function Get-W365KeyVaultName \{.*?^function Assert-LiveViewerConfiguration' -or
        $foundryBicep -notmatch "var resolvedResourcePrefix = !empty\(resourcePrefix\) \? resourcePrefix : environmentName" -or
        $foundryBicep -notmatch "var accountPrefix = take\(compactResourcePrefix, 12\)" -or
        $foundryBicep -notmatch "var subscriptionSuffix = take\(replace\(subscription\(\)\.subscriptionId, '-', ''\), 10\)" -or
        $foundryBicep -notmatch "param modelSkuCapacity int = 200" -or
        $foundryBicep -match "@allowed\(\[\s*'GlobalStandard'" -or
        $stateBicep -notmatch "resourcePrefix: resolvedResourcePrefix" -or
        $keyVaultBicep -notmatch "@maxLength\(90\)" -or
        $keyVaultBicep -notmatch "var compactResourcePrefix = toLower\(replace\(resourcePrefix, '-', ''\)\)" -or
        $keyVaultBicep -notmatch "var keyVaultName = 'k\$\{take\(compactResourcePrefix, 13\)\}-kv-\$\{resourceSuffix\}'" -or
        $initializerScript -notmatch 'Substring\(0, \[Math\]::Min\(\$compactPrefix\.Length, 12\)\)' -or
        $initializerScript -notmatch 'Substring\(0, 10\)' -or
        $foundryParameters -notmatch '"accountName": \{ "value": "\$\{AZURE_AI_ACCOUNT_NAME=\}" \}' -or
        $foundryParameters -notmatch '"modelSkuCapacity": \{ "value": "\$\{FOUNDRY_MODEL_SKU_CAPACITY=200\}" \}' -or
        $stateParameters -notmatch '"resourceGroupName": \{ "value": "\$\{AZURE_RESOURCE_GROUP=\}" \}' -or
        $viewerParameters -notmatch '"resourceGroupName": \{ "value": "\$\{AZURE_RESOURCE_GROUP=\}" \}') {
        throw 'Infrastructure layers do not consistently reuse one AZURE_RESOURCE_GROUP.'
    }
    $statePreflightIndex = $w365SetupFlow.IndexOf('Assert-W365StateResourceReady')
    $secretPreflightIndex = $w365SetupFlow.IndexOf('Assert-W365BlueprintSecretReady')
    $setupMutationIndex = $w365SetupFlow.IndexOf("& (Join-Path `$PSScriptRoot 'Setup-W365.ps1') @setupArguments")
    if ($statePreflightIndex -lt 0 -or
        $secretPreflightIndex -lt 0 -or
        $setupMutationIndex -lt 0 -or
        $statePreflightIndex -gt $setupMutationIndex -or
        $secretPreflightIndex -gt $setupMutationIndex -or
        $w365SetupFlow -notmatch 'EnvironmentName\s*=\s*\$environmentName' -or
        $w365SetupFlow -notmatch '\$environmentName\s*=\s*if\s*\(!\[string\]::IsNullOrWhiteSpace\(\$Environment\)\)' -or
        $w365SetupFlow -notmatch 'AuthorizeHostedRuntimeFederation:\$AuthorizeHostedRuntimeFederation') {
        throw 'W365 setup flow does not preserve selected-environment context or complete state and federation preflight before setup mutation.'
    }

    $tokens = $null
    $parseErrors = $null
    $deploymentAst = [Management.Automation.Language.Parser]::ParseFile(
        $deploymentScriptPath,
        [ref]$tokens,
        [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Invoke-AzdDeployment.ps1 did not parse: $($parseErrors -join '; ')"
    }
    $functions = @($deploymentAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    $invokeAzdFunction = $functions | Where-Object Name -eq 'Invoke-Azd' | Select-Object -First 1
    $keyVaultFunction = $functions | Where-Object Name -eq 'Get-W365KeyVaultName' | Select-Object -First 1
    $accessCheckFunction = $functions | Where-Object Name -eq 'Assert-W365AgentKeyVaultAccessConfigured' | Select-Object -First 1
    if ($null -eq $invokeAzdFunction -or
        $null -eq $keyVaultFunction -or
        $null -eq $accessCheckFunction) {
        throw 'Deployment output or blueprint-secret helpers are missing or scoped inside another function.'
    }
    $ancestor = $keyVaultFunction.Parent
    while ($null -ne $ancestor) {
        if ($ancestor -is [Management.Automation.Language.FunctionDefinitionAst]) {
            throw 'Get-W365KeyVaultName is scoped inside another function.'
        }
        $ancestor = $ancestor.Parent
    }
    if ($deploymentScript -match [regex]::Escape('Set-W365ClientSecretForDeployment') -or
        $deploymentScript -match [regex]::Escape('$env:W365_CLIENT_SECRET =')) {
        throw 'The deployment wrapper must not inject W365_CLIENT_SECRET; the hosted agent now fetches it directly from Key Vault using its own identity.'
    }
    $accessRegression = [scriptblock]::Create(@"
function Get-AzdOptionalValue {
    param([string]`$Name)
    switch (`$Name) {
        'W365_ENABLED' { 'true' }
        'W365_BLUEPRINT_CREDENTIAL_MODE' { 'client_secret' }
        'W365_KEY_VAULT_NAME' { 'sample-w365-vault' }
        'STATE_AGENT_PRINCIPAL_ID' { '22222222-2222-2222-2222-222222222222' }
        default { '' }
    }
}
function Get-AzdValue { param([string]`$Name) '11111111-1111-1111-1111-111111111111' }
function Write-DeploymentEvent { param([string]`$Kind, [string]`$Message) }
function az {
    `$global:LASTEXITCODE = 0
    'ok'
}
`$azd = [pscustomobject]@{ Path = 'azd' }
`$environmentName = 'sample-dev'
$($keyVaultFunction.Extent.Text)
$($accessCheckFunction.Extent.Text)
Assert-W365AgentKeyVaultAccessConfigured
"@)
    & $accessRegression

    $previewRegression = [scriptblock]::Create(@"
`$script:testLogLevel = 'summary'
function Get-SampleLogLevel { `$script:testLogLevel }
function Write-DeploymentEvent {
    param([string]`$Kind, [string]`$Message)
    Write-Output "EVENT:`${Kind}:`${Message}"
}
function Invoke-TestAzd {
    param([Parameter(ValueFromRemainingArguments)][string[]]`$Arguments)
    if (`$Arguments -contains 'fail') {
        `$global:LASTEXITCODE = 1
        Write-Output 'PREVIEW-FAILURE-DETAIL'
        return
    }
    `$global:LASTEXITCODE = 0
    Write-Output 'Creating a deployment plan'
    Write-Output 'Modify : Container App : sample-viewer'
}
`$azd = [pscustomobject]@{ Path = (Get-Command Invoke-TestAzd) }
$($invokeAzdFunction.Extent.Text)

`$summaryOutput = Invoke-Azd -Arguments @('provision', 'viewer', '--preview') -DetailedOutput *>&1 | Out-String
if (`$summaryOutput -match 'Creating a deployment plan|Modify : Container App' -or
    `$summaryOutput -notmatch 'detailed resource changes are hidden in summary mode') {
    throw "Summary logging exposed or failed to explain detailed preview output: `$summaryOutput"
}

`$script:testLogLevel = 'verbose'
`$verboseOutput = Invoke-Azd -Arguments @('provision', 'viewer', '--preview') -DetailedOutput *>&1 | Out-String
if (`$verboseOutput -notmatch 'Creating a deployment plan' -or
    `$verboseOutput -notmatch 'Modify : Container App') {
    throw "Verbose logging did not show detailed preview output: `$verboseOutput"
}

`$failureOutput = & {
    try {
        Invoke-Azd -Arguments @('provision', 'viewer', '--preview', 'fail') -DetailedOutput
    }
    catch {
        Write-Output `$_.Exception.Message
    }
} *>&1 | Out-String
if (`$failureOutput -notmatch 'PREVIEW-FAILURE-DETAIL' -or
    `$failureOutput -notmatch 'failed with exit code 1') {
    throw "Failed preview did not remain visible and actionable: `$failureOutput"
}
"@)
    & $previewRegression

    $detailedPreviewCalls = [regex]::Matches(
        $deploymentScript,
        "(?ms)Invoke-Azd\s+-Arguments\s+@\('provision',\s*'(foundry|state|viewer)',\s*'--preview',\s*'--no-prompt'\)\s+-DetailedOutput")
    if ($detailedPreviewCalls.Count -ne 3) {
        throw 'Foundry, state, and viewer previews must all use log-level-controlled detailed output.'
    }

}
finally {
    foreach ($name in $tracked) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Deployment visibility offline tests passed.'
