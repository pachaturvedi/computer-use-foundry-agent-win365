#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
. (Join-Path $scriptsRoot 'W365Provisioning.ps1')

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-provisioning-{0}" -f ([guid]::NewGuid()))
$environmentName = 'contoso-dev'
$previousPath = $env:PATH

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
    $fakeAzdRoot = Join-Path $tempRoot 'bin'
    New-Item -ItemType Directory -Path $fakeAzdRoot -Force | Out-Null
    $fakeAzdPath = Join-Path $fakeAzdRoot $(if ($IsWindows) { 'azd.cmd' } else { 'azd' })
    if ($IsWindows) {
        Set-Content -LiteralPath $fakeAzdPath -Value @(
            '@echo off',
            'echo azd version 99.0.0'
        )
    }
    else {
        Set-Content -LiteralPath $fakeAzdPath -Value @(
            '#!/bin/sh',
            'echo "azd version 99.0.0"'
        )
        [IO.File]::SetUnixFileMode(
            $fakeAzdPath,
            [IO.UnixFileMode]::UserRead -bor
                [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::UserExecute)
    }
    $env:PATH = @($fakeAzdRoot, $previousPath) -join [IO.Path]::PathSeparator
    function global:azd {
        throw 'The PowerShell azd function must not be treated as an executable candidate.'
    }

    $resolvedAzd = Get-W365AzdCommand
    if ($null -eq $resolvedAzd -or
        (Resolve-Path -LiteralPath $resolvedAzd.Path).Path -ne
            (Resolve-Path -LiteralPath $fakeAzdPath).Path) {
        throw 'W365 azd discovery did not ignore the shadowing PowerShell function and select the valid executable.'
    }

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
    $dedupedName = Get-W365PoolDisplayName -ResourcePrefix 'fawsep18-dev' -EnvironmentName 'fawsep18-dev'
    if ($dedupedName -ne 'foundry-w365-fawsep18-dev') {
        throw "W365 pool display name did not deduplicate a matching prefix/environment token: '$dedupedName'."
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

    $domains = @(
        [pscustomobject]@{
            id = 'customer.example'
            isDefault = $true
            isVerified = $true
        },
        [pscustomobject]@{
            id = 'tenant.onmicrosoft.com'
            isDefault = $false
            isVerified = $true
        },
        [pscustomobject]@{
            id = 'unverified.example'
            isDefault = $false
            isVerified = $false
        }
    )
    if ((Resolve-W365AgentUserDomain -Domains $domains) -ne 'customer.example') {
        throw 'W365 agent-user domain resolution did not use the verified tenant default domain.'
    }
    if ((Resolve-W365AgentUserDomain -Domains $domains -ExplicitDomain 'tenant.onmicrosoft.com') -ne
        'tenant.onmicrosoft.com') {
        throw 'W365 agent-user domain resolution rejected a verified nondefault override.'
    }
    Assert-Throws {
        Resolve-W365AgentUserDomain -Domains $domains -ExplicitDomain 'unverified.example' | Out-Null
    } 'W365 agent-user domain resolution accepted an unverified domain override.'
    Assert-Throws {
        Resolve-W365AgentUserDomain -Domains @(
            [pscustomobject]@{ id = 'one.example'; isDefault = $true; isVerified = $true },
            [pscustomobject]@{ id = 'two.example'; isDefault = $true; isVerified = $true }
        ) | Out-Null
    } 'W365 agent-user domain resolution accepted ambiguous default domains.'

    $agentUserPrincipalName = Get-W365AgentUserPrincipalName `
        -ResourcePrefix 'Contoso Sample' `
        -EnvironmentName 'Dev 01' `
        -Domain 'customer.example'
    if ($agentUserPrincipalName -ne 'foundry-w365-contoso-sample-dev-01@customer.example') {
        throw "Unexpected deterministic W365 agent-user UPN '$agentUserPrincipalName'."
    }
    $longAgentUserPrincipalName = Get-W365AgentUserPrincipalName `
        -ResourcePrefix ('prefix-' + ('a' * 80)) `
        -EnvironmentName ('environment-' + ('b' * 80)) `
        -Domain 'customer.example'
    $longLocalPart = $longAgentUserPrincipalName.Split('@')[0]
    if ($longLocalPart.Length -gt 64 -or $longLocalPart -notmatch '-[0-9a-f]{8}$') {
        throw "Long W365 agent-user UPN was not bounded deterministically: '$longAgentUserPrincipalName'."
    }
    $resolvedAgentUserPrincipalName = Resolve-W365OwnedAgentUserPrincipalName `
        -Domains $domains `
        -ResourcePrefix 'contoso' `
        -EnvironmentName 'contoso-dev'
    if ($resolvedAgentUserPrincipalName -ne 'foundry-w365-contoso-contoso-dev@customer.example') {
        throw "Automatic W365 agent-user UPN did not use the generic default domain: '$resolvedAgentUserPrincipalName'."
    }
    $ownedAgentUser = [ordered]@{
        w365 = [ordered]@{
            agentUser = [ordered]@{
                userPrincipalName = 'owned-agent@tenant.onmicrosoft.com'
            }
        }
    }
    if ((Resolve-W365OwnedAgentUserPrincipalName `
        -OwnershipManifest $ownedAgentUser `
        -Domains $domains) -ne 'owned-agent@tenant.onmicrosoft.com') {
        throw 'W365 agent-user UPN resolution did not preserve the manifest-owned UPN.'
    }
    Assert-Throws {
        Resolve-W365OwnedAgentUserPrincipalName `
            -ExplicitPrincipalName 'different@customer.example' `
            -OwnershipManifest $ownedAgentUser `
            -Domains $domains | Out-Null
    } 'W365 agent-user UPN resolution accepted an override that conflicted with the ownership manifest.'

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

    $agentIdentityId = [guid]'44444444-4444-4444-4444-444444444444'
    $tenantId = [guid]'22222222-2222-2222-2222-222222222222'
    $blueprintId = [guid]'11111111-1111-1111-1111-111111111111'
    $activationValues = [ordered]@{
        DEPLOY_STATE = 'true'
        SESSION_BLOB_URI = 'https://samplestate.blob.core.windows.net/desktop-state/slot.json'
        STATE_AGENT_PRINCIPAL_ID = $agentIdentityId.ToString()
        OPERATOR_TENANT_ID = '66666666-6666-6666-6666-666666666666'
        OPERATOR_OBJECT_ID = '77777777-7777-7777-7777-777777777777'
        HOSTED_ALLOWED_USER_ID = 'pending'
        W365_BLUEPRINT_CREDENTIAL_MODE = 'client_secret'
        W365_KEY_VAULT_NAME = 'sample-w365-vault'
    }
    $activation = Assert-W365ActivationPrerequisites `
        -EnvironmentValues $activationValues `
        -ExpectedAgentIdentityId $agentIdentityId
    if ($activation.CredentialMode -ne 'client_secret' -or
        $activation.KeyVaultName -ne 'sample-w365-vault') {
        throw 'W365 activation prerequisite validation did not return the selected credential configuration.'
    }
    Assert-Throws {
        $invalid = [ordered]@{} + $activationValues
        $invalid.STATE_AGENT_PRINCIPAL_ID = '55555555-5555-5555-5555-555555555555'
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $invalid `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
    } 'W365 activation accepted state provisioned for a different agent principal.'
    Assert-Throws {
        $invalid = [ordered]@{} + $activationValues
        $invalid.DEPLOY_STATE = 'false'
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $invalid `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
    } 'W365 activation accepted DEPLOY_STATE=false.'
    Assert-Throws {
        $invalid = [ordered]@{} + $activationValues
        $invalid.Remove('W365_KEY_VAULT_NAME')
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $invalid `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
    } 'W365 activation accepted client-secret mode without the shared Key Vault.'
    $federatedValues = [ordered]@{} + $activationValues
    $federatedValues.W365_BLUEPRINT_CREDENTIAL_MODE = 'managed_identity_federation'
    $federatedValues.Remove('W365_KEY_VAULT_NAME')
    Assert-Throws {
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $federatedValues `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
    } 'W365 activation accepted managed identity without explicit federation authorization.'
    Assert-Throws {
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $federatedValues `
            -ExpectedAgentIdentityId $agentIdentityId `
            -HostedRuntimeIdentityObjectId '55555555-5555-5555-5555-555555555555' `
            -AuthorizeHostedRuntimeFederation:$true | Out-Null
    } 'W365 activation accepted federation authorization for a different identity.'
    Assert-W365ActivationPrerequisites `
        -EnvironmentValues $federatedValues `
        -ExpectedAgentIdentityId $agentIdentityId `
        -HostedRuntimeIdentityObjectId $agentIdentityId `
        -AuthorizeHostedRuntimeFederation:$true | Out-Null

    $certificateValues = [ordered]@{} + $activationValues
    $certificateValues.W365_BLUEPRINT_CREDENTIAL_MODE = 'key_vault_certificate'
    $certificateActivation = Assert-W365ActivationPrerequisites `
        -EnvironmentValues $certificateValues `
        -ExpectedAgentIdentityId $agentIdentityId
    if ($certificateActivation.CredentialMode -ne 'key_vault_certificate' -or
        $certificateActivation.KeyVaultName -ne 'sample-w365-vault') {
        throw 'W365 activation prerequisite validation did not return the certificate credential configuration.'
    }
    Assert-Throws {
        $invalid = [ordered]@{} + $certificateValues
        $invalid.Remove('W365_KEY_VAULT_NAME')
        Assert-W365ActivationPrerequisites `
            -EnvironmentValues $invalid `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
    } 'W365 activation accepted key_vault_certificate mode without the shared Key Vault.'

    $savedStateBehavior = $env:TEST_W365_STATE_BEHAVIOR
    function az {
        $arguments = @($args)
        $global:LASTEXITCODE = 0
        if ($arguments[0] -eq 'storage' -and $arguments[1] -eq 'account') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-account') {
                $global:LASTEXITCODE = 1
                return ''
            }
            return '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/state-rg/providers/Microsoft.Storage/storageAccounts/samplestate'
        }
        if ($arguments[0] -eq 'rest') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-container') {
                $global:LASTEXITCODE = 1
                return ''
            }
            return 'desktop-state'
        }
        if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-role') {
                return ''
            }
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'wrong-role') {
                return '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
            }
            return '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        }
        if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'secret') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-secret') {
                $global:LASTEXITCODE = 1
                return ''
            }
            return 'https://sample-w365-vault.vault.azure.net/secrets/w365-blueprint-client-secret/version'
        }
        if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-certificate') {
                $global:LASTEXITCODE = 1
                return ''
            }
            return 'https://sample-w365-vault.vault.azure.net/certificates/w365-blueprint-certificate/version'
        }
        if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
            return 'https://sample-w365-vault.vault.azure.net/'
        }
        if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
            return 'fake-token'
        }
        throw "Unexpected state-read Azure CLI call: $($arguments -join ' ')"
    }
    $testCertificateRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=w365-blueprint-certificate',
        [System.Security.Cryptography.RSA]::Create(2048),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    ).CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
    $testCertificateCerBase64Url = [Convert]::ToBase64String($testCertificateRequest.RawData).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    $testCertificateKeyIdentifier = [Convert]::ToBase64String($testCertificateRequest.GetCertHash())
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers)
        if ($Uri -like '*/certificates/w365-blueprint-certificate*') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'missing-certificate') {
                throw 'Simulated: certificate bundle unavailable in Key Vault.'
            }
            return [pscustomobject]@{ cer = $testCertificateCerBase64Url }
        }
        if ([string]$Uri -like 'https://graph.microsoft.com/v1.0/applications(appId=*') {
            if ($env:TEST_W365_STATE_BEHAVIOR -eq 'not-registered') {
                return [pscustomobject]@{ keyCredentials = @() }
            }
            return [pscustomobject]@{ keyCredentials = @(
                [pscustomobject]@{ customKeyIdentifier = $testCertificateKeyIdentifier }
            ) }
        }
        throw "Unexpected mocked REST call: $Uri"
    }
    try {
        $env:TEST_W365_STATE_BEHAVIOR = 'ready'
        Assert-W365StateResourceReady `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -SessionBlobUri 'https://samplestate.blob.core.windows.net/desktop-state/slot.json' `
            -ExpectedAgentIdentityId $agentIdentityId | Out-Null
        foreach ($invalidUri in @(
            'https://user@samplestate.blob.core.windows.net/desktop-state/slot.json',
            'https://samplestate.blob.core.windows.net:444/desktop-state/slot.json',
            'https://samplestate.blob.core.windows.net/desktop-state/slot.json?sig=redacted',
            'https://samplestate.blob.core.windows.net/desktop-state/slot.json#fragment',
            'https://samplestate.blob.core.windows.net/desktop-state/%73lot.json',
            'https://samplestate.blob.core.windows.net/desktop-state/not-slot.json',
            'https://samplestate.blob.core.windows.net/desktop-state/slot.json/extra'
        )) {
            Assert-Throws {
                Assert-W365StateResourceReady `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                    -SessionBlobUri $invalidUri `
                    -ExpectedAgentIdentityId $agentIdentityId | Out-Null
            } "W365 state readiness accepted non-exact Blob URI '$invalidUri'."
        }
        foreach ($behavior in @('missing-account', 'missing-container', 'missing-role', 'wrong-role')) {
            $env:TEST_W365_STATE_BEHAVIOR = $behavior
            Assert-Throws {
                Assert-W365StateResourceReady `
                    -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                    -SessionBlobUri 'https://samplestate.blob.core.windows.net/desktop-state/slot.json' `
                    -ExpectedAgentIdentityId $agentIdentityId | Out-Null
            } "W365 state readiness accepted failure mode '$behavior'."
        }
        $env:TEST_W365_STATE_BEHAVIOR = 'ready'
        Assert-W365BlueprintSecretReady `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -KeyVaultName 'sample-w365-vault'
        $env:TEST_W365_STATE_BEHAVIOR = 'missing-secret'
        Assert-Throws {
            Assert-W365BlueprintSecretReady `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -KeyVaultName 'sample-w365-vault'
        } 'W365 blueprint-secret readiness accepted a missing Key Vault secret.'
        $env:TEST_W365_STATE_BEHAVIOR = 'ready'
        Assert-W365BlueprintCertificateReady `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -KeyVaultName 'sample-w365-vault' `
            -TenantId $tenantId `
            -BlueprintId $blueprintId
        $env:TEST_W365_STATE_BEHAVIOR = 'missing-certificate'
        Assert-Throws {
            Assert-W365BlueprintCertificateReady `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -KeyVaultName 'sample-w365-vault' `
                -TenantId $tenantId `
                -BlueprintId $blueprintId
        } 'W365 blueprint-certificate readiness accepted a missing Key Vault certificate.'
        $env:TEST_W365_STATE_BEHAVIOR = 'not-registered'
        Assert-Throws {
            Assert-W365BlueprintCertificateReady `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -KeyVaultName 'sample-w365-vault' `
                -TenantId $tenantId `
                -BlueprintId $blueprintId
        } 'W365 blueprint-certificate readiness accepted a certificate not registered on the blueprint.'
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'TEST_W365_STATE_BEHAVIOR',
            $savedStateBehavior,
            'Process')
        Remove-Item Function:\az -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }

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
            agentUser = [ordered]@{
                id = 'agent-user-id'
                userPrincipalName = 'foundry-w365-contoso-contoso-dev@customer.example'
            }
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
        W365_AGENT_USER_PRINCIPAL_NAME = 'foundry-w365-contoso-contoso-dev@customer.example'
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
    $persisted.W365_POOL_ID = 'pool-id'
    $persisted.W365_AGENT_USER_PRINCIPAL_NAME = 'different@customer.example'
    Assert-Throws {
        Get-W365ProvisioningState `
            -RepositoryRoot $tempRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $persisted | Out-Null
    } 'W365 provisioning accepted an agent-user UPN that drifted from the ownership manifest.'

    Write-Output 'Offline W365 provisioning: generic tenant domains, deterministic naming, approval, and fail-closed ownership state passed.'
}
finally {
    Remove-Item Function:\azd -Force -ErrorAction SilentlyContinue
    $env:PATH = $previousPath
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
