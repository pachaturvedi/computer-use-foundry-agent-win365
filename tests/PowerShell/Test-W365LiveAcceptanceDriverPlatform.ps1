#Requires -Version 7.4
# TestCategory: Platform
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This acceptance-driver test requires Windows.'
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$driverPath = Join-Path $repositoryRoot 'scripts\Invoke-W365LiveAcceptance.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-live-driver-{0}" -f ([guid]::NewGuid()))
$mockRoot = Join-Path $tempRoot 'repo'
$mockScripts = Join-Path $tempRoot 'mocks'
$logPath = Join-Path $tempRoot 'commands.log'
$environmentName = 'sample-live'
$subscriptionId = '11111111-1111-1111-1111-111111111111'
$tenantId = '22222222-2222-2222-2222-222222222222'

function Write-MockRepository {
    param([Parameter(Mandatory)][string]$Root)

    New-Item -ItemType Directory -Path (Join-Path $Root 'config') -Force | Out-Null
    @{
        w365 = @{
            poolBillingPlanId = '33333333-3333-3333-3333-333333333333'
            poolBillingType = 'payAsYouGo'
            poolGeographicLocationType = 'usCentral'
            poolRegionGroup = 'usCentral'
            poolRegions = @('centralus')
            poolImageId = 'gallery-image'
            poolImageType = 'gallery'
            poolOsLocale = 'en-US'
            poolMinimumCount = 1
            poolMaximumCount = 1
            poolEnableSingleSignOn = $false
        }
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $Root 'config\deployment.defaults.json')
}

try {
    New-Item -ItemType Directory -Path $mockRoot, $mockScripts -Force | Out-Null
    Write-MockRepository -Root $mockRoot

    $initializerPath = Join-Path $mockScripts 'Initialize.ps1'
    @'
param($SubscriptionId, $TenantId, $Prefix, $Environment, $Location, [switch]$EnableW365, $AgentUserDomain)
$environmentName = "$Prefix-$Environment"
$environmentRoot = Join-Path $env:MOCK_REPOSITORY_ROOT ".azure\$environmentName"
New-Item -ItemType Directory -Path $environmentRoot -Force | Out-Null
@"
AZURE_SUBSCRIPTION_ID="$SubscriptionId"
AZURE_TENANT_ID="$TenantId"
AZURE_LOCATION="$Location"
ENABLE_W365="true"
W365_ENABLED="true"
W365_POOL_ID="44444444-4444-4444-4444-444444444444"
W365_AGENT_USER_ID="55555555-5555-5555-5555-555555555555"
W365_AGENT_USER_PRINCIPAL_NAME="sample-agent@YOUR-TENANT.onmicrosoft.com"
W365_AGENT_ID="66666666-6666-6666-6666-666666666666"
W365_AGENT_OBJECT_ID="77777777-7777-7777-7777-777777777777"
W365_BLUEPRINT_ID="88888888-8888-8888-8888-888888888888"
AGENT_WIN365_DESKTOP_AGENT_VERSION="2"
"@ | Set-Content -LiteralPath (Join-Path $environmentRoot '.env')
@{
    schemaVersion = 1
    environmentName = $environmentName
    foundry = @{ projectOwnership = 'managed' }
    graph = @{
        blueprint = @{ appId = '88888888-8888-8888-8888-888888888888'; objectId = 'blueprint'; principalId = 'principal' }
        agent = @{ appId = '66666666-6666-6666-6666-666666666666'; objectId = '77777777-7777-7777-7777-777777777777' }
    }
    w365 = @{
        pool = @{ id = '44444444-4444-4444-4444-444444444444'; disposition = 'created' }
        agentUser = @{ id = '55555555-5555-5555-5555-555555555555'; userPrincipalName = 'sample-agent@YOUR-TENANT.onmicrosoft.com'; disposition = 'created' }
        assignment = @{ id = 'assignment'; poolId = '44444444-4444-4444-4444-444444444444'; userPrincipalId = '55555555-5555-5555-5555-555555555555'; disposition = 'created' }
    }
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $environmentRoot 'w365-ownership.json')
Add-Content -LiteralPath $env:MOCK_COMMAND_LOG -Value 'initialize'
'@ | Set-Content -LiteralPath $initializerPath

    $azdPath = Join-Path $mockScripts 'azd.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
Add-Content -LiteralPath $env:MOCK_COMMAND_LOG -Value ("azd " + ($Arguments -join ' '))
$environmentRoot = Join-Path $env:MOCK_REPOSITORY_ROOT ".azure\sample-live"
if ($Arguments[0] -eq 'up' -and $env:MOCK_FAIL_UP -eq 'true') {
    throw 'Expected deployment failure.'
}
if ($Arguments[0] -eq 'down') {
    $manifestPath = Join-Path $environmentRoot 'w365-ownership.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    $manifest.cleanup = @{ status = 'completed'; completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath
}
if ($Arguments[0] -eq 'env' -and $Arguments[1] -eq 'get-value') {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $environmentRoot '.env')) {
        if ($line -match '^([^=]+)="?(.*?)"?$') { $values[$Matches[1]] = $Matches[2].TrimEnd('"') }
    }
    $values[$Arguments[2]]
}
'@ | Set-Content -LiteralPath $azdPath

    $prerequisitePath = Join-Path $mockScripts 'Prerequisites.ps1'
    @'
param([switch]$RequireLogin)
Add-Content -LiteralPath $env:MOCK_COMMAND_LOG -Value 'prerequisites'
'@ | Set-Content -LiteralPath $prerequisitePath

    $graphModule = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {}
    $graphModule | Import-Module
    $env:MOCK_REPOSITORY_ROOT = $mockRoot
    $env:MOCK_COMMAND_LOG = $logPath
    $env:MOCK_FAIL_UP = 'false'

    & $driverPath `
        -SubscriptionId $subscriptionId `
        -TenantId $tenantId `
        -Prefix sample `
        -Location eastus `
        -ApprovalPhrase I_APPROVE_W365_BILLING_AND_CLEANUP `
        -RepositoryRoot $mockRoot `
        -EvidenceDirectory (Join-Path $mockRoot 'artifacts') `
        -AzdPath $azdPath `
        -InitializerScriptPath $initializerPath `
        -PrerequisiteScriptPath $prerequisitePath

    $commands = @(Get-Content -LiteralPath $logPath)
    if (@($commands | Where-Object { $_ -like 'azd up *' }).Count -ne 2 -or
        @($commands | Where-Object { $_ -like 'azd ai agent doctor *' }).Count -ne 2 -or
        @($commands | Where-Object { $_ -like 'azd down *' }).Count -ne 1) {
        throw "Acceptance driver did not execute deploy, rerun, doctor, and cleanup exactly once: $($commands -join '; ')"
    }

    $resumeRejected = $false
    try {
        & $driverPath `
            -SubscriptionId $subscriptionId `
            -TenantId $tenantId `
            -Prefix sample `
            -Location eastus `
            -ApprovalPhrase I_APPROVE_W365_BILLING_AND_CLEANUP `
            -Resume `
            -RepositoryRoot $mockRoot `
            -EvidenceDirectory (Join-Path $mockRoot 'artifacts') `
            -AzdPath $azdPath `
            -InitializerScriptPath $initializerPath `
            -PrerequisiteScriptPath $prerequisitePath
    }
    catch {
        $resumeRejected = $_.Exception.Message -like '*already completed cleanup*'
    }
    $commandsAfterRejectedResume = @(Get-Content -LiteralPath $logPath)
    if (!$resumeRejected -or
        @($commandsAfterRejectedResume | Where-Object { $_ -like 'azd down *' }).Count -ne 1) {
        throw 'A completed environment resume was not rejected safely before another teardown.'
    }

    $secondRoot = Join-Path $tempRoot 'failure-repo'
    Write-MockRepository -Root $secondRoot
    $env:MOCK_REPOSITORY_ROOT = $secondRoot
    $env:MOCK_COMMAND_LOG = Join-Path $tempRoot 'failure.log'
    $env:MOCK_FAIL_UP = 'true'
    $failed = $false
    try {
        & $driverPath `
            -SubscriptionId $subscriptionId `
            -TenantId $tenantId `
            -Prefix sample `
            -Location eastus `
            -ApprovalPhrase I_APPROVE_W365_BILLING_AND_CLEANUP `
            -RepositoryRoot $secondRoot `
            -EvidenceDirectory (Join-Path $secondRoot 'artifacts') `
            -AzdPath $azdPath `
            -InitializerScriptPath $initializerPath `
            -PrerequisiteScriptPath $prerequisitePath
    }
    catch {
        $failed = $_.Exception.Message -like '*cleanup completed*'
    }
    if (!$failed -or
        @((Get-Content -LiteralPath $env:MOCK_COMMAND_LOG) | Where-Object { $_ -like 'azd down *' }).Count -ne 1) {
        throw 'Acceptance driver did not preserve the deployment error while completing failure cleanup.'
    }

    Write-Output 'Windows live acceptance driver: fresh deployment, safe resume rejection, rerun stability, doctor, and failure cleanup passed.'
}
finally {
    Remove-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    foreach ($name in @('MOCK_REPOSITORY_ROOT', 'MOCK_COMMAND_LOG', 'MOCK_FAIL_UP')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
