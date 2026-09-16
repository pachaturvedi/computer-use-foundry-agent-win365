#Requires -Version 7.5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$BlueprintId,
    [Parameter(Mandatory)][guid]$AgentIdentityId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')][string]$AgentUserPrincipalName,
    [Parameter(Mandatory)][guid]$PoolId,
    [guid]$ViewerManagedIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeViewerFederation,
    [switch]$BillingConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($WhatIfPreference) {
    Write-Output "Plan only; no sign-in or network calls. Validate existing Foundry blueprint $BlueprintId and agent principal $AgentIdentityId in tenant $TenantId."
    Write-Output "Reconcile permissions and agent user '$AgentUserPrincipalName'; assign to existing pool $PoolId. No blueprint, agent identity, certificate or secret will be created."
    if ($AuthorizeViewerFederation) { Write-Output "Explicitly trust viewer managed identity $ViewerManagedIdentityObjectId on the existing blueprint. This trust can impersonate sibling agents, not only screen sharing." }
    return
}
if ($AuthorizeViewerFederation.IsPresent -ne ($ViewerManagedIdentityObjectId -ne [guid]::Empty)) {
    throw 'Supply both -ViewerManagedIdentityObjectId and -AuthorizeViewerFederation, or neither. Federation grants blueprint-wide impersonation capability.'
}
if (!$BillingConfirmed) { throw 'Read docs\W365-SETUP.md and pass -BillingConfirmed. Assignment permits consumption of paid Cloud PC capacity.' }
if (!$PSCmdlet.ShouldProcess("$TenantId / $BlueprintId / $AgentIdentityId", 'Configure existing Foundry identity, grant inherited consent (including sibling agents), create/reuse agent user and assign paid Cloud PC access')) { return }
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @(
    'Application.Read.All',
    'AgentIdentityBlueprint.ReadWrite.All', 'AgentIdentityBlueprint.UpdateAuthProperties.All',
    'AgentIdentity.Read.All', 'AgentIdUser.ReadWrite.All',
    'DelegatedPermissionGrant.ReadWrite.All', 'CloudPC.ReadWrite.All'
)
if ($AuthorizeViewerFederation) { $scopes += 'AgentIdentityBlueprint.AddRemoveCreds.All' }
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -ContextScope Process -NoWelcome
$context = Get-MgContext
if ($context.TenantId -ne $TenantId.ToString() -or $context.AuthType -ne 'Delegated') {
    throw 'A delegated Graph connection in the requested tenant is required.'
}
$missing = @($scopes | Where-Object { $_ -notin $context.Scopes })
if ($missing.Count) { throw "Missing Graph scopes: $($missing -join ', ')." }

function Graph([string]$Method, [string]$Path, $Body = $null) {
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://graph.microsoft.com/$Path" }
    if (!([uri]$uri).Host.Equals('graph.microsoft.com')) { throw 'Graph pagination returned an unexpected origin.' }
    $args = @{ Method = $Method; Uri = $uri; OutputType = 'Hashtable'; Headers = @{ 'OData-Version' = '4.0' } }
    if ($null -ne $Body) { $args.Body = ConvertTo-Json $Body -Depth 30 -Compress; $args.ContentType = 'application/json' }
    Invoke-MgGraphRequest @args
}
function List([string]$Path) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($Path) {
        if (!$seen.Add($Path)) { throw 'Repeated Graph pagination cursor.' }
        $page = Graph GET $Path
        foreach ($item in $page.value) { $item }
        $Path = $page['@odata.nextLink']
    }
}
function SingleOrNone($Items, [string]$Label) {
    $all = @($Items)
    if ($all.Count -gt 1) { throw "Ambiguous $Label; multiple matches. Resolve manually; no arbitrary object will be reused." }
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}
function Resource([string]$AppId) {
    $sp = SingleOrNone (List "v1.0/servicePrincipals?`$filter=appId eq '$AppId'") "resource $AppId"
    if ($null -eq $sp) { throw "Resource $AppId is absent. Complete Agent 365/W365 tenant onboarding first." }
    return $sp
}

# Validate the complete supplied identity chain before any mutation.
$agent = Graph GET "v1.0/servicePrincipals/$AgentIdentityId`?`$select=id,appId,displayName,agentIdentityBlueprintId"
if ($agent['@odata.type'] -ne '#microsoft.graph.agentIdentity' -or $agent.agentIdentityBlueprintId -ne $BlueprintId.ToString()) {
    throw 'Existing agent is not an agent identity or belongs to a different blueprint.'
}
$parsedClientId = [guid]::Empty
if ($agent.id -ne $AgentIdentityId.ToString() -or ![guid]::TryParse($agent.appId, [ref]$parsedClientId) -or $parsedClientId -eq [guid]::Empty) {
    throw 'Graph returned invalid agent identifiers.'
}
$blueprint = SingleOrNone (List "v1.0/applications/microsoft.graph.agentIdentityBlueprint?`$filter=appId eq '$BlueprintId'") 'Foundry blueprint app ID'
if (!$blueprint) { throw 'Existing Foundry blueprint is unavailable. Complete phase 1; setup will not create a replacement.' }
$bpPath = "v1.0/applications/$($blueprint.id)"
$blueprint = Graph GET "$bpPath`?`$select=id,appId,requiredResourceAccess"
if ($blueprint.appId -ne $BlueprintId.ToString()) { throw 'Resolved blueprint does not match the supplied client ID.' }
$principal = SingleOrNone (List "v1.0/servicePrincipals?`$filter=appId eq '$BlueprintId'") 'Foundry blueprint principal'
if (!$principal -or $principal['@odata.type'] -ne '#microsoft.graph.agentIdentityBlueprintPrincipal') {
    throw 'Foundry blueprint principal is missing or has the wrong type. Setup will not create a replacement.'
}
$agentUser = SingleOrNone (List "beta/users/microsoft.graph.agentUser?`$filter=userPrincipalName eq '$AgentUserPrincipalName'") 'agent user'
if ($agentUser -and $agentUser.identityParentId -ne $agent.id) { throw 'Existing agent user belongs to a different agent identity. Use a new UPN; never reparent implicitly.' }
$federation = $null
if ($AuthorizeViewerFederation) {
    $viewer = Graph GET "v1.0/servicePrincipals/$ViewerManagedIdentityObjectId"
    if ($viewer.servicePrincipalType -ne 'ManagedIdentity') { throw 'Viewer principal is not a managed identity in this tenant.' }
    $ficPath = "$bpPath/federatedIdentityCredentials"
    $ficName = "w365-viewer-$ViewerManagedIdentityObjectId"
    $federation = @{
        name = $ficName; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
        subject = $ViewerManagedIdentityObjectId.ToString(); audiences = @('api://AzureADTokenExchange')
    }
    $existingFic = SingleOrNone @(List $ficPath | Where-Object { $_.name -eq $ficName -or $_.subject -eq $federation.subject }) 'viewer federation'
    if ($existingFic) {
        if ($existingFic.issuer -ne $federation.issuer -or $existingFic.subject -ne $federation.subject -or
            @($existingFic.audiences).Count -ne 1 -or $existingFic.audiences[0] -ne 'api://AzureADTokenExchange') {
            throw 'Existing viewer federation differs. Review manually; no trust will be overwritten.'
        }
        $federation = $null
    }
}

# Resolve service metadata before making directory changes.
$resources = @(
    @{ Sp = (Resource 'da81128c-e5b5-4f9e-8d89-50d906f107c5'); Scopes = @('Tools.ListInvoke.All') },
    @{ Sp = (Resource 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'); Scopes = @('McpServersMetadata.Read.All') },
    @{ Sp = (Resource '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'); Scopes = @('Computer.See', 'Computer.Control') }
)
$inheritPath = "v1.0/applications/microsoft.graph.agentIdentityBlueprint/$($blueprint.appId)/inheritablePermissions"
$inheritances = @(List $inheritPath)
$grants = @(List "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($principal.id)'")
foreach ($resource in $resources) {
    foreach ($scope in $resource.Scopes) {
        $match = @($resource.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })
        if ($match.Count -ne 1) { throw "Resource $($resource.Sp.appId) does not publish enabled scope $scope." }
    }
    $resource.ExistingInheritance = SingleOrNone @($inheritances | Where-Object { $_.resourceAppId -eq $resource.Sp.appId }) 'inheritance entry'
    if ($resource.ExistingInheritance -and ($resource.ExistingInheritance.inheritableScopes.kind -ne 'allAllowed' -or
        $resource.ExistingInheritance.inheritableRoles.kind -ne 'none')) {
        throw "Existing inheritance for $($resource.Sp.appId) differs. Review it manually before rerunning."
    }
    $resource.Grant = SingleOrNone @($grants | Where-Object { $_.resourceId -eq $resource.Sp.id -and $_.consentType -eq 'AllPrincipals' }) 'OAuth grant'
}
$pool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$PoolId"
if ($pool['@odata.type'] -ne '#microsoft.graph.cloudPcAgentPool') { throw 'PoolId is not an agent pool.' }
Write-Output "Blueprint app ID: $($blueprint.appId)"
$required = @($blueprint.requiredResourceAccess | Where-Object { $null -ne $_ })
foreach ($resource in $resources) {
    $entry = SingleOrNone @($required | Where-Object { $_.resourceAppId -eq $resource.Sp.appId }) 'resource declaration'
    if ($null -eq $entry) { $entry = @{ resourceAppId = $resource.Sp.appId; resourceAccess = @() }; $required += $entry }
    foreach ($scope in $resource.Scopes) {
        $permission = @($resource.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })[0]
        if ($permission.id -notin @($entry.resourceAccess | ForEach-Object { $_.id })) {
            $entry.resourceAccess += @{ id = $permission.id; type = 'Scope' }
        }
    }
}
Graph PATCH $bpPath @{ requiredResourceAccess = $required } | Out-Null
foreach ($resource in $resources) {
    $grant = $resource.Grant
    $scope = @(@($(if ($grant) { $grant.scope -split ' ' })) + $resource.Scopes | Where-Object { $_ } | Sort-Object -Unique) -join ' '
    if ($grant) { Graph PATCH "v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $scope } | Out-Null }
    else { Graph POST 'v1.0/oauth2PermissionGrants' @{
        clientId = $principal.id; resourceId = $resource.Sp.id; consentType = 'AllPrincipals'; scope = $scope
    } | Out-Null }
    $inheritance = @{
        resourceAppId = $resource.Sp.appId
        inheritableScopes = @{ '@odata.type' = '#microsoft.graph.allAllowedScopes'; kind = 'allAllowed' }
        inheritableRoles = @{ '@odata.type' = '#microsoft.graph.noRoles'; kind = 'none' }
    }
    if (!$resource.ExistingInheritance) { Graph POST $inheritPath $inheritance | Out-Null }
}
if ($federation) { Graph POST $ficPath $federation | Out-Null }
Write-Output "Existing agent principal ID: $($agent.id)"
if (!$agentUser) {
    $agentUser = Graph POST 'beta/users/microsoft.graph.agentUser' @{
        displayName = "$($agent.displayName) user"; userPrincipalName = $AgentUserPrincipalName
        mailNickname = $AgentUserPrincipalName.Split('@')[0]; accountEnabled = $true; identityParentId = $agent.id
    }
}
$assignmentPath = "beta/deviceManagement/virtualEndpoint/cloudPcPools/$PoolId/assignments"
$assigned = SingleOrNone @(List $assignmentPath | Where-Object { $_.userPrincipalId -eq $agentUser.id }) 'agent pool assignment'
if (!$assigned) {
    Graph POST $assignmentPath @{
        '@odata.type' = '#microsoft.graph.cloudPcAgentPoolUserAssignment'; userPrincipalId = $agentUser.id
    } | Out-Null
}
Write-Output "`nSet these non-secret phase-2 azd environment values (no secret was created):"
Write-Output "W365_TENANT_ID=$TenantId"
Write-Output "W365_BLUEPRINT_ID=$($blueprint.appId)"
Write-Output "W365_AGENT_ID=$($agent.appId)"
Write-Output "W365_AGENT_OBJECT_ID=$($agent.id)"
Write-Output "W365_AGENT_USER_ID=$($agentUser.id)"
Write-Output 'Setup requests completed. Check pool readiness in Intune before running the sample.'
