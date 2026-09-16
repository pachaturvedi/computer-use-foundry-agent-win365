# Windows 365 setup

An Azure subscription and Foundry model do **not** imply that W365 is ready.
This is **phase 2**: first [deploy bootstrap and discover the Foundry
identity](DEPLOYMENT.md#phase-1-deploy-bootstrap). Setup reuses the exact
Foundry-provisioned blueprint and agent identity; it does not create replacements.

## Prerequisites

| Requirement | Action |
| --- | --- |
| Agent 365 | Complete tenant onboarding and licensing. |
| Windows entitlement | Windows Enterprise E3 or higher, plus Intune and Entra ID P1. |
| Billing | Activate a W365 for Agents pay-as-you-go billing plan; the script does not buy licenses or activate billing. |
| Pool | Create a provisioning policy **(Agents)** in Intune. Explicitly select billing plan, geography, image and capacity. Record the pool ID. |
| Foundry identities | Record the discovered blueprint app/client ID and agent object/principal ID. W365, Foundry and viewer Azure identities must share the tenant. |
| Administrator | Verify current tenant roles and consent policy for blueprint updates, agent users, grants and pool assignment. Use PIM where required. |
| Tooling | PowerShell 7.5+ and Microsoft.Graph.Authentication. |
| Optional viewer | Existing deployed UAMI, explicit administrator approval for blueprint federation, and the SDK URL/frame origins from W365 onboarding. |

W365 for Agents does not require a per-user Windows 365 Cloud PC seat for this
consumption model. Pool capacity can incur charges while the sample is idle.
A task timeout is not a billing cap. Stop/delete unneeded pools in Intune.

[Official prerequisites](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/getting-started.md),
[billing](https://learn.microsoft.com/windows-365/agents/billing-w365a),
[pool creation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/cloud-pc-pools.md).

## Bind the existing Foundry identities

From the repository root, substitute the IDs returned by discovery:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
$setup = @{
    TenantId = "<same-W365-and-Foundry-tenant-GUID>"
    BlueprintId = "<Foundry-blueprint-app-client-GUID>"
    AgentIdentityId = "<Foundry-agent-object-principal-GUID>"
    AgentUserPrincipalName = "foundry-w365-agent@YOUR-TENANT.onmicrosoft.com"
    PoolId = "<existing-agent-pool-GUID>"
}
.\scripts\Setup-W365.ps1 @setup -WhatIf
.\scripts\Setup-W365.ps1 @setup -BillingConfirmed
```

`-WhatIf` is offline: no sign-in or network calls. A real run requires explicit
confirmation and delegated Graph sign-in. `-BillingConfirmed` acknowledges
your completed billing prerequisites; it does not activate billing.

The script **never creates a blueprint, blueprint service principal, agent
identity, certificate or secret**. It finds the exact supplied existing entities,
resolves the agent app ID from the supplied object ID, and validates the agent's
blueprint parent and any existing agent user's parent **before any mutations**.
Missing entities or a mismatched parent stop setup. Display-name matches are not
authority to adopt an identity.

Preflight also rejects ambiguous existing grants or inheritance and incompatible
policies before writes. There is no `/me` lookup or owner takeover: setup operates
on the supplied existing entities under the administrator's approved permissions.

After preflight, setup merges resource declarations, consent and inheritance
while preserving unrelated entries, creates or reuses the correctly parented
agent user, and assigns it directly to the existing pool using
`cloudPcAgentPoolUserAssignment.userPrincipalId`, not through a group. Different
inheritance policies are not taken over. Pool creation remains an explicit
Intune step; no purchasing, geography or image choices are automated.

Copy these non-secret outputs to the phase-2 deployment configuration:

| Output | Meaning |
| --- | --- |
| `W365_TENANT_ID` | Tenant shared by Foundry, W365 and viewer Azure identity. |
| `W365_BLUEPRINT_ID` | Existing blueprint app/client ID. |
| `W365_AGENT_ID` | Existing agent **app/client ID**, resolved from its object ID. |
| `W365_AGENT_OBJECT_ID` | Existing agent **object/principal ID**, supplied as `AgentIdentityId`. |
| `W365_AGENT_USER_ID` | Agent-user object ID assigned to the pool. |

App IDs and object IDs are distinct identifiers and must not be substituted
for one another. Both `W365_AGENT_ID` and `W365_AGENT_OBJECT_ID` are required
when enabling either the Foundry agent or viewer. The agent-user ID is not a credential.

## Offline setup tests

From the repository root, run the mocked regression scripts with PowerShell 7.5+:

```powershell
pwsh -NoProfile -File .\scripts\Test-SetupOffline.ps1
pwsh -NoProfile -File .\scripts\Test-DiscoveryOffline.ps1
```

These scripts mock Graph and Azure CLI respectively: they do not sign in,
call a tenant, allocate a Cloud PC or incur W365 charges. The setup tests cover
existing identity reuse, distinct client/object IDs, pre-mutation parent/policy
rejection, preservation of unrelated configuration and optional idempotent
viewer federation. The discovery tests cover the exact read-only version URL,
ID types, tenant binding, missing metadata and untrusted endpoint rejection.
This is separate from setup `-WhatIf`, which prints the offline plan for your
supplied arguments. Neither proves live hosting compatibility.

## Optional viewer federation

First deploy the viewer in bootstrap mode to obtain its existing UAMI
`viewerIdentityPrincipalId` output. Only after administrator approval, add:

```powershell
$setup.ViewerManagedIdentityObjectId = "<viewerIdentityPrincipalId-GUID>"
.\scripts\Setup-W365.ps1 @setup -AuthorizeViewerFederation -WhatIf
.\scripts\Setup-W365.ps1 @setup -AuthorizeViewerFederation -BillingConfirmed
```

This optional FIC trusts that **UAMI object/principal ID** as subject on the
blueprint, with issuer `https://login.microsoftonline.com/<tenant>/v2.0` and
audience `api://AzureADTokenExchange`. It is not the UAMI client ID and not
the separate OIDC web application's ID.

**This permits blueprint impersonation, potentially including sibling agents,
not just ARI/screen sharing.** Do not authorize it when a shared blueprint or
administrator policy disallows that trust. A dedicated blueprint is recommended.
Leave the viewer disabled instead; the agent may return unavailable viewer
links. Configure only an approved viewer and do not attempt human-handoff tasks
without one.

## Setup permissions (delegated, not runtime)

| Graph scope | Purpose |
| --- | --- |
| `Application.Read.All` | Existing entities and service metadata. |
| `AgentIdentityBlueprint.ReadWrite.All` | Existing blueprint reconciliation and inheritance. |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | Auth properties / resource declarations. |
| `DelegatedPermissionGrant.ReadWrite.All` | Admin consent. |
| `AgentIdentity.Read.All` | Read existing agent identity and validate parent. |
| `AgentIdUser.ReadWrite.All` | Create/find agent user and validate parent. |
| `CloudPC.ReadWrite.All` | Pool validation and assignment. |
| `AgentIdentityBlueprint.AddRemoveCreds.All` | **Optional FIC only**, with explicit viewer federation authorization. |

No `User.Read`, blueprint, blueprint-principal or agent-identity creation scopes
are required.
Scopes and Entra roles are separate checks: requesting a scope does not activate
a role. Verify tenant roles, scopes and organizational approval for the actual
operations; use PIM and consent procedures, not permanent Global Administrator.
Runtime identities do not receive these Graph setup permissions.

## W365 runtime permissions

| Resource app ID | Delegated scopes |
| --- | --- |
| `da81128c-e5b5-4f9e-8d89-50d906f107c5` | `Tools.ListInvoke.All` |
| `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` | `McpServersMetadata.Read.All` |
| `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5` | `Computer.See`, `Computer.Control` |

Each resource is declared/consented on the blueprint and inherited by the agent.
`allAllowed` inherits already granted scopes; `noRoles` avoids application-role
inheritance. **Blueprint inherited grants can affect sibling agents.** An
administrator must explicitly approve that scope of change; use a dedicated
blueprint where possible. Existing declarations, grants and unrelated scopes
are preserved; a different policy is rejected rather than overwritten.

## Readiness and failures

Wait for pool provisioning (often 20-30 minutes), confirm available sessions and
the agent user assignment. The enabled runtime allocates once and polls for
Ready. 403: inspect declaration, consent and inheritance separately. 401:
inspect the deployed identity endpoint, blueprint selection, ID types, tenant,
FIC (viewer only) and audience. Missing resource scopes: finish W365 onboarding,
do not substitute another audience.

Graph propagation errors stop the script. Inspect IDs, wait and rerun with
the same supplied IDs and UPN. Mutation requests are not blindly retried.
An uncertain agent-user create is reconciled by exact UPN and parent on rerun.
Agent-user and pool APIs use Graph beta contracts; these may change and are
not a production provisioning guarantee.

## Migration from standalone identities

Stop/drain tasks and resolve any active session/lease before rebinding. Deploy
bootstrap, discover Foundry's identities, and run setup with those exact IDs.
An old agent user bound to a separate identity **must not be automatically
reparented**: choose a different UPN and create a user bound to the correct
Foundry identity.

Remove old certificate settings from deployment configuration.
`scripts/New-DevCertificate.ps1` has been deleted and the standalone-identity
quickstart is retired; there is
no certificate fallback. Do not delete old resources automatically. After the
new binding and hosting token flow are accepted, check all consumers before
retiring separate identities, certificate registrations, private files and
old Key Vault certificate secrets. Preserve the viewer's separate OIDC secret.

## Cleanup

End active sessions first. In Intune remove the sample assignment and delete
unneeded sample pools (deletion destroys their Cloud PCs). Remove only approved,
sample-specific agent users, grants, viewer FICs and role assignments. Check
other consumers and coordinate with the Foundry owner before deleting any
Foundry-managed blueprint, principal or agent identity. Never treat reused
identities as disposable script-owned resources.

Retire unneeded OIDC secrets and private state according to policy. Azure
resource-group deletion does not delete Entra identities or cancel W365 billing.

Sources: [Foundry identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[agent-user OAuth](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow),
[managed identity FIC](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity),
[agent users](https://learn.microsoft.com/powershell/module/microsoft.entra.users/new-entraagentuserforagentid),
[pool assignment](https://learn.microsoft.com/graph/api/cloudpcpool-post-assignments?view=graph-rest-beta).
