# Deploy to Microsoft Foundry and Azure

This guide covers deployment, verification, redeployment, rollback, and
teardown. The sample is a single-operator preview and creates billable Azure,
Foundry, and potentially Windows 365 resources.

For a dedicated environment, use `azd up`. It performs the required two-stage
sequence:

1. deploy a W365-disabled hosted-agent version so Foundry creates the blueprint
   and agent identity;
2. bind those exact identities to state and W365, then deploy an enabled
   immutable version.

Use the staged path only when reusing a shared Foundry project or when separate
preview and approval boundaries are required.

## Prerequisites

Run from Windows PowerShell 7.4 or later at the repository root.

- .NET 10 SDK and Git.
- Azure CLI and the Azure Developer CLI versions required by `azure.yaml`.
- The `microsoft.foundry` azd extension.
- An Azure subscription and tenant enabled for Microsoft Foundry.
- Model availability, regional support, and quota for the dedicated path. An
  existing-project deployment additionally requires a compatible model
  deployment that supports function calling and image input.
- For W365: completed tenant onboarding, approved billing, and either an
  existing agent pool or the inputs required to create one.
- For the viewer: Azure Container Apps capacity and the tenant-specific
  screen-share values described in [Viewer](VIEWER.md).
- Network policy allowing Entra token exchange, the Foundry project/model,
  private Blob state, and `agent365.svc.cloud.microsoft`. Viewer-enabled
  environments also need the configured OIDC, Key Vault, and screen-share
  endpoints.

The deploying identity needs the Azure and Foundry permissions required for the
selected project. Reusing a project requires **Foundry Project Manager** at the
project scope; subscription `Owner` alone does not grant Foundry data-plane
access. W365 and Graph permissions are listed in
[Windows 365 setup](W365-SETUP.md#setup-permissions-delegated-not-runtime).

Authenticate both CLIs to the same tenant and subscription, then run the
prerequisite check:

```powershell
az login --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
azd auth login
azd ext install microsoft.foundry
pwsh -NoProfile -File .\tests\PowerShell\Test-AzdPrerequisites.ps1 -RequireLogin
```

If the check reports that an older machine-wide `azd` shadows a supported
installation, run the printed `$env:Path` correction in the same PowerShell
window before continuing.

Do not run `azd init` or `azd ai agent init` inside this clone. The checked-in
`azure.yaml` is already the project manifest.

## Phase 1: deploy bootstrap

### Dedicated environment: recommended path

Create an isolated environment and run the complete deployment:

```powershell
azd env new "<resource-prefix>-dev" `
    --subscription "<subscription-id>" `
    --location eastus
azd up --environment "<resource-prefix>-dev"
```

Before provisioning, the `preup` hook prints the generated resource names,
model selection, capacity, and enabled components. Review that plan before
approving changes.

The interactive flow then:

1. provisions the Foundry account, project, model, and disabled bootstrap
   agent;
2. asks whether to reuse a W365 pool, create one, or keep a Foundry-only
   deployment;
3. asks whether to create a dedicated ACA managed environment, reuse an
   explicitly selected compatible environment, or skip the viewer;
4. discovers the bootstrap agent's exact Foundry-owned identity;
5. provisions private Blob state before viewer infrastructure;
6. completes approved W365/Entra setup and stores ownership evidence;
7. deploys the same agent name with W365 enabled; and
8. activates the viewer when all tenant-specific inputs are available.

The checked-in azd hooks complete W365 and viewer setup after the Foundry
bootstrap. Wait for the final sample deployment table and mode-specific next
commands; generic Foundry guidance can appear before `postup` finishes.

For unattended execution or stricter Windows process-tree cancellation,
same-environment locking, and final-state verification, use the optional
wrapper:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdUp.ps1 `
    -Environment "<resource-prefix>-dev" `
    -ConfirmResourceChanges `
    -NoPrompt
```

Before viewer bootstrap or activation can change runtime configuration, post-up
persists `W365_AGENT_REDEPLOY_CHECK_PENDING=true` with the previous viewer URL
and live state. Reconciliation clears that comparison marker when nothing
changed or promotes it to `W365_AGENT_REDEPLOY_PENDING=true` when hosted-agent
redeployment is required. The confirmed marker is cleared only after the
hosted agent is redeployed successfully. A failed or canceled run cannot report
completion while either marker remains. Correct the reported prerequisite and
rerun `azd up --environment "<resource-prefix>-dev"` for the same environment.

Expected result:

- `win365-desktop-agent` has an active immutable version;
- when W365 is selected, its identifiers and ownership evidence are stored
  under the selected `.azure\<environment>\` directory and private Blob state
  is configured;
- the viewer is either active, intentionally skipped, or healthy in bootstrap
  mode with its missing activation inputs listed.

The reviewed model defaults are `gpt-6-astra`, version `2026-09-03`,
`GlobalStandard`, and capacity `200` (200K TPM). Availability and quota vary by
subscription and region. To approve a smaller capacity before deployment:

```powershell
azd env set FOUNDRY_MODEL_SKU_CAPACITY "50" `
    --environment "<resource-prefix>-dev"
```

To deploy only the Foundry bootstrap:

```powershell
azd env set ENABLE_W365 false --environment "<resource-prefix>-dev"
azd up --environment "<resource-prefix>-dev"
```

Bootstrap is intentionally W365-disabled. `/health` is healthy, while Responses
requests return a phase-two-required 503. This is not proof of live W365
readiness.

If provisioning fails, do not assume that no resources were created. Inspect
the reported stage. Retry with the same environment after correcting a safe
prerequisite failure; for an abandoned sample-owned environment, use
[Operations and rollback](#operations-and-rollback).

### Existing Foundry project

Use this path only when the project owner has approved deployment into the
shared project and identified a compatible existing model deployment.

Use a fresh azd environment so stale W365, state, or viewer settings cannot be
published into the shared project. Bind all required project identifiers and
an isolated sample-owned resource group explicitly:

```powershell
$environment = "<resource-prefix>-dev"

azd env new $environment `
    --subscription "<subscription-id>" `
    --location eastus
azd env set AZURE_RESOURCE_GROUP `
    "<resource-prefix>-dev-rg" --environment $environment
azd env set FOUNDRY_PROJECT_ENDPOINT `
    "<existing-foundry-project-endpoint>" --environment $environment
azd env set FOUNDRY_PROJECT_OWNERSHIP "existing" --environment $environment
azd env set AZURE_AI_ACCOUNT_NAME `
    "<existing-foundry-account-name>" --environment $environment
azd env set AZURE_AI_PROJECT_NAME `
    "<existing-foundry-project-name>" --environment $environment
azd env set AZURE_AI_PROJECT_ID `
    "<existing-foundry-project-resource-id>" --environment $environment
azd env set AZD_FOUNDRY_RESOURCE_GROUP_ID `
    "<existing-foundry-resource-group-id>" --environment $environment
azd env set AZURE_FOUNDRY_RESOURCE_GROUP `
    "<existing-foundry-resource-group-name>" --environment $environment
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME `
    "<existing-model-deployment-name>" --environment $environment
azd env set ENABLE_W365 false --environment $environment
azd env set W365_ENABLED false --environment $environment
azd env set DEPLOY_STATE false --environment $environment
azd env set DEPLOY_VIEWER false --environment $environment
azd env set VIEWER_LIVE_ENABLED false --environment $environment
```

Preview and provision the sample-owned environment boundary. In
existing-project mode this layer creates the isolated resource group and
records the supplied project; it does not create or replace the shared Foundry
account, project, or model:

```powershell
azd provision foundry --environment $environment --preview --no-prompt
azd provision foundry --environment $environment --no-prompt
```

Validate before publishing:

```powershell
azd ai agent doctor --local-only
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode Validate
```

Validation checks the local manifest and the remote project, model, roles,
connections, and hosted-agent capability. It is read-only. Resolve every
failure before deployment.

Publish the disabled bootstrap only after review:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

The explicit ownership value prevents a managed endpoint from silently
switching into existing-project mode. Stop if the environment name already
exists or the preview targets resources outside the approved shared project
and sample-owned resource group. Do not grant broad subscription roles to work
around project data-plane failures.

### Staged dedicated deployment

Use this path when separate preview, provision, and publish approvals are
required:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
    -SubscriptionId "<subscription-id>" `
    -Prefix "<resource-prefix>" `
    -Environment "dev"

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode Validate

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode ProvisionFoundry `
    -ConfirmResourceChanges

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

The initializer creates local azd state and previews the Foundry layer. It does
not enable W365, state, or the viewer. The first hosted-agent version must exist
before phase two can grant its exact principal access.

## Discover the Foundry identity

Identity discovery is read-only and version-specific. Never silently select a
latest version.

```powershell
pwsh -NoProfile -File .\scripts\Get-FoundryIdentity.ps1 `
    -ProjectEndpoint "https://<account>.services.ai.azure.com/api/projects/<project>" `
    -AgentName "win365-desktop-agent" `
    -AgentVersion "<deployed-version>" `
    -TenantId "<tenant-guid>"
```

| Output | Use |
| --- | --- |
| `BlueprintId` | Blueprint app/client ID; passed as `-BlueprintId`. |
| `AgentIdentityId` | Agent object/principal ID; passed as `-AgentIdentityId` and used for Azure RBAC. |
| `TenantId` | Tenant shared by Foundry, W365, and the viewer Azure identity. |

App/client IDs and object/principal IDs are different identifier types even
when a service currently returns the same GUID for both. If discovery cannot
return the documented fields, stop instead of creating replacement identities.

## Optional phase-1 viewer bootstrap

The viewer is a separate ACA application that references `Win365Shared`; it
does not host the model or Responses endpoint. Direct W365 execution does not
require it.

For the dedicated `azd up` path, viewer bootstrap is automatic after private
state has been created and validated. Until `VIEWER_LIVE_ENABLED=true`,
`/health` is available, other viewer routes return 503, and the hosted agent
does not advertise viewer links.

The viewer can:

- create a dedicated ACA managed environment;
- reuse an explicitly selected compatible managed environment; or
- remain disabled with `DEPLOY_VIEWER=false`.

It never silently adopts shared ACA infrastructure. If a new managed
environment fails specifically because of quota or capacity, the interactive
flow can offer existing environments for explicit selection. Other viewer,
RBAC, image, networking, or health failures remain fatal.

For OIDC, Key Vault, screen-share values, viewer federation, and activation,
follow [Viewer](VIEWER.md). Do not substitute `SCREENSHARE_APP_URL` for the
companion viewer's `VIEWER_PUBLIC_URL`.

For a staged deployment, record these non-secret bootstrap outputs:

| Output | Use |
| --- | --- |
| `viewerIdentityClientId` | Selects the viewer UAMI through `AZURE_CLIENT_ID`. |
| `viewerIdentityPrincipalId` | Viewer object/principal ID used for RBAC and optional federation. |
| `viewerHostname` | Default ACA hostname used to configure the public viewer origin and OIDC callback. |

## Phase 2: bind and enable

The direct dedicated `azd up` path performs this phase automatically. Use the
steps below only for a staged or existing-project deployment.

Before W365 or Entra mutation:

1. discover the exact phase-one identity;
2. provision private Blob state and container-scoped RBAC;
3. configure the hosted operator;
4. explicitly select and prepare one blueprint credential mode;
5. confirm W365 billing and pool inputs; and
6. review inherited blueprint grants, especially for shared projects.

Credential modes and their current validation status are documented in
[Authentication](AUTHENTICATION.md). The checked-in default is
`client_secret`, stored in Key Vault. There is no automatic fallback between
credential modes.

### Provision shared state

```powershell
$environment = "<azd-environment-name>"

azd env set DEPLOY_STATE true --environment $environment
azd env set STATE_AGENT_PRINCIPAL_ID `
    "<Foundry-agent-object-principal-guid>" `
    --environment $environment

azd provision state --environment $environment --preview --no-prompt
azd provision state --environment $environment --no-prompt
```

The state layer creates the shared W365 Key Vault and private
`desktop-state` Blob container, grants the exact agent principal
`Storage Blob Data Contributor` on that container, and emits
`SESSION_BLOB_URI`. Live runtime does not support local file state.

### Configure the operator and default credential mode

```powershell
azd env set OPERATOR_TENANT_ID `
    "<operator-tenant-guid>" --environment $environment
azd env set OPERATOR_OBJECT_ID `
    "<operator-object-guid>" --environment $environment
azd env set HOSTED_ALLOWED_USER_ID pending --environment $environment
azd env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret `
    --environment $environment

pwsh -NoProfile -File .\scripts\Set-ViewerSecrets.ps1 `
    -Environment $environment `
    -BlueprintOnly `
    -BootstrapOperatorAccess
```

`HOSTED_ALLOWED_USER_ID=pending` denies W365 access until the intended Foundry
caller partition is bound. The blueprint credential is collected through a
secure prompt and stored in Key Vault; it is not persisted in source, JSON,
logs, command history, or azd environment state.

For `managed_identity_federation` or `key_vault_certificate`, follow
[Authentication](AUTHENTICATION.md) and the exact setup sequence in
[Windows 365 setup](W365-SETUP.md#staged-azd-flow).

### Run W365 setup and deploy the enabled version

```powershell
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
    -Environment $environment `
    -TenantId "<Foundry-and-W365-tenant-guid>" `
    -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
    -BillingConfirmed `
    -ConfirmResourceChanges `
    -UseDeviceCode
```

The wrapper verifies state, RBAC, operator binding, credential readiness, and
the exact Foundry identity before mutation. It then reconciles W365/Entra,
persists the ownership manifest and non-secret IDs, and redeploys the same agent
name. Do not immediately deploy it a second time.

For a new pool, omit `-PoolIdOrUrl` only after saving a reviewed pool profile as
described in [Windows 365 setup](W365-SETUP.md).

Expected result:

- `W365_ENABLED=true`;
- `W365_TENANT_ID`, `W365_BLUEPRINT_ID`, `W365_AGENT_ID`,
  `W365_AGENT_OBJECT_ID`, `W365_AGENT_USER_ID`, and `W365_POOL_ID` are present;
- `.azure\<environment>\w365-ownership.json` exists;
- an enabled immutable agent version is active.

If W365 setup succeeds but final agent deployment fails, fix the reported
deployment prerequisite, then rerun the complete workflow for the same
environment:

```powershell
azd up --environment $environment
```

The retained ownership and redeployment markers make this retry idempotent. Do
not clear them manually or invoke the agent deployment stage directly. If
recovery cannot complete, use the ownership-aware teardown:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDown.ps1 `
    -EnvironmentName $environment `
    -Purge `
    -Force
```

## Bind the hosted operator

`x-agent-user-id` is a Foundry-injected opaque caller partition. It is not the
human operator's Entra object ID and not the W365 agent-user ID.

When the partition is unknown:

1. deploy with `HOSTED_ALLOWED_USER_ID=pending`;
2. have only the intended operator issue one identifiable invocation;
3. correlate the denied request's `sha256:` fingerprint;
4. bind that fingerprint and redeploy.

```powershell
azd env set HOSTED_ALLOWED_USER_ID "sha256:<fingerprint>" `
    --environment $environment

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

Never enroll an uncorrelated caller. If the platform header is missing, stop
and confirm hosted-ingress support rather than disabling the gate.

## Verify the deployment

Verify the exact active version:

```powershell
$environment = "<azd-environment-name>"

azd ai agent doctor --environment $environment
azd ai agent show win365-desktop-agent `
    --environment $environment `
    --output json
```

Confirm:

- deployment status is `active`;
- the version matches `AGENT_WIN365_DESKTOP_AGENT_VERSION`;
- the project and blueprint IDs match the accepted phase-one identities;
- the Responses endpoint is HTTPS under the intended Foundry project.

Start the first task after redeployment with a fresh hosted session pinned to
that immutable version. Use the invoice command in
[README](../README.md#verify-live-behavior). A build, health check, or successful
`doctor` command does not prove live W365 acceptance. If invocation has an
unknown outcome, do not retry automatically; use
[fail-closed recovery](ARCHITECTURE.md#fail-closed-recovery).

## Operations and rollback

### Redeploy

Use the guarded wrapper for hosted-agent publication:

```powershell
$environment = "<azd-environment-name>"

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

Do not replace it with raw `azd deploy win365-desktop-agent`. The wrapper
checks credential readiness and Key Vault RBAC, packages the complete local
solution context, runs Foundry doctor, and can perform a smoke invocation.

For a complete dedicated-environment update, rerun:

```powershell
$environment = "<azd-environment-name>"

azd up --environment $environment
```

If deployment fails or is canceled, treat the deployment as partial. Inspect
the reported stage and retained ownership evidence before retrying the same
environment. If the environment will be abandoned, remove it through the
ownership-aware teardown:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDown.ps1 `
    -EnvironmentName $environment `
    -Purge `
    -Force
```

Do not replace this command with raw resource-group deletion; the wrapper
cleans tenant-owned W365 and Entra resources before Azure infrastructure.

Stop or drain active tasks before deployment or identity changes. Preserve the
same Foundry agent name and reject unexpected blueprint or agent identity
replacement.

### Logging

Set sanitized operational verbosity in the selected environment:

```powershell
$environment = "<azd-environment-name>"

azd env set SAMPLE_LOG_LEVEL verbose --environment $environment

azd up --environment $environment
```

Supported values are `summary`, `verbose`, and `debug`. PowerShell scripts also
support `-Verbose` and `-Debug`. Secret, token, password, assertion,
certificate, and private session values remain redacted.

### Rollback

Rollback means republishing a previously accepted code/configuration state as a
new immutable version under the same agent name. Stop or drain active tasks,
ensure the worktree is clean, and record the current version before selecting
the known-good commit:

```powershell
$environment = "<azd-environment-name>"
$currentVersion = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment $environment

git status --short
git switch --detach "<known-good-commit>"

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode DeployAgent `
    -ConfirmResourceChanges

$rollbackVersion = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment $environment
azd ai agent doctor --environment $environment
azd ai agent show win365-desktop-agent `
    --environment $environment `
    --output json
```

Confirm that `$rollbackVersion` is new, the active project and blueprint IDs
still match the accepted binding, and a fresh hosted session is pinned to that
version before allowing tasks. Return to the working branch with `git switch -`
after collecting evidence. If publication or verification fails, leave tasks
drained, preserve the last known active version, and resolve the reported
deployment stage before another attempt.

Do not clear private state merely to make a deployment appear healthy. Resolve
the remote session and use the guarded recovery workflow. Switching to
bootstrap does not end an already allocated W365 session.

### Teardown

End known active sessions, review the ownership manifests, then run:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDown.ps1 `
    -EnvironmentName "<azd-environment-name>" `
    -Purge `
    -Force
```

The wrapper:

1. runs W365/Entra ownership cleanup once;
2. removes `viewer`, `state`, and `foundry` in reverse dependency order;
3. treats only an exact missing ARM deployment as already absent;
4. propagates every other azd failure; and
5. fails if a resource group tagged for the environment remains.

Cleanup is ownership-driven, not name-driven. If W365 state exists without its
ownership manifest, teardown stops before mutation. Reused grants and
inheritance are preserved or restored to their prior scope.

Do not tear down an environment bound to a shared or pre-existing Foundry
project until the owner has reviewed every target. The explicit
`ALLOW_EXISTING_FOUNDRY_CLEANUP=true` override is only for a dedicated
disposable project whose entire boundary is approved for removal.

Azure resource deletion does not cancel W365 billing. Confirm pool retirement
in the owning service. Certificate-mode blueprint credentials and any operator
certificate-management role created outside the ownership manifest require the
additional cleanup documented in
[Windows 365 setup](W365-SETUP.md#key_vault_certificate-mode-cleanup).

## Live acceptance

Offline tests cannot prove tenant, preview SDK, model, or W365 compatibility.
Before real workloads, complete these authorized live checks in an isolated
environment:

1. verify the active immutable agent version and unchanged Foundry identities;
2. verify the selected credential mode completes T1, T2, and agent-user T3
   without fallback;
3. run one benign desktop task through readiness, a catalog refresh, an
   allowlisted action, and `EndSession`;
4. verify the operator partition denies another caller;
5. test viewer OIDC, See-only observation, pause, take control, and explicit
   resume only when the viewer is enabled;
6. test cancellation and fail-closed stale-state recovery; and
7. prove ownership-driven teardown and W365 capacity cleanup.

The isolated Windows driver automates deployment, identity and ownership
validation, a stable rerun, and teardown attempts. It does not automate the
desktop task, caller-denial, viewer handoff, cancellation, or stale-state
recovery checks above; perform those manually and record their sanitized
evidence.

The driver requires explicit billing approval:

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

The driver previews changes, requires the exact approval phrase shown by the
script, deploys an isolated environment, verifies ownership and a stable rerun,
and attempts teardown in `finally`. Use `-Resume` only after reviewing a
retained failed environment.

## Troubleshooting

| Symptom | Safe action |
| --- | --- |
| Prerequisite check finds an older `azd` first | Apply the printed `$env:Path` correction in the current PowerShell process and rerun the check. |
| Foundry returns 403 | Verify project-scoped Foundry data-plane roles and wait for RBAC propagation; do not grant broad roles blindly. |
| Model validation or deployment fails | Confirm the exact deployment name, supported capabilities, SKU, quota, version, and region. No agent version is published until validation succeeds. |
| Viewer managed-environment quota is exhausted | Explicitly select an approved existing ACA environment or request quota. The deployment never selects one automatically. |
| Viewer remains in bootstrap mode | Obtain the approved screen-share values, complete OIDC/Key Vault setup in [Viewer](VIEWER.md), and rerun `azd up --environment "<azd-environment-name>"`. |
| Hosted-agent redeployment remains pending | Configure the operator values in [Configure the operator and default credential mode](#configure-the-operator-and-default-credential-mode) and [Bind the hosted operator](#bind-the-hosted-operator), then rerun `azd up` for the same environment. Do not clear `W365_AGENT_REDEPLOY_PENDING` manually. |
| W365 setup is blocked | Follow the exact prerequisite or ownership error in [Windows 365 setup](W365-SETUP.md); do not bypass parent, consent, billing, or manifest checks. |
| Agent deployment fails after W365 setup or viewer configuration changes | Fix the reported prerequisite, then rerun `azd up` for the same environment so the durable redeployment marker is reconciled. |
| Invocation is disconnected or ambiguous | Do not replay. Inspect sanitized logs and follow [fail-closed recovery](ARCHITECTURE.md#fail-closed-recovery). |
| Teardown reports a missing layer deployment | Use `Invoke-AzdDown.ps1`; it continues to remaining layers and verifies residual resource groups. |
| Teardown reports any other error | Stop and resolve the exact authentication, authorization, ownership, provider, or residual-resource failure. |

## Next steps

- Use [Windows 365 setup](W365-SETUP.md) for Graph permissions, agent users,
  pools, billing, ownership manifests, and tenant cleanup.
- Use [Authentication](AUTHENTICATION.md) for credential modes, token
  exchanges, Key Vault delivery, and blueprint trust.
- Use [Viewer](VIEWER.md) for ACA topology, OIDC, screen sharing, live
  activation, and human handoff.
- Use [Architecture](ARCHITECTURE.md) for request flow, state ownership,
  lifecycle guarantees, and recovery.
