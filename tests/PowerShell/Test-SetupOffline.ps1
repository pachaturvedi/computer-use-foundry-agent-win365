#Requires -Version 7.4
# TestCategory: Offline
# All endpoints are mocked. Unexpected calls fail, including identity/credential creation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$setupScriptPath = Join-Path $repoRoot 'scripts\Setup-W365.ps1'
$setupScriptText = Get-Content -LiteralPath $setupScriptPath -Raw
$tokens = $null
$parseErrors = $null
$setupAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $setupScriptText,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Setup-W365.ps1 failed to parse: $($parseErrors[0].Message)"
}

$getAzdCommandAst = $setupAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-AzdCommand'
}, $true) | Select-Object -First 1
if (!$getAzdCommandAst) {
    throw "Unable to locate function 'Get-AzdCommand' in Setup-W365.ps1 for isolated testing."
}

$commandDiscoveryTempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-setup-azd-discovery-{0}" -f ([guid]::NewGuid()))
$malformedAzdRoot = Join-Path $commandDiscoveryTempRoot 'malformed'
$validAzdRoot = Join-Path $commandDiscoveryTempRoot 'valid'
$fakeAzdFileName = if ($IsWindows) { 'azd.cmd' } else { 'azd' }
$malformedAzdPath = Join-Path $malformedAzdRoot $fakeAzdFileName
$fakeAzdPath = Join-Path $validAzdRoot $fakeAzdFileName
$previousPath = $env:PATH
$commandDiscoveryModule = $null
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

    $commandDiscoveryModule = New-Module -Name W365SetupAzdCommandDiscovery -ScriptBlock ([scriptblock]::Create(@"
$($getAzdCommandAst.Extent.Text)
function azd { 'profile shadow' }
"@))
    $azd = & $commandDiscoveryModule { Get-AzdCommand }
    if ($null -eq $azd -or $azd.Path -ne $fakeAzdPath -or $azd.Version -ne ([version]'9.99.9')) {
        throw 'Setup azd discovery did not ignore invalid candidates or select the highest supported executable.'
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

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:blueprintId = '11111111-1111-1111-1111-111111111111'
    $script:agentId = '22222222-2222-2222-2222-222222222222'
    $script:agentClientId = '33333333-3333-3333-3333-333333333333'
    $script:viewerId = '44444444-4444-4444-4444-444444444444'
    $script:poolId = '55555555-5555-5555-5555-555555555555'
    $script:billingPlanId = '66666666-6666-6666-6666-666666666666'
    $script:failBlueprintPatch = $false
    $script:failPoolCreateAfterCommit = $false
    $script:connectCalls = 0
    $script:timeoutFailuresRemaining = 1
    $script:lastContextScope = ''
    $script:lastUseDeviceCode = $false
    $script:lastInformationAction = ''
    $script:ledger = @{
        Blueprint = @{ id = 'blueprint-object'; appId = $script:blueprintId; keyCredentials = @('untouched-key'); requiredResourceAccess = @(
            @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) }
        ) }
        Principal = @{ id = 'blueprint-sp'; appId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentityBlueprintPrincipal' }
        Agent = @{ id = $script:agentId; appId = $script:agentClientId; displayName = 'Existing Foundry agent'
            agentIdentityBlueprintId = $script:blueprintId; '@odata.type' = '#microsoft.graph.agentIdentity' }
        Pool = @{
            '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
            id = $script:poolId
            displayName = 'Existing pool'
            description = 'Existing description'
            billingConfiguration = @{ billingType = 'payAsYouGo'; billingPlanId = $script:billingPlanId }
            capabilities = @{ enableSingleSignOn = $false }
            cloudPcConfiguration = @{ imageId = 'gallery-image'; imageType = 'gallery'; osLocale = 'en-US' }
            networkConfiguration = @{ geographicLocationType = 'usWest'; regionGroups = @(@{ regionGroup = 'usWest'; regions = @('westus2', 'westus3') }) }
            scalingPolicy = @{ minimumCount = 1; maximumCount = 1 }
        }
        Domains = @(
            @{ id = 'customer.example'; isDefault = $true; isVerified = $true },
            @{ id = 'tenant.onmicrosoft.com'; isDefault = $false; isVerified = $true },
            @{ id = 'example.com'; isDefault = $false; isVerified = $true }
        )
        User = $null; Grants = @(); Inheritance = @(); Assignments = @(); Fics = @(); Creates = 0; Writes = 0
    }
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, $ClientTimeout, [switch]$NoWelcome, [switch]$UseDeviceCode, $InformationAction)
        $script:connectCalls++
        $script:lastContextScope = $ContextScope
        $script:lastUseDeviceCode = $UseDeviceCode.IsPresent
        $script:lastInformationAction = [string]$InformationAction
        if ($script:timeoutFailuresRemaining -gt 0) {
            $script:timeoutFailuresRemaining--
            throw 'Authentication timed out after 120 seconds due to inactivity. Please try again.'
        }
        if ($Scopes | Where-Object { $_ -like '*.Create*' }) { throw 'Setup requested identity creation permission.' }
        $script:tenant = $TenantId.ToString(); $script:scopes = $Scopes
    }
    function Get-MgContext { @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes } }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)
        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($Method -eq 'GET') {
            if ($path -eq 'v1.0/domains?$select=id,isDefault,isVerified') { return @{ value = $script:ledger.Domains } }
            if ($path.StartsWith("v1.0/servicePrincipals/$script:agentId`?")) { return $script:ledger.Agent }
            if ($path -eq "v1.0/servicePrincipals/$script:viewerId") { return @{ servicePrincipalType = 'ManagedIdentity' } }
            if ($path -match "^v1.0/servicePrincipals\?\`$filter=appId eq '([^']+)'") {
                $id = $Matches[1]
                if ($id -eq $script:blueprintId) { return @{ value = @($script:ledger.Principal | Where-Object { $_ }) } }
                $names = switch ($id) {
                    'da81128c-e5b5-4f9e-8d89-50d906f107c5' { @('Tools.ListInvoke.All') }
                    'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' { @('McpServersMetadata.Read.All') }
                    '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5' {
                        @('Computer.See', 'Computer.Control', 'Computer.Do', 'Computer.Get')
                    }
                    default { throw "Unknown mocked resource $id" }
                }
                return @{ value = @(@{ id = "sp-$id"; appId = $id; oauth2PermissionScopes = @($names | ForEach-Object { @{ id = "scope-$_"; value = $_; isEnabled = $true } }) }) }
            }
            if ($path -like '*cloudPcPools/*/assignments') { return @{ value = $script:ledger.Assignments } }
            if ($path -eq 'beta/deviceManagement/virtualEndpoint/cloudPcPools') {
                return @{ value = @($script:ledger.Pool | Where-Object { $_ }) }
            }
            if ($path -like '*cloudPcPools/*') { return $script:ledger.Pool }
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
                if ($script:failBlueprintPatch) {
                    throw 'Simulated failure after pool creation.'
                }
                if ($bodyObject.Keys.Count -ne 1 -or !$bodyObject.ContainsKey('requiredResourceAccess')) { throw 'Attempted to modify Foundry credentials.' }
                $script:ledger.Blueprint.requiredResourceAccess = $bodyObject.requiredResourceAccess
                return
            }
            if ($path -like 'beta/deviceManagement/virtualEndpoint/cloudPcPools/*') {
                foreach ($key in $bodyObject.Keys) {
                    if ($key -eq '@odata.type') {
                        continue
                    }
                    $script:ledger.Pool[$key] = $bodyObject[$key]
                }
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
                'beta/deviceManagement/virtualEndpoint/cloudPcPools' {
                    $bodyObject.id = '77777777-7777-7777-7777-777777777777'
                    $script:ledger.Pool = $bodyObject
                    if ($script:failPoolCreateAfterCommit) {
                        $script:failPoolCreateAfterCommit = $false
                        throw 'Simulated interruption after remote pool creation.'
                    }
                    return $bodyObject
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
    function Get-ConnectState {
        [pscustomobject]@{
            Calls = $script:connectCalls
            ContextScope = $script:lastContextScope
            UseDeviceCode = $script:lastUseDeviceCode
            InformationAction = $script:lastInformationAction
        }
    }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Get-ConnectState
}
$module | Import-Module -Global
$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$localConfigPath = Join-Path $repoRoot 'config\deployment.local.json'
$ownershipManifestPath = Join-Path ([IO.Path]::GetTempPath()) ("w365-ownership-{0}.json" -f ([guid]::NewGuid()))
$savedLocalConfig = if (Test-Path -LiteralPath $localConfigPath) {
    Get-Content -LiteralPath $localConfigPath -Raw
}
else {
    $null
}
if (Test-Path -LiteralPath $localConfigPath) {
    Remove-Item -LiteralPath $localConfigPath
}
try {
    $setupArgs = @{
        TenantId = [guid]::Empty; BlueprintId = '11111111-1111-1111-1111-111111111111'
        AgentIdentityId = '22222222-2222-2222-2222-222222222222'; AgentUserPrincipalName = 'agent@example.com'
        PoolId = '55555555-5555-5555-5555-555555555555'; BillingConfirmed = $true; Confirm = $false; SkipAzdEnvironmentSync = $true
        UseDeviceCode = $true
        OwnershipManifestPath = $ownershipManifestPath
    }
    $output = & "$scriptsRoot\Setup-W365.ps1" @setupArgs
    $connectState = Get-ConnectState
    if ($connectState.Calls -ne 2 -or
        $connectState.ContextScope -ne 'Process' -or
        !$connectState.UseDeviceCode -or
        $connectState.InformationAction -ne 'Continue') {
        throw 'W365 setup did not retry device-code authentication with a visible, process-scoped Graph context.'
    }
    if ('W365_AGENT_ID=33333333-3333-3333-3333-333333333333' -notin $output -or
        'W365_AGENT_OBJECT_ID=22222222-2222-2222-2222-222222222222' -notin $output) { throw 'Client and object IDs were conflated.' }
    if (!(Test-Path -LiteralPath $ownershipManifestPath)) { throw 'Ownership manifest was not written.' }
    $manifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.w365.pool.id -ne '55555555-5555-5555-5555-555555555555' -or
        $manifest.w365.pool.disposition -ne 'reused' -or
        $manifest.w365.assignment.disposition -ne 'created' -or
        $manifest.graph.blueprint.appId -ne '11111111-1111-1111-1111-111111111111') {
        throw 'Ownership manifest contents were incomplete.'
    }
    $restoreBaselineBeforeRerun = [ordered]@{
        previousScope = $manifest.graph.permissionGrants['90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'].previousScope
        requiredResourceAccessBefore = $manifest.graph.blueprint.requiredResourceAccessBefore
        requiredResourceAccessAdded = $manifest.graph.blueprint.requiredResourceAccessAdded
    } | ConvertTo-Json -Depth 40 -Compress
    & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    $manifestAfterRerun = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    $restoreBaselineAfterRerun = [ordered]@{
        previousScope = $manifestAfterRerun.graph.permissionGrants['90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'].previousScope
        requiredResourceAccessBefore = $manifestAfterRerun.graph.blueprint.requiredResourceAccessBefore
        requiredResourceAccessAdded = $manifestAfterRerun.graph.blueprint.requiredResourceAccessAdded
    } | ConvertTo-Json -Depth 40 -Compress
    if ($restoreBaselineAfterRerun -ne $restoreBaselineBeforeRerun) {
        throw 'Setup rerun overwrote the original cleanup restore baseline.'
    }
    & $module {
        if ($script:ledger.Creates -ne 8 -or $script:ledger.Grants.Count -ne 3 -or $script:ledger.Inheritance.Count -ne 3 -or
            $script:ledger.Assignments.Count -ne 1 -or $script:ledger.Fics.Count -ne 0) { throw 'Setup was not idempotent.' }
        if ($script:ledger.Blueprint.keyCredentials[0] -ne 'untouched-key' -or
            'unrelated-resource' -notin $script:ledger.Blueprint.requiredResourceAccess.resourceAppId) { throw 'Unrelated configuration was modified.' }
    }
    $setupArgs.HostedRuntimeIdentityObjectId = '22222222-2222-2222-2222-222222222222'
    $setupArgs.AuthorizeHostedRuntimeFederation = $true
    & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & $module { if ($script:ledger.Fics.Count -ne 1 -or $script:ledger.Creates -ne 9) { throw 'Hosted federation was duplicated.' } }
    $setupArgs.ViewerManagedIdentityObjectId = '44444444-4444-4444-4444-444444444444'
    $setupArgs.AuthorizeViewerFederation = $true
    & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null
    & $module { if ($script:ledger.Fics.Count -ne 2 -or $script:ledger.Creates -ne 10) { throw 'Viewer federation was duplicated.' } }
    foreach ($scenario in @(
        'agent-parent',
        'user-parent',
        'missing-blueprint',
        'missing-principal',
        'fic-mismatch',
        'inheritance-mismatch',
        'unverified-domain'
    )) {
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
                'unverified-domain' {
                    ($script:ledger.Domains | Where-Object { $_.id -eq 'example.com' }).isVerified = $false
                }
            }
        } $scenario
        $rejected = $false
        try { & "$scriptsRoot\Setup-W365.ps1" @setupArgs | Out-Null }
        catch { $rejected = $true }
        if (!$rejected -or (& $module { $script:ledger.Writes }) -ne $before) { throw "$scenario was not rejected before mutations." }
        & $module { param($saved) $script:ledger = $saved | ConvertFrom-Json -AsHashtable } $saved
    }
    if (Test-Path -LiteralPath $ownershipManifestPath) {
        Remove-Item -LiteralPath $ownershipManifestPath
    }
    & $module {
        $script:ledger.Pool = $null
        $script:ledger.User = $null
        $script:ledger.Assignments = @()
    }
    $createArgs = @{
        TenantId = [guid]::Empty; BlueprintId = '11111111-1111-1111-1111-111111111111'
        AgentIdentityId = '22222222-2222-2222-2222-222222222222'; AgentUserPrincipalName = 'new-agent@example.com'
        PoolDisplayName = 'Created pool'; PoolDescription = 'Created by setup'; PoolBillingPlanId = '66666666-6666-6666-6666-666666666666'
        PoolGeographicLocationType = 'usWest'; PoolRegionGroup = 'usWest'; PoolRegions = @('westus2', 'westus3')
        PoolImageId = 'microsoftwindowsdesktop_windows-ent-cpc_win11-23h2-ent-cpc-m365'; PoolMinimumCount = 2; PoolMaximumCount = 4
        PoolEnableSingleSignOn = $true; BillingConfirmed = $true; Confirm = $false; SkipAzdEnvironmentSync = $true
        OwnershipManifestPath = $ownershipManifestPath
    }
    & $module { $script:failPoolCreateAfterCommit = $true }
    $poolCreateInterrupted = $false
    try {
        & "$scriptsRoot\Setup-W365.ps1" @createArgs | Out-Null
    }
    catch {
        $poolCreateInterrupted = $_.Exception.Message -match 'Simulated interruption after remote pool creation'
    }
    $poolPendingManifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if (!$poolCreateInterrupted -or !$poolPendingManifest.operations.Contains('w365.pool.create')) {
        throw 'Setup did not preserve pending ownership after the ambiguous pool-create outcome.'
    }

    $createOutput = & "$scriptsRoot\Setup-W365.ps1" @createArgs
    if ('W365_POOL_ID=77777777-7777-7777-7777-777777777777' -notin $createOutput -or
        'W365_POOL_NAME=Created pool' -notin $createOutput -or
        'W365_ENABLED=true' -notin $createOutput) { throw 'Pool creation outputs were not persisted.' }
    $manifest = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.w365.pool.id -ne '77777777-7777-7777-7777-777777777777' -or
        $manifest.w365.pool.disposition -ne 'created') {
        throw 'Created pool ownership was not persisted.'
    }
    $createCountAfterFirstRun = & $module { $script:ledger.Creates }
    $rerunOutput = & "$scriptsRoot\Setup-W365.ps1" @createArgs
    if ('W365_POOL_ID=77777777-7777-7777-7777-777777777777' -notin $rerunOutput) {
        throw 'Pool rerun did not reuse the environment-owned pool.'
    }
    if ((& $module { $script:ledger.Creates }) -ne $createCountAfterFirstRun) {
        throw 'Pool rerun created duplicate W365 or Graph resources.'
    }
    $mismatchedArgs = @{} + $createArgs
    $mismatchedArgs.PoolId = '88888888-8888-8888-8888-888888888888'
    $rejected = $false
    try {
        & "$scriptsRoot\Setup-W365.ps1" @mismatchedArgs | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'Setup accepted a pool ID that differed from the environment ownership manifest.'
    }
    if (Test-Path -LiteralPath $ownershipManifestPath) {
        Remove-Item -LiteralPath $ownershipManifestPath
    }
    & $module {
        $script:ledger.Pool = $null
        $script:ledger.User = $null
        $script:ledger.Grants = @()
        $script:ledger.Inheritance = @()
        $script:ledger.Assignments = @()
        $script:ledger.Fics = @()
        $script:ledger.Blueprint.requiredResourceAccess = @(
            @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) }
        )
        $script:failBlueprintPatch = $true
    }
    $rejected = $false
    try {
        & "$scriptsRoot\Setup-W365.ps1" @createArgs | Out-Null
    }
    catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'Setup did not surface the simulated post-pool failure.'
    }
    $checkpoint = Get-Content -LiteralPath $ownershipManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($checkpoint.w365.pool.id -ne '77777777-7777-7777-7777-777777777777' -or
        $checkpoint.w365.pool.disposition -ne 'created') {
        throw 'Setup did not checkpoint newly created pool ownership before later Graph mutations.'
    }
    Remove-Item -LiteralPath $ownershipManifestPath
    & $module {
        $script:ledger.Pool = $null
        $script:ledger.User = $null
        $script:ledger.Grants = @()
        $script:ledger.Inheritance = @()
        $script:ledger.Assignments = @()
        $script:ledger.Fics = @()
        $script:ledger.Blueprint.requiredResourceAccess = @(
            @{ resourceAppId = 'unrelated-resource'; resourceAccess = @(@{ id = 'unrelated-scope'; type = 'Scope' }) }
        )
        $script:failBlueprintPatch = $false
    }
    Set-Content -LiteralPath $localConfigPath -Value @'
{
  "w365": {
    "poolDisplayName": "Configured pool",
    "poolDescription": "Configured from deployment.local.json",
    "poolBillingPlanId": "66666666-6666-6666-6666-666666666666",
    "poolBillingType": "payAsYouGo",
    "poolGeographicLocationType": "usWest",
    "poolRegionGroup": "usWest",
    "poolRegions": [
      "westus2",
      "westus3"
    ],
    "poolImageId": "microsoftwindowsdesktop_windows-ent-cpc_win11-23h2-ent-cpc-m365",
    "poolImageType": "gallery",
    "poolOsLocale": "en-US",
    "poolMinimumCount": 2,
    "poolMaximumCount": 4,
    "poolEnableSingleSignOn": true
  }
}
'@
    $configCreateArgs = @{
        TenantId = [guid]::Empty; BlueprintId = '11111111-1111-1111-1111-111111111111'
        AgentIdentityId = '22222222-2222-2222-2222-222222222222'; AgentUserPrincipalName = 'config-agent@example.com'
        BillingConfirmed = $true; Confirm = $false; SkipAzdEnvironmentSync = $true
        OwnershipManifestPath = $ownershipManifestPath
    }
    $configCreateOutput = & "$scriptsRoot\Setup-W365.ps1" @configCreateArgs
    if ('W365_POOL_ID=77777777-7777-7777-7777-777777777777' -notin $configCreateOutput) {
        throw 'Pool creation did not consume deployment.local.json values.'
    }
    & $module {
        if ($script:ledger.Pool.displayName -ne 'Configured pool' -or
            $script:ledger.Pool.billingConfiguration.billingPlanId -ne '66666666-6666-6666-6666-666666666666' -or
            @($script:ledger.Pool.networkConfiguration.regionGroups[0].regions) -join ',' -ne 'westus2,westus3' -or
            $script:ledger.Pool.scalingPolicy.minimumCount -ne 2 -or
            $script:ledger.Pool.scalingPolicy.maximumCount -ne 4) {
            throw 'deployment.local.json defaults were not applied to pool creation.'
        }
    }
    Write-Output 'Offline setup: existing identity reuse, distinct client/object IDs, parent preflight, preserved configuration and optional idempotent hosted/viewer federation passed.'
}
finally {
    if ($null -ne $savedLocalConfig) {
        Set-Content -LiteralPath $localConfigPath -Value $savedLocalConfig
    }
    elseif (Test-Path -LiteralPath $localConfigPath) {
        Remove-Item -LiteralPath $localConfigPath
    }
    if (Test-Path -LiteralPath $ownershipManifestPath) {
        Remove-Item -LiteralPath $ownershipManifestPath
    }

    Remove-Module Microsoft.Graph.Authentication
}
