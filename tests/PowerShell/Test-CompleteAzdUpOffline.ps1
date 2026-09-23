#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\W365OwnershipManifest.ps1')
$scriptPath = Join-Path $repoRoot 'scripts\Complete-AzdUp.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("complete-azd-up-{0}" -f ([guid]::NewGuid()))
$environmentName = 'sample-dev'
$environmentDirectory = Join-Path $tempRoot ".azure\$environmentName"
$environmentPath = Join-Path $environmentDirectory '.env'
$w365CallsPath = Join-Path $tempRoot 'w365-calls.json'
$phaseTwoCallsPath = Join-Path $tempRoot 'phase-two-calls.json'
$viewerCallsPath = Join-Path $tempRoot 'viewer-calls.json'
$agentDeployCallsPath = Join-Path $tempRoot 'agent-deploy-calls.json'
$viewerSecretsCallsPath = Join-Path $tempRoot 'viewer-secrets-calls.json'
$viewerActivationCallsPath = Join-Path $tempRoot 'viewer-activation-calls.json'
$certificateInitializationCallsPath = Join-Path $tempRoot 'certificate-initialization-calls.json'
$certificateRegistrationCallsPath = Join-Path $tempRoot 'certificate-registration-calls.json'
$orderPath = Join-Path $tempRoot 'order.txt'
$mockW365Path = Join-Path $tempRoot 'Mock-W365Setup.ps1'
$mockPhaseTwoPath = Join-Path $tempRoot 'Mock-PhaseTwo.ps1'
$failingW365Path = Join-Path $tempRoot 'Mock-W365SetupFailure.ps1'
$failingFinalDeploymentPath = Join-Path $tempRoot 'Mock-W365FinalDeploymentFailure.ps1'
$mockViewerPath = Join-Path $tempRoot 'Mock-Viewer.ps1'
$mockAgentDeployPath = Join-Path $tempRoot 'Mock-AgentDeploy.ps1'
$failingAgentDeployPath = Join-Path $tempRoot 'Mock-AgentDeployFailure.ps1'
$mockViewerSecretsPath = Join-Path $tempRoot 'Mock-ViewerSecrets.ps1'
$failingViewerSecretsPath = Join-Path $tempRoot 'Mock-ViewerSecretsFailure.ps1'
$mockViewerActivationPath = Join-Path $tempRoot 'Mock-ViewerActivation.ps1'
$mockCertificateInitializationPath = Join-Path $tempRoot 'Mock-CertificateInitialization.ps1'
$mockCertificateRegistrationPath = Join-Path $tempRoot 'Mock-CertificateRegistration.ps1'
$mockProvisioningProfilePath = Join-Path $tempRoot 'Mock-ProvisioningProfile.ps1'

$trackedEnvironmentVariables = @(
    'ENABLE_W365',
    'W365_ENABLED',
    'W365_AGENT_USER_PRINCIPAL_NAME',
    'W365_AGENT_USER_DOMAIN',
    'W365_RESOURCE_CHANGES_CONFIRMED',
    'W365_POSTUP_IN_PROGRESS',
    'W365_AZD_UP_WRAPPER',
    'W365_AZD_UP_RUN_ID',
    'W365_AGENT_REDEPLOY_PENDING',
    'W365_AGENT_REDEPLOY_CHECK_PENDING',
    'W365_AGENT_REDEPLOY_BASELINE_VIEWER_URL',
    'W365_AGENT_REDEPLOY_BASELINE_VIEWER_LIVE_ENABLED',
    'OPERATOR_TENANT_ID',
    'OPERATOR_OBJECT_ID',
    'HOSTED_ALLOWED_USER_ID',
    'AZD_NON_INTERACTIVE',
    'AZURE_ENV_NAME',
    'AZURE_TENANT_ID',
    'FOUNDRY_PROJECT_OWNERSHIP',
    'DEPLOY_STATE',
    'STATE_AGENT_PRINCIPAL_ID',
    'W365_POOL_ID',
    'W365_AGENT_USER_ID',
    'W365_AGENT_ID',
    'W365_AGENT_OBJECT_ID',
    'W365_BLUEPRINT_ID'
    'VIEWER_PUBLIC_URL',
    'DEPLOY_VIEWER',
    'VIEWER_LIVE_ENABLED',
    'VIEWER_LIVE_CHANGES_CONFIRMED',
    'W365_KEY_VAULT_NAME',
    'VIEWER_KEY_VAULT_NAME',
    'W365_BLUEPRINT_CREDENTIAL_MODE',
    'SCREENSHARE_SDK_URL',
    'SCREENSHARE_FRAME_ORIGINS',
    'SCREENSHARE_APP_URL',
    'SAMPLE_LOG_LEVEL',
    'TEST_AZ_BEHAVIOR',
    'TEST_CERTIFICATE_INITIALIZATION_FAILURE',
    'TEST_CERTIFICATE_REGISTRATION_FAILURE',
    'TEST_AZ_ROLE_DELETE_FAILURE'
)
$savedEnvironment = @{}
foreach ($name in $trackedEnvironmentVariables) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$env:TEST_AZ_BEHAVIOR = 'success'
function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show') {
        if ($env:TEST_AZ_BEHAVIOR -eq 'fail') {
            $global:LASTEXITCODE = 1
            return ''
        }
        return '99999999-9999-9999-9999-999999999999'
    }
    if ($arguments[0] -eq 'ad' -and $arguments[1] -eq 'signed-in-user') {
        if ($env:TEST_AZ_BEHAVIOR -eq 'fail') {
            $global:LASTEXITCODE = 1
            return ''
        }
        return '88888888-8888-8888-8888-888888888888'
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
        return '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/sample-rg/providers/Microsoft.KeyVault/vaults/sample-w365-vault'
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        return ''
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'create') {
        if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'certificate-role-acquire' }
        return '/subscriptions/99999999-9999-9999-9999-999999999999/providers/Microsoft.Authorization/roleAssignments/temporary'
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'list') {
        return ''
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'delete') {
        if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'certificate-role-release' }
        if ($env:TEST_AZ_ROLE_DELETE_FAILURE -eq 'true') {
            $global:LASTEXITCODE = 1
            return ''
        }
        return
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

$global:azdEnvSetCalls = [System.Collections.Generic.List[string]]::new()
function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'set') {
        $global:azdEnvSetCalls.Add("$($arguments[2])=$($arguments[3])")
        return
    }
    throw "Unexpected azd call: $($arguments -join ' ')"
}

function Reset-Calls {
    Remove-Item -LiteralPath `
        $w365CallsPath, `
        $phaseTwoCallsPath, `
        $viewerCallsPath, `
        $agentDeployCallsPath, `
        $viewerSecretsCallsPath, `
        $viewerActivationCallsPath, `
        $certificateInitializationCallsPath, `
        $certificateRegistrationCallsPath, `
        $orderPath `
        -ErrorAction SilentlyContinue
}

function Write-TestEnvironment {
    param(
        [bool]$Complete,
        [string]$AgentUserPrincipalName,
        [string]$AgentUserDomain,
        [switch]$OmitDeploymentFlags
    )

    New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null
    $lines = @(
        "AZURE_ENV_NAME=`"$environmentName`"",
        'AZURE_TENANT_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"',
        'AZURE_SUBSCRIPTION_ID="99999999-9999-9999-9999-999999999999"',
        'RESOURCE_PREFIX="sample-dev"',
        'FOUNDRY_PROJECT_OWNERSHIP="managed"',
        'VIEWER_LIVE_ENABLED="false"',
        'W365_BLUEPRINT_CREDENTIAL_MODE="client_secret"',
        'W365_KEY_VAULT_NAME="sample-w365-vault"',
        'W365_POOL_BILLING_PLAN_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"',
        "W365_ENABLED=`"$($Complete.ToString().ToLowerInvariant())`""
    )
    if (!$OmitDeploymentFlags) {
        $lines += @(
            'DEPLOY_STATE="false"',
            'DEPLOY_VIEWER="false"'
        )
    }
    if (![string]::IsNullOrWhiteSpace($AgentUserPrincipalName)) {
        $lines += "W365_AGENT_USER_PRINCIPAL_NAME=`"$AgentUserPrincipalName`""
    }
    if (![string]::IsNullOrWhiteSpace($AgentUserDomain)) {
        $lines += "W365_AGENT_USER_DOMAIN=`"$AgentUserDomain`""
    }
    if ($Complete) {
        $lines += @(
            'W365_POOL_ID="11111111-1111-1111-1111-111111111111"',
            'W365_AGENT_USER_ID="22222222-2222-2222-2222-222222222222"',
            'W365_AGENT_ID="33333333-3333-3333-3333-333333333333"',
            'W365_AGENT_OBJECT_ID="44444444-4444-4444-4444-444444444444"',
            'W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"',
            'OPERATOR_TENANT_ID="66666666-6666-6666-6666-666666666666"',
            'OPERATOR_OBJECT_ID="77777777-7777-7777-7777-777777777777"',
            'HOSTED_ALLOWED_USER_ID="pending"'
        )
    }
    Set-Content -LiteralPath $environmentPath -Value $lines
}

function Write-CompleteManifest {
    . (Join-Path $repoRoot 'scripts\W365OwnershipManifest.ps1')
    $manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $tempRoot -EnvironmentName $environmentName
    Write-W365OwnershipManifest -Path $manifestPath -Manifest ([ordered]@{
        schemaVersion = 1
        environmentName = $environmentName
        w365 = [ordered]@{
            pool = [ordered]@{ id = '11111111-1111-1111-1111-111111111111' }
            agentUser = [ordered]@{
                id = '22222222-2222-2222-2222-222222222222'
                userPrincipalName = 'foundry-w365-sample-dev@customer.example'
            }
            assignment = [ordered]@{
                poolId = '11111111-1111-1111-1111-111111111111'
                userPrincipalId = '22222222-2222-2222-2222-222222222222'
            }
        }
        graph = [ordered]@{
            blueprint = [ordered]@{ appId = '55555555-5555-5555-5555-555555555555' }
            agent = [ordered]@{
                appId = '33333333-3333-3333-3333-333333333333'
                objectId = '44444444-4444-4444-4444-444444444444'
            }
        }
    })
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $atomicEnvironmentPath = Join-Path $tempRoot 'atomic.env'
    foreach ($transition in @(
        @{
            Name = 'initial comparison marker'
            Initial = @('KEEP="original"', 'W365_AGENT_REDEPLOY_CHECK_PENDING="false"')
            Values = @{
                W365_AGENT_REDEPLOY_CHECK_PENDING = 'true'
                W365_AGENT_REDEPLOY_BASELINE_VIEWER_URL = 'https://viewer.original.example.com'
            }
        },
        @{
            Name = 'promotion to confirmed pending'
            Initial = @(
                'KEEP="original"',
                'W365_AGENT_REDEPLOY_CHECK_PENDING="true"',
                'W365_AGENT_REDEPLOY_PENDING="false"'
            )
            Values = @{
                W365_AGENT_REDEPLOY_CHECK_PENDING = 'false'
                W365_AGENT_REDEPLOY_PENDING = 'true'
            }
        },
        @{
            Name = 'confirmed pending clearing'
            Initial = @('KEEP="original"', 'W365_AGENT_REDEPLOY_PENDING="true"')
            Values = @{ W365_AGENT_REDEPLOY_PENDING = 'false' }
        }
    )) {
        Set-Content -LiteralPath $atomicEnvironmentPath -Value $transition.Initial
        $before = Get-Content -LiteralPath $atomicEnvironmentPath -Raw
        $faultInjected = $false
        try {
            Set-AzdEnvironmentFileValues `
                -Path $atomicEnvironmentPath `
                -Values $transition.Values `
                -BeforeReplace { throw 'Simulated atomic replacement interruption.' }
        }
        catch {
            $faultInjected = $_.Exception.Message -match 'Simulated atomic replacement interruption'
        }
        if (!$faultInjected -or
            (Get-Content -LiteralPath $atomicEnvironmentPath -Raw) -ne $before) {
            throw "Atomic azd environment persistence failed during $($transition.Name)."
        }
    }
    Set-AzdEnvironmentFileValues `
        -Path $atomicEnvironmentPath `
        -Values @{ W365_AGENT_REDEPLOY_PENDING = 'false' }
    $atomicValues = Read-AzdEnvironmentFile -Path $atomicEnvironmentPath
    if ([string]$atomicValues['KEEP'] -ne 'original' -or
        [string]$atomicValues['W365_AGENT_REDEPLOY_PENDING'] -ne 'false' -or
        @(Get-ChildItem -LiteralPath $tempRoot -Filter '.atomic.env.*.tmp').Count -gt 0) {
        throw 'Atomic azd environment persistence did not preserve unrelated values or clean temporary files.'
    }

    Set-Content -LiteralPath $mockViewerPath -Value @'
param()
if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'viewer-bootstrap' }
Write-Host 'MOCK-VIEWER-BOOTSTRAP-RAN'
@{
    w365Enabled = $env:W365_ENABLED
    deployViewer = $env:DEPLOY_VIEWER
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_VIEWER_CALLS_PATH
if (![string]::IsNullOrWhiteSpace($env:TEST_VIEWER_PUBLIC_URL)) {
    $environmentPath = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$($env:AZURE_ENV_NAME)\.env"
    Add-Content -LiteralPath $environmentPath -Value "VIEWER_PUBLIC_URL=`"$($env:TEST_VIEWER_PUBLIC_URL)`""
}
'@
    Set-Content -LiteralPath $failingViewerSecretsPath -Value @'
param(
    [string]$Environment,
    [switch]$BlueprintOnly,
    [switch]$BootstrapOperatorAccess
)
throw 'Simulated viewer secret configuration failure.'
'@
    Set-Content -LiteralPath $mockPhaseTwoPath -Value @'
param(
    [string]$Environment,
    [switch]$DeployViewer,
    [switch]$FinalizeCredentialAccess
)
if ($env:TEST_ORDER_PATH) {
    Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value $(if ($FinalizeCredentialAccess) {
        'phase-two-finalize'
    } else {
        'phase-two-base'
    })
}
@{
    environment = $Environment
    deployViewer = $DeployViewer.IsPresent
    finalizeCredentialAccess = $FinalizeCredentialAccess.IsPresent
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_PHASE_TWO_CALLS_PATH
$environmentPath = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment\.env"
Add-Content -LiteralPath $environmentPath -Value @(
    'ENABLE_W365="true"',
    'DEPLOY_STATE="true"',
    'STATE_AGENT_PRINCIPAL_ID="99999999-9999-9999-9999-999999999999"',
    'W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"',
    "DEPLOY_VIEWER=`"$($DeployViewer.IsPresent.ToString().ToLowerInvariant())`""
)
'@
    Set-Content -LiteralPath $mockCertificateInitializationPath -Value @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Environment,
    [switch]$ConfirmResourceChanges,
    [psobject]$CertificateOfficerLease
)
if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'certificate-initialize' }
if ($null -eq $CertificateOfficerLease) { throw 'Certificate officer lease was not supplied.' }
if ($env:TEST_CERTIFICATE_INITIALIZATION_FAILURE -eq 'true') {
    throw 'Simulated certificate initialization failure.'
}
@{
    environment = $Environment
    confirmResourceChanges = $ConfirmResourceChanges.IsPresent
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_CERTIFICATE_INITIALIZATION_CALLS_PATH
[pscustomobject]@{
    CertificateName = 'w365-blueprint-certificate'
    VaultName = 'sample-w365-vault'
    PublicCertificateBase64 = 'cHVibGljLWNlcnRpZmljYXRl'
}
'@
    Set-Content -LiteralPath $mockCertificateRegistrationPath -Value @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [guid]$TenantId,
    [guid]$BlueprintId,
    [string]$PublicCertificateBase64,
    [switch]$ConfirmResourceChanges,
    [switch]$UseDeviceCode
)
if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'certificate-register' }
if ($env:TEST_CERTIFICATE_REGISTRATION_FAILURE -eq 'true') {
    throw 'Simulated certificate registration failure.'
}
@{
    tenantId = $TenantId.ToString()
    blueprintId = $BlueprintId.ToString()
    publicCertificateBase64 = $PublicCertificateBase64
    confirmResourceChanges = $ConfirmResourceChanges.IsPresent
    useDeviceCode = $UseDeviceCode.IsPresent
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_CERTIFICATE_REGISTRATION_CALLS_PATH
'@
    Set-Content -LiteralPath $mockAgentDeployPath -Value @'
param(
    [string]$Mode,
    [string]$Environment,
    [switch]$ConfirmResourceChanges,
    [switch]$SmokeInvoke
)
@{
    mode = $Mode
    environment = $Environment
    confirmResourceChanges = $ConfirmResourceChanges.IsPresent
    smokeInvoke = $SmokeInvoke.IsPresent
    viewerPublicUrl = $env:VIEWER_PUBLIC_URL
    recursionGuard = $env:W365_POSTUP_IN_PROGRESS
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_AGENT_DEPLOY_CALLS_PATH
'@
    Set-Content -LiteralPath $failingAgentDeployPath -Value @'
param(
    [string]$Mode,
    [string]$Environment,
    [switch]$ConfirmResourceChanges,
    [switch]$SmokeInvoke
)
throw 'Simulated hosted-agent deployment failure.'
'@
    Set-Content -LiteralPath $mockViewerSecretsPath -Value @'
param(
    [string]$Environment,
    [switch]$BlueprintOnly,
    [switch]$BootstrapOperatorAccess
)
@{
    environment = $Environment
    blueprintOnly = $BlueprintOnly.IsPresent
    bootstrapOperatorAccess = $BootstrapOperatorAccess.IsPresent
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_VIEWER_SECRETS_CALLS_PATH
'@
    Set-Content -LiteralPath $mockViewerActivationPath -Value @'
param([string]$Environment)
@{
    environment = $Environment
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_VIEWER_ACTIVATION_CALLS_PATH
$environmentPath = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment\.env"
Add-Content -LiteralPath $environmentPath -Value 'VIEWER_LIVE_ENABLED="true"'
'@
    Set-Content -LiteralPath $mockProvisioningProfilePath -Value @'
param(
    [string]$Environment,
    [string]$RepositoryRoot
)
# The approval regression exercises the interactive confirmation gate only. The real
# resolver would prompt for W365 and ACA choices and has its own suite, so this mock
# just persists choices that were already made.
$environmentPath = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment\.env"
$lines = @(Get-Content -LiteralPath $environmentPath)
foreach ($pair in @('ENABLE_W365="true"', 'VIEWER_HOSTING_MODE="new"')) {
    $key = $pair.Split('=')[0]
    $lines = @($lines | Where-Object { $_ -notmatch "^$key=" }) + $pair
}
Set-Content -LiteralPath $environmentPath -Value $lines
'@
    Set-Content -LiteralPath $mockW365Path -Value @'
param(
    [string]$Environment,
    [guid]$TenantId,
    [string]$AgentUserPrincipalName,
    [string]$AgentUserDomain,
    [switch]$BillingConfirmed,
    [switch]$ConfirmResourceChanges,
    [switch]$UseDeviceCode,
    [guid]$PoolId,
    [guid]$PoolBillingPlanId,
    [string]$PoolBillingType,
    [string]$PoolGeographicLocationType,
    [string]$PoolRegionGroup,
    [string[]]$PoolRegions,
    [string]$PoolImageId,
    [string]$PoolImageType,
    [string]$PoolOsLocale,
    [int]$PoolMinimumCount,
    [int]$PoolMaximumCount,
    [switch]$PoolEnableSingleSignOn
)
if ($env:TEST_ORDER_PATH) { Add-Content -LiteralPath $env:TEST_ORDER_PATH -Value 'w365-setup' }
@{
    environment = $Environment
    tenantId = $TenantId.ToString()
    agentUserPrincipalName = $AgentUserPrincipalName
    agentUserDomain = $AgentUserDomain
    billingConfirmed = $BillingConfirmed.IsPresent
    confirmResourceChanges = $ConfirmResourceChanges.IsPresent
    useDeviceCode = $UseDeviceCode.IsPresent
    poolBillingPlanId = $PoolBillingPlanId.ToString()
    recursionGuard = $env:W365_POSTUP_IN_PROGRESS
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_W365_CALLS_PATH

$environmentDirectory = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment"
Add-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
    "AZURE_ENV_NAME=`"$Environment`"",
    'RESOURCE_PREFIX="sample-dev"',
    'W365_ENABLED="true"',
    'W365_AGENT_USER_PRINCIPAL_NAME="foundry-w365-sample-dev@customer.example"',
    'W365_POOL_ID="11111111-1111-1111-1111-111111111111"',
    'W365_AGENT_USER_ID="22222222-2222-2222-2222-222222222222"',
    'W365_AGENT_ID="33333333-3333-3333-3333-333333333333"',
    'W365_AGENT_OBJECT_ID="44444444-4444-4444-4444-444444444444"',
    'W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"'
)
. (Join-Path $env:TEST_SOURCE_ROOT 'scripts\W365OwnershipManifest.ps1')
$manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $env:TEST_REPOSITORY_ROOT -EnvironmentName $Environment
Write-W365OwnershipManifest -Path $manifestPath -Manifest ([ordered]@{
    schemaVersion = 1
    environmentName = $Environment
    w365 = [ordered]@{
        pool = [ordered]@{ id = '11111111-1111-1111-1111-111111111111' }
        agentUser = [ordered]@{
            id = '22222222-2222-2222-2222-222222222222'
            userPrincipalName = 'foundry-w365-sample-dev@customer.example'
        }
        assignment = [ordered]@{
            poolId = '11111111-1111-1111-1111-111111111111'
            userPrincipalId = '22222222-2222-2222-2222-222222222222'
        }
    }
    graph = [ordered]@{
        blueprint = [ordered]@{ appId = '55555555-5555-5555-5555-555555555555' }
        agent = [ordered]@{
            appId = '33333333-3333-3333-3333-333333333333'
            objectId = '44444444-4444-4444-4444-444444444444'
        }
    }
})
'@
    Set-Content -LiteralPath $failingW365Path -Value @'
param(
    [string]$Environment,
    [guid]$TenantId,
    [string]$AgentUserPrincipalName,
    [string]$AgentUserDomain,
    [switch]$BillingConfirmed,
    [switch]$ConfirmResourceChanges,
    [switch]$UseDeviceCode
)
. (Join-Path $env:TEST_SOURCE_ROOT 'scripts\W365OwnershipManifest.ps1')
$manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $env:TEST_REPOSITORY_ROOT -EnvironmentName $Environment
Write-W365OwnershipManifest -Path $manifestPath -Manifest ([ordered]@{
    schemaVersion = 1
    environmentName = $Environment
    w365 = [ordered]@{ pool = [ordered]@{ id = '11111111-1111-1111-1111-111111111111'; disposition = 'created' } }
    graph = [ordered]@{}
})
throw 'Simulated W365 setup failure.'
'@
    Set-Content -LiteralPath $failingFinalDeploymentPath -Value @'
param(
    [string]$Environment,
    [guid]$TenantId,
    [string]$AgentUserPrincipalName,
    [string]$AgentUserDomain,
    [switch]$BillingConfirmed,
    [switch]$ConfirmResourceChanges,
    [switch]$UseDeviceCode
)
$environmentPath = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment\.env"
Add-Content -LiteralPath $environmentPath -Value @(
    'W365_ENABLED="true"',
    'W365_POOL_ID="11111111-1111-1111-1111-111111111111"',
    'W365_AGENT_USER_ID="22222222-2222-2222-2222-222222222222"',
    'W365_AGENT_ID="33333333-3333-3333-3333-333333333333"',
    'W365_AGENT_OBJECT_ID="44444444-4444-4444-4444-444444444444"',
    'W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"',
    'OPERATOR_TENANT_ID="66666666-6666-6666-6666-666666666666"',
    'OPERATOR_OBJECT_ID="77777777-7777-7777-7777-777777777777"',
    'HOSTED_ALLOWED_USER_ID="pending"'
)
. (Join-Path $env:TEST_SOURCE_ROOT 'scripts\W365OwnershipManifest.ps1')
$manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $env:TEST_REPOSITORY_ROOT -EnvironmentName $Environment
Write-W365OwnershipManifest -Path $manifestPath -Manifest ([ordered]@{
    schemaVersion = 1
    environmentName = $Environment
    w365 = [ordered]@{
        pool = [ordered]@{ id = '11111111-1111-1111-1111-111111111111' }
        agentUser = [ordered]@{
            id = '22222222-2222-2222-2222-222222222222'
            userPrincipalName = 'foundry-w365-sample-dev@customer.example'
        }
        assignment = [ordered]@{
            poolId = '11111111-1111-1111-1111-111111111111'
            userPrincipalId = '22222222-2222-2222-2222-222222222222'
        }
    }
    graph = [ordered]@{
        blueprint = [ordered]@{ appId = '55555555-5555-5555-5555-555555555555' }
        agent = [ordered]@{
            appId = '33333333-3333-3333-3333-333333333333'
            objectId = '44444444-4444-4444-4444-444444444444'
        }
    }
})
throw 'Hosted agent redeployment failed.'
'@

    $env:TEST_SOURCE_ROOT = $repoRoot
    $env:TEST_REPOSITORY_ROOT = $tempRoot
    $env:TEST_W365_CALLS_PATH = $w365CallsPath
    $env:TEST_PHASE_TWO_CALLS_PATH = $phaseTwoCallsPath
    $env:TEST_VIEWER_CALLS_PATH = $viewerCallsPath
    $env:TEST_AGENT_DEPLOY_CALLS_PATH = $agentDeployCallsPath
    $env:TEST_VIEWER_SECRETS_CALLS_PATH = $viewerSecretsCallsPath
    $env:TEST_VIEWER_ACTIVATION_CALLS_PATH = $viewerActivationCallsPath
    $env:TEST_CERTIFICATE_INITIALIZATION_CALLS_PATH = $certificateInitializationCallsPath
    $env:TEST_CERTIFICATE_REGISTRATION_CALLS_PATH = $certificateRegistrationCallsPath
    $env:TEST_ORDER_PATH = $orderPath
    $env:TEST_VIEWER_PUBLIC_URL = ''
    $env:AZURE_ENV_NAME = $environmentName
    $env:AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $env:W365_AGENT_USER_PRINCIPAL_NAME = ''
    $env:W365_AGENT_USER_DOMAIN = ''
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    $env:AZD_NON_INTERACTIVE = 'true'
    $env:VIEWER_LIVE_CHANGES_CONFIRMED = 'true'

    Reset-Calls
    Write-TestEnvironment -Complete:$false -OmitDeploymentFlags
    (Get-Content -LiteralPath $environmentPath) -replace
        'W365_BLUEPRINT_CREDENTIAL_MODE="client_secret"',
        'W365_BLUEPRINT_CREDENTIAL_MODE="key_vault_certificate"' |
        Set-Content -LiteralPath $environmentPath
    $env:ENABLE_W365 = ''
    $env:W365_ENABLED = 'false'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -CertificateInitializationScriptPath $mockCertificateInitializationPath `
        -CertificateRegistrationScriptPath $mockCertificateRegistrationPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath
    $certificateInitializationCall = Get-Content -LiteralPath $certificateInitializationCallsPath -Raw | ConvertFrom-Json
    $certificateRegistrationCall = Get-Content -LiteralPath $certificateRegistrationCallsPath -Raw | ConvertFrom-Json
    if ($certificateInitializationCall.environment -ne $environmentName -or
        !$certificateInitializationCall.confirmResourceChanges -or
        $certificateRegistrationCall.blueprintId -ne '55555555-5555-5555-5555-555555555555' -or
        !$certificateRegistrationCall.confirmResourceChanges -or
        !$certificateRegistrationCall.useDeviceCode) {
        throw 'Fresh certificate-mode azd up did not create/reuse and register the exact blueprint certificate.'
    }
    if (Test-Path -LiteralPath $viewerSecretsCallsPath) {
        throw 'Fresh certificate-mode azd up requested or stored a blueprint client secret.'
    }
    $certificateViewerCall = Get-Content -LiteralPath $viewerCallsPath -Raw | ConvertFrom-Json
    if ($certificateViewerCall.deployViewer -ne 'true') {
        throw 'Fresh certificate-mode azd up did not refresh DEPLOY_VIEWER before viewer bootstrap.'
    }
    $order = @(Get-Content -LiteralPath $orderPath)
    $expectedOrder = @(
        'phase-two-base',
        'certificate-role-acquire',
        'certificate-initialize',
        'certificate-register',
        'phase-two-finalize',
        'viewer-bootstrap',
        'w365-setup',
        'certificate-role-release'
    )
    for ($index = 0; $index -lt $expectedOrder.Count; $index++) {
        if ($order[$index] -ne $expectedOrder[$index]) {
            throw "Fresh certificate-mode azd up ordering was incorrect at step $index."
        }
    }
    if (@($order | Where-Object { $_ -eq 'certificate-role-release' }).Count -ne 1) {
        throw 'The temporary certificate officer lease was not released exactly once.'
    }

    foreach ($failureStage in @('initialization', 'registration')) {
        Reset-Calls
        Write-TestEnvironment -Complete:$false -OmitDeploymentFlags
        (Get-Content -LiteralPath $environmentPath) -replace
            'W365_BLUEPRINT_CREDENTIAL_MODE="client_secret"',
            'W365_BLUEPRINT_CREDENTIAL_MODE="key_vault_certificate"' |
            Set-Content -LiteralPath $environmentPath
        $env:ENABLE_W365 = ''
        $env:W365_ENABLED = 'false'
        $env:TEST_CERTIFICATE_INITIALIZATION_FAILURE = ($failureStage -eq 'initialization').ToString().ToLowerInvariant()
        $env:TEST_CERTIFICATE_REGISTRATION_FAILURE = ($failureStage -eq 'registration').ToString().ToLowerInvariant()
        $certificateFailureRejected = $false
        try {
            & $scriptPath `
                -RepositoryRoot $tempRoot `
                -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
                -CertificateInitializationScriptPath $mockCertificateInitializationPath `
                -CertificateRegistrationScriptPath $mockCertificateRegistrationPath `
                -W365SetupScriptPath $mockW365Path `
                -ViewerBootstrapScriptPath $mockViewerPath `
                -ViewerSecretsScriptPath $mockViewerSecretsPath
        }
        catch {
            $certificateFailureRejected = $true
        }
        $failureOrder = @(Get-Content -LiteralPath $orderPath)
        if (!$certificateFailureRejected -or
            'phase-two-finalize' -in $failureOrder -or
            'viewer-bootstrap' -in $failureOrder -or
            'w365-setup' -in $failureOrder -or
            'certificate-role-release' -notin $failureOrder) {
            throw "Certificate $failureStage failure did not stop and clean up before final RBAC, viewer, and W365 setup."
        }
    }
    $env:TEST_CERTIFICATE_INITIALIZATION_FAILURE = ''
    $env:TEST_CERTIFICATE_REGISTRATION_FAILURE = ''

    foreach ($roleDeleteFails in @($false, $true)) {
        Reset-Calls
        Write-TestEnvironment -Complete:$false -OmitDeploymentFlags
        (Get-Content -LiteralPath $environmentPath) -replace
            'W365_BLUEPRINT_CREDENTIAL_MODE="client_secret"',
            'W365_BLUEPRINT_CREDENTIAL_MODE="key_vault_certificate"' |
            Set-Content -LiteralPath $environmentPath
        $env:ENABLE_W365 = ''
        $env:W365_ENABLED = 'false'
        $env:TEST_AZ_ROLE_DELETE_FAILURE = $roleDeleteFails.ToString().ToLowerInvariant()
        $postCertificateError = $null
        try {
            & $scriptPath `
                -RepositoryRoot $tempRoot `
                -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
                -CertificateInitializationScriptPath $mockCertificateInitializationPath `
                -CertificateRegistrationScriptPath $mockCertificateRegistrationPath `
                -W365SetupScriptPath $failingW365Path `
                -ViewerBootstrapScriptPath $mockViewerPath `
                -ViewerSecretsScriptPath $mockViewerSecretsPath
        }
        catch {
            $postCertificateError = $_
        }
        $postCertificateOrder = @(Get-Content -LiteralPath $orderPath)
        if ($null -eq $postCertificateError) {
            throw 'Postup hid a failure that occurred after blueprint certificate provisioning.'
        }
        if ('certificate-role-release' -notin $postCertificateOrder) {
            throw 'The temporary certificate officer lease was not released after a post-certificate failure.'
        }
        $postCertificateException = $postCertificateError.Exception
        if ($roleDeleteFails) {
            if ($postCertificateException -isnot [AggregateException] -or
                @($postCertificateException.InnerExceptions |
                    Where-Object { $_.Message -match 'Simulated W365 setup failure\.' }).Count -ne 1 -or
                @($postCertificateException.InnerExceptions |
                    Where-Object { $_.Message -match 'revoke the temporary Key Vault Certificates Officer' }).Count -ne 1) {
                throw 'A post-certificate failure with a failing revocation did not retain both errors.'
            }
        }
        elseif ($postCertificateException -is [AggregateException] -or
            $postCertificateException.Message -notmatch 'Simulated W365 setup failure\.') {
            throw 'A post-certificate failure did not surface the primary error.'
        }
    }
    $env:TEST_AZ_ROLE_DELETE_FAILURE = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'false'
    $env:W365_ENABLED = 'false'
    $env:SAMPLE_LOG_LEVEL = 'verbose'
    $planOutput = & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath *>&1 | Out-String
    $env:SAMPLE_LOG_LEVEL = ''
    $planOutput = $planOutput -replace "`r", ''
    $planIndex = $planOutput.IndexOf('postup plan (runs after azd provision, before this hook exits):')
    $bootstrapIndex = $planOutput.IndexOf('MOCK-VIEWER-BOOTSTRAP-RAN')
    if ($planIndex -lt 0 -or $bootstrapIndex -lt 0 -or $planIndex -gt $bootstrapIndex) {
        throw 'The postup plan summary did not print before viewer bootstrap execution.'
    }
    if ($planOutput -notmatch '(?m)^.*1\. After the Foundry principal is known, provision shared Blob state without the optional viewer\.$' -or
        $planOutput -notmatch '(?m)^.*2\. Skip Windows 365 setup because ENABLE_W365 is not true\.$' -or
        $planOutput -notmatch '(?m)^.*3\. Skip live-viewer activation\.$' -or
        $planOutput -notmatch '(?m)^.*4\. Redeploy the same hosted-agent name after W365 setup and again if viewer activation changes its runtime configuration\.$' -or
        $planOutput -notmatch '(?m)^.*5\. Print the final deployment summary table\.$') {
        throw 'The postup plan summary did not describe every disabled step accurately.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'false'
    $env:W365_ENABLED = 'false'
    $env:SAMPLE_LOG_LEVEL = ''
    $summaryModeOutput = & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath *>&1 | Out-String
    if ($summaryModeOutput -match 'postup plan \(runs after azd provision, before this hook exits\):') {
        throw 'The postup plan summary printed in default/summary mode; it should only appear in verbose or debug mode.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false -OmitDeploymentFlags
    $env:ENABLE_W365 = ''
    $env:W365_ENABLED = 'false'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath
    $phaseTwoCall = Get-Content -LiteralPath $phaseTwoCallsPath -Raw | ConvertFrom-Json
    if ($phaseTwoCall.environment -ne $environmentName -or
        !$phaseTwoCall.deployViewer -or
        !$phaseTwoCall.finalizeCredentialAccess) {
        throw 'Fresh managed azd up did not default to phase-two state and viewer provisioning.'
    }
    if (!(Test-Path -LiteralPath $w365CallsPath) -or !(Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Fresh managed azd up did not continue through viewer bootstrap and W365 setup.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'false'
    $env:W365_ENABLED = 'false'
    & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    if (Test-Path -LiteralPath $w365CallsPath) {
        throw 'Disabled postup invoked W365 setup.'
    }
    if (!(Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Disabled W365 path did not preserve viewer bootstrap.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:W365_AGENT_USER_PRINCIPAL_NAME = 'stale@wrong.example'
    $env:W365_AGENT_USER_DOMAIN = 'wrong.example'
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $env:W365_RESOURCE_CHANGES_CONFIRMED = ''
    $approvalFailed = $false
    try {
        & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    }
    catch {
        $approvalFailed = $true
    }
    if (!$approvalFailed -or (Test-Path -LiteralPath $w365CallsPath)) {
        throw 'Noninteractive W365 postup did not fail before setup when approval was absent.'
    }

    foreach ($approvalAnswer in @('YES', 'ALWAYS', 'no')) {
        Reset-Calls
        Write-TestEnvironment -Complete:$false
        $env:ENABLE_W365 = 'true'
        $env:W365_ENABLED = 'false'
        $env:W365_RESOURCE_CHANGES_CONFIRMED = ''
        $env:AZD_NON_INTERACTIVE = ''
        $global:azdEnvSetCalls.Clear()
        $global:testApprovalAnswer = $approvalAnswer
        function global:Read-Host {
            param([Parameter(Position = 0)][string]$Prompt)

            return $global:testApprovalAnswer
        }
        $declined = $false
        try {
            & $scriptPath -RepositoryRoot $tempRoot -ProvisioningProfileScriptPath $mockProvisioningProfilePath -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
        }
        catch {
            $declined = $true
        }
        finally {
            Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        }

        $remembered = $global:azdEnvSetCalls -contains 'W365_RESOURCE_CHANGES_CONFIRMED=true'
        if ($approvalAnswer -eq 'no') {
            if (!$declined -or (Test-Path -LiteralPath $w365CallsPath) -or $remembered) {
                throw 'A declined approval did not fail closed before W365 setup.'
            }
            continue
        }
        if ($declined -or !(Test-Path -LiteralPath $w365CallsPath)) {
            throw "Interactive approval '$approvalAnswer' did not continue to W365 setup."
        }
        if ($approvalAnswer -eq 'ALWAYS' -and !$remembered) {
            throw 'ALWAYS did not record the approval in the azd environment.'
        }
        if ($approvalAnswer -eq 'YES' -and $remembered) {
            throw 'A single-run YES approval was persisted to the azd environment.'
        }
    }
    $env:AZD_NON_INTERACTIVE = 'true'

    Reset-Calls
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    $w365Call = Get-Content -LiteralPath $w365CallsPath -Raw | ConvertFrom-Json
    if ($w365Call.environment -ne $environmentName -or
        $w365Call.tenantId -ne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -or
        ![string]::IsNullOrWhiteSpace([string]$w365Call.agentUserPrincipalName) -or
        ![string]::IsNullOrWhiteSpace([string]$w365Call.agentUserDomain) -or
        !$w365Call.billingConfirmed -or
        !$w365Call.confirmResourceChanges -or
        !$w365Call.useDeviceCode -or
        $w365Call.poolBillingPlanId -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -or
        $w365Call.recursionGuard -ne 'true') {
        throw 'Enabled postup did not invoke the guarded W365 setup contract.'
    }
    $viewerCall = Get-Content -LiteralPath $viewerCallsPath -Raw | ConvertFrom-Json
    if ($viewerCall.w365Enabled -ne 'false') {
        throw 'Postup did not run viewer bootstrap before W365 enablement.'
    }
    if ($env:W365_AGENT_USER_PRINCIPAL_NAME -ne 'foundry-w365-sample-dev@customer.example') {
        throw 'Postup did not refresh the automatically resolved W365 agent-user UPN.'
    }

    Reset-Calls
    Write-TestEnvironment `
        -Complete:$false `
        -AgentUserPrincipalName 'explicit@custom.example' `
        -AgentUserDomain 'custom.example'
    & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    $overrideCall = Get-Content -LiteralPath $w365CallsPath -Raw | ConvertFrom-Json
    if ($overrideCall.agentUserPrincipalName -ne 'explicit@custom.example' -or
        $overrideCall.agentUserDomain -ne 'custom.example') {
        throw 'Postup did not preserve explicit W365 agent-user naming overrides.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'true'
    & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    if (Test-Path -LiteralPath $w365CallsPath) {
        throw 'Completed W365 environment reran setup.'
    }
    if (!(Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Completed W365 environment did not continue to viewer bootstrap.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    $env:W365_AZD_UP_WRAPPER = 'true'
    $env:W365_AZD_UP_RUN_ID = 'producer-run-1'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath
    $producerEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($producerEnvironment -notmatch 'W365_AZD_UP_POSTUP_RUN_ID="producer-run-1"') {
        throw 'Complete-AzdUp did not persist the wrapper current-run post-up marker.'
    }

    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    $env:W365_AZD_UP_RUN_ID = ''
    $missingRunIdFailed = $false
    try {
        & $scriptPath `
            -RepositoryRoot $tempRoot `
            -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
            -W365SetupScriptPath $mockW365Path `
            -ViewerBootstrapScriptPath $mockViewerPath `
            -ViewerSecretsScriptPath $mockViewerSecretsPath
    }
    catch {
        $missingRunIdFailed = $_.Exception.Message -match 'run-specific completion ID'
    }
    if (!$missingRunIdFailed) {
        throw 'Complete-AzdUp accepted wrapper execution without a current run ID.'
    }
    $env:W365_AZD_UP_WRAPPER = ''
    $env:W365_AZD_UP_RUN_ID = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    $env:VIEWER_PUBLIC_URL = ''
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.example.com'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    $agentDeployCall = Get-Content -LiteralPath $agentDeployCallsPath -Raw | ConvertFrom-Json
    if ($agentDeployCall.mode -ne 'DeployAgent' -or
        $agentDeployCall.environment -ne $environmentName -or
        !$agentDeployCall.confirmResourceChanges -or
        !$agentDeployCall.smokeInvoke -or
        $agentDeployCall.viewerPublicUrl -ne 'https://viewer.example.com' -or
        $agentDeployCall.recursionGuard -ne 'true') {
        throw 'Postup did not redeploy the hosted agent after discovering the viewer URL.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    Add-Content -LiteralPath $environmentPath -Value 'DEPLOY_VIEWER="true"'
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $env:VIEWER_PUBLIC_URL = ''
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.fresh.example.com'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    if (!(Test-Path -LiteralPath $w365CallsPath) -or
        (Test-Path -LiteralPath $agentDeployCallsPath)) {
        throw 'Fresh viewer-enabled setup did not use exactly the hosted-agent deployment owned by W365 setup.'
    }
    $freshEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($freshEnvironment -match '(?m)^W365_AGENT_REDEPLOY_(CHECK_)?PENDING="?true"?\r?$') {
        throw 'Fresh W365 setup left a redundant hosted-agent redeployment marker.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    if (!(Test-Path -LiteralPath $w365CallsPath) -or
        (Test-Path -LiteralPath $agentDeployCallsPath)) {
        throw 'Fresh viewer-disabled setup did not use exactly the hosted-agent deployment owned by W365 setup.'
    }
    $viewerDisabledSuccessEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($viewerDisabledSuccessEnvironment -match '(?m)^W365_AGENT_REDEPLOY_(CHECK_)?PENDING="?true"?\r?$') {
        throw 'Fresh viewer-disabled W365 setup left a redundant hosted-agent redeployment marker.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    Add-Content -LiteralPath $environmentPath -Value @(
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.same.example.com"'
    )
    $env:VIEWER_PUBLIC_URL = 'https://viewer.same.example.com'
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.same.example.com'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    if (Test-Path -LiteralPath $agentDeployCallsPath) {
        throw 'Postup redeployed the hosted agent even though viewer configuration did not change.'
    }
    $noChangeEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($noChangeEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_CHECK_PENDING="?false"?\r?$' -or
        $noChangeEnvironment -match '(?m)^W365_AGENT_REDEPLOY_PENDING="?true"?\r?$') {
        throw 'No-change reconciliation did not clear only the comparison state.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    Add-Content -LiteralPath $environmentPath -Value @(
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.original.example.com"'
    )
    $env:VIEWER_PUBLIC_URL = 'https://viewer.original.example.com'
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.interrupted.example.com'
    $env:W365_AZD_UP_WRAPPER = 'true'
    $env:W365_AZD_UP_RUN_ID = 'interrupted-viewer-run'
    $viewerInterruptionFailed = $false
    try {
        & $scriptPath `
            -RepositoryRoot $tempRoot `
            -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
            -W365SetupScriptPath $failingW365Path `
            -ViewerBootstrapScriptPath $mockViewerPath `
            -ViewerSecretsScriptPath $mockViewerSecretsPath `
            -AgentDeploymentScriptPath $mockAgentDeployPath
    }
    catch {
        $viewerInterruptionFailed = $_.Exception.Message -match 'Simulated W365 setup failure'
    }
    if (!$viewerInterruptionFailed) {
        throw 'Postup did not propagate the simulated failure after viewer mutation.'
    }
    $interruptedEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($interruptedEnvironment -notmatch '(?m)^VIEWER_PUBLIC_URL="https://viewer\.interrupted\.example\.com"\r?$' -or
        $interruptedEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_CHECK_PENDING="?true"?\r?$' -or
        $interruptedEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_BASELINE_VIEWER_URL="https://viewer\.original\.example\.com"\r?$' -or
        $interruptedEnvironment -match '(?m)^W365_AZD_UP_POSTUP_RUN_ID=') {
        throw 'Postup did not retain the viewer comparison state across an intermediate viewer failure.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''
    $env:W365_AZD_UP_RUN_ID = 'recovered-viewer-run'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    if (!(Test-Path -LiteralPath $w365CallsPath)) {
        throw 'Postup did not complete W365 setup and its hosted-agent deployment after recovering from an intermediate viewer failure.'
    }
    $recoveredViewerEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($recoveredViewerEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?false"?\r?$' -or
        $recoveredViewerEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_CHECK_PENDING="?false"?\r?$' -or
        $recoveredViewerEnvironment -notmatch '(?m)^W365_AZD_UP_POSTUP_RUN_ID="?recovered-viewer-run"?\r?$') {
        throw 'Postup completed before resolving the viewer-triggered redeployment obligation.'
    }
    $env:W365_AZD_UP_WRAPPER = ''
    $env:W365_AZD_UP_RUN_ID = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    Add-Content -LiteralPath $environmentPath -Value @(
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.before-failure.example.com"'
    )
    $env:VIEWER_PUBLIC_URL = 'https://viewer.before-failure.example.com'
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.after-failure.example.com'
    $env:W365_AZD_UP_WRAPPER = 'true'
    $env:W365_AZD_UP_RUN_ID = 'failed-agent-deploy-run'
    $agentDeploymentFailed = $false
    try {
        & $scriptPath `
            -RepositoryRoot $tempRoot `
            -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
            -W365SetupScriptPath $mockW365Path `
            -ViewerBootstrapScriptPath $mockViewerPath `
            -ViewerSecretsScriptPath $mockViewerSecretsPath `
            -AgentDeploymentScriptPath $failingAgentDeployPath
    }
    catch {
        $agentDeploymentFailed = $_.Exception.Message -match 'Simulated hosted-agent deployment failure'
    }
    if (!$agentDeploymentFailed) {
        throw 'Postup did not propagate the hosted-agent deployment failure.'
    }
    $failedDeploymentEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($failedDeploymentEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?true"?\r?$' -or
        $failedDeploymentEnvironment -match '(?m)^W365_AZD_UP_POSTUP_RUN_ID=') {
        throw 'Hosted-agent deployment failure did not preserve confirmed pending state and block completion.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''
    $env:W365_AZD_UP_RUN_ID = 'recovered-agent-deploy-run'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    $recoveredDeploymentEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($recoveredDeploymentEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?false"?\r?$' -or
        $recoveredDeploymentEnvironment -notmatch '(?m)^W365_AZD_UP_POSTUP_RUN_ID="?recovered-agent-deploy-run"?\r?$') {
        throw 'Same-environment recovery did not complete the retained hosted-agent redeployment.'
    }
    $env:W365_AZD_UP_WRAPPER = ''
    $env:W365_AZD_UP_RUN_ID = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    $envLines = Get-Content -LiteralPath $environmentPath | Where-Object {
        $_ -notmatch '^(OPERATOR_TENANT_ID|OPERATOR_OBJECT_ID|HOSTED_ALLOWED_USER_ID)='
    }
    Set-Content -LiteralPath $environmentPath -Value $envLines
    $env:OPERATOR_TENANT_ID = ''
    $env:OPERATOR_OBJECT_ID = ''
    $env:HOSTED_ALLOWED_USER_ID = ''
    $env:VIEWER_PUBLIC_URL = ''
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.example.com'
    $env:TEST_AZ_BEHAVIOR = 'fail'
    $env:W365_AZD_UP_WRAPPER = 'true'
    $env:W365_AZD_UP_RUN_ID = 'incomplete-redeploy-run'
    $missingOperatorOutput = try {
        & $scriptPath `
            -RepositoryRoot $tempRoot `
            -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
            -W365SetupScriptPath $mockW365Path `
            -ViewerBootstrapScriptPath $mockViewerPath `
            -ViewerSecretsScriptPath $mockViewerSecretsPath `
            -AgentDeploymentScriptPath $mockAgentDeployPath *>&1 | Out-String
    }
    catch {
        $_ | Out-String
    }
    if (Test-Path -LiteralPath $agentDeployCallsPath) {
        throw 'Postup redeployed the hosted agent even though required operator identity values were missing.'
    }
    if ($missingOperatorOutput -notmatch 'Hosted-agent redeployment is required' -or
        $missingOperatorOutput -notmatch 'OPERATOR_TENANT_ID' -or
        $missingOperatorOutput -notmatch 'OPERATOR_OBJECT_ID') {
        throw 'Postup did not fail with the missing hosted-agent operator prerequisites.'
    }
    $incompleteEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($incompleteEnvironment -match '(?m)^W365_AZD_UP_POSTUP_RUN_ID=') {
        throw 'Postup persisted a completion marker after skipping required hosted-agent redeployment.'
    }
    if ($incompleteEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?true"?\r?$') {
        throw 'Postup did not persist the pending hosted-agent redeployment obligation.'
    }

    Add-Content -LiteralPath $environmentPath -Value @(
        'OPERATOR_TENANT_ID="66666666-6666-6666-6666-666666666666"',
        'OPERATOR_OBJECT_ID="77777777-7777-7777-7777-777777777777"'
    )
    $env:OPERATOR_TENANT_ID = '66666666-6666-6666-6666-666666666666'
    $env:OPERATOR_OBJECT_ID = '77777777-7777-7777-7777-777777777777'
    $env:W365_AZD_UP_RUN_ID = 'recovered-redeploy-run'
    $env:TEST_AZ_BEHAVIOR = 'success'
    $env:TEST_VIEWER_PUBLIC_URL = ''
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    if (!(Test-Path -LiteralPath $agentDeployCallsPath)) {
        throw 'Postup did not retry the pending hosted-agent redeployment after operator values were supplied.'
    }
    $recoveredEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if ($recoveredEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?false"?\r?$' -or
        $recoveredEnvironment -notmatch '(?m)^W365_AZD_UP_POSTUP_RUN_ID="?recovered-redeploy-run"?\r?$') {
        throw 'Postup did not clear the redeployment obligation and persist completion after recovery.'
    }
    $env:W365_AZD_UP_WRAPPER = ''
    $env:W365_AZD_UP_RUN_ID = ''
    $env:TEST_AZ_BEHAVIOR = 'success'
    $env:TEST_VIEWER_PUBLIC_URL = ''
    $env:TEST_AZ_BEHAVIOR = 'success'

    Reset-Calls
    Write-TestEnvironment -Complete:$true
    Write-CompleteManifest
    Add-Content -LiteralPath $environmentPath -Value @(
        'DEPLOY_VIEWER="true"',
        'W365_KEY_VAULT_NAME="sample-w365-vault"',
        'SCREENSHARE_SDK_URL="https://screenshare.example.com/sdk.js"',
        'SCREENSHARE_FRAME_ORIGINS="https://screenshare.example.com"',
        'SCREENSHARE_APP_URL="https://viewer-static.example.com"'
    )
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'true'
    $env:VIEWER_PUBLIC_URL = ''
    $env:TEST_VIEWER_PUBLIC_URL = 'https://viewer.example.com'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -ViewerActivationScriptPath $mockViewerActivationPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    $secretCall = Get-Content -LiteralPath $viewerSecretsCallsPath -Raw | ConvertFrom-Json
    if ($secretCall.environment -ne $environmentName -or
        !$secretCall.blueprintOnly -or
        !$secretCall.bootstrapOperatorAccess) {
        throw 'Postup did not bootstrap Key Vault access and configure the blueprint secret after viewer bootstrap.'
    }
    $activationCall = Get-Content -LiteralPath $viewerActivationCallsPath -Raw | ConvertFrom-Json
    if ($activationCall.environment -ne $environmentName) {
        throw 'Postup did not activate the live viewer after credentials and prerequisites were ready.'
    }
    $activatedAgentDeployCall = Get-Content -LiteralPath $agentDeployCallsPath -Raw | ConvertFrom-Json
    if ($activatedAgentDeployCall.mode -ne 'DeployAgent' -or
        !$activatedAgentDeployCall.confirmResourceChanges -or
        !$activatedAgentDeployCall.smokeInvoke) {
        throw 'Postup did not redeploy and smoke-test the hosted agent after activating an existing viewer URL.'
    }
    $env:TEST_VIEWER_PUBLIC_URL = ''

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $failed = $false
    try {
        & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $failingW365Path -ViewerBootstrapScriptPath $mockViewerPath -ViewerSecretsScriptPath $mockViewerSecretsPath
    }
    catch {
        $failed = $true
    }
    if (!$failed) {
        throw 'Postup hid a W365 setup failure.'
    }
    if (!(Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Postup did not create the viewer bootstrap resources before W365 setup.'
    }
    $failureManifest = Get-Content -LiteralPath (Join-Path $environmentDirectory 'w365-ownership.json') -Raw | ConvertFrom-Json
    if ($failureManifest.w365.pool.disposition -ne 'created') {
        throw 'Postup did not preserve partial ownership evidence after failure.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $env:W365_AZD_UP_WRAPPER = 'true'
    $env:W365_AZD_UP_RUN_ID = 'viewer-disabled-failure'
    $finalDeploymentFailed = $false
    try {
        & $scriptPath `
            -RepositoryRoot $tempRoot `
            -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
            -W365SetupScriptPath $failingFinalDeploymentPath `
            -ViewerBootstrapScriptPath $mockViewerPath `
            -ViewerSecretsScriptPath $mockViewerSecretsPath `
            -AgentDeploymentScriptPath $mockAgentDeployPath
    }
    catch {
        $finalDeploymentFailed = $_.Exception.Message -match 'Hosted agent redeployment failed'
    }
    $failedFinalEnvironment = Get-Content -LiteralPath $environmentPath -Raw
    if (!$finalDeploymentFailed -or
        $failedFinalEnvironment -notmatch '(?m)^W365_ENABLED="true"\r?$' -or
        $failedFinalEnvironment -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?true"?\r?$' -or
        $failedFinalEnvironment -match '(?m)^W365_AZD_UP_POSTUP_RUN_ID=') {
        throw 'Viewer-disabled final hosted-agent deployment failure did not retain a recovery obligation.'
    }
    $env:W365_AZD_UP_RUN_ID = 'viewer-disabled-recovery'
    & $scriptPath `
        -RepositoryRoot $tempRoot `
        -PhaseTwoPreparationScriptPath $mockPhaseTwoPath `
        -W365SetupScriptPath $mockW365Path `
        -ViewerBootstrapScriptPath $mockViewerPath `
        -ViewerSecretsScriptPath $mockViewerSecretsPath `
        -AgentDeploymentScriptPath $mockAgentDeployPath
    $viewerDisabledRecovery = Get-Content -LiteralPath $environmentPath -Raw
    if (!(Test-Path -LiteralPath $agentDeployCallsPath) -or
        $viewerDisabledRecovery -notmatch '(?m)^W365_AGENT_REDEPLOY_PENDING="?false"?\r?$' -or
        $viewerDisabledRecovery -notmatch '(?m)^W365_AZD_UP_POSTUP_RUN_ID="?viewer-disabled-recovery"?\r?$') {
        throw 'Viewer-disabled W365 setup did not recover the retained hosted-agent deployment obligation.'
    }
    $env:W365_AZD_UP_WRAPPER = ''
    $env:W365_AZD_UP_RUN_ID = ''

    Reset-Calls
    $env:W365_POSTUP_IN_PROGRESS = 'true'
    & $scriptPath -RepositoryRoot $tempRoot -PhaseTwoPreparationScriptPath $mockPhaseTwoPath -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
    if ((Test-Path -LiteralPath $w365CallsPath) -or (Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Nested postup execution was not fully suppressed.'
    }

    Write-Output 'Offline azd postup: automatic and explicit agent-user naming, state transitions, and recursion guard passed.'
}
finally {
    foreach ($name in $trackedEnvironmentVariables) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    foreach ($name in @(
        'TEST_SOURCE_ROOT',
        'TEST_REPOSITORY_ROOT',
        'TEST_W365_CALLS_PATH',
        'TEST_PHASE_TWO_CALLS_PATH',
        'TEST_VIEWER_CALLS_PATH',
        'TEST_AGENT_DEPLOY_CALLS_PATH',
        'TEST_VIEWER_SECRETS_CALLS_PATH',
        'TEST_VIEWER_ACTIVATION_CALLS_PATH',
        'TEST_VIEWER_PUBLIC_URL'
    )) {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
