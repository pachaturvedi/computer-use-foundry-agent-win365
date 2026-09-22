#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$cleanupScriptPath = Join-Path $scriptsRoot 'Remove-W365Resources.ps1'
$cleanupScriptText = Get-Content -LiteralPath $cleanupScriptPath -Raw
$tokens = $null
$parseErrors = $null
$cleanupAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cleanupScriptText,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Remove-W365Resources.ps1 failed to parse: $($parseErrors[0].Message)"
}

$getAzdCommandAst = $cleanupAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-AzdCommand'
}, $true) | Select-Object -First 1
if (!$getAzdCommandAst) {
    throw "Unable to locate function 'Get-AzdCommand' in Remove-W365Resources.ps1 for isolated testing."
}

$commandDiscoveryTempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-azd-discovery-{0}" -f ([guid]::NewGuid()))
$malformedAzdRoot = Join-Path $commandDiscoveryTempRoot 'malformed'
$validAzdRoot = Join-Path $commandDiscoveryTempRoot 'valid'
$fakeAzdFileName = if ($IsWindows) { 'azd.cmd' } else { 'azd' }
$malformedAzdPath = Join-Path $malformedAzdRoot $fakeAzdFileName
$fakeAzdPath = Join-Path $validAzdRoot $fakeAzdFileName
$previousPath = $env:PATH
try {
    New-Item -ItemType Directory -Path $malformedAzdRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $validAzdRoot -Force | Out-Null
    if ($IsWindows) {
        Set-Content -LiteralPath $malformedAzdPath -Value '@echo azd version 999999999999.1.1 (commit malformed-test)'
        Set-Content -LiteralPath $fakeAzdPath -Value '@echo azd version 9.99.9 (commit offline-test)'
    }
    else {
        Set-Content -LiteralPath $malformedAzdPath -Value "#!/bin/sh`necho 'azd version 999999999999.1.1 (commit malformed-test)'"
        Set-Content -LiteralPath $fakeAzdPath -Value "#!/bin/sh`necho 'azd version 9.99.9 (commit offline-test)'"
        $executableMode = [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        [IO.File]::SetUnixFileMode($malformedAzdPath, $executableMode)
        [IO.File]::SetUnixFileMode($fakeAzdPath, $executableMode)
    }
    $env:PATH = @($malformedAzdRoot, $validAzdRoot, $previousPath) -join [IO.Path]::PathSeparator

    $commandDiscoveryModule = New-Module -Name W365AzdCommandDiscovery -ScriptBlock ([scriptblock]::Create(@"
$($getAzdCommandAst.Extent.Text)
function azd { 'profile shadow' }
"@))
    $azd = & $commandDiscoveryModule { Get-AzdCommand }
    if ($null -eq $azd -or $azd.Path -ne $fakeAzdPath -or $azd.Version -ne ([version]'9.99.9')) {
        throw 'Cleanup azd discovery did not ignore invalid candidates or select the highest supported executable.'
    }
}
finally {
    $env:PATH = $previousPath
    if ($commandDiscoveryModule) {
        Remove-Module $commandDiscoveryModule
    }
    if (Test-Path -LiteralPath $commandDiscoveryTempRoot) {
        Remove-Item -LiteralPath $commandDiscoveryTempRoot -Recurse -Force
    }
}

$noStateTempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-no-state-{0}" -f ([guid]::NewGuid()))
$noStateEnvironmentPath = Join-Path $noStateTempRoot '.env'
try {
    New-Item -ItemType Directory -Path $noStateTempRoot -Force | Out-Null
    Set-Content -LiteralPath $noStateEnvironmentPath -Value @(
        'AZURE_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"'
        'W365_ENABLED="false"'
    )

    $noStateOutput = @(
        & $cleanupScriptPath `
            -EnvironmentName 'no-state-test' `
            -EnvironmentFilePath $noStateEnvironmentPath `
            -OwnershipManifestPath (Join-Path $noStateTempRoot 'missing-ownership.json') `
            -Confirm:$false
    )
    $expectedNoStateOutput = "Pre-teardown cleanup completed for 'no-state-test': no configured W365 state remains. Azure resource deletion can continue."
    if ($noStateOutput.Count -ne 1 -or $noStateOutput[0] -ne $expectedNoStateOutput) {
        throw "No-state cleanup emitted unexpected output: [$($noStateOutput -join ' | ')]"
    }
}
finally {
    if (Test-Path -LiteralPath $noStateTempRoot) {
        Remove-Item -LiteralPath $noStateTempRoot -Recurse -Force
    }
}

$previousPredownState = $env:W365_PREDOWN_ALREADY_COMPLETED
try {
    $env:W365_PREDOWN_ALREADY_COMPLETED = 'true'
    $alreadyCompletedOutput = @(
        & $cleanupScriptPath `
            -EnvironmentName 'already-completed-test' `
            -EnvironmentFilePath 'missing-environment-file' `
            -OwnershipManifestPath 'missing-ownership-file' `
            -Confirm:$false
    )
    $expectedAlreadyCompletedOutput = 'W365 pre-teardown cleanup was already completed by Invoke-AzdDown.ps1. Azure resource deletion can continue.'
    if ($alreadyCompletedOutput.Count -ne 1 -or
        $alreadyCompletedOutput[0] -ne $expectedAlreadyCompletedOutput) {
        throw "Repeated predown cleanup emitted unexpected output: [$($alreadyCompletedOutput -join ' | ')]"
    }
}
finally {
    [Environment]::SetEnvironmentVariable('W365_PREDOWN_ALREADY_COMPLETED', $previousPredownState, 'Process')
}

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:tenant = '01eed126-9f96-4d2d-a127-dc2e786a898b'
    $script:scopes = @()
    $script:baseState = $null
    $script:state = $null

    function New-BaseState {
        return @{
            Blueprint = @{
                id = 'blueprint-object'
                appId = '11111111-1111-1111-1111-111111111111'
                requiredResourceAccess = @(
                    @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) },
                    @{ resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; resourceAccess = @(
                        @{ id = 'scope-Computer.See'; type = 'Scope' },
                        @{ id = 'scope-Computer.Control'; type = 'Scope' }
                    ) },
                    @{ resourceAppId = 'da81128c-e5b5-4f9e-8d89-50d906f107c5'; resourceAccess = @(@{ id = 'scope-Tools.ListInvoke.All'; type = 'Scope' }) },
                    @{ resourceAppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'; resourceAccess = @(@{ id = 'scope-McpServersMetadata.Read.All'; type = 'Scope' }) }
                )
            }
            Pool = @{
                '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
                id = '55555555-5555-5555-5555-555555555555'
                displayName = 'Sample owned pool'
                description = 'Created by setup'
            }
            AgentUser = @{ id = 'agent-user'; userPrincipalName = 'agent@example.com'; identityParentId = '22222222-2222-2222-2222-222222222222' }
            Assignments = @(
                @{ id = 'assignment-created'; userPrincipalId = 'agent-user' }
            )
            Fics = @(
                @{ id = 'fic-created'; name = 'w365-hosted-22222222-2222-2222-2222-222222222222'; subject = '22222222-2222-2222-2222-222222222222'; issuer = 'https://login.microsoftonline.com/01eed126-9f96-4d2d-a127-dc2e786a898b/v2.0'; audiences = @('api://AzureADTokenExchange') },
                @{ id = 'fic-unrelated'; name = 'unrelated-fic'; subject = 'elsewhere'; issuer = 'https://login.microsoftonline.com/01eed126-9f96-4d2d-a127-dc2e786a898b/v2.0'; audiences = @('api://AzureADTokenExchange') }
            )
            Grants = @(
                @{ id = 'grant-created-tools'; resourceId = 'sp-tools'; consentType = 'AllPrincipals'; scope = 'Tools.ListInvoke.All' },
                @{ id = 'grant-created-meta'; resourceId = 'sp-meta'; consentType = 'AllPrincipals'; scope = 'McpServersMetadata.Read.All' },
                @{ id = 'grant-reused-computer'; resourceId = 'sp-computer'; consentType = 'AllPrincipals'; scope = 'Computer.Control Computer.Do Computer.Get Computer.See' },
                @{ id = 'grant-unrelated'; resourceId = 'sp-unrelated'; consentType = 'AllPrincipals'; scope = 'Keep.Scope' }
            )
            Inheritances = @(
                @{ id = 'inherit-created-tools'; resourceAppId = 'da81128c-e5b5-4f9e-8d89-50d906f107c5'; inheritableScopes = @{ kind = 'allAllowed' }; inheritableRoles = @{ kind = 'none' } },
                @{ id = 'inherit-created-meta'; resourceAppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'; inheritableScopes = @{ kind = 'allAllowed' }; inheritableRoles = @{ kind = 'none' } },
                @{ id = 'inherit-reused-computer'; resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; inheritableScopes = @{ kind = 'allAllowed' }; inheritableRoles = @{ kind = 'none' } },
                @{ id = 'inherit-unrelated'; resourceAppId = 'unrelated-resource'; inheritableScopes = @{ kind = 'allAllowed' }; inheritableRoles = @{ kind = 'none' } }
            )
            Operations = @()
            FailReusedGrantLookup = $false
            FailReusedInheritanceLookup = $false
        }
    }

    function Reset-MockGraphState {
        $script:baseState = New-BaseState
        $script:state = ($script:baseState | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable)
    }

    function Get-MockGraphState {
        return ($script:state | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable)
    }

    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode)
        $script:tenant = $TenantId.ToString()
        $script:scopes = $Scopes
    }

    function Get-MgContext {
        return @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes }
    }

    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)

        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }

        if ($Method -eq 'GET') {
            switch -Wildcard ($path) {
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/55555555-5555-5555-5555-555555555555/assignments' { return @{ value = @($script:state.Assignments) } }
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/55555555-5555-5555-5555-555555555555' {
                    if ($null -eq $script:state.Pool) { throw 'Pool not found' }
                    return $script:state.Pool
                }
                'beta/users/microsoft.graph.agentUser?*' {
                    return @{ value = @($script:state.AgentUser | Where-Object { $_ }) }
                }
                'v1.0/oauth2PermissionGrants?*' {
                    if ($script:state.FailReusedGrantLookup) {
                        return @{ value = @($script:state.Grants | Where-Object { $_.id -ne 'grant-reused-computer' }) }
                    }
                    return @{ value = @($script:state.Grants) }
                }
                'v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials' { return @{ value = @($script:state.Fics) } }
                'v1.0/applications/microsoft.graph.agentIdentityBlueprint/11111111-1111-1111-1111-111111111111/inheritablePermissions' {
                    if ($script:state.FailReusedInheritanceLookup) {
                        return @{ value = @($script:state.Inheritances | Where-Object { $_.id -ne 'inherit-reused-computer' }) }
                    }
                    return @{ value = @($script:state.Inheritances) }
                }
                'v1.0/applications/blueprint-object?*' { return $script:state.Blueprint }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        if ($Method -eq 'DELETE') {
            $script:state.Operations += "DELETE $path"
            switch -Wildcard ($path) {
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/*/assignments/*' {
                    $id = $path.Split('/')[-1]
                    $script:state.Assignments = @($script:state.Assignments | Where-Object { $_.id -ne $id })
                    return
                }
                'beta/users/*' {
                    $script:state.AgentUser = $null
                    return
                }
                'v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials/*' {
                    $id = $path.Split('/')[-1]
                    $script:state.Fics = @($script:state.Fics | Where-Object { $_.id -ne $id })
                    return
                }
                'v1.0/oauth2PermissionGrants/*' {
                    $id = $path.Split('/')[-1]
                    $script:state.Grants = @($script:state.Grants | Where-Object { $_.id -ne $id })
                    return
                }
                'v1.0/applications/microsoft.graph.agentIdentityBlueprint/*/inheritablePermissions/*' {
                    $id = $path.Split('/')[-1]
                    $script:state.Inheritances = @($script:state.Inheritances | Where-Object { $_.id -ne $id })
                    return
                }
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/*' {
                    $script:state.Pool = $null
                    return
                }
            }
        }

        if ($Method -eq 'PATCH') {
            $script:state.Operations += "PATCH $path"
            switch -Wildcard ($path) {
                'v1.0/oauth2PermissionGrants/*' {
                    $id = $path.Split('/')[-1]
                    $grant = @($script:state.Grants | Where-Object { $_.id -eq $id })[0]
                    $grant.scope = $bodyObject.scope
                    return
                }
                'v1.0/applications/blueprint-object' {
                    $script:state.Blueprint.requiredResourceAccess = $bodyObject.requiredResourceAccess
                    return
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        throw "Unexpected mocked Graph request: $Method $path"
    }

    Reset-MockGraphState
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Reset-MockGraphState, Get-MockGraphState
}

$module | Import-Module -Global

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-cleanup-{0}" -f ([guid]::NewGuid()))
$envName = 'cleanup-test'
$envDir = Join-Path $tempRoot $envName
$envFilePath = Join-Path $envDir '.env'
$manifestPath = Join-Path $envDir 'w365-ownership.json'
$previousCleanupApproval = $env:W365_CLEANUP_CONFIRMED

function Write-TestEnvironment {
    param(
        [string]$ProjectOwnership = 'managed',
        [string]$ProjectEndpoint = '',
        [switch]$OmitProjectOwnership
    )

    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    $lines = @(
        'AZURE_TENANT_ID="01eed126-9f96-4d2d-a127-dc2e786a898b"'
        'W365_TENANT_ID="01eed126-9f96-4d2d-a127-dc2e786a898b"'
        'W365_ENABLED="true"'
        'W365_POOL_ID="55555555-5555-5555-5555-555555555555"'
        'W365_AGENT_USER_ID="agent-user"'
    )
    if (!$OmitProjectOwnership) {
        $lines += "FOUNDRY_PROJECT_OWNERSHIP=`"$ProjectOwnership`""
    }
    if (![string]::IsNullOrWhiteSpace($ProjectEndpoint)) {
        $lines += "FOUNDRY_PROJECT_ENDPOINT=`"$ProjectEndpoint`""
    }

    Set-Content -LiteralPath $envFilePath -Value $lines
}

function Write-TestManifest {
    param([string]$ProjectOwnership = 'managed')

    $manifest = [ordered]@{
        schemaVersion = 1
        environmentName = $envName
        foundry = [ordered]@{
            projectOwnership = $ProjectOwnership
            existingProjectBound = $ProjectOwnership -eq 'existing'
            projectEndpoint = 'https://example.services.ai.azure.com/api/projects/proj'
            projectId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/acct/projects/proj'
            resourceGroupName = 'rg-test'
            resourceGroupId = '/subscriptions/sub/resourceGroups/rg-test'
        }
        w365 = [ordered]@{
            pool = [ordered]@{ id = '55555555-5555-5555-5555-555555555555'; displayName = 'Sample owned pool'; disposition = 'created' }
            agentUser = [ordered]@{ id = 'agent-user'; userPrincipalName = 'agent@example.com'; parentAgentObjectId = '22222222-2222-2222-2222-222222222222'; disposition = 'created' }
            assignment = [ordered]@{ id = 'assignment-created'; poolId = '55555555-5555-5555-5555-555555555555'; userPrincipalId = 'agent-user'; disposition = 'created' }
        }
        graph = [ordered]@{
            blueprint = [ordered]@{
                appId = '11111111-1111-1111-1111-111111111111'
                objectId = 'blueprint-object'
                principalId = 'blueprint-sp'
                requiredResourceAccessBefore = @(
                    @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) },
                    @{ resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; resourceAccess = @(@{ id = 'scope-Computer.See'; type = 'Scope' }) }
                )
                requiredResourceAccessAdded = @(
                    @{ resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; resourceAccess = @(
                        @{ id = 'scope-Computer.Do'; type = 'Scope' },
                        @{ id = 'scope-Computer.Get'; type = 'Scope' }
                    ) },
                    @{ resourceAppId = 'da81128c-e5b5-4f9e-8d89-50d906f107c5'; resourceAccess = @(@{ id = 'scope-Tools.ListInvoke.All'; type = 'Scope' }) },
                    @{ resourceAppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'; resourceAccess = @(@{ id = 'scope-McpServersMetadata.Read.All'; type = 'Scope' }) }
                )
            }
            agent = [ordered]@{ appId = '33333333-3333-3333-3333-333333333333'; objectId = '22222222-2222-2222-2222-222222222222' }
            permissionGrants = [ordered]@{
                createdTools = [ordered]@{ resourceAppId = 'da81128c-e5b5-4f9e-8d89-50d906f107c5'; resourceId = 'sp-tools'; grantId = 'grant-created-tools'; disposition = 'created'; previousScope = ''; scope = 'Tools.ListInvoke.All' }
                createdMeta = [ordered]@{ resourceAppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'; resourceId = 'sp-meta'; grantId = 'grant-created-meta'; disposition = 'created'; previousScope = ''; scope = 'McpServersMetadata.Read.All' }
                reusedComputer = [ordered]@{ resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; resourceId = 'sp-computer'; grantId = 'grant-reused-computer'; disposition = 'reused'; previousScope = 'Computer.Control Computer.See'; scope = 'Computer.Control Computer.Do Computer.Get Computer.See' }
            }
            inheritablePermissions = [ordered]@{
                createdTools = [ordered]@{ resourceAppId = 'da81128c-e5b5-4f9e-8d89-50d906f107c5'; entryId = 'inherit-created-tools'; disposition = 'created' }
                createdMeta = [ordered]@{ resourceAppId = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'; entryId = 'inherit-created-meta'; disposition = 'created' }
                reusedComputer = [ordered]@{ resourceAppId = '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'; entryId = 'inherit-reused-computer'; disposition = 'reused' }
            }
            federatedIdentityCredentials = [ordered]@{
                hosted = [ordered]@{ id = 'fic-created'; name = 'w365-hosted-22222222-2222-2222-2222-222222222222'; subject = '22222222-2222-2222-2222-222222222222'; disposition = 'created' }
            }
        }
    }

    Set-Content -LiteralPath $manifestPath -Value (ConvertTo-Json $manifest -Depth 60)
}

try {
    Write-TestEnvironment
    Write-TestManifest

    $env:W365_CLEANUP_CONFIRMED = 'true'
    $cleanupOutput = @(
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath
    )
    $env:W365_CLEANUP_CONFIRMED = ''
    $assignmentPlan = "Deleting W365 pool assignment 'assignment-created' from pool '55555555-5555-5555-5555-555555555555' for principal 'agent-user'."
    $assignmentResult = 'Removed pool assignment assignment-created.'
    $rolePlan = "Deleting delegated permission grant 'grant-created-tools' for resource application 'da81128c-e5b5-4f9e-8d89-50d906f107c5'."
    $roleResult = 'Removed permission grant for da81128c-e5b5-4f9e-8d89-50d906f107c5.'
    $poolPlan = "Deleting sample-owned W365 pool '55555555-5555-5555-5555-555555555555'."
    $poolResult = 'Removed sample-owned pool 55555555-5555-5555-5555-555555555555.'
    foreach ($pair in @(
        @($assignmentPlan, $assignmentResult),
        @($rolePlan, $roleResult),
        @($poolPlan, $poolResult)
    )) {
        $planIndex = $cleanupOutput.IndexOf($pair[0])
        $resultIndex = $cleanupOutput.IndexOf($pair[1])
        if ($planIndex -lt 0 -or $resultIndex -lt 0 -or $planIndex -ge $resultIndex) {
            throw "Cleanup did not log '$($pair[0])' before '$($pair[1])'."
        }
    }

    $state = Get-MockGraphState
    if ($null -ne $state.Pool -or $null -ne $state.AgentUser) {
        throw 'Created pool or agent user was not deleted.'
    }
    if (@($state.Assignments | Where-Object { $_.id -eq 'assignment-created' }).Count -ne 0) {
        throw 'Created assignment was not deleted.'
    }
    if (@($state.Fics | Where-Object { $_.id -eq 'fic-created' }).Count -ne 0 -or @($state.Fics | Where-Object { $_.id -eq 'fic-unrelated' }).Count -ne 1) {
        throw 'Federated credential cleanup touched the wrong entries.'
    }
    if (@($state.Grants | Where-Object { $_.id -eq 'grant-created-tools' -or $_.id -eq 'grant-created-meta' }).Count -ne 0) {
        throw 'Created permission grants were not deleted.'
    }
    if ((@($state.Grants | Where-Object { $_.id -eq 'grant-reused-computer' })[0]).scope -ne 'Computer.Control Computer.See') {
        throw 'Reused permission grant was not restored.'
    }
    if (@($state.Grants | Where-Object { $_.id -eq 'grant-unrelated' }).Count -ne 1) {
        throw 'Unrelated permission grant should have been preserved.'
    }
    if (@($state.Inheritances | Where-Object { $_.id -eq 'inherit-created-tools' -or $_.id -eq 'inherit-created-meta' }).Count -ne 0) {
        throw 'Created inheritance entries were not deleted.'
    }
    if (@($state.Inheritances | Where-Object { $_.id -eq 'inherit-reused-computer' }).Count -ne 1 -or @($state.Inheritances | Where-Object { $_.id -eq 'inherit-unrelated' }).Count -ne 1) {
        throw 'Cleanup did not preserve reused or unrelated inheritance entries.'
    }
    $requiredEntries = @($state.Blueprint.requiredResourceAccess)
    $unrelatedEntry = @($requiredEntries | Where-Object { $_.resourceAppId -eq 'unrelated-resource' })
    $computerEntry = @($requiredEntries | Where-Object { $_.resourceAppId -eq '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5' })
    if ($requiredEntries.Count -ne 2 -or
        $unrelatedEntry.Count -ne 1 -or
        @($unrelatedEntry[0].resourceAccess).Count -ne 1 -or
        [string]@($unrelatedEntry[0].resourceAccess)[0].id -ne 'unrelated-scope' -or
        $computerEntry.Count -ne 1 -or
        @($computerEntry[0].resourceAccess).Count -ne 2 -or
        'scope-Computer.See' -notin @($computerEntry[0].resourceAccess | ForEach-Object { [string]$_.id }) -or
        'scope-Computer.Control' -notin @($computerEntry[0].resourceAccess | ForEach-Object { [string]$_.id })) {
        throw 'Blueprint requiredResourceAccess was not restored.'
    }
    $assignmentDeleteIndex = $state.Operations.IndexOf('DELETE beta/deviceManagement/virtualEndpoint/cloudPcPools/55555555-5555-5555-5555-555555555555/assignments/assignment-created')
    $userDeleteIndex = $state.Operations.IndexOf('DELETE beta/users/agent-user')
    $poolDeleteIndex = $state.Operations.IndexOf('DELETE beta/deviceManagement/virtualEndpoint/cloudPcPools/55555555-5555-5555-5555-555555555555')
    if ($assignmentDeleteIndex -lt 0 -or $userDeleteIndex -lt 0 -or $poolDeleteIndex -lt 0 -or !($assignmentDeleteIndex -lt $userDeleteIndex -and $userDeleteIndex -lt $poolDeleteIndex)) {
        throw 'Cleanup order did not remove W365 dependencies before the pool.'
    }
    $savedOperations = @($state.Operations)

    & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne $savedOperations.Count) {
        throw 'Cleanup rerun should have been idempotent.'
    }

    Reset-MockGraphState
    Write-TestEnvironment
    Write-TestManifest
    & $module { $script:state.Assignments += @{ id = 'assignment-unrelated'; userPrincipalId = 'someone-else' } }
    $sharedAssignmentBlocked = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $sharedAssignmentBlocked = $true
    }
    if (!$sharedAssignmentBlocked) {
        throw 'Cleanup should block before deleting a pool assigned to another principal.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Shared pool-assignment preflight mutated state before blocking.'
    }

    Reset-MockGraphState
    Write-TestEnvironment -ProjectOwnership existing
    Write-TestManifest -ProjectOwnership existing
    $blocked = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $blocked = $true
    }
    if (!$blocked) {
        throw 'Existing-project cleanup should require an explicit override.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Existing-project cleanup mutated state before blocking.'
    }

    Reset-MockGraphState
    Write-TestEnvironment -OmitProjectOwnership -ProjectEndpoint 'https://example.services.ai.azure.com/api/projects/proj'
    Write-TestManifest -ProjectOwnership unknown
    $inferredExistingBlocked = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $inferredExistingBlocked = $true
    }
    if (!$inferredExistingBlocked) {
        throw 'An existing project endpoint without explicit ownership should fail closed.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Inferred existing-project cleanup mutated state before blocking.'
    }

    Reset-MockGraphState
    Write-TestEnvironment
    if (Test-Path -LiteralPath $manifestPath) {
        Remove-Item -LiteralPath $manifestPath
    }
    $missingManifestBlocked = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $missingManifestBlocked = $true
    }
    if (!$missingManifestBlocked) {
        throw 'Cleanup should fail closed when W365 state exists but the ownership manifest is missing.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Missing-manifest cleanup mutated state before blocking.'
    }

    Reset-MockGraphState
    Write-TestEnvironment
    Write-TestManifest
    & $module { $script:state.FailReusedGrantLookup = $true }
    $failed = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $failed = $true
    }
    if (!$failed) {
        throw 'Cleanup should fail closed when a reused grant cannot be restored.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Reused-grant preflight should block cleanup before any deletions run.'
    }

    Reset-MockGraphState
    Write-TestEnvironment
    Write-TestManifest
    & $module { $script:state.FailReusedInheritanceLookup = $true }
    $inheritanceFailed = $false
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $manifestPath -Confirm:$false | Out-Null
    }
    catch {
        $inheritanceFailed = $true
    }
    if (!$inheritanceFailed) {
        throw 'Cleanup should fail closed when a reused inheritance entry cannot be verified.'
    }
    $state = Get-MockGraphState
    if ($state.Operations.Count -ne 0) {
        throw 'Reused-inheritance preflight should block cleanup before any deletions run.'
    }

    Write-Output 'Offline cleanup: protected approval, reverse-order deletion, idempotent rerun, shared-project guard, and fail-closed partial cleanup passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('W365_CLEANUP_CONFIRMED', $previousCleanupApproval, 'Process')
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }

    Remove-Module Microsoft.Graph.Authentication
}