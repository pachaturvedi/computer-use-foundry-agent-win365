#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:tenant = '01eed126-9f96-4d2d-a127-dc2e786a898b'
    $script:scopes = @()
    $script:blueprintId = '11111111-1111-1111-1111-111111111111'
    $script:agentObjectId = '22222222-2222-2222-2222-222222222222'
    $script:agentClientId = '33333333-3333-3333-3333-333333333333'
    $script:viewerObjectId = '44444444-4444-4444-4444-444444444444'
    $script:billingPlanId = '66666666-6666-6666-6666-666666666666'
    $script:nextGrantIndex = 1
    $script:nextInheritanceIndex = 0
    $script:nextFicIndex = 0
    $script:nextAssignmentIndex = 0
    $script:state = $null

    function Reset-MockGraphState {
        $script:nextGrantIndex = 0
        $script:nextInheritanceIndex = 0
        $script:nextFicIndex = 0
        $script:nextAssignmentIndex = 0
        $script:state = @{
            Blueprint = @{
                id = 'blueprint-object'
                appId = $script:blueprintId
                keyCredentials = @('untouched-key')
                requiredResourceAccess = @(
                    @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) }
                )
            }
            Principal = @{ id = 'blueprint-sp'; appId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentityBlueprintPrincipal' }
            Agent = @{ id = $script:agentObjectId; appId = $script:agentClientId; displayName = 'Existing Foundry agent'; agentIdentityBlueprintId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentity' }
            Viewer = @{ id = $script:viewerObjectId; servicePrincipalType = 'ManagedIdentity' }
            Pool = $null
            User = $null
            Grants = @(@{
                id = 'existing-grant'
                clientId = 'blueprint-sp'
                resourceId = 'sp-da81128c-e5b5-4f9e-8d89-50d906f107c5'
                consentType = 'AllPrincipals'
                scope = 'Existing.Read'
            })
            Inheritance = @()
            Fics = @()
            Assignments = @()
            Operations = @()
            FailAfterGrantPatchCommit = $false
        }
    }

    function Get-MockGraphState {
        return ($script:state | ConvertTo-Json -Depth 80 | ConvertFrom-Json -AsHashtable)
    }

    function Set-GrantPatchCommitInterruption {
        $script:state.FailAfterGrantPatchCommit = $true
    }

    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode, $InformationAction)
        $script:tenant = $TenantId.ToString()
        $script:scopes = $Scopes
    }

    function Get-MgContext {
        return @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes }
    }

    function Get-ResourceServicePrincipal {
        param([string]$AppId)

        $scopeNames = switch ($AppId) {
            'da81128c-e5b5-4f9e-8d89-50d906f107c5' { @('Tools.ListInvoke.All') }
            'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' { @('McpServersMetadata.Read.All') }
            '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5' {
                @('Computer.See', 'Computer.Control', 'Computer.Do', 'Computer.Get')
            }
            default { throw "Unknown mocked resource $AppId" }
        }

        return @{
            id = "sp-$AppId"
            appId = $AppId
            oauth2PermissionScopes = @($scopeNames | ForEach-Object { @{ id = "scope-$_"; value = $_; isEnabled = $true } })
        }
    }

    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)

        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }

        if ($Method -eq 'GET') {
            if ($path -eq 'v1.0/domains?$select=id,isDefault,isVerified') {
                return @{ value = @(
                    @{ id = 'example.com'; isDefault = $true; isVerified = $true },
                    @{ id = 'tenant.onmicrosoft.com'; isDefault = $false; isVerified = $true }
                ) }
            }
            if ($path.StartsWith("v1.0/servicePrincipals/$script:agentObjectId`?")) { return $script:state.Agent }
            if ($path -eq "v1.0/servicePrincipals/$script:viewerObjectId") { return $script:state.Viewer }
            if ($path.StartsWith("v1.0/servicePrincipals?`$filter=appId eq '")) {
                $appId = $path.Substring("v1.0/servicePrincipals?`$filter=appId eq '".Length).TrimEnd("'")
                if ($appId -eq $script:blueprintId) {
                    return @{ value = @($script:state.Principal | Where-Object { $_ }) }
                }

                return @{ value = @((Get-ResourceServicePrincipal -AppId $appId)) }
            }
            if ($path.StartsWith('v1.0/applications/microsoft.graph.agentIdentityBlueprint?')) { return @{ value = @($script:state.Blueprint | Where-Object { $_ }) } }
            if ($path.StartsWith('v1.0/applications/blueprint-object?')) { return $script:state.Blueprint }
            if ($path -eq 'v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials') { return @{ value = @($script:state.Fics) } }
            if ($path -eq "v1.0/applications/microsoft.graph.agentIdentityBlueprint/$script:blueprintId/inheritablePermissions") { return @{ value = @($script:state.Inheritance) } }
            if ($path -like 'v1.0/oauth2PermissionGrants?*') { return @{ value = @($script:state.Grants) } }
            if ($path -like 'beta/users/microsoft.graph.agentUser?*') { return @{ value = @($script:state.User | Where-Object { $_ }) } }
            if ($path -like 'beta/deviceManagement/virtualEndpoint/cloudPcPools/*/assignments') { return @{ value = @($script:state.Assignments) } }
            if ($path -eq 'beta/deviceManagement/virtualEndpoint/cloudPcPools') {
                return @{ value = @($script:state.Pool | Where-Object { $_ }) }
            }
            if ($path -like 'beta/deviceManagement/virtualEndpoint/cloudPcPools/*') {
                if ($null -eq $script:state.Pool) {
                    throw 'Pool not found'
                }

                return $script:state.Pool
            }
        }

        if ($Method -eq 'POST') {
            switch -Wildcard ($path) {
                'v1.0/oauth2PermissionGrants' {
                    $bodyObject.id = "grant-$script:nextGrantIndex"
                    $script:nextGrantIndex++
                    $script:state.Grants += $bodyObject
                    return $bodyObject
                }
                'beta/deviceManagement/virtualEndpoint/cloudPcPools' {
                    $bodyObject.id = '77777777-7777-7777-7777-777777777777'
                    $script:state.Pool = $bodyObject
                    return $bodyObject
                }
                '*/inheritablePermissions' {
                    $script:nextInheritanceIndex++
                    $script:state.Inheritance += $bodyObject
                    return $bodyObject
                }
                '*/federatedIdentityCredentials' {
                    $bodyObject.id = "fic-$script:nextFicIndex"
                    $script:nextFicIndex++
                    $script:state.Fics += $bodyObject
                    return $bodyObject
                }
                'beta/users/microsoft.graph.agentUser' {
                    if ($bodyObject.identityParentId -ne $script:agentObjectId) {
                        throw 'Agent user was parented to a client ID instead of object ID.'
                    }

                    $bodyObject.id = 'agent-user'
                    $script:state.User = $bodyObject
                    return $bodyObject
                }
                '*/assignments' {
                    $bodyObject.id = "assignment-$script:nextAssignmentIndex"
                    $script:nextAssignmentIndex++
                    $script:state.Assignments += $bodyObject
                    return $bodyObject
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        if ($Method -eq 'PATCH') {
            $script:state.Operations += "PATCH $path"
            if ($path -eq 'v1.0/applications/blueprint-object') {
                if ($bodyObject.Keys.Count -ne 1 -or !$bodyObject.ContainsKey('requiredResourceAccess')) {
                    throw 'Attempted to modify Foundry credentials.'
                }

                $script:state.Blueprint.requiredResourceAccess = $bodyObject.requiredResourceAccess
                return
            }
            if ($path -like 'beta/deviceManagement/virtualEndpoint/cloudPcPools/*') {
                foreach ($key in $bodyObject.Keys) {
                    if ($key -eq '@odata.type') {
                        continue
                    }

                    $script:state.Pool[$key] = $bodyObject[$key]
                }

                return
            }
            if ($path -like 'v1.0/oauth2PermissionGrants/*') {
                $grantId = $path.Split('/')[-1]
                $grant = @($script:state.Grants | Where-Object { $_.id -eq $grantId })[0]
                $grant.scope = $bodyObject.scope
                if ($script:state.FailAfterGrantPatchCommit) {
                    $script:state.FailAfterGrantPatchCommit = $false
                    throw 'Simulated interruption after remote permission-grant commit.'
                }
                return
            }

            throw "Unexpected mocked Graph request: $Method $path"
        }

        if ($Method -eq 'DELETE') {
            $script:state.Operations += "DELETE $path"
            switch -Wildcard ($path) {
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/*/assignments/*' {
                    $assignmentId = $path.Split('/')[-1]
                    $script:state.Assignments = @($script:state.Assignments | Where-Object { $_.id -ne $assignmentId })
                    return
                }
                'beta/users/*' {
                    $script:state.User = $null
                    return
                }
                'v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials/*' {
                    $ficId = $path.Split('/')[-1]
                    $script:state.Fics = @($script:state.Fics | Where-Object { $_.id -ne $ficId })
                    return
                }
                'v1.0/oauth2PermissionGrants/*' {
                    $grantId = $path.Split('/')[-1]
                    $script:state.Grants = @($script:state.Grants | Where-Object { $_.id -ne $grantId })
                    return
                }
                'v1.0/applications/microsoft.graph.agentIdentityBlueprint/*/inheritablePermissions/*' {
                    $resourceAppId = $path.Split('/')[-1]
                    $script:state.Inheritance = @($script:state.Inheritance | Where-Object { $_.resourceAppId -ne $resourceAppId })
                    return
                }
                'beta/deviceManagement/virtualEndpoint/cloudPcPools/*' {
                    $script:state.Pool = $null
                    return
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        throw "Unexpected mocked Graph request: $Method $path"
    }

    Reset-MockGraphState
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Reset-MockGraphState, Get-MockGraphState, Set-GrantPatchCommitInterruption
}

$module | Import-Module -Global

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-teardown-flow-{0}" -f ([guid]::NewGuid()))
$envName = 'teardown-flow-test'
$envDir = Join-Path $tempRoot $envName
$envFilePath = Join-Path $envDir '.env'
$ownershipManifestPath = Join-Path $envDir 'w365-ownership.json'
$localConfigPath = Join-Path $repoRoot 'config\deployment.local.json'
$savedLocalConfig = if (Test-Path -LiteralPath $localConfigPath) {
    Get-Content -LiteralPath $localConfigPath -Raw
}
else {
    $null
}

function Get-OutputValue {
    param(
        [string[]]$Lines,
        [string]$Name
    )

    $prefix = "$Name="
    $line = @($Lines | Where-Object { $_ -like "$prefix*" })[-1]
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "Expected output '$Name' was missing."
    }

    return $line.Substring($prefix.Length)
}

function Write-TestEnvironment {
    param(
        [string]$PoolId,
        [string]$AgentUserId
    )

    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    Set-Content -LiteralPath $envFilePath -Value @"
AZURE_TENANT_ID="01eed126-9f96-4d2d-a127-dc2e786a898b"
W365_TENANT_ID="01eed126-9f96-4d2d-a127-dc2e786a898b"
W365_ENABLED="true"
W365_POOL_ID="$PoolId"
W365_AGENT_USER_ID="$AgentUserId"
FOUNDRY_PROJECT_OWNERSHIP="managed"
"@
}

try {
    $setupArgs = @{
        TenantId = '01eed126-9f96-4d2d-a127-dc2e786a898b'
        BlueprintId = '11111111-1111-1111-1111-111111111111'
        AgentIdentityId = '22222222-2222-2222-2222-222222222222'
        AgentUserPrincipalName = 'flow-agent@example.com'
        PoolDisplayName = 'Created pool'
        PoolDescription = 'Created by setup'
        PoolBillingPlanId = '66666666-6666-6666-6666-666666666666'
        PoolGeographicLocationType = 'usWest'
        PoolRegionGroup = 'usWest'
        PoolRegions = @('westus2', 'westus3')
        PoolImageId = 'microsoftwindowsdesktop_windows-ent-cpc_win11-23h2-ent-cpc-m365'
        PoolMinimumCount = 2
        PoolMaximumCount = 4
        PoolEnableSingleSignOn = $true
        HostedRuntimeIdentityObjectId = '22222222-2222-2222-2222-222222222222'
        AuthorizeHostedRuntimeFederation = $true
        ViewerManagedIdentityObjectId = '44444444-4444-4444-4444-444444444444'
        AuthorizeViewerFederation = $true
        BillingConfirmed = $true
        Confirm = $false
        SkipAzdEnvironmentSync = $true
        OwnershipManifestPath = $ownershipManifestPath
    }

    Set-GrantPatchCommitInterruption
    $interrupted = $false
    try {
        & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    }
    catch {
        $interrupted = $_.Exception.Message -match 'Simulated interruption after remote permission-grant commit'
    }
    if (!$interrupted) {
        throw 'Setup did not surface the simulated post-commit interruption.'
    }
    $interruptedManifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if (!$interruptedManifest.operations.Contains('graph.permissionGrant.da81128c-e5b5-4f9e-8d89-50d906f107c5') -or
        [string](Get-MockGraphState).Grants[0].scope -eq 'Existing.Read') {
        throw 'Setup did not preserve the prior grant scope across the ambiguous remote outcome.'
    }

    $setupOutput = & "$scriptsRoot\Setup-W365.ps1" @setupArgs
    $poolId = Get-OutputValue -Lines $setupOutput -Name 'W365_POOL_ID'
    $agentUserId = Get-OutputValue -Lines $setupOutput -Name 'W365_AGENT_USER_ID'
    $manifestOutputPath = Get-OutputValue -Lines $setupOutput -Name 'W365_OWNERSHIP_MANIFEST'
    if ($manifestOutputPath -ne $ownershipManifestPath) {
        throw 'Setup reported an unexpected ownership manifest path.'
    }
    if (!(Test-Path -LiteralPath $ownershipManifestPath)) {
        throw 'Setup did not write the ownership manifest.'
    }

    $manifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.w365.pool.disposition -ne 'created' -or
        $manifest.w365.agentUser.disposition -ne 'created' -or
        $manifest.w365.assignment.disposition -ne 'created') {
        throw 'Setup did not record created W365 ownership correctly.'
    }
    if ($manifest.operations.Count -ne 0) {
        throw 'Setup retry did not reconcile all pending ownership operations.'
    }
    $permissionGrantKeys = @($manifest.graph.permissionGrants.Keys)
    $inheritanceKeys = @($manifest.graph.inheritablePermissions.Keys)
    $federationKeys = @($manifest.graph.federatedIdentityCredentials.Keys)
    if ($permissionGrantKeys.Count -ne 3 -or
        $inheritanceKeys.Count -ne 3 -or
        $federationKeys.Count -ne 2) {
        throw "Setup manifest did not capture teardown-owned Graph state. Grants=[$($permissionGrantKeys -join ',')] Inheritance=[$($inheritanceKeys -join ',')] Federations=[$($federationKeys -join ',')]"
    }
    foreach ($resourceAppId in $inheritanceKeys) {
        if ([string]$manifest.graph.inheritablePermissions[$resourceAppId].deletionKey -ne $resourceAppId) {
            throw "Setup manifest did not preserve '$resourceAppId' as the inheritable-permission deletion key."
        }
    }
    & $module {
        $script:state.Blueprint.requiredResourceAccess += @{
            resourceAppId = 'post-setup-external-resource'
            resourceAccess = @(@{ id = 'post-setup-external-scope'; type = 'Scope' })
        }
    }

    Write-TestEnvironment -PoolId $poolId -AgentUserId $agentUserId

    & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath $ownershipManifestPath -Confirm:$false | Out-Null

    $state = Get-MockGraphState
    if ($null -ne $state.Pool -or $null -ne $state.User) {
        throw 'Composed teardown did not delete the setup-created pool or agent user.'
    }
    if ($state.Assignments.Count -ne 0 -or $state.Fics.Count -ne 0 -or $state.Grants.Count -ne 1 -or
        [string]$state.Grants[0].scope -ne 'Existing.Read' -or $state.Inheritance.Count -ne 0) {
        throw 'Composed teardown did not delete the setup-created W365/Graph artifacts.'
    }

    $requiredEntries = @($state.Blueprint.requiredResourceAccess)
    $baselineEntry = @($requiredEntries | Where-Object { $_.resourceAppId -eq 'unrelated-resource' })
    $externalEntry = @($requiredEntries | Where-Object { $_.resourceAppId -eq 'post-setup-external-resource' })
    if ($requiredEntries.Count -ne 2 -or
        $baselineEntry.Count -ne 1 -or
        @($baselineEntry[0].resourceAccess).Count -ne 1 -or
        [string]@($baselineEntry[0].resourceAccess)[0].id -ne 'unrelated-scope' -or
        $externalEntry.Count -ne 1 -or
        @($externalEntry[0].resourceAccess).Count -ne 1 -or
        [string]@($externalEntry[0].resourceAccess)[0].id -ne 'post-setup-external-scope') {
        $actualRequiredResourceAccess = $state.Blueprint.requiredResourceAccess | ConvertTo-Json -Depth 20 -Compress
        throw "Composed teardown did not remove only setup-added blueprint permissions. Actual=$actualRequiredResourceAccess"
    }
    if ($state.Blueprint.keyCredentials[0] -ne 'untouched-key') {
        throw 'Composed teardown touched unrelated blueprint credentials.'
    }

    $assignmentDeleteIndex = $state.Operations.IndexOf('DELETE beta/deviceManagement/virtualEndpoint/cloudPcPools/77777777-7777-7777-7777-777777777777/assignments/assignment-0')
    $userDeleteIndex = $state.Operations.IndexOf('DELETE beta/users/agent-user')
    $poolDeleteIndex = $state.Operations.IndexOf('DELETE beta/deviceManagement/virtualEndpoint/cloudPcPools/77777777-7777-7777-7777-777777777777')
    if ($assignmentDeleteIndex -lt 0 -or $userDeleteIndex -lt 0 -or $poolDeleteIndex -lt 0 -or !($assignmentDeleteIndex -lt $userDeleteIndex -and $userDeleteIndex -lt $poolDeleteIndex)) {
        throw 'Composed teardown did not preserve reverse dependency order.'
    }

    $manifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.cleanup.status -ne 'completed') {
        throw 'Cleanup did not mark the ownership manifest complete.'
    }

    Write-Output 'Offline setup-to-cleanup flow: post-commit retry ownership, reverse-order teardown, and blueprint restoration passed.'
}
finally {
    if ($null -ne $savedLocalConfig) {
        Set-Content -LiteralPath $localConfigPath -Value $savedLocalConfig
    }
    elseif (Test-Path -LiteralPath $localConfigPath) {
        Remove-Item -LiteralPath $localConfigPath
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }

    Remove-Module Microsoft.Graph.Authentication
}