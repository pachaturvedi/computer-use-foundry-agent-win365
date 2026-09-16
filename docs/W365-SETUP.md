# Windows 365 setup

An Azure subscription and Foundry model do **not** imply that W365 is ready.

## Prerequisites

| Requirement | Action |
| --- | --- |
| Agent 365 | Complete tenant onboarding and licensing. |
| Windows entitlement | Windows Enterprise E3 or higher, plus Intune and Entra ID P1. |
| Billing | Activate a W365 for Agents pay-as-you-go billing plan; the script does not buy licenses or activate billing. |
| Pool | Create a provisioning policy **(Agents)** in Intune. Explicitly select billing plan, geography, image and capacity. Record the pool ID. |
| Administrator | Agent ID Administrator for certificates/agent users; consent administrator for delegated grants; Cloud PC/Intune administrative privileges for pool assignment. |
| Tooling | PowerShell 7.5+ and Microsoft.Graph.Authentication. |
| Viewer | Obtain the SDK bundle URL and allowed iframe origins from W365 onboarding. |

W365 for Agents does not require a per-user Windows 365 Cloud PC seat for this
consumption model. Pool capacity can incur charges while the sample is idle.
A task timeout is not a billing cap. Stop/delete unneeded pools in Intune.

[Official prerequisites](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/getting-started.md),
[billing](https://learn.microsoft.com/windows-365/agents/billing-w365a),
[pool creation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/cloud-pc-pools.md).

## Certificate and identities

```powershell
.\scripts\New-DevCertificate.ps1
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
$setup = @{
    TenantId = "<W365-tenant-GUID>"
    Name = "foundry-w365-sample"
    AgentUserPrincipalName = "foundry-w365-agent@YOUR-TENANT.onmicrosoft.com"
    CertificatePublicPath = ".local\blueprint.cer"
    PoolId = "<existing-agent-pool-GUID>"
}
.\scripts\Setup-W365.ps1 @setup -WhatIf
.\scripts\Setup-W365.ps1 @setup -BillingConfirmed
```

The certificate helper prompts for a password and creates a 90-day RSA encrypted
PFX plus public CER in `.local`. It refuses to overwrite either file. Restrict
the directory to your own account. Use an organizationally managed certificate
for hosted deployment.

`-WhatIf` is offline: no sign-in or network calls. A real run requires explicit
confirmation and delegated Graph sign-in. The script validates the tenant,
scopes, certificate, W365 resource metadata and existing pool; then:

1. Creates/reuses the uniquely named blueprint and its principal; registers only
   the public certificate, preserving unrelated keys.
2. Merges permission declarations, AllPrincipals consent and inheritance.
3. Creates/reuses an agent identity and agent user, validating each parent ID.
4. Assigns the agent user directly to the pool via
   `cloudPcAgentPoolUserAssignment.userPrincipalId`, not through a group.
5. Prints four non-secret W365 identifiers to copy into `.env`.

Display names are not unique: multiple matches abort. Reuse requires the current
user to own the blueprint; unrelated parents or different inheritance policies
are not overwritten. No per-instance duplicate grants or blueprint secrets are
created. Pool creation remains an explicit Intune step so the script never
guesses billing, geography or image choices.

## Setup permissions (delegated, not runtime)

| Graph scope | Purpose |
| --- | --- |
| `User.Read` | Current owner/sponsor. |
| `Application.Read.All` | Service metadata and existing configuration. |
| `AgentIdentityBlueprint.Create` | Create blueprint. |
| `AgentIdentityBlueprint.ReadWrite.All` | Blueprint reconciliation and inheritance. |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | Auth properties / resource declarations. |
| `AgentIdentityBlueprint.AddRemoveCreds.All` | Certificate registration. |
| `AgentIdentityBlueprintPrincipal.Create` | Blueprint principal. |
| `AgentIdentity.Create.All`, `AgentIdentity.Read.All` | Create/find agent identity. |
| `AgentIdUser.ReadWrite.All` | Create/find agent user and validate parent. |
| `DelegatedPermissionGrant.ReadWrite.All` | Admin consent. |
| `CloudPC.ReadWrite.All` | Pool validation and assignment. |

Scopes and Entra roles are different checks. Requesting a scope does not activate
a role. Use PIM and your organization's consent procedures; do not permanently
grant Global Administrator just to run this sample. Runtime identities do not
receive these Graph setup permissions.

## W365 runtime permissions

| Resource app ID | Delegated scopes |
| --- | --- |
| `da81128c-e5b5-4f9e-8d89-50d906f107c5` | `Tools.ListInvoke.All` |
| `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` | `McpServersMetadata.Read.All` |
| `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5` | `Computer.See`, `Computer.Control` |

Each resource is declared/consented on the blueprint and inherited by the agent.
`allAllowed` inherits already granted scopes; `noRoles` avoids application-role
inheritance. The script preserves existing grants; use a dedicated blueprint.

## Readiness and failures

Wait for pool provisioning (often 20-30 minutes), confirm available sessions and
the agent user assignment. The runtime allocates once and polls for Ready.
403: inspect declaration, consent and inheritance separately. 401: inspect
certificate validity, identity IDs and audience. Missing resource scopes: finish
W365 onboarding rather than substituting another audience.

Graph propagation errors stop the script. Inspect the printed IDs, wait, and
rerun with the same names. Mutation requests are not blindly retried. A lost
create response is reconciled by name/UPN and parent on the next run.
Agent-user and pool APIs use Graph beta contracts, which can change and are not
a production provisioning guarantee.

## Cleanup

End active sessions first. In Intune remove the sample assignment and delete
unneeded sample pools (deletion destroys their Cloud PCs). In Entra remove the
agent user, agent identity, blueprint principal and blueprint only after checking
for other consumers. Remove sample-only grants/certificates, Key Vault secrets,
role assignments and local private files. Azure resource-group deletion does not
delete Entra identities or cancel W365 billing.

Sources: [blueprints](https://learn.microsoft.com/entra/agent-id/create-blueprint),
[agent creation](https://learn.microsoft.com/graph/api/agentidentity-post),
[agent users](https://learn.microsoft.com/powershell/module/microsoft.entra.users/new-entraagentuserforagentid),
[pool assignment](https://learn.microsoft.com/graph/api/cloudpcpool-post-assignments?view=graph-rest-beta).
