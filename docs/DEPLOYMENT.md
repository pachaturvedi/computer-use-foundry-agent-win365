# Deploy to Foundry and Azure Container Apps

Deployment is explicit and billable. No script runs it automatically. Use a
dedicated resource group and, where possible, a dedicated Foundry blueprint.
Review resource, role and blueprint trust changes before execution. This is
a single-operator preview sample, not a production multi-user service.

Deployment has two phases: **bootstrap to obtain Foundry-owned identities**,
then **bind W365 to those exact identities and enable the runtime**.

| Stage | Operation | Current status |
| --- | --- | --- |
| Phase 1 | Deploy `win365-desktop-agent` with `W365_ENABLED=false` | Completed; active version `1` |
| Binding | Discover version `1`, run W365 setup, create/reuse the agent user, and create or update the W365 agent pool | Scripted; live pool creation still requires tenant-specific billing and image inputs |
| Phase 2 | Apply returned IDs and state/operator values, keep `W365_ENABLED=true`, and redeploy the same service | Scripted through the W365 flow wrapper or by rerunning `DeployAgent` |

Ordinary Responses hosting still must be validated for blueprint-selected
managed identity after phase 2; the public reference helper is from an
activity/autopilot sample, not evidence that this host supports it. No autopilot
publication or hiring workflow is required here. See
[authentication](AUTHENTICATION.md#sdk-and-hosting-boundary).

## Phase 1: deploy bootstrap

Choose one Foundry path for phase 1:

- reuse an existing Foundry project that already has hosted-agent support and a
   deployed model that supports function calling and image input
- create a dedicated Foundry account, project, and model deployment in a fresh
   azd environment

`gpt-6-astra` is the suggested model; use its actual deployment name if
available in your subscription/region. The template does not invent a model
version or SKU.

When reusing an existing project, the user must provide **both** the project
and a deployed model available to that project. An empty project is not
deployable with this sample because `AZURE_AI_MODEL_DEPLOYMENT_NAME` is
mandatory. The model may be deployed on the project's parent Foundry account or
exposed through a project connection, but its deployment name must be known and
it must support function calling and image input. The developer running azd
needs **Foundry Project Manager** at the project scope; generic subscription
`Owner` alone does not grant Foundry data-plane access.

For users without either resource, the checked-in project service declares a
default GA `gpt-6-astra` deployment using GlobalStandard capacity 50. In a new,
dedicated environment, azd can create the Foundry account, project, model
deployment, and the minimum Foundry RBAC required for the deploying developer
and project managed identity. Defaults are committed in
`config\deployment.defaults.json`. Existing-project users can override the
deployment name, model version, SKU, location, viewer image, or project
endpoint through `config\deployment.local.json` or environment variables and
must not run provisioning against an unreviewed shared project.

Install .NET 10, PowerShell 7.4+, Azure CLI and Azure Developer CLI. From the
repository root, verify the exact versions required by `azure.yaml`:

```powershell
az login
az account set --subscription "<subscription-id>"
azd ext install microsoft.foundry
azd auth login
.\tests\PowerShell\Test-AzdPrerequisites.ps1 -RequireLogin
```

Use the same intended identity for Azure CLI and azd. Confirm the subscription,
Foundry project region, project endpoint, and exact model deployment name with
the resource owner before continuing. A tenant-level Azure CLI login with a
subscription named `N/A(tenant level account)` is not sufficient for policy,
quota, or resource validation.

If the check warns that an older machine-wide `azd` shadows a newer user
installation, run the one-line `$env:Path` command printed by the check in the
same PowerShell window before continuing with direct `azd` commands.

Choose exactly one project setup path.

**Existing clone (recommended):** the checked-in `azure.yaml` is already the
project manifest. Create only local azd environment state from the repository
root:

```powershell
$env:Path = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:Path"
azd env list
azd env new computer-use-foundry-agent-win365-dev
```

If the environment is already listed, replace `azd env new` with:

```powershell
azd env select computer-use-foundry-agent-win365-dev
```

Do **not** run `azd init` or `azd ai agent init -m .\azure.yaml` in a clone.
Those commands treat the repository as template input and try to copy it into
itself, causing the overlapping-source or existing-`azure.yaml` errors.

**No-clone template initialization:** from a genuinely empty directory, point the
Foundry-specific initializer at this repository's raw `azure.yaml` URL:

```powershell
azd auth login
azd ai agent init -m "https://raw.githubusercontent.com/pachaturvedi/computer-use-foundry-agent-win365/main/azure.yaml"
.\tests\PowerShell\Test-AzdPrerequisites.ps1 -RequireLogin
```

The no-clone command creates a new project directory. Change into that generated
directory before running subsequent commands. Do not run it from the repository
clone or target the existing clone directory.

When the user has no existing Foundry resources, choose **create a new project**
and use a dedicated environment. The minimum successful path is staged so each
boundary is validated before the first live agent publish:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
   -SubscriptionId "<subscription-id>" `
   -Prefix "fawin365" `
   -Environment "dev"

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
   -Mode Validate `
   -Environment "fawin365-dev"

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
   -Mode ProvisionFoundry `
   -Environment "fawin365-dev" `
   -ConfirmResourceChanges

azd ai agent doctor --environment fawin365-dev

pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
   -Mode DeployAgent `
   -Environment "fawin365-dev" `
   -ConfirmResourceChanges

azd ai agent doctor --environment fawin365-dev
```

`Initialize-Greenfield.ps1` creates only local azd environment state and a
Foundry preview. `ProvisionFoundry` then creates the resource group, Foundry
account, project, model deployment, and the minimum Foundry roles needed for
the next step: `Foundry Project Manager` plus `Foundry User` on the new account
for the deploying principal, and `Foundry User` for the project managed
identity. `DeployAgent` publishes the first immutable hosted-agent version only
after the project endpoint and role checks are green.

To opt into the stitched W365 path, supply the agent-user UPN while initializing
the environment, confirm the W365 pool profile in the ignored
`config\deployment.local.json`, and then run one `azd up`:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
   -SubscriptionId "<subscription-id>" `
   -Prefix "fawin365" `
   -Environment "dev" `
   -EnableW365

azd up
```

The normal deployment publishes the bootstrap version with
`W365_ENABLED=false`. The Windows `postup` hook then requests explicit W365
resource approval, uses device-code Graph authentication, creates or validates
the environment-owned pool and agent user, persists the ownership manifest,
and deploys the same agent name again with `W365_ENABLED=true`. A failed W365
step leaves the bootstrap agent disabled and prints the manifest path needed
for recovery or teardown. The agent-user UPN is derived from the tenant's
verified default user-creation domain; it does not assume an
`onmicrosoft.com` suffix. `-AgentUserPrincipalName` and `-AgentUserDomain`
remain optional overrides.

Keep `W365_ENABLED=false`, `DEPLOY_STATE=false`, and `DEPLOY_VIEWER=false` for
this bootstrap pass unless the later phases are explicitly approved. Existing-
project mode still expects preexisting Foundry access and does not grant roles
on a shared project for you.

Only when reusing an existing Foundry project in an existing clone, bind the
existing Foundry project endpoint, set the model deployment name, and keep the
safe feature gate disabled. These values are not part of the initial fresh
environment setup:

```powershell
azd env set FOUNDRY_PROJECT_ENDPOINT "<existing-foundry-project-endpoint>"
azd env set FOUNDRY_PROJECT_OWNERSHIP "existing"
azd env set AZURE_AI_ACCOUNT_NAME "<existing-foundry-account-name>"
azd env set AZURE_AI_PROJECT_NAME "<existing-foundry-project-name>"
azd env set AZURE_AI_PROJECT_ID "<existing-foundry-project-resource-id>"
azd env set AZD_FOUNDRY_RESOURCE_GROUP_ID "<existing-foundry-resource-group-id>"
azd env set AZURE_FOUNDRY_RESOURCE_GROUP "<existing-foundry-resource-group-name>"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "<existing-model-deployment-name>"
azd ai agent doctor --local-only
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Mode Validate
```

The explicit ownership value prevents a project endpoint emitted by a managed
deployment from silently switching later Bicep runs into existing-project mode.
Existing-project mode fails closed unless the endpoint, project resource ID, and
Foundry resource-group ID and name are all supplied.

For a validation-only review, stop here. Both the local-only doctor command and
`Invoke-AzdDeployment.ps1 -Mode Validate` are read-only. The first checks the
local manifest/environment, and the second also checks the remote project,
role, hosted-agent capability, and configured connections.

Only after the validation output and deployment plan are reviewed:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

The manifest requires the extension's `azure.ai.agents` capability. Preview
extension names/commands can change; check installed extension help if needed.
The checked-in manifest follows the current official Foundry hosted-agent shape:
one `azure.ai.project` service, one `azure.ai.agent` service, pinned minimum
tool versions, code runtime/entry point, protocol, environment mapping, resource
limits, and scenario tags.

Generic templates often use `azd up`, but this sample deliberately uses
`azd deploy win365-desktop-agent`: the project and model must already exist, and
phase 1 must not provision an unconfirmed model SKU or W365 capacity. Do not run
`azd provision` or `azd up` unless you have intentionally added and reviewed
complete infrastructure declarations for your own fork, or you are following
the dedicated greenfield path above.

`W365_ENABLED` defaults to `false` and accepts only `true` or `false`. In phase 1,
all phase-2 environment values in the manifest may remain empty: **no W365 IDs,
operator, state or viewer configuration is mandatory yet**. Foundry provisions
its blueprint and agent identity. Bootstrap starts before any model initialization
and does not access
W365, model or state credentials. Healthy readiness and a **503 explaining phase
2 for Responses requests** are expected, not proof of live W365 readiness.

Hosted agent bootstrap binds `0.0.0.0` on `PORT` (default `8088`), following the
[hosted-agent contract](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-contract).
Viewer bootstrap respects ACA's configured port `8080`. Local mode stays fixed
to loopback: agent `8088`, viewer `5050`.

The manifest uses azd expansion `${W365_ENABLED:-false}` and `${VAR:-}` for
empty phase-2 fallbacks. These defaults are intentional; do not replace them
with required phase-2 values just to complete bootstrap.

Foundry injects the project endpoint and hosting identity configuration. Never
set reserved platform variables, including `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID`,
yourself. Keep `SAMPLE_LOCAL_MODE=false` in Azure. Local mode is loopback-only
bootstrap/offline; enabling W365 on a local desktop is refused.

## Discover the Foundry identity

Record the actual deployed **agent name and version** from the deployment.
`-AgentVersion` is required; discovery does not silently choose a latest version.
The default manifest name is `win365-desktop-agent`; use the name actually
deployed if initialization changed it.

```powershell
az login --tenant "<Foundry-tenant-GUID>"
.\scripts\Get-FoundryIdentity.ps1 `
    -ProjectEndpoint "https://<account>.services.ai.azure.com/api/projects/<project>" `
    -AgentName "<deployed-agent-name>" `
    -TenantId "<Foundry-tenant-GUID>" `
    -AgentVersion "<deployed-version>"
```

This helper is **read-only**. It uses
`az rest --method get --resource https://ai.azure.com` to read the selected version with Foundry
`GET /agents/<name>/versions/<version>?api-version=2025-11-15-preview`, relative
to the project endpoint. Azure CLI handles the bearer internally; the helper
does not explicitly print or persist tokens, provision or mutate identities.
Do not enable CLI debug dumps or paste tokens into issues.

The helper accepts only public-cloud HTTPS project URLs on
`*.services.ai.azure.com`, with path `/api/projects/<project>`. Arbitrary hosts
and sovereign-cloud endpoints are not supported; do not bypass endpoint
validation to send credentials to another host.

| Discovery output | Response field / use |
| --- | --- |
| `BlueprintId` | `blueprint.client_id`: blueprint **app/client ID**, passed to setup as `-BlueprintId`. |
| `AgentIdentityId` | `instance_identity.principal_id`: agent **object/principal ID**, passed as `-AgentIdentityId`. |
| `TenantId` | Tenant used for discovery/setup; must match Foundry and W365. |

An object-ID field is not an app-ID field. Setup resolves the agent app/client
ID from the existing agent object and emits both `W365_AGENT_ID` and
`W365_AGENT_OBJECT_ID`. Foundry may currently return the same GUID value for
both fields, but callers must still use each value according to its documented
role rather than infer one from the other. If discovery does not return the required fields
or the actual host cannot provide a matching blueprint identity endpoint, stop
and investigate the preview hosting contract; do not create a substitute identity.

The stitched azd flow wraps this discovery automatically. After bootstrap
deployment, `Invoke-W365SetupFlow.ps1` reads the selected azd environment,
discovers the deployed blueprint and agent identity from the current hosted
agent version, runs `Setup-W365.ps1`, persists the returned `W365_*` values,
writes a non-secret ownership manifest used for teardown, and redeploys the
same agent name:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
   -Environment "<azd-environment-name>" `
   -AgentUserPrincipalName "foundry-w365-agent@YOUR-VERIFIED-DOMAIN.example" `
   -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
   -BillingConfirmed `
   -ConfirmResourceChanges `
   -UseDeviceCode
```

If `W365_POOL_ID` is already persisted in the azd environment, reruns update
that pool instead of creating another one. If no pool ID is present, the setup
script can create a pool when you supply the billing, geography, region, image,
and scaling inputs.

The setup script prints `W365_OWNERSHIP_MANIFEST=<path>` after it records the
created or reused pool, assignment, agent user, grants, inheritance entries,
federated credentials, and the blueprint's prior `requiredResourceAccess`.
`azd down` uses that manifest to prove what the sample is allowed to remove.

## Optional phase-1 viewer bootstrap

The viewer is a separate process built from the same project (`--viewer`).
It may stay disabled if blueprint federation is not approved. Deploy bootstrap
first when you need the viewer UAMI IDs for approval.

Create a dedicated prefix-driven resource group; do not reuse unrelated shared
or production resources. `infra/viewer-foundation.bicep` creates the required
ACA environment, ACR, Log Analytics workspace, Storage account/private
`desktop-state` container, and Key Vault. `infra/viewer.bicep` then creates the
viewer UAMI, resource-scoped roles, and Container App. Key Vault is **only for
the phase-2 OIDC secret**; bootstrap does not reference an OIDC secret or grant
its read role.

The foundation uses POC defaults: ACR Basic, Storage LRS, 30-day logs,
HTTPS/TLS 1.2+, disabled registry admin access, disabled Blob public/shared-key
access, Key Vault RBAC, soft delete, and purge protection. Review redundancy,
private networking, diagnostics, retention, and policy requirements before
production use.

For a new Foundry project and viewer, initialize the complete environment:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
    -SubscriptionId "<subscription-id>" `
    -Prefix "fawin365" `
    -Environment "dev" `
    -DeployViewer
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAll `
    -ConfirmResourceChanges
```

`-TenantId` is optional and should be supplied only to override the tenant
selected by `azd auth login`. Omit `-DeployViewer` unless the dedicated viewer
resources and Container Apps environment quota have been explicitly approved.
The initializer uses reusable config helpers in `scripts/DeploymentConfig.ps1`
so later hosted and cleanup workflows can consume the same defaults and
override precedence without duplicating parsing logic.

For an environment already bound to a Foundry project, set the viewer layer
explicitly. Resource names remain derived from the supplied prefix:

```powershell
$resourcePrefix = "fawin365-dev"
azd env set RESOURCE_PREFIX $resourcePrefix
azd env set DEPLOY_VIEWER true
azd env set VIEWER_RESOURCE_GROUP_NAME "$resourcePrefix-viewer-rg"
azd env set VIEWER_IMAGE_NAME "win365-sample:v1"
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAll `
    -ConfirmResourceChanges
```

If you are deploying the viewer, set `SCREENSHARE_APP_URL` in the azd
environment or an untracked parameter file to the endpoint supplied by W365
onboarding. The repository intentionally does not contain a concrete endpoint.

`azd up` provisions the conditional Bicep layer using the `SCREENSHARE_APP_URL`
you supplied,
deploys the Foundry agent, then runs the Windows `postup` hook. The hook builds
the repository image in the newly created ACR, waits for `AcrPull` role
propagation, switches the Container App to that image, and verifies `/health`.
Storage and ACR names remove hyphens, use lowercase alphanumerics, include a
deterministic suffix, and stay within service-specific length limits.

Before enabling `DEPLOY_VIEWER`, preview the viewer layer separately:

```powershell
azd provision viewer --preview --no-prompt
```

Layered projects do not support a combined `azd provision --preview`. If the
preview reports `MaxNumberOfGlobalEnvironmentsInSubExceeded`, stop and request
a Container Apps managed-environment quota increase. Do not silently reuse an
unrelated environment or switch hosting services.

The [parameter example](../infra/viewer.parameters.example.json) contains only
identifiers and URLs, never secret values. Its phase-2 placeholders are not
requirements for bootstrap. Keep your copy untracked. Prefer an immutable image
digest for releases. The template defaults `w365Enabled` to `false`, creates
the viewer UAMI with ACR pull and container-scoped Blob roles, and runs one
HTTPS-only replica. `/health` is healthy and other routes return 503; no OIDC
configuration is needed until active.

Phase-2 identity, operator, viewer and SDK parameters default to empty strings
in Bicep. The foundation creates `keyVaultName` for future OIDC use; no OIDC
secret value or reference is needed in bootstrap.

Record `viewerHostname`, `viewerIdentityClientId` and
`viewerIdentityPrincipalId` from the deployment outputs. The **principal/object
ID** is the optional setup FIC subject; the **client ID** selects the UAMI as
`AZURE_CLIENT_ID` in the viewer. Do not exchange these identifiers.

## Phase 2: bind and enable

Complete [W365 setup](W365-SETUP.md) with the discovered tenant, blueprint
client ID and agent object ID. Confirm Intune pool, licensing and billing
prerequisites; setup does not purchase capacity. Review the effects of inherited
blueprint grants on sibling agents. For an optional viewer FIC, obtain explicit
administrator approval for **blueprint impersonation**, not merely ARI access.
Do not enable or configure an unapproved viewer.

Prepare private shared Blob state before enabling; live runtime requires Blob.
`FileSessionStore` is an offline-test helper, not a local live backend.
Grant the correct deployed
Foundry identity model/project invocation under current Foundry RBAC guidance
and Storage Blob Data Contributor on the state container. Ordinary Azure
model/state credentials remain separate from the W365 flow. **The agent does
not need Key Vault certificate access.** Viewer Bicep grants roles only to its
own UAMI, not to the Foundry principal. Verify the actual Azure principal used
for model/state access rather than substituting an app/client ID in RBAC.
Role assignments need appropriately scoped authorization (for example Role
Based Access Control Administrator); do not blindly grant Owner.

For the existing-project two-phase workflow, enable the dedicated azd state
layer after phase-1 identity discovery:

```powershell
azd env set DEPLOY_STATE true
azd env set STATE_RESOURCE_GROUP_NAME "fawin365-dev-state-rg"
azd env set STATE_AGENT_PRINCIPAL_ID "<Foundry-agent-object-principal-GUID>"
azd provision state --preview --no-prompt
azd provision state --no-prompt
```

The state layer derives a globally unique Storage account name, creates the
private `desktop-state` container, grants the supplied agent principal Storage
Blob Data Contributor only on that container, and emits `SESSION_BLOB_URI`.
Greenfield phase 1 defaults `DEPLOY_STATE=false` because the agent principal is
not available until the first hosted-agent deployment.

The validated development deployment created:

| Item | Value |
| --- | --- |
| Resource group | `fawin365-dev-state-rg` |
| Storage account | `fawin365devstsq53oc` |
| Container | `desktop-state` |
| Session Blob URI | `https://fawin365devstsq53oc.blob.core.windows.net/desktop-state/slot.json` |
| Data principal | `5ff7789e-bb85-4e15-9667-bf83c94465e1` |

The application creates `slot.json` atomically on first enabled use; the
infrastructure deployment intentionally does not seed the Blob.

Set non-secret values using `azd env set KEY VALUE`:

| Setting | Source |
| --- | --- |
| `W365_TENANT_ID`, `W365_BLUEPRINT_ID` | Setup output; Foundry/W365/viewer Azure tenant and blueprint app ID. |
| `W365_AGENT_ID`, `W365_AGENT_OBJECT_ID`, `W365_AGENT_USER_ID` | Setup output; agent app ID, agent object ID, agent-user object ID. |
| `SESSION_BLOB_URI` | `https://<storage>.blob.core.windows.net/desktop-state/slot.json` |
| `OPERATOR_TENANT_ID`, `OPERATOR_OBJECT_ID` | Exact human operator's tenant/object IDs. |
| `HOSTED_ALLOWED_USER_ID` | **Foundry agent only:** platform user partition or `sha256:` fingerprint; see binding below. Not a viewer parameter. |
| `VIEWER_PUBLIC_URL` | Optional for an agent-only deployment. When omitted, desktop execution remains available but live-view/take-control links are returned as unavailable. Required for the viewer itself. |
| `SCREENSHARE_APP_URL` | **Viewer only:** W365-hosted view-only application origin supplied by W365 onboarding. It is required only when `VIEWER_LIVE_ENABLED=true`. |
| `VIEWER_LIVE_ENABLED` | Explicit viewer phase switch. Leave `false` for bootstrap; set `true` only after OIDC, state, W365, SDK/frame-origin values, and the Key Vault secret are ready. |
| `W365_ENABLED` | Internal phase switch. Bootstrap sets it to `false`; `Setup-W365.ps1` persists `true` only after phase-2 prerequisites are ready. |

Enabled configuration requires valid identity IDs and same-tenant Foundry/W365/
viewer Azure identities. The human OIDC tenant can differ. The runtime requires
the **platform-injected** `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID` to match
`W365_BLUEPRINT_ID`; never manufacture the platform variable to bypass this check.

`W365_AGENT_OBJECT_ID` is required for **both** the enabled agent and enabled
viewer, separately from `W365_AGENT_ID` (app/client ID). Set viewer `agentObjectId`
from the corresponding setup output, not the agent's app ID. The viewer has no
`hostedAllowedUserId` Bicep parameter; its authorization uses the human OIDC claims.

For an approved viewer, finish [OIDC/SDK configuration](VIEWER.md#enable-the-hosted-viewer).
Store its OIDC web-app secret as `w365-viewer-client-secret` in Key Vault. Never
put the value in `.azure`, parameter files, `azure.yaml` or the image. Fill the
phase-2 viewer parameters, set `VIEWER_LIVE_ENABLED=true`, review the deployment
what-if, and redeploy using the same viewer name/UAMI. Only then does the template reference
the OIDC secret and grant Key Vault access. No blueprint certificate parameter
or W365 Key Vault credential setting is used.

Agent and enabled viewer must use **exactly the same W365 identities and state
Blob**. Their compute identities remain different. Viewer `AZURE_CLIENT_ID`
selects its UAMI; never overwrite Foundry's credential selection.

```powershell
# All phase-2 values above must already be set.
azd ai agent doctor
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

Use the **same Foundry agent name**, deploying a new version rather than a new
agent. `W365_AGENT_USER_ID` selects the correctly parented W365 agent user; it
is not a secret and does not replace the Foundry runtime identity. Rerun
discovery for the new version and compare all IDs with phase 1.
Reject unexpected identity replacement before permitting tasks; do not silently
rebind users, consent or FICs to replacements. A rollback must also preserve
the accepted identity binding.

Network policies must allow Entra exchange, Blob, the Foundry project/model
and `agent365.svc.cloud.microsoft`; an enabled viewer additionally needs its OIDC
authority and Key Vault. The browser needs onboarding screen-share/WebRTC
endpoints. On RBAC propagation delays, wait/restart the affected revision;
do not substitute storage keys or embedded tokens.

## Bind the hosted operator

`x-agent-user-id` is a **platform-injected opaque partition**, not necessarily the
operator's Entra object ID. `OPERATOR_OBJECT_ID` independently controls OIDC.
Do not copy one into the other without confirming the platform contract.

Binding is a phase-2 operation, not a bootstrap prerequisite. If the partition
is unknown, use `HOSTED_ALLOWED_USER_ID=pending` for the enabled deployment and
have only the intended operator issue one identifiable invocation. It is denied
before W365 access. The warning includes a `sha256:` partition fingerprint and
correlation ID in both the structured 403 response and server log, not the raw
user identity or tokens. Have the administrator
correlate the invocation and set
`azd env set HOSTED_ALLOWED_USER_ID "sha256:<fingerprint>"`, then redeploy with
the same name and check identities again. Never enroll an uncorrelated caller.
If the header is `missing`, stop and confirm platform support; do not disable
the gate.

This gate is trustworthy **only behind Foundry's platform ingress**, which owns
the headers. Agent mode refuses ordinary nonlocal hosting without the Foundry
hosting marker. A marker is not authentication: do not expose the agent
container as an independent public ACA endpoint with spoofable headers.

## Operations and rollback

Keep one active revision/replica per component. Stop/drain tasks before
deployment or identity changes. Do not clear a slot to make a deployment appear
healthy: follow [recovery](ARCHITECTURE.md#fail-closed-recovery) after resolving
the remote session. Health probes confirm process readiness, not W365/model
access. Switching to bootstrap does not end a previously allocated session.

Pin image digests and retain a rollback release. Rotate the viewer OIDC secret
independently and review/revoke unneeded viewer FIC trust under administrator
policy. Keep request content, screenshots, tokens and token-exchange bodies out
of Application Insights/content traces. Logs include safe status/type/correlation
metadata and explicit critical cleanup failures.

For old deployments, follow [migration](W365-SETUP.md#migration-from-standalone-identities);
do not automatically delete or reparent existing resources. Remove sample-only
resources/RBAC following [cleanup](W365-SETUP.md#cleanup). Azure resource-group
deletion does not cancel W365 billing.

`azure.yaml` now runs `scripts/Remove-W365Resources.ps1` as an interactive
`predown` hook. Teardown order is intentionally reversed from setup:
assignment first, then agent user, then sample-created federated credentials,
then created permission grants or restored reused grant scopes, then
sample-created inheritance entries, then blueprint `requiredResourceAccess`,
and finally a sample-created W365 pool. Only after that succeeds does `azd down`
continue with Azure resource deletion.

The cleanup hook fails closed when it cannot prove ownership. If W365 state is
configured but no ownership manifest exists, `azd down` is blocked. The same
guard applies to environments bound to an existing Foundry project: cleanup
stops before any mutation unless you explicitly set
`ALLOW_EXISTING_FOUNDRY_CLEANUP=true` or pass
`-AllowExistingProjectCleanup` to the script after confirming the target
project resource group is disposable. Cleanup also verifies that reused shared
grants and reused inheritance entries are still present before it deletes any
sample-owned W365 or Entra objects.

Do not run `azd down` against an environment bound to a shared or pre-existing
Foundry project unless you have deliberately reviewed that override. Even with
the W365 predown hook, remove only resources created specifically for this
sample, review role assignments and viewer federation separately, and cancel
W365 capacity through its owning service when applicable.

## Live acceptance

Offline compilation/tests cannot prove tenant, preview SDK or service
compatibility. Live versions through `6` have now been deployed in the
authorized test tenant. Version `6` is active and caller binding passes, but
desktop opening is blocked before W365 MCP because the hosted runtime cannot
acquire the blueprint assertion. Continue these checks only after resolving
that identity capability without adding stored credentials:

1. Deploy phase 1 without W365/operator/state/OIDC configuration. Confirm healthy
   readiness, phase-2 503 responses and no W365/model/state credential access.
2. Discover the actual agent version's IDs. Confirm ordinary Responses hosting
   injects the matching blueprint client ID and supports blueprint-selected
   `ManagedIdentityCredential` for the exchange audience. If unsupported, stop;
   do not add a certificate, secret or CLI fallback.
3. Run setup twice against the supplied identities. Confirm parent mismatches
   and existing grant/inheritance ambiguity fail before mutations, identity IDs
   stay unchanged, unrelated scopes/grants/
   policies are preserved and pool assignment is not duplicated.
4. If approved, confirm viewer FIC has the exact UAMI object-ID subject, tenant
   issuer and audience, and that both deployed paths complete T1 -> T2 -> T3.
   Review the broader blueprint/sibling trust with the administrator.
5. Redeploy the same agent name, rediscover the new version and reject
   unexpected identity replacement. Confirm model availability, image inputs
   and live allowlisted tool discovery.
6. Start a benign task: Ready, screenshot, action, explicit end. Confirm release
   and absence of `/storage/responses` payload-size failures. Deny a second hosted
   caller and another viewer account even when they possess an opaque link.
7. Inspect watch permissions securely: See-only, not Control. Take control
   during an action; verify pause ordering, explicit resume and no auto-resume
   on disconnect/token-refresh failure.
8. Cancel/expire tasks and inspect cleanup. Crash a test worker, verify the
   slot/lease blocks takeover and perform documented recovery. Validate actual
   ACA OIDC callback, PKCE, CSRF, no-store tokens, CSP/frame origins, refresh and
   screenshot scaling.

[Foundry deployment reference](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent),
[Foundry agent identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[public token helper](https://github.com/microsoft-foundry/foundry-samples/blob/main/samples/csharp/foundry-autopilot-agent/src/hello_world_a365_agent/Services/AgentTokenHelper.cs).
