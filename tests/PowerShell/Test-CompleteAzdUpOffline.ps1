#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'scripts\Complete-AzdUp.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("complete-azd-up-{0}" -f ([guid]::NewGuid()))
$environmentName = 'sample-dev'
$environmentDirectory = Join-Path $tempRoot ".azure\$environmentName"
$environmentPath = Join-Path $environmentDirectory '.env'
$w365CallsPath = Join-Path $tempRoot 'w365-calls.json'
$viewerCallsPath = Join-Path $tempRoot 'viewer-calls.json'
$mockW365Path = Join-Path $tempRoot 'Mock-W365Setup.ps1'
$failingW365Path = Join-Path $tempRoot 'Mock-W365SetupFailure.ps1'
$mockViewerPath = Join-Path $tempRoot 'Mock-Viewer.ps1'

$trackedEnvironmentVariables = @(
    'ENABLE_W365',
    'W365_ENABLED',
    'W365_AGENT_USER_PRINCIPAL_NAME',
    'W365_AGENT_USER_DOMAIN',
    'W365_RESOURCE_CHANGES_CONFIRMED',
    'W365_POSTUP_IN_PROGRESS',
    'AZD_NON_INTERACTIVE',
    'AZURE_ENV_NAME',
    'AZURE_TENANT_ID',
    'W365_POOL_ID',
    'W365_AGENT_USER_ID',
    'W365_AGENT_ID',
    'W365_AGENT_OBJECT_ID',
    'W365_BLUEPRINT_ID'
)
$savedEnvironment = @{}
foreach ($name in $trackedEnvironmentVariables) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Reset-Calls {
    Remove-Item -LiteralPath $w365CallsPath, $viewerCallsPath -ErrorAction SilentlyContinue
}

function Write-TestEnvironment {
    param(
        [bool]$Complete,
        [string]$AgentUserPrincipalName,
        [string]$AgentUserDomain
    )

    New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null
    $lines = @(
        "AZURE_ENV_NAME=`"$environmentName`"",
        'AZURE_TENANT_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"',
        'RESOURCE_PREFIX="sample-dev"',
        "W365_ENABLED=`"$($Complete.ToString().ToLowerInvariant())`""
    )
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
            'W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"'
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
    Set-Content -LiteralPath $mockViewerPath -Value @'
param()
@{
    w365Enabled = $env:W365_ENABLED
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_VIEWER_CALLS_PATH
'@
    Set-Content -LiteralPath $mockW365Path -Value @'
param(
    [string]$Environment,
    [guid]$TenantId,
    [string]$AgentUserPrincipalName,
    [string]$AgentUserDomain,
    [switch]$BillingConfirmed,
    [switch]$ConfirmResourceChanges,
    [switch]$UseDeviceCode
)
@{
    environment = $Environment
    tenantId = $TenantId.ToString()
    agentUserPrincipalName = $AgentUserPrincipalName
    agentUserDomain = $AgentUserDomain
    billingConfirmed = $BillingConfirmed.IsPresent
    confirmResourceChanges = $ConfirmResourceChanges.IsPresent
    useDeviceCode = $UseDeviceCode.IsPresent
    recursionGuard = $env:W365_POSTUP_IN_PROGRESS
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_W365_CALLS_PATH

$environmentDirectory = Join-Path $env:TEST_REPOSITORY_ROOT ".azure\$Environment"
Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
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

    $env:TEST_SOURCE_ROOT = $repoRoot
    $env:TEST_REPOSITORY_ROOT = $tempRoot
    $env:TEST_W365_CALLS_PATH = $w365CallsPath
    $env:TEST_VIEWER_CALLS_PATH = $viewerCallsPath
    $env:AZURE_ENV_NAME = $environmentName
    $env:AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $env:W365_AGENT_USER_PRINCIPAL_NAME = ''
    $env:W365_AGENT_USER_DOMAIN = ''
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    $env:AZD_NON_INTERACTIVE = 'true'

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'false'
    $env:W365_ENABLED = 'false'
    & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
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
        & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
    }
    catch {
        $approvalFailed = $true
    }
    if (!$approvalFailed -or (Test-Path -LiteralPath $w365CallsPath)) {
        throw 'Noninteractive W365 postup did not fail before setup when approval was absent.'
    }

    Reset-Calls
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
    $w365Call = Get-Content -LiteralPath $w365CallsPath -Raw | ConvertFrom-Json
    if ($w365Call.environment -ne $environmentName -or
        $w365Call.tenantId -ne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -or
        ![string]::IsNullOrWhiteSpace([string]$w365Call.agentUserPrincipalName) -or
        ![string]::IsNullOrWhiteSpace([string]$w365Call.agentUserDomain) -or
        !$w365Call.billingConfirmed -or
        !$w365Call.confirmResourceChanges -or
        !$w365Call.useDeviceCode -or
        $w365Call.recursionGuard -ne 'true') {
        throw 'Enabled postup did not invoke the guarded W365 setup contract.'
    }
    $viewerCall = Get-Content -LiteralPath $viewerCallsPath -Raw | ConvertFrom-Json
    if ($viewerCall.w365Enabled -ne 'true') {
        throw 'Postup did not refresh persisted W365 values before viewer bootstrap.'
    }
    if ($env:W365_AGENT_USER_PRINCIPAL_NAME -ne 'foundry-w365-sample-dev@customer.example') {
        throw 'Postup did not refresh the automatically resolved W365 agent-user UPN.'
    }

    Reset-Calls
    Write-TestEnvironment `
        -Complete:$false `
        -AgentUserPrincipalName 'explicit@custom.example' `
        -AgentUserDomain 'custom.example'
    & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
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
    & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
    if (Test-Path -LiteralPath $w365CallsPath) {
        throw 'Completed W365 environment reran setup.'
    }
    if (!(Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Completed W365 environment did not continue to viewer bootstrap.'
    }

    Reset-Calls
    Write-TestEnvironment -Complete:$false
    $env:ENABLE_W365 = 'true'
    $env:W365_ENABLED = 'false'
    $failed = $false
    try {
        & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $failingW365Path -ViewerBootstrapScriptPath $mockViewerPath
    }
    catch {
        $failed = $true
    }
    if (!$failed) {
        throw 'Postup hid a W365 setup failure.'
    }
    if (Test-Path -LiteralPath $viewerCallsPath) {
        throw 'Postup continued to viewer bootstrap after W365 setup failure.'
    }
    $failureManifest = Get-Content -LiteralPath (Join-Path $environmentDirectory 'w365-ownership.json') -Raw | ConvertFrom-Json
    if ($failureManifest.w365.pool.disposition -ne 'created') {
        throw 'Postup did not preserve partial ownership evidence after failure.'
    }

    Reset-Calls
    $env:W365_POSTUP_IN_PROGRESS = 'true'
    & $scriptPath -RepositoryRoot $tempRoot -W365SetupScriptPath $mockW365Path -ViewerBootstrapScriptPath $mockViewerPath
    if ((Test-Path -LiteralPath $w365CallsPath) -or (Test-Path -LiteralPath $viewerCallsPath)) {
        throw 'Nested postup execution was not fully suppressed.'
    }

    Write-Output 'Offline azd postup: automatic and explicit agent-user naming, state transitions, and recursion guard passed.'
}
finally {
    foreach ($name in $trackedEnvironmentVariables) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    foreach ($name in @('TEST_SOURCE_ROOT', 'TEST_REPOSITORY_ROOT', 'TEST_W365_CALLS_PATH', 'TEST_VIEWER_CALLS_PATH')) {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
