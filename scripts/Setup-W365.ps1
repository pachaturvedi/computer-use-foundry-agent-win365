#Requires -Version 7.5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{3,50}$')][string]$Name,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')][string]$AgentUserPrincipalName,
    [Parameter(Mandatory)][string]$CertificatePublicPath,
    [Parameter(Mandatory)][guid]$PoolId,
    [switch]$BillingConfirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($WhatIfPreference) {
    Write-Output "Plan only; no sign-in or network calls. Tenant: $TenantId. Reconcile blueprint '$Name-blueprint', its principal, '$Name' agent and '$AgentUserPrincipalName' agent user."
    Write-Output "Register only the public certificate. Declare, consent and inherit ATG, metadata and ARI delegated scopes. Assign agent user directly to existing pool $PoolId. Never create a blueprint secret."
    return
}
if (!$BillingConfirmed) { throw 'Read docs\W365-SETUP.md and pass -BillingConfirmed. Assignment permits consumption of paid Cloud PC capacity.' }
if (!$PSCmdlet.ShouldProcess("$TenantId / $Name", 'Create/reconcile agent identities, grant delegated consent, register certificate and assign paid Cloud PC access')) { return }
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @(
    'User.Read', 'Application.Read.All', 'AgentIdentityBlueprint.Create',
    'AgentIdentityBlueprint.ReadWrite.All', 'AgentIdentityBlueprint.UpdateAuthProperties.All',
    'AgentIdentityBlueprint.AddRemoveCreds.All', 'AgentIdentityBlueprintPrincipal.Create',
    'AgentIdentity.Create.All', 'AgentIdentity.Read.All', 'AgentIdUser.ReadWrite.All',
    'DelegatedPermissionGrant.ReadWrite.All', 'CloudPC.ReadWrite.All'
)
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

$publicBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CertificatePublicPath))
$cert = [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificate($publicBytes)
if ($cert.HasPrivateKey -or $cert.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or
    $cert.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow) { throw 'Supply a currently valid public RSA certificate (.cer), not a PFX.' }
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
if ($null -eq $rsa -or $rsa.KeySize -lt 2048) { throw 'Use an RSA certificate of at least 2048 bits.' }
$rsa.Dispose()
$me = Graph GET 'v1.0/me?$select=id'
$userReference = "https://graph.microsoft.com/v1.0/users/$($me.id)"

# Resolve service metadata before making directory changes.
$resources = @(
    @{ Sp = (Resource 'da81128c-e5b5-4f9e-8d89-50d906f107c5'); Scopes = @('Tools.ListInvoke.All') },
    @{ Sp = (Resource 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'); Scopes = @('McpServersMetadata.Read.All') },
    @{ Sp = (Resource '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'); Scopes = @('Computer.See', 'Computer.Control') }
)
foreach ($resource in $resources) {
    foreach ($scope in $resource.Scopes) {
        $match = @($resource.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })
        if ($match.Count -ne 1) { throw "Resource $($resource.Sp.appId) does not publish enabled scope $scope." }
    }
}
$pool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$PoolId"
if ($pool['@odata.type'] -ne '#microsoft.graph.cloudPcAgentPool') { throw 'PoolId is not an agent pool.' }
$blueprint = SingleOrNone (List "v1.0/applications/microsoft.graph.agentIdentityBlueprint?`$filter=displayName eq '$Name-blueprint'") 'blueprint name'
if ($null -eq $blueprint) {
    $blueprint = Graph POST 'v1.0/applications' @{
        '@odata.type' = '#microsoft.graph.agentIdentityBlueprint'; displayName = "$Name-blueprint"
        'sponsors@odata.bind' = @($userReference); 'owners@odata.bind' = @($userReference)
    }
}
Write-Output "Blueprint app ID: $($blueprint.appId)"
$bpPath = "v1.0/applications/$($blueprint.id)"
$owners = @(List "$bpPath/owners")
if ($me.id -notin $owners.id) { throw 'The signed-in user must own the selected blueprint. Review existing objects rather than adopting them implicitly.' }
$blueprint = Graph GET "$bpPath`?`$select=id,appId,keyCredentials,requiredResourceAccess"
$keys = @($blueprint.keyCredentials | Where-Object { $null -ne $_ })
$thumbprint = [Convert]::ToBase64String($cert.GetCertHash())
if (!($keys | Where-Object { $_.customKeyIdentifier -eq $thumbprint })) {
    if ($keys | Where-Object { !$_.key }) { throw 'Graph did not return existing public certificate keys. Refusing to overwrite the key collection.' }
    $keys += @{
        keyId = [guid]::NewGuid().ToString(); type = 'AsymmetricX509Cert'; usage = 'Verify'
        displayName = 'W365 sample certificate'; key = [Convert]::ToBase64String($cert.RawData)
        customKeyIdentifier = $thumbprint
        startDateTime = $cert.NotBefore.ToUniversalTime().ToString('o')
        endDateTime = $cert.NotAfter.ToUniversalTime().ToString('o')
    }
    Graph PATCH $bpPath @{ keyCredentials = $keys } | Out-Null
}
$principal = SingleOrNone (List "v1.0/servicePrincipals?`$filter=appId eq '$($blueprint.appId)'") 'blueprint principal'
if ($null -eq $principal) {
    $principal = Graph POST 'v1.0/servicePrincipals' @{
        '@odata.type' = '#microsoft.graph.agentIdentityBlueprintPrincipal'; appId = $blueprint.appId
    }
}
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
    $grants = @(List "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($principal.id)'")
    $grant = SingleOrNone @($grants | Where-Object { $_.resourceId -eq $resource.Sp.id -and $_.consentType -eq 'AllPrincipals' }) 'OAuth grant'
    $scope = @(@($(if ($grant) { $grant.scope -split ' ' })) + $resource.Scopes | Where-Object { $_ } | Sort-Object -Unique) -join ' '
    if ($grant) { Graph PATCH "v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $scope } | Out-Null }
    else { Graph POST 'v1.0/oauth2PermissionGrants' @{
        clientId = $principal.id; resourceId = $resource.Sp.id; consentType = 'AllPrincipals'; scope = $scope
    } | Out-Null }
    $inheritPath = "v1.0/applications/microsoft.graph.agentIdentityBlueprint/$($blueprint.appId)/inheritablePermissions"
    $existing = SingleOrNone @(List $inheritPath | Where-Object { $_.resourceAppId -eq $resource.Sp.appId }) 'inheritance entry'
    $inheritance = @{
        resourceAppId = $resource.Sp.appId
        inheritableScopes = @{ '@odata.type' = '#microsoft.graph.allAllowedScopes'; kind = 'allAllowed' }
        inheritableRoles = @{ '@odata.type' = '#microsoft.graph.noRoles'; kind = 'none' }
    }
    if ($existing) {
        # Do not expand or remove unrelated existing inheritance policies.
        if ($existing.inheritableScopes.kind -ne 'allAllowed' -or $existing.inheritableRoles.kind -ne 'none') {
            throw "Existing inheritance for $($resource.Sp.appId) differs. Review it manually before rerunning."
        }
    } else { Graph POST $inheritPath $inheritance | Out-Null }
}
$agent = SingleOrNone (List "v1.0/servicePrincipals/microsoft.graph.agentIdentity?`$filter=displayName eq '$Name'") 'agent name'
if ($agent -and $agent.agentIdentityBlueprintId -ne $blueprint.appId) { throw 'Existing agent belongs to a different blueprint.' }
if (!$agent) {
    $agent = Graph POST 'v1.0/servicePrincipals/microsoft.graph.agentIdentity' @{
        displayName = $Name; agentIdentityBlueprintId = $blueprint.appId
        'sponsors@odata.bind' = @($userReference)
    }
}
Write-Output "Agent ID: $($agent.id)"
$agentUser = SingleOrNone (List "beta/users/microsoft.graph.agentUser?`$filter=userPrincipalName eq '$AgentUserPrincipalName'") 'agent user'
if ($agentUser -and $agentUser.identityParentId -ne $agent.id) { throw 'Existing agent user belongs to a different agent identity.' }
if (!$agentUser) {
    $agentUser = Graph POST 'beta/users/microsoft.graph.agentUser' @{
        displayName = "$Name user"; userPrincipalName = $AgentUserPrincipalName
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
Write-Output "`nCopy these identifiers into .env (no secret was created):"
Write-Output "W365_TENANT_ID=$TenantId"
Write-Output "W365_BLUEPRINT_ID=$($blueprint.appId)"
Write-Output "W365_AGENT_ID=$($agent.id)"
Write-Output "W365_AGENT_USER_ID=$($agentUser.id)"
Write-Output 'Setup requests completed. Check pool readiness in Intune before running the sample.'
