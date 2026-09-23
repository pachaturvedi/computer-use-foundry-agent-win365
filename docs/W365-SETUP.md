# Windows 365 setup

Windows 365 setup is phase two. First deploy the disabled bootstrap and
discover the exact Foundry-provisioned blueprint and agent identity; setup
reuses those identities and never creates replacements.

For a dedicated environment, `azd up` performs this workflow automatically.
Use the staged commands when reusing a project, selecting a non-default
credential mode, or requiring separate approval boundaries.

## Prerequisites

| Requirement | Action |
| --- | --- |
| Agent 365 | Complete tenant onboarding and licensing. |
| Windows entitlement | Confirm Windows Enterprise E3 or higher, Intune, and Entra ID P1 requirements for the tenant. |
| Billing | Activate an approved W365 for Agents pay-as-you-go billing plan. The scripts acknowledge billing but do not activate or purchase it. |
| Pool | Choose an existing agent pool or prepare the billing plan, geography, image, and capacity needed to create one. |
| Foundry identities | Record the exact blueprint app/client ID and agent object/principal ID from phase one. |
| State | Provision the private `desktop-state` Blob and container-scoped agent RBAC. |
| Credential mode | Explicitly select and prepare one mode from [Authentication](AUTHENTICATION.md). |
| Administrator | Activate the tenant roles and delegated consent required for blueprint, agent-user, grant, and pool operations. |
| Tooling | Use Windows PowerShell 7.4+ with `Microsoft.Graph.Authentication`. |
| Viewer | Live activation additionally requires its approved OIDC and screen-share settings. |

Foundry, W365, and the viewer Azure identity must share a tenant. The human
viewer sign-in tenant may differ.

W365 for Agents does not require a per-user Cloud PC seat for this consumption
model. Pool capacity can incur charges while idle, and task timeout is not a
billing cap. Stop or remove unneeded capacity through its owning service.

Official references: [prerequisites](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/getting-started.md),
[billing](https://learn.microsoft.com/windows-365/agents/billing-w365a), and
[pool creation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/cloud-pc-pools.md).

## Fresh `azd up` onboarding

Interactive `azd up` deploys the Foundry bootstrap before collecting W365
tenant choices. Select one:

1. reuse an existing W365 agent pool;
2. create a new pool from reviewed tenant-supported values; or
3. skip W365 and retain the Foundry-only bootstrap.

For a new pool, the flow uses checked-in region and image defaults only when
the tenant advertises them. It derives a billing-plan GUID from an existing
pool when possible; otherwise the operator supplies the approved GUID.

For non-interactive deployment, provide an existing pool ID or billing-plan ID
before `azd up`:

```powershell
azd env set W365_POOL_ID "<existing-pool-guid>" `
    --environment "<azd-environment-name>"

# Or, when creating a pool from the reviewed profile:
azd env set W365_POOL_BILLING_PLAN_ID "<billing-plan-guid>" `
    --environment "<azd-environment-name>"
```

If the checked-in region or image is unavailable in the tenant, select
tenant-supported values and save them to ignored `config\deployment.local.json`
before retrying:

```powershell
pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -UseDeviceCode `
    -Configure
```

`-NoPrompt` disables stdin prompts from the deployment wrapper; it is not a
fully unattended tenant workflow. W365 discovery and setup still require the
operator to complete delegated Graph device-code authentication.

Use this protected command block so post-up approvals apply to only one
deployment attempt and are restored even when the attempt fails:

```powershell
$environment = "<azd-environment-name>"
$previousW365Approval = $env:W365_RESOURCE_CHANGES_CONFIRMED
$previousViewerApproval = $env:VIEWER_LIVE_CHANGES_CONFIRMED
try {
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    $env:VIEWER_LIVE_CHANGES_CONFIRMED = 'true' # omit when live activation is not configured

    pwsh -NoProfile -File .\scripts\Invoke-AzdUp.ps1 `
        -Environment $environment `
        -ConfirmResourceChanges `
        -NoPrompt
}
finally {
    [Environment]::SetEnvironmentVariable(
        'W365_RESOURCE_CHANGES_CONFIRMED',
        $previousW365Approval,
        'Process')
    [Environment]::SetEnvironmentVariable(
        'VIEWER_LIVE_CHANGES_CONFIRMED',
        $previousViewerApproval,
        'Process')
}
```

`-ConfirmResourceChanges` approves the outer deployment; it does not replace
the attempt-scoped W365 and viewer post-up approvals. Prompt-free reuse also
requires an explicit pool ID and, when reusing ACA, an explicit persisted
`VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID`. Empty or ambiguous discovery fails
closed.

For the protected `-NoPrompt` workflow, the default `client_secret` credential
mode normally requires two attempts for a fresh environment because the shared
Key Vault does not exist before the first deployment attempt. Interactive
execution can collect the secret during the first attempt. When a `-NoPrompt`
attempt reports that the blueprint secret is missing, store the existing
onboarding secret interactively:

```powershell
pwsh -NoProfile -File .\scripts\Set-ViewerSecrets.ps1 `
    -Environment $environment `
    -BlueprintOnly `
    -BootstrapOperatorAccess
```

Then rerun the protected `Invoke-AzdUp.ps1` block above for the same
environment. Do not clear ownership or redeployment markers between attempts.

The interactive hook then:

- obtains explicit W365/Entra resource approval;
- completes delegated Graph device-code sign-in;
- creates or reuses the default non-exportable Key Vault certificate and
  registers only its public bytes, with no blueprint secret prompt;
- creates or reuses the correctly parented agent user and approved pool;
- records ownership and non-secret IDs;
- approves viewer OIDC activation when screen-share prerequisites are present;
  and
- redeploys the same Foundry agent name.

It never creates a replacement Foundry blueprint or agent identity.

## Setup permission summary

Setup uses the operator's delegated Microsoft Graph identity. These permissions
are separate from the runtime credential mode.

The operator must be able to:

- read and update the existing blueprint;
- reconcile required resource access, delegated grants, and inheritance;
- create or reuse an agent user parented to the discovered agent identity;
- validate or create the selected W365 pool and assign the agent user; and
- read the azd environment and redeploy the hosted agent.

If the tenant uses PIM or admin-consent workflows, activate them before setup.
The script fails closed when it cannot prove the expected parent and ownership
chain. Exact scopes are listed under
[Setup permissions](#setup-permissions-delegated-not-runtime).

## Bind the existing Foundry identities

### Preview setup inputs with known IDs

Use `-WhatIf` only to validate low-level setup arguments without signing in or
calling the tenant:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

$setup = @{
    TenantId = "<Foundry-and-W365-tenant-guid>"
    BlueprintId = "<Foundry-blueprint-app-client-guid>"
    AgentIdentityId = "<Foundry-agent-object-principal-guid>"
    AgentUserPrincipalName = "foundry-w365-agent@YOUR-TENANT.onmicrosoft.com"
    PoolId = "<existing-agent-pool-guid>"
}

pwsh -NoProfile -File .\scripts\Setup-W365.ps1 @setup -WhatIf
```

Do not use `Setup-W365.ps1` directly for a real staged mutation. It does not
prove shared Blob state, exact container RBAC, operator binding, or credential
readiness. Use the wrapper below.

### Staged azd flow

Run this only after
[deployment phase two](DEPLOYMENT.md#phase-2-bind-and-enable) has provisioned
state, configured the operator, and prepared the selected credential.

Fresh/unset environments use `key_vault_certificate`; `azd up` creates or
reuses the certificate, registers only its public bytes on the discovered
blueprint, and verifies registration before W365 mutation. Existing explicit
modes are preserved.

#### Legacy `client_secret` opt-in

```powershell
$environment = "<azd-environment-name>"

azd env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret `
    --environment $environment

pwsh -NoProfile -File .\scripts\Set-ViewerSecrets.ps1 `
    -Environment $environment `
    -BlueprintOnly `
    -BootstrapOperatorAccess

pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

The secure prompt stores `w365-blueprint-client-secret` in the shared Key
Vault. The secret is not written to azd state, source, JSON, logs, or command
history.

#### `managed_identity_federation` mode

This mode requires explicit trust for the exact discovered hosted-agent object
ID and remains blocked on the tested Responses host by `AADSTS700231`.

```powershell
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

#### `key_vault_certificate` mode

This mode uses a self-signed, non-exportable certificate whose private key
never leaves Key Vault. Create the certificate, then register only its public
bytes on the blueprint. Prefer `azd up`, which also grants and revokes the
temporary Key Vault Certificates Officer role the operator needs across these
steps. Running the staged sequence manually requires you to hold that role
through the final `Invoke-W365SetupFlow.ps1` readiness check.

```powershell
azd env set W365_BLUEPRINT_CREDENTIAL_MODE key_vault_certificate `
    --environment $environment

$certificate = & .\scripts\Initialize-W365BlueprintCertificate.ps1 `
    -Environment $environment `
    -ConfirmResourceChanges

pwsh -NoProfile -File .\scripts\Register-W365BlueprintCertificate.ps1 `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -BlueprintId "<Foundry-blueprint-app-client-guid>" `
    -PublicCertificateBase64 $certificate.PublicCertificateBase64 `
    -ConfirmResourceChanges `
    -UseDeviceCode

# Required if state was last provisioned in another credential mode: it grants
# the agent the certificate-scoped Key Vault roles before the redeploy below.
azd provision state --environment $environment --no-prompt

pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

`Register-W365BlueprintCertificate.ps1` needs a delegated Graph sign-in with
`AgentIdentityBlueprint.AddRemoveCreds.All` and touches only the blueprint's
`keyCredentials`. It preserves existing credentials and is idempotent by
certificate thumbprint. Re-running `Initialize-W365BlueprintCertificate.ps1`
without `-Rotate` reuses the existing certificate; `-Rotate` issues a new one,
after which you must re-run the registration step. Reuse fails closed unless
the existing policy is non-exportable RSA 2048 with digital-signature usage.

Before mutating W365 resources, `Invoke-W365SetupFlow.ps1` re-verifies through
a read-only Graph call that the exact certificate is registered on the
blueprint. Key Vault presence alone does not satisfy this check. Certificate
mode is implemented and offline-validated but still requires live tenant
acceptance.

`PoolIdOrUrl` accepts a raw pool GUID or an Intune URL containing
`poolId/<guid>`. `-BillingConfirmed` acknowledges an already approved billing
plan; it does not activate billing.

During `azd up`, a temporary Key Vault Certificates Officer role is held across
certificate creation, Graph registration, readiness verification, and the
agent deployment preflight, because those steps read the certificate through
the Key Vault data plane as the same operator. RBAC-propagation failures are
retried with bounded backoff; terminal errors stop immediately. The role is
revoked once, whether or not the remaining steps succeed, and a failure in
those steps stays the reported error. If revocation also fails, both errors are
reported. A revocation-only failure marks the deployment incomplete.

Rerun `azd up` after correcting the reported cause; certificate creation and
registration are idempotent. If the output reports residual temporary RBAC,
remove only the reported role assignment before retrying. Do not delete the
certificate or unrelated role assignments.

If setup fails after the certificate is registered but before `W365_ENABLED`
becomes `true`, do not run `azd provision state` on its own: that pass would
revoke the certificate-scoped agent roles just granted. Deployment detects this
window and fails closed. Complete setup so `W365_ENABLED=true` is persisted,
then reprovision state and redeploy.

For repeatable creates without `-PoolId`, store reusable pool settings in the
`w365` section of `config\deployment.local.json`. `Setup-W365.ps1` reads it
when the corresponding argument is omitted.

Use `-UseDeviceCode` in terminals where WAM cannot obtain a parent window. The
scripts display the Microsoft device-login URL. Microsoft Graph enforces its
own device-code inactivity timeout and it cannot be extended, so a timed-out
code is reissued automatically for up to three sign-in attempts. Every script
that signs in to Graph behaves this way, including setup, discovery, pool
capture, blueprint certificate registration, viewer sign-in configuration, and
cleanup. Use `-DeviceCodeMaxAttempts` to change that.

### Discover and save a pool profile

Read tenant-supported pools, regions, and images:

```powershell
pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 `
    -TenantId "<tenant-guid>" `
    -UseDeviceCode
```

Use `-Configure` to select discovered values and write them to ignored
`config\deployment.local.json`:

```powershell
pwsh -NoProfile -File .\scripts\Get-W365DiscoveryOptions.ps1 `
    -TenantId "<tenant-guid>" `
    -UseDeviceCode `
    -Configure `
    -DefaultBillingPlanId "<billing-plan-guid>"
```

To capture the supported settings of an existing pool without modifying it:

```powershell
pwsh -NoProfile -File .\scripts\Save-W365PoolTemplate.ps1 `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -PoolDisplayName "<new-pool-display-name>" `
    -UseDeviceCode
```

The helpers are read-only against Graph/W365 and write only non-secret local
configuration. Review `config\deployment.local.example.json` for the supported
shape. Display names are operator notes; IDs are authoritative.

### Setup behavior and outputs

Before mutation, setup verifies:

- blueprint and agent identity existence and parentage;
- any existing agent user's parent;
- grant, inheritance, and policy compatibility;
- explicit credential-mode prerequisites;
- pool ownership or approved creation inputs; and
- billing and resource-change confirmation.

It preserves unrelated declarations, grants, credentials, and policies.
Ambiguous existing state is rejected instead of adopted. Reruns reconcile exact
matches and do not duplicate pool assignment.

Successful setup writes these non-secret values:

| Output | Meaning |
| --- | --- |
| `W365_TENANT_ID` | Tenant shared by Foundry, W365, and the viewer Azure identity. |
| `W365_BLUEPRINT_ID` | Existing blueprint app/client ID. |
| `W365_AGENT_ID` | Existing agent app/client ID. |
| `W365_AGENT_OBJECT_ID` | Existing agent object/principal ID. |
| `W365_AGENT_USER_ID` | Agent-user object ID assigned to the pool. |
| `W365_POOL_ID` | Reused or sample-created pool ID. |
| `W365_ENABLED` | Set to `true` only after setup succeeds. |

It also writes `.azure\<environment>\w365-ownership.json`, recording created
and reused objects plus the blueprint's prior configuration for teardown.

The post-up workflow redeploys the same `win365-desktop-agent` name after setup. If that
deployment or later viewer reconciliation fails, preserve the ownership
manifest and rerun the same environment:

```powershell
azd up --environment "<azd-environment-name>"
```

Do not clear redeployment markers or substitute a standalone `DeployAgent`
command.

## Stale desktop-state recovery prerequisite

Recovery is exceptional, not startup cleanup. Stop all hosted sessions for the
selected environment, then inspect without `-Apply`:

```powershell
pwsh -NoProfile -File .\scripts\Recover-StaleDesktopState.ps1 `
    -Environment "<azd-environment-name>"
```

Only after read-only inspection proves stale state and the exact W365
no-session response should an operator approve:

```powershell
pwsh -NoProfile -File .\scripts\Recover-StaleDesktopState.ps1 `
    -Environment "<azd-environment-name>" `
    -Apply
```

If acquire, upload, or release is ambiguous, rerun read-only inspection. Never
automatically repeat `-Apply`. See
[fail-closed recovery](ARCHITECTURE.md#fail-closed-recovery).

## Offline setup tests

The canonical offline gate is:

```powershell
pwsh -NoProfile -File .\scripts\Validate-PrePr.ps1
```

Focused setup and cleanup regressions:

```powershell
pwsh -NoProfile -File .\tests\PowerShell\Test-SetupOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-DiscoveryOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-RemoveW365ResourcesOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-W365TeardownFlowOffline.ps1
```

These tests use mocked endpoints. They do not authenticate, allocate a Cloud
PC, call a live model, or mutate Azure, Entra, Graph, or W365. They do not prove
live compatibility.

## Troubleshooting

| Symptom | Safe action |
| --- | --- |
| Device-code sign-in expires | Rerun with `-UseDeviceCode` and complete the new prompt immediately. Increase `-DeviceCodeMaxAttempts` only when needed. |
| Setup cannot read Cloud PC data | Confirm delegated Graph consent and tenant roles; do not substitute another audience or Azure CLI token. |
| Existing pool or agent user is rejected | Verify the exact blueprint, agent object ID, agent app ID, parent chain, pool ID, and selected ownership manifest. |
| Setup reports ambiguous grants or inheritance | Review the existing shared blueprint policy. The script will not take it over. |
| Graph propagation fails after a known mutation | Wait, then rerun with the same IDs and UPN. Do not change identities or blindly replay with new values. |
| Final hosted-agent deployment fails | Preserve the ownership manifest, fix the reported prerequisite, and rerun `azd up` for the same environment. Do not clear redeployment markers or substitute standalone `DeployAgent`. |

## Optional viewer federation

This section applies only when
`W365_BLUEPRINT_CREDENTIAL_MODE=managed_identity_federation`. The default
certificate mode does not require a viewer FIC: the viewer UAMI signs with the
same non-exportable Key Vault certificate under object-scoped RBAC. Credential
modes are explicit and never fall back to each other.

After viewer bootstrap produces `viewerIdentityPrincipalId`, explicitly
authorize that exact UAMI object/principal ID:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment "<azd-environment-name>" `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -ViewerManagedIdentityObjectId "<viewerIdentityPrincipalId-guid>" `
    -AuthorizeViewerFederation `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

The FIC uses issuer
`https://login.microsoftonline.com/<tenant>/v2.0` and audience
`api://AzureADTokenExchange`. This is blueprint impersonation and can affect
sibling agents; it is not limited to screen sharing. Do not approve it for an
untrusted viewer or a shared blueprint whose policy disallows that trust.

## Hosted runtime federation

This section applies only to explicitly approved
`managed_identity_federation` mode:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment "<azd-environment-name>" `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -HostedRuntimeIdentityObjectId "<W365_AGENT_OBJECT_ID>" `
    -AuthorizeHostedRuntimeFederation `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

The subject must exactly equal the discovered agent object ID. An existing
exact FIC is reused; conflicts fail before mutation. The tested Responses host
still fails at the Entra chained-federation boundary, so this mode must not
fall back to another credential.

## Setup permissions (delegated, not runtime)

| Graph scope | Purpose |
| --- | --- |
| `Application.Read.All` | Read existing entities and service metadata. |
| `Domain.Read.All` | Read verified domains for agent-user creation. |
| `AgentIdentityBlueprint.ReadWrite.All` | Reconcile the existing blueprint and inheritance. |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | Update auth properties and resource declarations. |
| `DelegatedPermissionGrant.ReadWrite.All` | Reconcile delegated admin consent. |
| `AgentIdentity.Read.All` | Read the existing agent identity and validate its parent. |
| `AgentIdUser.ReadWrite.All` | Create or reuse the correctly parented agent user. |
| `CloudPC.ReadWrite.All` | Validate/create the pool and manage assignment. |
| `AgentIdentityBlueprint.AddRemoveCreds.All` | Explicit FIC operations and certificate public-key registration. |

Scopes and Entra roles are separate requirements. Use PIM and organizational
consent processes rather than permanent broad administrator roles. Runtime
identities do not receive these setup scopes.

Each script states its own minimum before prompting for a device code:

| Step | Minimum Entra access |
| --- | --- |
| Read-only discovery (`Get-W365DiscoveryOptions.ps1`, `Save-W365PoolTemplate.ps1`) | Cloud PC Reader |
| Blueprint certificate registration (`Register-W365BlueprintCertificate.ps1`) | Owner of the agent identity blueprint |
| W365 setup (`Setup-W365.ps1`) | Agent ID Administrator (or blueprint owner) plus Cloud PC Administrator; Privileged Role Administrator for delegated permission grants |
| Viewer sign-in (`Configure-ViewerOidc.ps1`, optional) | Application Administrator or Cloud Application Administrator |

Global Administrator is not required for any step. Blueprint owners can manage
their own blueprint and its agents without an Agent ID role; creating a
blueprint with the Agent ID Developer role makes the creator an owner
automatically. An administrator still has to consent to the delegated scopes
above once per tenant.

## W365 runtime permissions

| Resource app ID | Delegated scopes |
| --- | --- |
| `da81128c-e5b5-4f9e-8d89-50d906f107c5` | `Tools.ListInvoke.All` |
| `ea9ffc3e-8a23-4a7d-836d-234d7c7565c1` | `McpServersMetadata.Read.All` |
| `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5` | `Computer.See`, `Computer.Control`, `Computer.Do`, `Computer.Get` |

The blueprint declares and receives consent for these scopes; the agent
inherits them. Existing unrelated declarations and grants are preserved.
Inherited blueprint grants can affect sibling agents, so shared-blueprint
changes require explicit administrator review.

## Readiness and failures

Pool provisioning can take 20–30 minutes. Confirm available capacity and the
agent-user assignment before invoking a task.

- **401:** verify tenant, blueprint selection, ID types, selected credential,
  FIC/certificate registration, and audience.
- **403:** inspect resource declaration, delegated grant, inheritance, and pool
  assignment separately.
- **Missing scope:** complete W365 onboarding and consent; do not substitute a
  different resource or audience.

Agent-user and pool operations use preview Graph contracts and are not a
production provisioning guarantee.

## Migration from standalone identities

Stop tasks and resolve any active session or lease before rebinding. Deploy the
Foundry bootstrap, discover its identities, and run setup with those exact IDs.

Do not reparent an old agent user automatically. Create a new user with a
different UPN under the correct Foundry agent identity. Retire old identities,
credentials, and private files only after all consumers have moved.

The retired exported-certificate quickstart is not the supported
`key_vault_certificate` mode. The supported mode uses a non-exportable Key
Vault key and explicit public-key registration.

## Live acceptance

Use the isolated acceptance workflow in
[Deployment](DEPLOYMENT.md#live-acceptance). It requires explicit billing
approval, writes sanitized evidence, and attempts ownership-driven teardown.
Offline tests and `-WhatIf` are not live acceptance.

## Cleanup

End active sessions and review
`.azure\<environment>\w365-ownership.json` and, when present,
`viewer-ownership.json`. Then run:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDown.ps1 `
    -EnvironmentName "<azd-environment-name>" `
    -Purge `
    -Force
```

Cleanup removes or restores only manifest-recorded resources:

1. pool assignment and agent user;
2. sample-created FICs;
3. created grants or prior scopes of reused grants;
4. sample-created inheritance entries;
5. prior blueprint `requiredResourceAccess`;
6. a sample-created pool;
7. sample-created viewer OIDC artifacts; and
8. recorded viewer Key Vault RBAC assignments.

Reused identities, pools, applications, grants, and assignments are preserved.
Missing ownership evidence, unexpected pool assignments, or drift that prevents
safe restoration blocks cleanup before mutation.

For a dedicated disposable environment bound to an existing Foundry project,
cleanup still requires explicit approval:

```powershell
$env:ALLOW_EXISTING_FOUNDRY_CLEANUP = 'true'

pwsh -NoProfile -File .\scripts\Invoke-AzdDown.ps1 `
    -EnvironmentName "<azd-environment-name>" `
    -Purge `
    -Force
```

Do not use this override for a shared project. Azure deletion does not remove
untracked Entra objects or cancel W365 billing.

### `key_vault_certificate` mode cleanup

`scripts/Register-W365BlueprintCertificate.ps1` and
`scripts/Initialize-W365BlueprintCertificate.ps1` mutate the tenant (a
blueprint `keyCredential`; any self-granted operator certificate role is
revoked in a `finally` block) outside
the ownership manifest that `Remove-W365Resources.ps1` tracks. These are not
removed automatically by `azd down` or the cleanup script above. When retiring
an environment that used `key_vault_certificate` mode, an administrator with
`AgentIdentityBlueprint.AddRemoveCreds.All` must also:

1. Remove the registered certificate `keyCredential`(s) from the blueprint.
   List the blueprint's current `keyCredentials` (`GET
   /applications/{applicationObjectId}/microsoft.graph.agentIdentityBlueprint?$select=keyCredentials`)
   — `{applicationObjectId}` is the Entra **application object ID** of the
   blueprint (for example `blueprint.id` as resolved by
   `scripts/Register-W365BlueprintCertificate.ps1`, via `GET
   /applications/microsoft.graph.agentIdentityBlueprint?$filter=appId eq
   '<BlueprintId>'`), not the blueprint's client/app ID you passed as
   `-BlueprintId` when registering.
   `displayName` alone is not a safe identifier: every credential this sample
   registers uses the same `w365-blueprint-certificate` display name, and
   `-Rotate` intentionally adds a new one alongside the prior entry rather than
   replacing it, so more than one entry can share that name. Instead, identify
   entries this sample added by their `customKeyIdentifier` (base64 of the
   certificate's SHA-1 hash — compare against
   `[Convert]::ToBase64String($cert.GetCertHash())` for each
   `w365-blueprint-certificate` certificate version you intend to retire, for
   example via `az keyvault certificate list-versions --vault-name <vault>
   --name w365-blueprint-certificate`) or `keyId` if you recorded it when
   registering. `PATCH` the blueprint with only the confirmed entry (or
   entries) removed from the `keyCredentials` array (a full read-modify-write,
   matching how `Register-W365BlueprintCertificate.ps1` added it). Do not
   remove `keyCredentials` belonging to any other integration, and do not
   remove an entry you cannot uniquely match to a retired certificate.
2. Verify no temporary "Key Vault Certificates Officer" assignment remains.
   Fresh orchestration holds its assignment through exact readiness
   verification and revokes it in an outer `finally`; standalone initialization
   also revokes an assignment it owns. If cleanup reported a failure or an
   older release left one behind, remove it with `az role
   assignment delete --assignee-object-id <operator-object-id> --role "Key
   Vault Certificates Officer" --scope <vault-resource-id>`. Skip this step if the
   operator already held the role before setup for another reason.
3. Deleting the Key Vault (via `azd down`) removes the certificate object and
   its backing key; no separate Key Vault cleanup is required for those.

Blueprint credential removal requires
`AgentIdentityBlueprint.AddRemoveCreds.All` and a full read-modify-write of the
blueprint `keyCredentials` array. If the retired entry cannot be matched
unambiguously, stop rather than removing another integration's credential.

## Next steps

- Return to [Deployment](DEPLOYMENT.md#phase-2-bind-and-enable) to publish or
  verify the enabled hosted-agent version.
- Use [Authentication](AUTHENTICATION.md) for credential delivery, token
  exchanges, and federation trust.
- Use [Viewer](VIEWER.md) only after core W365 execution works and viewer
  identity, OIDC, and screen-share inputs are approved.
