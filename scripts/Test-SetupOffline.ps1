#Requires -Version 7.4
# All endpoints are mocked. Unexpected calls fail, including identity/credential creation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:blueprintId = '11111111-1111-1111-1111-111111111111'
    $script:agentId = '22222222-2222-2222-2222-222222222222'
    $script:agentClientId = '33333333-3333-3333-3333-333333333333'
    $script:viewerId = '44444444-4444-4444-4444-444444444444'
    $script:ledger = @{
        Blueprint = @{ id = 'blueprint-object'; appId = $script:blueprintId; keyCredentials = @('untouched-key'); requiredResourceAccess = @(
            @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) }
        ) }
        Principal = @{ id = 'blueprint-sp'; appId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentityBlueprintPrincipal' }
        Agent = @{ id = $script:agentId; appId = $script:agentClientId; displayName = 'Existing Foundry agent'
            agentIdentityBlueprintId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentity' }
        User = $null; Grants = @(); Inheritance = @(); Assignments = @(); Fics = @(); Creates = 0; Writes = 0
    }
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome)
        if ($Scopes | Where-Object { $_ -like '*.Create*' }) { throw 'Setup requested identity creation permission.' }
        $script:tenant = $TenantId.ToString(); $script:scopes = $Scopes
    }
    function Get-MgContext { @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes } }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)
        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($Method -eq 'GET') {
            if ($path.StartsWith("v1.0/servicePrincipals/$script:agentId`?")) { return $script:ledger.Agent }
            if ($path -eq "v1.0/servicePrincipals/$script:viewerId") { return @{ servicePrincipalType = 'ManagedIdentity' } }
            if ($path -match "^v1.0/servicePrincipals\?\`$filter=appId eq '([^']+)'") {
                $id = $Matches[1]
                if ($id -eq $script:blueprintId) { return @{ value = @($script:ledger.Principal | Where-Object { $_ }) } }
                $names = switch ($id) {
                    'da81128c-e5b5-4f9e-8d89-50d906f107c5' { @('Tools.ListInvoke.All') }
                    'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' { @('McpServersMetadata.Read.All') }
                    '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5' { @('Computer.See', 'Computer.Control') }
                    default { throw "Unknown mocked resource $id" }
                }
                return @{ value = @(@{ id = "sp-$id"; appId = $id; oauth2PermissionScopes = @($names | ForEach-Object { @{ id = "scope-$_"; value = $_; isEnabled = $true } }) }) }
            }
            if ($path -like '*cloudPcPools/*/assignments') { return @{ value = $script:ledger.Assignments } }
            if ($path -like '*cloudPcPools/*') { return @{ '@odata.type' = '#microsoft.graph.cloudPcAgentPool' } }
            if ($path.StartsWith('v1.0/applications/microsoft.graph.agentIdentityBlueprint?')) { return @{ value = @($script:ledger.Blueprint | Where-Object { $_ }) } }
            if ($path.StartsWith('v1.0/applications/blueprint-object?')) { return $script:ledger.Blueprint }
            if ($path -like 'v1.0/oauth2PermissionGrants?*') { return @{ value = $script:ledger.Grants } }
            if ($path -like '*/inheritablePermissions') { return @{ value = $script:ledger.Inheritance } }
            if ($path -like '*/federatedIdentityCredentials') { return @{ value = $script:ledger.Fics } }
            if ($path -like 'beta/users/microsoft.graph.agentUser?*') { return @{ value = @($script:ledger.User | Where-Object { $_ }) } }
        }
        if ($Method -eq 'PATCH') {
            $script:ledger.Writes++
            if ($path -eq 'v1.0/applications/blueprint-object') {
                if ($bodyObject.Keys.Count -ne 1 -or !$bodyObject.ContainsKey('requiredResourceAccess')) { throw 'Attempted to modify Foundry credentials.' }
                $script:ledger.Blueprint.requiredResourceAccess = $bodyObject.requiredResourceAccess
                return
            }
            if ($path -like 'v1.0/oauth2PermissionGrants/*') {
                $grant = $script:ledger.Grants | Where-Object { $_.id -eq $path.Split('/')[-1] }
                $grant.scope = $bodyObject.scope; return
            }
        }
        if ($Method -eq 'POST') {
            $script:ledger.Creates++; $script:ledger.Writes++
            switch -Wildcard ($path) {
                'v1.0/oauth2PermissionGrants' {
                    $bodyObject.id = "grant-$($script:ledger.Grants.Count)"; $script:ledger.Grants += $bodyObject; return $bodyObject
                }
                '*/inheritablePermissions' { $script:ledger.Inheritance += $bodyObject; return $bodyObject }
                '*/federatedIdentityCredentials' { $script:ledger.Fics += $bodyObject; return $bodyObject }
                'beta/users/microsoft.graph.agentUser' {
                    if ($bodyObject.identityParentId -ne $script:agentId) { throw 'Agent user was parented to a client ID instead of object ID.' }
                    $bodyObject.id = 'agent-user'; $script:ledger.User = $bodyObject; return $bodyObject
                }
                '*/assignments' { $script:ledger.Assignments += $bodyObject; return $bodyObject }
            }
        }
        throw "Unexpected mocked Graph request: $Method $path"
    }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest
}
$module | Import-Module -Global
try {
    $setupArgs = @{
        TenantId = [guid]::Empty; BlueprintId = '11111111-1111-1111-1111-111111111111'
        AgentIdentityId = '22222222-2222-2222-2222-222222222222'; AgentUserPrincipalName = 'agent@example.com'
        PoolId = [guid]::Empty; BillingConfirmed = $true; Confirm = $false
    }
    $output = & "$PSScriptRoot\Setup-W365.ps1" @setupArgs
    if ('W365_AGENT_ID=33333333-3333-3333-3333-333333333333' -notin $output -or
        'W365_AGENT_OBJECT_ID=22222222-2222-2222-2222-222222222222' -notin $output) { throw 'Client and object IDs were conflated.' }
    & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & $module {
        if ($script:ledger.Creates -ne 8 -or $script:ledger.Grants.Count -ne 3 -or $script:ledger.Inheritance.Count -ne 3 -or
            $script:ledger.Assignments.Count -ne 1 -or $script:ledger.Fics.Count -ne 0) { throw 'Setup was not idempotent.' }
        if ($script:ledger.Blueprint.keyCredentials[0] -ne 'untouched-key' -or
            'unrelated-resource' -notin $script:ledger.Blueprint.requiredResourceAccess.resourceAppId) { throw 'Unrelated configuration was modified.' }
    }
    $setupArgs.HostedRuntimeIdentityObjectId = '22222222-2222-2222-2222-222222222222'
    $setupArgs.AuthorizeHostedRuntimeFederation = $true
    & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & $module { if ($script:ledger.Fics.Count -ne 1 -or $script:ledger.Creates -ne 9) { throw 'Hosted federation was duplicated.' } }
    $setupArgs.ViewerManagedIdentityObjectId = '44444444-4444-4444-4444-444444444444'
    $setupArgs.AuthorizeViewerFederation = $true
    & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & $module { if ($script:ledger.Fics.Count -ne 2 -or $script:ledger.Creates -ne 10) { throw 'Viewer federation was duplicated.' } }
    foreach ($scenario in @('agent-parent', 'user-parent', 'missing-blueprint', 'missing-principal', 'fic-mismatch', 'inheritance-mismatch')) {
        $saved = & $module { $script:ledger | ConvertTo-Json -Depth 30 }
        $before = & $module { $script:ledger.Writes }
        & $module {
            param($scenario)
            switch ($scenario) {
                'agent-parent' { $script:ledger.Agent.agentIdentityBlueprintId = 'wrong-parent' }
                'user-parent' { $script:ledger.User.identityParentId = 'wrong-parent' }
                'missing-blueprint' { $script:ledger.Blueprint = $null }
                'missing-principal' { $script:ledger.Principal = $null }
                'fic-mismatch' { $script:ledger.Fics[0].issuer = 'https://untrusted.example' }
                'inheritance-mismatch' { $script:ledger.Inheritance[0].inheritableScopes.kind = 'enumerated' }
            }
        } $scenario
        $rejected = $false
        try { & "$PSScriptRoot\Setup-W365.ps1" @setupArgs | Out-Null }
        catch { $rejected = $true }
        if (!$rejected -or (& $module { $script:ledger.Writes }) -ne $before) { throw "$scenario was not rejected before mutations." }
        & $module { param($saved) $script:ledger = $saved | ConvertFrom-Json -AsHashtable } $saved
    }
    Write-Output 'Offline setup: existing identity reuse, distinct client/object IDs, parent preflight, preserved configuration and optional idempotent hosted/viewer federation passed.'
}
finally { Remove-Module Microsoft.Graph.Authentication }
