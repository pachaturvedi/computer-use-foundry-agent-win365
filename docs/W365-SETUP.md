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
- completes delegated Graph sign-in;
- securely collects the blueprint credential when the selected mode requires
  one;
- creates or reuses the correctly parented agent user and approved pool;
- records ownership and non-secret IDs; and
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

#### Default `client_secret` mode

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

This agent-only mode uses a self-signed, non-exportable Key Vault certificate:

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

azd provision state --environment $environment --no-prompt

pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

Reprovisioning state is required when switching from another mode so the agent
receives certificate/key-scoped RBAC. Registration adds only the public
certificate and preserves existing blueprint credentials. Re-running without
`-Rotate` reuses the certificate; after rotation, register the new public
certificate before deployment.

The wrapper validates the exact certificate registration before any W365
mutation. Certificate mode is implemented and offline-validated but still
requires live tenant acceptance.

`PoolIdOrUrl` accepts a raw pool GUID or an Intune URL containing
`poolId/<guid>`. `-BillingConfirmed` acknowledges an already approved billing
plan; it does not activate billing.

Use `-UseDeviceCode` in terminals where WAM cannot obtain a parent window. The
scripts display the Microsoft device-login URL and retry a timed-out prompt
once by default.

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

This section applies only to
`W365_BLUEPRINT_CREDENTIAL_MODE=managed_identity_federation`. The default
client-secret viewer path does not require a viewer FIC.

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

Certificate registration and an operator role granted by
`Initialize-W365BlueprintCertificate.ps1` are outside the W365 ownership
manifest. When retiring certificate mode:

1. Remove only the blueprint `keyCredential` entries that match the retired
   certificate versions. Match by recorded `keyId` or
   `customKeyIdentifier`—the base64 SHA-1 certificate hash—not by display name.
2. Preserve every unrelated blueprint credential. Rotation can leave multiple
   credentials with the same `w365-blueprint-certificate` display name.
3. If setup granted the operator **Key Vault Certificates Officer**, remove
   that exact assignment after certificate administration is complete. Preserve
   a role that predated this sample.
4. Delete the Key Vault through the normal environment teardown; that removes
   the certificate object and backing key.

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
