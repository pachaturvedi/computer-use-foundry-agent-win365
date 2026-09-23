#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Resolve-AzdUpProvisioningProfile.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "azd-up-profile-$([guid]::NewGuid())"
$environmentName = 'sample-dev'
$environmentDirectory = Join-Path $tempRoot ".azure\$environmentName"
$environmentPath = Join-Path $environmentDirectory '.env'
$configDirectory = Join-Path $tempRoot 'config'
$configPath = Join-Path $configDirectory 'deployment.defaults.json'
$localConfigPath = Join-Path $configDirectory 'deployment.local.json'
$w365DiscoveryPath = Join-Path $tempRoot 'Mock-W365Discovery.ps1'
$viewerDiscoveryPath = Join-Path $tempRoot 'Mock-ViewerDiscovery.ps1'
$savedNonInteractive = $env:AZD_NON_INTERACTIVE
$savedMultipleDiscovery = $env:TEST_MULTIPLE_DISCOVERY
$savedRegionMismatch = $env:TEST_REGION_MISMATCH
$savedImageMismatch = $env:TEST_IMAGE_MISMATCH
$savedZeroDiscovery = $env:TEST_ZERO_DISCOVERY
. (Join-Path $root 'scripts\W365OwnershipManifest.ps1')

function Write-EnvironmentFile {
    param([string[]]$AdditionalValues)

    New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null
    $values = @(
        "AZURE_ENV_NAME=`"$environmentName`"",
        'AZURE_TENANT_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"',
        'AZURE_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"',
        'FOUNDRY_PROJECT_OWNERSHIP="managed"',
        'ENABLE_W365="true"',
        'W365_ENABLED="false"'
    ) + $AdditionalValues
    Set-Content -LiteralPath $environmentPath -Value $values
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $root 'config\deployment.defaults.json') `
        -Destination $configPath
    Set-Content -LiteralPath $w365DiscoveryPath -Value @'
param(
    [guid]$TenantId,
    [switch]$UseDeviceCode,
    [switch]$AsJson
)
$pools = @(
    [pscustomobject]@{
        displayName = 'approved-pool'
        poolId = '22222222-2222-2222-2222-222222222222'
        billingPlanId = '33333333-3333-3333-3333-333333333333'
        billingType = 'payAsYouGo'
    }
)
if ($env:TEST_MULTIPLE_DISCOVERY -eq 'true') {
    $pools += [pscustomobject]@{
        displayName = 'second-approved-pool'
        poolId = '44444444-4444-4444-4444-444444444444'
        billingPlanId = '55555555-5555-5555-5555-555555555555'
        billingType = 'payAsYouGo'
    }
}
if ($env:TEST_ZERO_DISCOVERY -eq 'true') {
    $pools = @()
}
[pscustomobject]@{
    tenantId = $TenantId.ToString()
    pools = $pools
    regions = @(
        [pscustomobject]@{
            id = $(if ($env:TEST_REGION_MISMATCH -eq 'true') { 'westus2' } else { 'centralus' })
            regionName = $(if ($env:TEST_REGION_MISMATCH -eq 'true') { 'westus2' } else { 'centralus' })
            geographicLocationType = 'usCentral'
            regionGroup = 'usCentral'
        }
    )
    galleryImages = @(
        [pscustomobject]@{
            id = $(if ($env:TEST_IMAGE_MISMATCH -eq 'true') { 'different-image' } else { 'microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365' })
            displayName = 'Windows 11 Enterprise 25H2'
        }
    )
} | ConvertTo-Json -Depth 10
'@
    Set-Content -LiteralPath $viewerDiscoveryPath -Value @'
param(
    [guid]$SubscriptionId,
    [switch]$SucceededOnly,
    [switch]$AsJson
)
$environments = @(
    [pscustomobject]@{
        Name = 'shared-aca'
        ResourceGroup = 'shared-rg'
        Location = 'eastus'
        ProvisioningState = 'Succeeded'
        ContainerAppCount = 2
        ResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/managedEnvironments/shared-aca'
    }
)
if ($env:TEST_ZERO_DISCOVERY -eq 'true') {
    $environments = @()
}
if ($env:TEST_MULTIPLE_DISCOVERY -eq 'true') {
    $environments += [pscustomobject]@{
        Name = 'second-shared-aca'
        ResourceGroup = 'second-shared-rg'
        Location = 'westus2'
        ProvisioningState = 'Succeeded'
        ContainerAppCount = 1
        ResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/second-shared-rg/providers/Microsoft.App/managedEnvironments/second-shared-aca'
    }
}
$environments | ConvertTo-Json -Depth 5
'@

    $env:AZD_NON_INTERACTIVE = 'true'
    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath $configPath `
        -W365DiscoveryScriptPath $w365DiscoveryPath `
        -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
        -W365Mode new `
        -ViewerMode new
    $newValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($newValues['W365_ONBOARDING_MODE'] -ne 'new' -or
        $newValues['W365_POOL_BILLING_PLAN_ID'] -ne '33333333-3333-3333-3333-333333333333' -or
        $newValues['W365_POOL_GEOGRAPHIC_LOCATION_TYPE'] -ne 'usCentral' -or
        $newValues['W365_POOL_REGION_GROUP'] -ne 'usCentral' -or
        $newValues['W365_POOL_REGIONS'] -ne 'centralus' -or
        $newValues['W365_POOL_IMAGE_ID'] -ne 'microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365' -or
        $newValues['VIEWER_HOSTING_MODE'] -ne 'new' -or
        $newValues['DEPLOY_VIEWER'] -ne 'false' -or
        ![string]::IsNullOrWhiteSpace([string]$newValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'])) {
        throw 'New W365 pool and pending ACA environment choices were not persisted safely per azd environment.'
    }

    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath $configPath `
        -W365DiscoveryScriptPath $w365DiscoveryPath `
        -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
        -W365Mode existing `
        -PoolId '22222222-2222-2222-2222-222222222222' `
        -ViewerMode existing
    $existingValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($existingValues['W365_ONBOARDING_MODE'] -ne 'existing' -or
        $existingValues['W365_POOL_ID'] -ne '22222222-2222-2222-2222-222222222222' -or
        $existingValues['VIEWER_HOSTING_MODE'] -ne 'existing' -or
    $existingValues['DEPLOY_VIEWER'] -ne 'false' -or
    $existingValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] -notmatch '/managedEnvironments/shared-aca$') {
    throw 'Existing W365 pool and pending ACA managed-environment choices were not persisted safely.'
    }

    Set-AzdEnvironmentFileValues -Path $environmentPath -Values ([ordered]@{
        DEPLOY_VIEWER = 'true'
    })
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath $configPath `
        -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
        -ViewerOnly `
        -ViewerMode existing
    $viewerRetryValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($viewerRetryValues['DEPLOY_VIEWER'] -ne 'true' -or
        $viewerRetryValues['VIEWER_HOSTING_MODE'] -ne 'existing') {
        throw 'Viewer-only ACA quota recovery changed the phase-two-owned viewer activation state.'
    }

    $failingViewerDiscoveryPath = Join-Path $tempRoot 'Mock-ViewerDiscoveryFailure.ps1'
    Set-Content -LiteralPath $failingViewerDiscoveryPath -Value @'
param(
    [guid]$SubscriptionId,
    [switch]$SucceededOnly,
    [switch]$AsJson
)
throw 'ACA managed-environment discovery ran even though a selection was already recorded.'
'@
    $rememberedResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/managedEnvironments/shared-aca'
    Write-EnvironmentFile -AdditionalValues @(
        'W365_POOL_ID="22222222-2222-2222-2222-222222222222"',
        'VIEWER_HOSTING_MODE="existing"',
        "VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID=`"$rememberedResourceId`""
    )
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
        -W365DiscoveryScriptPath $w365DiscoveryPath `
        -ViewerDiscoveryScriptPath $failingViewerDiscoveryPath
    $rememberedValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($rememberedValues['VIEWER_HOSTING_MODE'] -ne 'existing' -or
        $rememberedValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] -ne $rememberedResourceId) {
        throw 'A recorded ACA managed-environment selection was not reused for the same azd environment.'
    }

    # A regenerated environment file loses the recorded selection. The deployed viewer must
    # supply it instead of re-prompting.
    $deployedResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/deployed-rg/providers/Microsoft.App/managedEnvironments/deployed-aca'
    $azProbePath = Join-Path $tempRoot 'az-calls.txt'
    $env:TEST_AZ_DEPLOYED_ENVIRONMENT_ID = $deployedResourceId
    $env:TEST_AZ_CALLS_PATH = $azProbePath
    Remove-Item -LiteralPath $azProbePath -ErrorAction SilentlyContinue
    function az {
        $arguments = @($args)
        $global:LASTEXITCODE = 0
        Add-Content -LiteralPath $env:TEST_AZ_CALLS_PATH -Value ($arguments -join ' ')
        if ($arguments[0] -eq 'resource' -and $arguments[1] -eq 'show') {
            return $env:TEST_AZ_DEPLOYED_ENVIRONMENT_ID
        }
        return ''
    }
    Write-EnvironmentFile -AdditionalValues @(
        'W365_POOL_ID="22222222-2222-2222-2222-222222222222"',
        'RESOURCE_PREFIX="sample-dev"',
        'AZURE_RESOURCE_GROUP="deployed-rg"',
        'VIEWER_HOSTING_MODE="existing"',
        'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID=""'
    )
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
        -W365DiscoveryScriptPath $w365DiscoveryPath `
        -ViewerDiscoveryScriptPath $failingViewerDiscoveryPath
    $recoveredValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($recoveredValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] -ne $deployedResourceId) {
        throw 'A lost ACA managed-environment selection was not recovered from the deployed viewer.'
    }
    if (!(Test-Path -LiteralPath $azProbePath) -or
        (Get-Content -LiteralPath $azProbePath -Raw) -notmatch 'sample-dev-viewer') {
        throw 'The deployed viewer was not queried to recover the managed-environment selection.'
    }
    Remove-Item -LiteralPath function:az
    $env:TEST_AZ_DEPLOYED_ENVIRONMENT_ID = $null
    $env:TEST_AZ_CALLS_PATH = $null

    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath $configPath `
        -W365Mode skip
    $skipValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($skipValues['ENABLE_W365'] -ne 'false' -or
        $skipValues['DEPLOY_VIEWER'] -ne 'false' -or
        $skipValues['W365_ONBOARDING_MODE'] -ne 'skip' -or
        $skipValues['VIEWER_HOSTING_MODE'] -ne 'skip') {
        throw 'The explicit Foundry-only choice did not disable W365 and the viewer.'
    }

    Write-EnvironmentFile
    $blocked = $false
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath
    }
    catch {
        $blocked = $_.Exception.Message -match 'Non-interactive W365 setup requires'
    }
    if (!$blocked) {
        throw 'Non-interactive profile resolution did not require an explicit W365 pool or billing plan.'
    }

    $env:TEST_MULTIPLE_DISCOVERY = 'true'
    Write-EnvironmentFile
    $beforeAmbiguousPool = Get-Content -LiteralPath $environmentPath -Raw
    $ambiguousPoolMessage = ''
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -W365Mode existing `
            -ViewerMode skip
    }
    catch {
        $ambiguousPoolMessage = $_.Exception.Message
    }
    if ($ambiguousPoolMessage -notmatch 'Multiple Windows 365 agent pools' -or
        $ambiguousPoolMessage -notmatch 'azd env set W365_POOL_ID' -or
        (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeAmbiguousPool) {
        throw 'Non-interactive profile resolution selected or persisted an ambiguous W365 pool.'
    }

    Write-EnvironmentFile
    $beforeAmbiguousBilling = Get-Content -LiteralPath $environmentPath -Raw
    $ambiguousBillingMessage = ''
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -W365Mode new `
            -ViewerMode skip
    }
    catch {
        $ambiguousBillingMessage = $_.Exception.Message
    }
    if ($ambiguousBillingMessage -notmatch 'Multiple Windows 365 billing plans' -or
        $ambiguousBillingMessage -notmatch 'azd env set W365_POOL_BILLING_PLAN_ID' -or
        (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeAmbiguousBilling) {
        throw 'Non-interactive profile resolution selected or persisted an ambiguous W365 billing plan.'
    }

    Write-EnvironmentFile -AdditionalValues @(
        'W365_POOL_ID="22222222-2222-2222-2222-222222222222"',
        'VIEWER_HOSTING_MODE="existing"',
        'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID="/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/managedEnvironments/shared-aca"'
    )
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath $configPath `
        -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
        -ViewerOnly `
        -ViewerMode existing
    $persistedViewerValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($persistedViewerValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] -notmatch '/managedEnvironments/shared-aca$') {
        throw 'Non-interactive recovery did not retain the explicitly persisted ACA managed environment.'
    }

    Write-EnvironmentFile -AdditionalValues @(
        'W365_POOL_ID="22222222-2222-2222-2222-222222222222"'
    )
    $beforeAmbiguousViewer = Get-Content -LiteralPath $environmentPath -Raw
    $ambiguousViewerMessage = ''
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -ViewerMode existing
    }
    catch {
        $ambiguousViewerMessage = $_.Exception.Message
    }
    if ($ambiguousViewerMessage -notmatch 'Multiple Azure Container Apps managed environments' -or
        $ambiguousViewerMessage -notmatch 'azd env set VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID' -or
        (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeAmbiguousViewer) {
        throw 'Non-interactive profile resolution selected or persisted an ambiguous ACA managed environment.'
    }
    $env:TEST_MULTIPLE_DISCOVERY = ''

    $env:TEST_ZERO_DISCOVERY = 'true'
    Write-EnvironmentFile
    $beforeMissingPool = Get-Content -LiteralPath $environmentPath -Raw
    $missingPoolMessage = ''
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -W365Mode existing `
            -ViewerMode skip
    }
    catch {
        $missingPoolMessage = $_.Exception.Message
    }
    if ($missingPoolMessage -notmatch 'No Windows 365 agent pools were discovered' -or
        (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeMissingPool) {
        throw "Zero-result W365 discovery did not fail without mutation: $missingPoolMessage"
    }

    Write-EnvironmentFile
    $beforeMissingViewer = Get-Content -LiteralPath $environmentPath -Raw
    $missingViewerMessage = ''
    try {
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -ViewerOnly `
            -ViewerMode existing
    }
    catch {
        $missingViewerMessage = $_.Exception.Message
    }
    if ($missingViewerMessage -notmatch 'No succeeded Azure Container Apps managed environments were discovered' -or
        (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeMissingViewer) {
        throw "Zero-result ACA discovery did not fail without mutation: $missingViewerMessage"
    }
    $env:TEST_ZERO_DISCOVERY = ''

    foreach ($mismatch in @(
        @{
            Variable = 'TEST_REGION_MISMATCH'
            Message = 'configured default W365 region'
            Override = @{ poolRegions = @('westus2') }
            ExpectedName = 'W365_POOL_REGIONS'
            ExpectedValue = 'westus2'
        },
        @{
            Variable = 'TEST_IMAGE_MISMATCH'
            Message = 'configured default W365 gallery image'
            Override = @{ poolImageId = 'different-image' }
            ExpectedName = 'W365_POOL_IMAGE_ID'
            ExpectedValue = 'different-image'
        }
    )) {
        Write-EnvironmentFile
        $beforeMismatch = Get-Content -LiteralPath $environmentPath -Raw
        [Environment]::SetEnvironmentVariable($mismatch.Variable, 'true', 'Process')
        $mismatchMessage = ''
        try {
            & $scriptPath `
                -Environment $environmentName `
                -RepositoryRoot $tempRoot `
                -ConfigPath $configPath `
                -W365DiscoveryScriptPath $w365DiscoveryPath `
                -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
                -W365Mode new `
                -ViewerMode skip
        }
        catch {
            $mismatchMessage = $_.Exception.Message
        }
        if ($mismatchMessage -notmatch $mismatch.Message -or
            $mismatchMessage -notmatch 'Get-W365DiscoveryOptions.ps1' -or
            (Get-Content -LiteralPath $environmentPath -Raw) -ne $beforeMismatch) {
            throw "Non-interactive profile resolution prompted or mutated state for $($mismatch.Variable)."
        }

        @{
            w365 = $mismatch.Override
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $localConfigPath
        & $scriptPath `
            -Environment $environmentName `
            -RepositoryRoot $tempRoot `
            -ConfigPath $configPath `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
            -W365Mode new `
            -ViewerMode skip
        $remediatedValues = Read-AzdEnvironmentFile -Path $environmentPath
        if ($remediatedValues[$mismatch.ExpectedName] -ne $mismatch.ExpectedValue) {
            throw "Saved local configuration did not remediate $($mismatch.Variable)."
        }
        Remove-Item -LiteralPath $localConfigPath -Force
        [Environment]::SetEnvironmentVariable($mismatch.Variable, '', 'Process')
    }

    Write-Host 'Post-bootstrap W365 and ACA provisioning-profile offline test passed.'
}
finally {
    $env:AZD_NON_INTERACTIVE = $savedNonInteractive
    $env:TEST_MULTIPLE_DISCOVERY = $savedMultipleDiscovery
    $env:TEST_REGION_MISMATCH = $savedRegionMismatch
    $env:TEST_IMAGE_MISMATCH = $savedImageMismatch
    $env:TEST_ZERO_DISCOVERY = $savedZeroDiscovery
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
