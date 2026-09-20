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
| Pool | Either record an existing provisioning policy **(Agents)** ID, or prepare the billing plan, geography, image and capacity values needed for the script to create one. |
| Foundry identities | Record the discovered blueprint app/client ID and agent object/principal ID. W365, Foundry and viewer Azure identities must share the tenant. |
| Administrator | Verify current tenant roles and consent policy for blueprint updates, agent users, grants and pool assignment. Use PIM where required. |
| Tooling | PowerShell 7.4+ and Microsoft.Graph.Authentication. |
| Optional viewer | Existing deployed UAMI, explicit administrator approval for blueprint federation, and the SDK URL/frame origins from W365 onboarding. |

W365 for Agents does not require a per-user Windows 365 Cloud PC seat for this
consumption model. Pool capacity can incur charges while the sample is idle.
A task timeout is not a billing cap. Stop/delete unneeded pools in Intune.

[Official prerequisites](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/getting-started.md),
[billing](https://learn.microsoft.com/windows-365/agents/billing-w365a),
[pool creation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/cloud-pc-pools.md).

## Setup permission summary

The setup flow runs with an operator's delegated Microsoft Graph permissions.
These are separate from the runtime credential mode documented in
[authentication](AUTHENTICATION.md).

- The operator must be able to sign in interactively with Microsoft Graph through `Connect-MgGraph` or an Azure CLI Graph token fallback.
- The operator must have tenant-approved delegated access to read and update the existing blueprint app registration, reconcile required resource access, create or reuse the agent user, and assign that user to the selected W365 pool.
- The operator must also have the Azure-side access needed to read the selected azd environment and redeploy the hosted agent after setup persists the non-secret `W365_*` identifiers.

If your tenant uses PIM or admin consent workflows, activate those roles before
running setup. The script fails closed when the delegated setup identity cannot
prove the required parent/ownership chain.

The exact delegated Graph scope list appears later under
[Setup permissions (delegated, not runtime)](#setup-permissions-delegated-not-runtime).

## Bind the existing Foundry identities

From the repository root, either substitute the IDs returned by discovery or let
the azd wrapper discover them from the currently deployed hosted-agent version.

### Preview setup inputs with known IDs

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
```

`Setup-W365.ps1 -WhatIf` is the low-level, offline input preview. Do not run
that script directly for a staged deployment mutation: it does not prove the
shared Blob state, exact container-scoped RBAC, operator binding, or credential
readiness. Use the wrapper below for every real setup.

### Staged azd flow

Run this only after the phase-1 identity has been discovered and
[deployment phase 2](DEPLOYMENT.md#phase-2-bind-and-enable) has provisioned
shared Blob state, configured the hosted operator, explicitly selected a
credential mode, and securely stored the blueprint secret when using
`client_secret`. The wrapper verifies these prerequisites before any W365 or
Entra mutation.

For `client_secret` mode:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment "<azd-environment-name>" `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -AgentUserPrincipalName "foundry-w365-agent@YOUR-TENANT.onmicrosoft.com" `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

For the explicitly approved `managed_identity_federation` mode:

```powershell
$environment = "<azd-environment-name>"
azd env set W365_BLUEPRINT_CREDENTIAL_MODE managed_identity_federation `
    --environment $environment
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -HostedRuntimeIdentityObjectId "<Foundry-agent-object-principal-guid>" `
    -AuthorizeHostedRuntimeFederation `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

`PoolIdOrUrl` accepts either a raw pool GUID or the Intune URL that contains
`poolId/<guid>`, including links copied from the admin center.

`-WhatIf` is offline: no sign-in or network calls. A real run requires explicit
confirmation and delegated Graph sign-in. `-BillingConfirmed` acknowledges
your completed billing prerequisites; it does not activate billing.
`-UseDeviceCode` is recommended in VS Code and other embedded terminals where
WAM cannot obtain a parent window handle.

For repeatable no-`PoolId` creates, store reusable pool settings in
`config\deployment.local.json`. `Setup-W365.ps1` now reads the `w365` section
automatically when the corresponding command-line argument is omitted.

If you already have a working pool, do not hand-copy its settings. Capture them
once from the Intune URL and persist the template automatically:

```powershell
pwsh -NoProfile -File .\scripts\Save-W365PoolTemplate.ps1 `
    -PoolIdOrUrl "https://intune.microsoft.com/#view/Microsoft_Azure_CloudPC/CloudPCAgentPoolDetail.ReactView/poolId/8607571b-2177-462c-bd6f-b8d1dac75333" `
    -PoolDisplayName "su-cua-test-clone" `
    -UseDeviceCode
```

To review tenant-supported choices before writing configuration, authenticate
first and query the read-only discovery catalogs:

```powershell
pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 `
    -TenantId "<tenant-guid>" `
    -UseDeviceCode
```

The result contains:

- existing W365 agent pools with display name, pool ID, and billing-plan GUID;
- currently available region names, geographic location types, and groups
  (catalog object GUIDs are informational and are not written as pool regions);
- currently supported gallery image IDs and display names.

Use the selected pool URL with `Save-W365PoolTemplate.ps1`, or pass the selected
billing-plan GUID to `Invoke-W365LiveAcceptance.ps1`. Discovery is read-only
and never adopts or modifies the source pool.

For the guided path, add `-Configure`:

```powershell
pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 `
    -TenantId "<tenant-guid>" `
    -UseDeviceCode `
    -Configure `
    -DefaultBillingPlanId "<billing-plan-guid>"
```

The helper displays numbered tenant-supported billing plans, available regions,
and supported gallery images. It marks the existing local value or checked-in
sample value as `(default)`. Press Enter to accept the default, or enter another
number to choose from the discovered list. The selected minimum-capacity
profile is written to ignored `config\deployment.local.json`; discovery does
not create or modify any W365 resource.

When `-UseDeviceCode` is supplied, the helper now skips the default Windows
interactive path and prints the browser URL, timing guidance, and device-code
prompt. Open `https://login.microsoft.com/device`, enter the displayed code,
and complete sign-in within 120 seconds. The command waits for authentication
and then continues discovery; do not close the terminal.

If you miss the first prompt, the helper retries device-code sign-in once by
default and shows a fresh code. Adjust that bounded retry count with
`-DeviceCodeMaxAttempts` when needed.

`Invoke-W365SetupFlow.ps1` uses the same behavior: it prints the
browser instructions before requesting the code, waits for completion, and
retries once with a fresh code when the fixed 120-second window expires.

This workflow uses direct delegated Microsoft Graph authentication with
`CloudPC.Read.All`. It intentionally does not use Azure CLI tokens for Graph
discovery because the Azure CLI public client cannot request this first-party
scope in every tenant. Complete the displayed device code promptly as an
authorized tenant operator. `GraphClientTimeoutSeconds` affects Graph HTTP
requests, not the fixed device-code sign-in window.

Rerun the same command whenever the source pool changes. The script updates the
stored `w365` values in place while preserving unrelated settings in
`config\deployment.local.json`.

After that, future setup runs can omit all pool-creation arguments and only
pass the operator-specific values such as the agent-user UPN.

```json
{
    "w365": {
        "poolDisplayName": "su-cua-test-clone",
        "poolDescription": "Cloned from the su-cua-test pool template.",
        "poolBillingPlanId": "<billing-plan-guid>",
        "poolBillingPlanName": "w365a-billingplan",
        "poolBillingType": "payAsYouGo",
        "poolGeographicLocationType": "usCentral",
        "poolRegionGroup": "usCentral",
        "poolRegions": ["centralus"],
        "poolImageId": "microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365",
        "poolImageDisplayName": "Windows 11 Enterprise 25H2",
        "poolImageType": "gallery",
        "poolOsLocale": "en-US",
        "poolMinimumCount": 1,
        "poolMaximumCount": 1,
        "poolEnableSingleSignOn": false
    }
}
```

`poolBillingPlanName` and `poolImageDisplayName` are operator notes only. The
script uses `poolBillingPlanId` and `poolImageId` for the actual create call.
The sample `poolImageId` above is the expected gallery identifier for the UI's
"Windows 11 Enterprise 25H2" image and should be confirmed in your tenant if
Microsoft changes gallery image naming.

The script **never creates a blueprint, blueprint service principal, agent
identity, certificate or secret**. It can add an explicitly authorized,
exact-subject FIC to the existing blueprint. It finds the exact supplied entities,
resolves the agent app ID from the supplied object ID, and validates the agent's
blueprint parent and any existing agent user's parent **before any mutations**.
Missing entities or a mismatched parent stop setup. Display-name matches are not
authority to adopt an identity.

Preflight also rejects ambiguous existing grants or inheritance and incompatible
policies before writes. There is no `/me` lookup or owner takeover: setup operates
on the supplied existing entities under the administrator's approved permissions.

After preflight, setup merges resource declarations, consent and inheritance
while preserving unrelated entries, creates or reuses the correctly parented
agent user, creates or updates the Cloud PC agent pool when requested, and
assigns the agent user directly using
`cloudPcAgentPoolUserAssignment.userPrincipalId`, not through a group. Different
inheritance policies are not taken over. Incremental reruns reuse the persisted
pool only when the selected environment's ownership manifest proves its exact
ID and relationships. A standalone `W365_POOL_ID` or matching display name is
not ownership proof. The staged wrapper can create the pool from
the validated local profile and derives its display name from `RESOURCE_PREFIX`
and `AZURE_ENV_NAME`.

`Invoke-W365SetupFlow.ps1` runs only after the bootstrap identity and phase-2
state are ready. It reads the tenant's verified default domain used for user
creation and derives an environment-owned agent-user UPN. Custom verified
tenant domains are supported; the workflow does not assume an
`onmicrosoft.com` suffix. `W365_AGENT_USER_PRINCIPAL_NAME` can override the
full UPN, while `W365_AGENT_USER_DOMAIN` can select another verified tenant
domain. The wrapper requires explicit W365 resource approval before mutations.

`Setup-W365.ps1` writes these non-secret outputs into the currently selected azd
environment when `azd 1.32.0+` is available. Record them for review; they are
identifiers, not credentials.

| Output | Meaning |
| --- | --- |
| `W365_TENANT_ID` | Tenant shared by Foundry, W365 and viewer Azure identity. |
| `W365_BLUEPRINT_ID` | Existing blueprint app/client ID. |
| `W365_AGENT_ID` | Existing agent **app/client ID**, resolved from its object ID. |
| `W365_AGENT_OBJECT_ID` | Existing agent **object/principal ID**, supplied as `AgentIdentityId`. |
| `W365_AGENT_USER_ID` | Agent-user object ID assigned to the pool. |
| `W365_POOL_ID` | Agent pool ID reused or created by setup, then used for the assignment. |
| `W365_ENABLED` | Internal phase switch set to `true` only after setup succeeds. |

When setup can resolve the selected azd environment, it also writes a
non-secret ownership manifest under `.azure/<environment>/w365-ownership.json`
and prints `W365_OWNERSHIP_MANIFEST=<path>`. That manifest records which W365
and Entra objects were created by the sample, which ones were reused, and the
blueprint's prior `requiredResourceAccess` so teardown can restore it.

If automatic persistence cannot run, copy the same non-secret outputs to the
phase-2 deployment configuration manually.

App IDs and object IDs are distinct identifier types and must be resolved from
their documented fields rather than inferred from one another. A Foundry agent
identity may currently expose the same GUID value for both fields; that does
not make their API roles interchangeable. Both `W365_AGENT_ID` and
`W365_AGENT_OBJECT_ID` are required when enabling either the Foundry agent or
viewer. The agent-user ID is not a credential.

After setup persists the returned values plus your Blob/operator configuration,
`Invoke-W365SetupFlow.ps1` redeploys the **same** `win365-desktop-agent`
service. Do not immediately repeat that deployment. Use the scoped recovery
command in [deployment phase 2](DEPLOYMENT.md#phase-2-bind-and-enable) only if
the wrapper reports that setup succeeded but its final agent deployment failed.

The deployment creates a new immutable agent version under the existing agent
name. Rediscover that exact version and reject unexpected blueprint or instance
identity replacement before enabling desktop tasks.

## Offline setup tests

The canonical Windows setup runs the build, .NET tests, and both mocked
regression suites:

```powershell
pwsh -NoProfile -File .\scripts\Setup-Local.ps1
```

To rerun only the setup/discovery regressions:

```powershell
pwsh -NoProfile -File .\tests\PowerShell\Test-SetupOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-RemoveW365ResourcesOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-DiscoveryOffline.ps1
```

The regression scripts mock Graph and Azure CLI respectively: they do not sign in,
call a tenant, allocate a Cloud PC or incur W365 charges. The setup tests cover
existing identity reuse, distinct client/object IDs, pre-mutation parent/policy
rejection, preservation of unrelated configuration and optional idempotent
viewer federation. The cleanup tests cover reverse-order deletion, idempotent
runs, shared-project blocking, already-absent resource handling, pre-mutation
verification of reused grants and reused inheritance entries, and fail-closed
behavior when shared-state restoration is no longer safe. The discovery tests
cover the exact read-only version URL, ID types, tenant binding, missing
metadata and untrusted endpoint rejection. This is separate from setup `-WhatIf`,
which prints the offline plan for your supplied arguments. Neither proves live
hosting compatibility.

## Troubleshooting

| Symptom | Cause or check | Resolution |
| --- | --- | --- |
| Device-code sign-in expires before completion | The Graph PowerShell prompt was not completed within its fixed sign-in window. | Rerun with `-UseDeviceCode`, complete the displayed code immediately, and increase `-DeviceCodeMaxAttempts` only when the first prompt is routinely missed. |
| Azure CLI fallback reports missing CloudPC consent | The cached Azure CLI Graph token does not include the required CloudPC scope or consent. | Run `az logout`, then `az login --tenant "<tenant-id>" --scope "https://graph.microsoft.com/CloudPC.Read.All"`, and rerun the helper. |
| Setup refuses to reuse an existing pool or agent user | The parent/ownership chain or persisted ownership manifest does not match the supplied entities. | Review the emitted validation error, confirm the exact blueprint, agent object ID, agent app ID, and pool ID, then rerun with the intended environment selected. |

## Next steps

- Return to [deployment phase 2](DEPLOYMENT.md#phase-2-bind-and-enable) to redeploy the same hosted agent name with desktop access enabled.
- Use [viewer setup](VIEWER.md) only after the core W365 flow is working and you have explicit approval for viewer federation.

## Optional viewer federation

This section applies only when
`W365_BLUEPRINT_CREDENTIAL_MODE=managed_identity_federation`. The default E2E
demo uses the existing blueprint client secret and does not require a viewer
FIC. Credential modes are explicit and never fall back to each other.

First deploy the viewer in bootstrap mode to obtain its existing UAMI
`viewerIdentityPrincipalId` output. Only after administrator approval, add:

```powershell
$environment = "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -ViewerManagedIdentityObjectId "<viewerIdentityPrincipalId-GUID>" `
    -AuthorizeViewerFederation `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
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

## Hosted runtime federation

Foundry Responses hosting may expose the agent's instance identity but not a
direct blueprint assertion. After a live probe confirms that
`W365_AGENT_OBJECT_ID` can acquire
`api://AzureADTokenExchange/.default`, explicitly authorize the exact instance
identity as a blueprint FIC:

```powershell
$environment = "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -HostedRuntimeIdentityObjectId "<W365_AGENT_OBJECT_ID>" `
    -AuthorizeHostedRuntimeFederation `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

The script requires the hosted subject to exactly equal `AgentIdentityId`.
It uses the tenant issuer and only `api://AzureADTokenExchange` as audience.
An existing matching FIC is reused; a conflicting issuer, subject, audience,
or duplicate match fails before mutation. This trust can authenticate the
blueprint and therefore can affect sibling agents under a shared blueprint.
Use it only for the exact Foundry instance identity after the live assertion
probe succeeds.

## Setup permissions (delegated, not runtime)

| Graph scope | Purpose |
| --- | --- |
| `Application.Read.All` | Existing entities and service metadata. |
| `Domain.Read.All` | Read verified tenant domains and select the default domain used for agent-user creation. |
| `AgentIdentityBlueprint.ReadWrite.All` | Existing blueprint reconciliation and inheritance. |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | Auth properties / resource declarations. |
| `DelegatedPermissionGrant.ReadWrite.All` | Admin consent. |
| `AgentIdentity.Read.All` | Read existing agent identity and validate parent. |
| `AgentIdUser.ReadWrite.All` | Create/find agent user and validate parent. |
| `CloudPC.ReadWrite.All` | Pool validation and assignment. |
| `AgentIdentityBlueprint.AddRemoveCreds.All` | **Optional FIC only**, with explicit hosted-runtime or viewer federation authorization. |

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
| `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5` | `Computer.See`, `Computer.Control`, `Computer.Do`, `Computer.Get` |

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

## Live acceptance

The authoritative acceptance path is a Windows PowerShell driver centered on
one isolated azd environment. It does not require a GitHub Environment.

The checked-in defaults use the sample's Windows 11 Enterprise 25H2 gallery
image in `centralus`, region group/geography `usCentral`, and minimum/maximum
capacity of `1`. The pool display name and description are derived from the
isolated azd environment. Confirm those defaults are supported in the tenant;
override only values that differ in ignored `config\deployment.local.json`.
The billing-plan GUID is tenant-specific and must be supplied to the driver.

Sign in to Azure and run:

```powershell
azd auth login
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

pwsh -NoProfile -File .\scripts\Invoke-W365LiveAcceptance.ps1 `
    -SubscriptionId "<subscription-guid>" `
    -TenantId "<tenant-guid>" `
    -Location "eastus" `
    -Prefix "w365accept" `
    -PoolBillingPlanId "<tenant-billing-plan-guid>"
```

Example effective defaults:

```text
Geographic location type: usCentral
Region group:              usCentral
Regions:                   centralus
Gallery image ID:          microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365
```

The driver creates `w365accept-live`, previews the Azure deployment, and then
requires `I_APPROVE_W365_BILLING_AND_CLEANUP`. It deploys the bootstrap and
W365-enabled agent, requests delegated Graph device-code sign-in, verifies the
ownership manifest and Foundry doctor, reruns `azd up` to prove the manifest is
stable, and always attempts `azd down` in `finally`.

Use `-Resume` only after reviewing a retained environment from a failed run.
Existing environments are otherwise rejected. Use
`-RemoveEnvironmentAfterCleanup` to remove local azd state only after cleanup is
proven; by default the cleaned `.azure\<prefix>-live` state is retained for
review. Sanitized evidence is written under
`artifacts\w365-live-acceptance`; it excludes tenant IDs, resource IDs, UPNs,
endpoints, credentials, and tokens.

The manually dispatched `W365 live acceptance` GitHub workflow is an optional
wrapper around the same script. It uses repository-level `AZURE_CLIENT_ID` for
GitHub OIDC and accepts the deployment context and W365 profile as explicit
dispatch inputs; it does not require a GitHub Environment.

## Cleanup

End active sessions first. `azd down` now invokes
`scripts/Remove-W365Resources.ps1` through the manifest `predown` hook in
`azure.yaml`, and that script removes W365/Entra artifacts before Azure
resources. The recorded teardown order is: pool assignment, agent user,
sample-created federated credentials, created permission grants or restored
reused grant scopes, sample-created inheritance entries, blueprint
`requiredResourceAccess`, and finally a sample-created W365 pool.

Cleanup is ownership-driven, not name-driven. The script reads
`.azure/<environment>/w365-ownership.json` and removes only objects recorded as
sample-created. Reused grants are restored to their prior scope instead of being
deleted, reused inheritance entries are preserved, and reused identities or
pools are preserved. Before any sample-owned deletion runs, cleanup now verifies
that every reused shared-state dependency it may need to preserve or restore is
still present. If W365 state exists but the manifest is missing, or reused
shared state has drifted beyond safe restoration, cleanup is blocked because the
sample can no longer prove what it owns.

For direct execution, use the selected azd environment or pass the paths
explicitly:

```powershell
pwsh -NoProfile -File .\scripts\Remove-W365Resources.ps1 -Confirm
pwsh -NoProfile -File .\scripts\Remove-W365Resources.ps1 `
    -EnvironmentName "<azd-environment-name>" `
    -EnvironmentFilePath ".\.azure\<azd-environment-name>\.env" `
    -OwnershipManifestPath ".\.azure\<azd-environment-name>\w365-ownership.json" `
    -UseDeviceCode `
    -Confirm
```

If the environment is bound to an existing Foundry project, cleanup fails before
any mutation unless you explicitly confirm that the Foundry side is also safe to
destroy:

```powershell
$env:ALLOW_EXISTING_FOUNDRY_CLEANUP = 'true'
pwsh -NoProfile -File .\scripts\Remove-W365Resources.ps1 -Confirm
```

Use that override only for dedicated disposable environments. It is not a safe
default for shared Foundry projects.

Outside the scripted path, remove only approved, sample-specific role
assignments and viewer FICs. Check other consumers and coordinate with the
Foundry owner before deleting any Foundry-managed blueprint, principal or agent
identity. Never treat reused identities as disposable script-owned resources.

Retire unneeded OIDC secrets and private state according to policy. Azure
resource-group deletion does not delete Entra identities or cancel W365 billing.

Sources: [Foundry identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[agent-user OAuth](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow),
[managed identity FIC](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity),
[agent users](https://learn.microsoft.com/powershell/module/microsoft.entra.users/new-entraagentuserforagentid),
[pool assignment](https://learn.microsoft.com/graph/api/cloudpcpool-post-assignments?view=graph-rest-beta).
