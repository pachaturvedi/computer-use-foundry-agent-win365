#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
. (Join-Path $scriptsRoot 'W365Provisioning.ps1')

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-provisioning-{0}" -f ([guid]::NewGuid()))
$environmentName = 'contoso-dev'

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }

    if (!$threw) {
        throw $Message
    }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'config\deployment.defaults.json') -Value @'
{
  "w365": {
    "poolBillingType": "payAsYouGo",
    "poolMinimumCount": 1,
    "poolMaximumCount": 1
  }
}
'@
    Set-Content -LiteralPath (Join-Path $tempRoot 'config\deployment.local.json') -Value @'
{
  "w365": {
    "poolMinimumCount": 2
  }
}
'@

    $config = Get-DeploymentConfig -RepositoryRoot $tempRoot
    if ($config.Values.w365.poolBillingType -ne 'payAsYouGo' -or
        $config.Values.w365.poolMinimumCount -ne 2 -or
        $config.Values.w365.poolMaximumCount -ne 1) {
        throw 'W365 provisioning did not preserve deployment configuration precedence.'
    }

    $name = Get-W365PoolDisplayName -ResourcePrefix 'Contoso Sample' -EnvironmentName 'Dev 01'
    if ($name -ne 'foundry-w365-contoso-sample-dev-01') {
        throw "Unexpected deterministic W365 pool display name '$name'."
    }
    $longName = Get-W365PoolDisplayName `
        -ResourcePrefix ('prefix-' + ('a' * 80)) `
        -EnvironmentName ('environment-' + ('b' * 80))
    if ($longName.Length -gt 64 -or $longName -notmatch '-[0-9a-f]{8}$') {
        throw "Long W365 pool display name was not bounded deterministically: '$longName'."
    }
    if ($longName -ne (Get-W365PoolDisplayName `
        -ResourcePrefix ('prefix-' + ('a' * 80)) `
        -EnvironmentName ('environment-' + ('b' * 80)))) {
        throw 'W365 pool display-name hashing is not deterministic.'
    }

    $ownedPoolId = '11111111-1111-1111-1111-111111111111'
    $ownership = [ordered]@{
        w365 = [ordered]@{
            pool = [ordered]@{ id = $ownedPoolId }
        }
    }
    if ((Resolve-W365OwnedPoolId -OwnershipManifest $ownership) -ne [guid]$ownedPoolId) {
        throw 'W365 pool resolution did not use the manifest-owned pool.'
    }
    Assert-Throws {
        Resolve-W365OwnedPoolId `
            -ExplicitPoolId '22222222-2222-2222-2222-222222222222' `
            -OwnershipManifest $ownership | Out-Null
    } 'W365 pool resolution accepted an explicit pool that differed from the ownership manifest.'
    Assert-Throws {
        Resolve-W365OwnedPoolId -PersistedPoolId $ownedPoolId | Out-Null
    } 'W365 pool resolution trusted an azd pool ID without an ownership manifest.'
    Assert-Throws {
        Resolve-W365OwnedPoolId -OwnershipManifest ([ordered]@{ schemaVersion = 1 }) | Out-Null
    } 'W365 pool resolution accepted a partial ownership manifest without a pool ID.'
    if ((Resolve-W365OwnedPoolId -ExplicitPoolId $ownedPoolId) -ne [guid]$ownedPoolId) {
        throw 'W365 pool resolution broke the explicit advanced compatibility path.'
    }
    if ((Resolve-W365OwnedPoolId) -ne [guid]::Empty) {
        throw 'W365 first-run pool resolution should return an empty ID so setup creates a pool.'
    }

    Assert-W365ResourceApproval -EnableW365:$false -ConfirmResourceChanges:$false
    Assert-Throws {
        Assert-W365ResourceApproval -EnableW365:$true -ConfirmResourceChanges:$false
    } 'W365 provisioning accepted enabled resource changes without explicit approval.'
    Assert-W365ResourceApproval -EnableW365:$true -ConfirmResourceChanges:$true

    $emptyEnvironment = [ordered]@{}
    $state = Get-W365ProvisioningState `
        -RepositoryRoot $tempRoot `
        -EnvironmentName $environmentName `
        -EnvironmentValues $emptyEnvironment
    if ($state.Name -ne 'FirstRun') {
        throw "Expected FirstRun state, received '$($state.Name)'."
    }

    Assert-Throws {
        Get-W365ProvisioningState `
            -RepositoryRoot $tempRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues ([ordered]@{ W365_POOL_ID = 'pool-without-proof' }) | Out-Null
    } 'W365 provisioning accepted persisted resource state without an ownership manifest.'

    $manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $tempRoot -EnvironmentName $environmentName
    $manifest = [ordered]@{
        schemaVersion = 1
        environmentName = $environmentName
        w365 = [ordered]@{
            pool = [ordered]@{ id = 'pool-id' }
            agentUser = [ordered]@{ id = 'agent-user-id' }
            assignment = [ordered]@{
                poolId = 'pool-id'
                userPrincipalId = 'agent-user-id'
            }
        }
        graph = [ordered]@{
            blueprint = [ordered]@{ appId = 'blueprint-id' }
            agent = [ordered]@{
                appId = 'agent-client-id'
                objectId = 'agent-object-id'
            }
        }
    }
    Write-W365OwnershipManifest -Path $manifestPath -Manifest $manifest

    $persisted = [ordered]@{
        W365_POOL_ID = 'pool-id'
        W365_AGENT_USER_ID = 'agent-user-id'
        W365_AGENT_ID = 'agent-client-id'
        W365_AGENT_OBJECT_ID = 'agent-object-id'
        W365_BLUEPRINT_ID = 'blueprint-id'
        W365_ENABLED = 'false'
    }
    $state = Get-W365ProvisioningState `
        -RepositoryRoot $tempRoot `
        -EnvironmentName $environmentName `
        -EnvironmentValues $persisted
    if ($state.Name -ne 'Provisioned') {
        throw "Expected Provisioned state, received '$($state.Name)'."
    }

    $persisted.W365_ENABLED = 'true'
    $state = Get-W365ProvisioningState `
        -RepositoryRoot $tempRoot `
        -EnvironmentName $environmentName `
        -EnvironmentValues $persisted
    if ($state.Name -ne 'Complete') {
        throw "Expected Complete state, received '$($state.Name)'."
    }

    $persisted.W365_POOL_ID = 'different-pool'
    Assert-Throws {
        Get-W365ProvisioningState `
            -RepositoryRoot $tempRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $persisted | Out-Null
    } 'W365 provisioning accepted environment state that drifted from the ownership manifest.'

    Write-Output 'Offline W365 provisioning: config precedence, deterministic naming, approval, and fail-closed ownership state passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
