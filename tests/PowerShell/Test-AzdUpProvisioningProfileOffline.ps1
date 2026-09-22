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
$w365DiscoveryPath = Join-Path $tempRoot 'Mock-W365Discovery.ps1'
$viewerDiscoveryPath = Join-Path $tempRoot 'Mock-ViewerDiscovery.ps1'
$savedNonInteractive = $env:AZD_NON_INTERACTIVE
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
    Set-Content -LiteralPath $w365DiscoveryPath -Value @'
param(
    [guid]$TenantId,
    [switch]$UseDeviceCode,
    [switch]$AsJson
)
[pscustomobject]@{
    tenantId = $TenantId.ToString()
    pools = @(
        [pscustomobject]@{
            displayName = 'approved-pool'
            poolId = '22222222-2222-2222-2222-222222222222'
            billingPlanId = '33333333-3333-3333-3333-333333333333'
            billingType = 'payAsYouGo'
        }
    )
    regions = @(
        [pscustomobject]@{
            id = 'centralus'
            regionName = 'centralus'
            geographicLocationType = 'usCentral'
            regionGroup = 'usCentral'
        }
    )
    galleryImages = @(
        [pscustomobject]@{
            id = 'microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365'
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
@(
    [pscustomobject]@{
        Name = 'shared-aca'
        ResourceGroup = 'shared-rg'
        Location = 'eastus'
        ProvisioningState = 'Succeeded'
        ContainerAppCount = 2
        ResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/managedEnvironments/shared-aca'
    }
) | ConvertTo-Json -Depth 5
'@

    $env:AZD_NON_INTERACTIVE = 'true'
    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
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
        $newValues['DEPLOY_VIEWER'] -ne 'true' -or
        ![string]::IsNullOrWhiteSpace([string]$newValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'])) {
        throw 'New W365 pool and new ACA environment choices were not persisted per azd environment.'
    }

    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
        -W365DiscoveryScriptPath $w365DiscoveryPath `
        -ViewerDiscoveryScriptPath $viewerDiscoveryPath `
        -W365Mode existing `
        -PoolId '22222222-2222-2222-2222-222222222222' `
        -ViewerMode existing
    $existingValues = Read-AzdEnvironmentFile -Path $environmentPath
    if ($existingValues['W365_ONBOARDING_MODE'] -ne 'existing' -or
        $existingValues['W365_POOL_ID'] -ne '22222222-2222-2222-2222-222222222222' -or
        $existingValues['VIEWER_HOSTING_MODE'] -ne 'existing' -or
        $existingValues['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] -notmatch '/managedEnvironments/shared-aca$') {
        throw 'Existing W365 pool and ACA managed-environment choices were not persisted.'
    }

    Write-EnvironmentFile
    & $scriptPath `
        -Environment $environmentName `
        -RepositoryRoot $tempRoot `
        -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
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
            -ConfigPath (Join-Path $root 'config\deployment.defaults.json') `
            -W365DiscoveryScriptPath $w365DiscoveryPath `
            -ViewerDiscoveryScriptPath $viewerDiscoveryPath
    }
    catch {
        $blocked = $_.Exception.Message -match 'Non-interactive W365 setup requires'
    }
    if (!$blocked) {
        throw 'Non-interactive profile resolution did not require an explicit W365 pool or billing plan.'
    }

    Write-Host 'Post-bootstrap W365 and ACA provisioning-profile offline test passed.'
}
finally {
    $env:AZD_NON_INTERACTIVE = $savedNonInteractive
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
