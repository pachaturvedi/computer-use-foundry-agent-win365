#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$workflowPath = Join-Path $repositoryRoot '.github\workflows\w365-live-acceptance.yml'
$workflow = Get-Content -LiteralPath $workflowPath -Raw

$requiredFragments = @(
    'workflow_dispatch:',
    'environment: w365-live-acceptance',
    'id-token: write',
    'cancel-in-progress: false',
    'I_APPROVE_W365_BILLING_AND_CLEANUP',
    'W365_RESOURCE_CHANGES_CONFIRMED: ''true''',
    'W365_CLEANUP_CONFIRMED: ''true''',
    'azd down --environment $env:AZD_ENVIRONMENT_NAME --force --purge --no-prompt',
    'if: always()',
    'actions/upload-artifact@v4'
)
foreach ($fragment in $requiredFragments) {
    if (!$workflow.Contains($fragment, [StringComparison]::Ordinal)) {
        throw "Live acceptance workflow is missing required contract '$fragment'."
    }
}
if ($workflow -match '(?m)^\s+(push|pull_request):') {
    throw 'Live acceptance must never run from push or pull_request.'
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-live-verifier-{0}" -f ([guid]::NewGuid()))
$environmentName = 'sample-live'
$environmentRoot = Join-Path $tempRoot ".azure\$environmentName"
$environmentPath = Join-Path $environmentRoot '.env'
$manifestPath = Join-Path $environmentRoot 'w365-ownership.json'
$evidencePath = Join-Path $tempRoot 'evidence.json'

try {
    New-Item -ItemType Directory -Path $environmentRoot -Force | Out-Null
    @'
ENABLE_W365="true"
W365_ENABLED="true"
W365_POOL_ID="11111111-1111-1111-1111-111111111111"
W365_AGENT_USER_ID="22222222-2222-2222-2222-222222222222"
W365_AGENT_USER_PRINCIPAL_NAME="sample-agent@YOUR-TENANT.onmicrosoft.com"
W365_AGENT_ID="33333333-3333-3333-3333-333333333333"
W365_AGENT_OBJECT_ID="44444444-4444-4444-4444-444444444444"
W365_BLUEPRINT_ID="55555555-5555-5555-5555-555555555555"
AGENT_WIN365_DESKTOP_AGENT_VERSION="2"
'@ | Set-Content -LiteralPath $environmentPath
    $manifest = @{
        schemaVersion = 1
        environmentName = $environmentName
        foundry = @{ projectOwnership = 'managed' }
        graph = @{
            blueprint = @{
                appId = '55555555-5555-5555-5555-555555555555'
                objectId = '66666666-6666-6666-6666-666666666666'
                principalId = '77777777-7777-7777-7777-777777777777'
            }
            agent = @{
                appId = '33333333-3333-3333-3333-333333333333'
                objectId = '44444444-4444-4444-4444-444444444444'
            }
        }
        w365 = @{
            pool = @{ id = '11111111-1111-1111-1111-111111111111'; disposition = 'created' }
            agentUser = @{
                id = '22222222-2222-2222-2222-222222222222'
                userPrincipalName = 'sample-agent@YOUR-TENANT.onmicrosoft.com'
                disposition = 'created'
            }
            assignment = @{
                id = 'assignment-1'
                poolId = '11111111-1111-1111-1111-111111111111'
                userPrincipalId = '22222222-2222-2222-2222-222222222222'
                disposition = 'created'
            }
        }
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath

    $result = & (Join-Path $repositoryRoot 'scripts\Test-W365LiveDeployment.ps1') `
        -EnvironmentName $environmentName `
        -RepositoryRoot $tempRoot `
        -EvidencePath $evidencePath
    if ($result.state -ne 'Complete' -or
        $result.agentUserDomainKind -ne 'MicrosoftProvided' -or
        !(Test-Path -LiteralPath $evidencePath)) {
        throw 'Live deployment verification did not emit the expected sanitized evidence.'
    }

    $hashMismatchBlocked = $false
    try {
        & (Join-Path $repositoryRoot 'scripts\Test-W365LiveDeployment.ps1') `
            -EnvironmentName $environmentName `
            -RepositoryRoot $tempRoot `
            -ExpectedManifestSha256 ('0' * 64) | Out-Null
    }
    catch {
        $hashMismatchBlocked = $true
    }
    if (!$hashMismatchBlocked) {
        throw 'Live deployment verification accepted changed ownership evidence.'
    }

    $manifest.cleanup = @{ status = 'completed'; completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath
    $cleanupResult = & (Join-Path $repositoryRoot 'scripts\Test-W365LiveDeployment.ps1') `
        -EnvironmentName $environmentName `
        -RepositoryRoot $tempRoot `
        -RequireCleanupComplete
    if (!$cleanupResult.cleanupComplete) {
        throw 'Live deployment verification did not prove completed cleanup.'
    }

    Write-Output 'Offline live acceptance: manual protection, approvals, teardown, rerun evidence, and cleanup proof passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
