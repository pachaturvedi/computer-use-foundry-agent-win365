# Deploy to Foundry and Azure Container Apps

Deployment is explicit and billable. No script runs it automatically. Use a
dedicated resource group and, where possible, a dedicated Foundry blueprint.
Review resource, role and blueprint trust changes before execution. This is
a single-operator preview sample, not a production multi-user service.

Deployment has two phases: **bootstrap to obtain Foundry-owned identities**,
then **bind W365 to those exact identities and enable the runtime**.

## Prerequisites

Use this guide when you are ready to deploy or redeploy the hosted agent. For
the shortest operator path, start in [README](../README.md) and come here when
you need the full staged deployment, rollback, or live-acceptance detail.

- Azure CLI and Azure Developer CLI authenticated to the intended subscription and tenant.
- PowerShell 7.4+ and .NET 10 installed on the Windows operator machine.
- One Foundry path selected up front: either a fresh environment that will provision a dedicated Foundry project, or an existing Foundry project with a supported model deployment.
- Windows 365 onboarding, billing, and pool decisions reviewed before enabling phase 2.
- Viewer deployment approved only if you need authenticated live view or human handoff.

| Stage | Operation | Current status |
| --- | --- | --- |
| Phase 1 | Deploy `win365-desktop-agent` with `W365_ENABLED=false` | Greenfield bootstrap validated as version `1` in the separate `fawsep18-dev` evidence environment |
| Binding | Discover the deployed version, run W365 setup, create/reuse the agent user, and create or update the W365 agent pool | Scripted; live pool creation still requires tenant-specific billing and image inputs |
| Phase 2 | Provision state, apply returned IDs and operator values, enable W365, and redeploy the same service | Staged after the phase-1 agent principal is known |

The complete W365 lifecycle is validated with explicit `client_secret` mode.
Blueprint-selected managed identity remains blocked on the tested Responses
host by Entra `AADSTS700231`; the public reference helper is from an
activity/autopilot sample, not proof that this host supports chained
federation. No autopilot publication or hiring workflow is required. See
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

Do not pass `-EnableW365` on the initial greenfield deployment. The first
hosted-agent version must exist before its principal can be granted access to
the shared Blob state required by enabled W365 execution. Complete the staged
bootstrap above, discover the exact agent principal, and continue with
[phase 2](#phase-2-bind-and-enable). Do not use a one-shot `azd up` for a fresh
W365-enabled environment until the state principal and all phase-2 values have
been explicitly configured and reviewed.

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

`win365-desktop-agent` sets `codeConfiguration.dependencyResolution: bundled`.
`Win365Agent.csproj` references the sibling `Win365Shared` project and relies on
the repo-root `Directory.Packages.props` for central package versions. Foundry's
default `remote_build` mode zips and restores only the `project:` folder
(`src/Win365Agent`) on the build server, so it cannot see `Win365Shared` or the
central package-version file and fails restore with `NU1015` /
`Win365Shared.csproj ... was not found`. `bundled` makes `azd deploy` build and
publish locally, where the full repository/solution context is available, and
upload only the published output.

`bundled` publishes for the container's target runtime with `dotnet publish -r
linux-x64 --self-contained false`. A RID-specific publish otherwise implicitly
builds a native apphost, which needs the `Microsoft.NETCore.App.Host.linux-x64`
runtime pack; if that pack isn't already cached locally and the machine's
global NuGet sources are restricted, restore fails with `NU1101`. Because the
agent always starts as `dotnet Win365Agent.dll` (see `entryPoint` above), no
native apphost is required, so `Win365Agent.csproj` sets
`<UseAppHost>false</UseAppHost>` to skip that extra restore entirely.

Do not switch this back to `remote_build`
without also giving the agent a self-contained build context (for example, a
container deploy modeled on the viewer's `Dockerfile`, which already copies
`Directory.Packages.props`, `NuGet.Config`, and `Win365Shared` before
restoring).

Generic templates often use `azd up`, but this sample deliberately uses the
`Invoke-AzdDeployment.ps1` wrapper: the project and model must already exist,
and phase 1 must not provision an unconfirmed model SKU or W365 capacity. In
`client_secret` mode, the hosted agent fetches the blueprint client secret
directly from Key Vault at startup using its own runtime identity (see
"Blueprint client secret delivery" in `docs/AUTHENTICATION.md`), so a direct
`azd deploy win365-desktop-agent` or `azd up` no longer risks an empty
`W365_CLIENT_SECRET` crash. Still prefer the wrapper: it also confirms the
`w365-blueprint-client-secret` secret and the agent's Key Vault RBAC exist
before deployment, and runs `azd ai agent doctor` plus an optional smoke
invocation afterward. Do not run `azd provision` or `azd up` unless you have
intentionally added and reviewed complete infrastructure declarations for your
own fork, or you are following the dedicated greenfield path above.

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

`Invoke-W365SetupFlow.ps1` can repeat discovery automatically, run setup,
persist the returned `W365_*` values and ownership manifest, and redeploy the
same agent name. Do not invoke it yet: it fails before W365 or Entra mutation
unless the phase-2 Blob state, operator binding, and selected credential are
already configured as described below.

If `W365_POOL_ID` is already persisted in the azd environment, reruns update
that pool instead of creating another one. If no pool ID is present, the setup
script can create a pool when you supply the billing, geography, region, image,
and scaling inputs.

The setup script prints `W365_OWNERSHIP_MANIFEST=<path>` after it records the
created or reused pool, assignment, agent user, grants, inheritance entries,
federated credentials, and the blueprint's prior `requiredResourceAccess`.
`azd down` uses that manifest to prove what the sample is allowed to remove.

## Optional phase-1 viewer bootstrap

The viewer is a separate `src\Win365Viewer` executable and ACA container. It
references shared identity/state contracts from `Win365Agent` but has an
independent startup path and cannot expose the hosted Responses endpoint.
Until `VIEWER_LIVE_ENABLED=true`, the hosted agent suppresses viewer links even
if `VIEWER_PUBLIC_URL` already contains the provisioned ACA hostname.
Deploy it in bootstrap mode first so ACA can establish the public origin, UAMI,
and ACR without requiring live W365 or OIDC settings. The shared W365
credential vault is provisioned separately by the state layer.

The viewer reuses the agent's existing `SESSION_BLOB_URI`; it does not create a
second Storage account or session container. It also accepts an existing
Container Apps managed-environment resource ID, which is the recommended path
when the subscription is at the managed-environment quota. The foundation
creates a managed environment and Log Analytics only when that ID is empty.
It always creates the viewer ACR. The state-access module grants
the viewer UAMI Blob Data Contributor on the exact existing state container.

For a new Foundry project and viewer, initialize the complete environment:

```powershell
az containerapp show --help
az containerapp update --help
az containerapp registry set --help
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
    -SubscriptionId "<subscription-id>" `
    -Prefix "fawin365" `
    -Environment "dev" `
    -DeployViewer
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAll `
    -ConfirmResourceChanges
```

The three Azure CLI checks must succeed when the viewer is enabled. Upgrade
Azure CLI if they are unavailable; install or upgrade the `containerapp`
extension only when the upgraded CLI still does not provide them.

`-TenantId` is optional and should be supplied only to override the tenant
selected by `azd auth login`. Omit `-DeployViewer` unless the dedicated viewer
resources have been approved. Put the full ID of an approved existing
environment in `config\deployment.local.json` as
`viewer.managedEnvironmentResourceId`; use
`.\scripts\Get-ViewerManagedEnvironments.ps1` to list candidates. Leaving it
empty is the normal/default path and creates a dedicated managed environment.
Supplying the resource ID is an optional reuse path for quota-constrained or
shared-infrastructure environments. The approved environment may be in another
Azure region; the viewer Container App and its managed identity are created in
that environment's region while the remaining sample-owned resources stay in
`AZURE_RESOURCE_GROUP`. When `DEPLOY_VIEWER=false`, neither path is evaluated.
New managed environments default to `VIEWER_LOG_ANALYTICS_ENABLED=false`, which
uses the ACA `none` log destination and avoids creating a Log Analytics
workspace for the demo. Set it to `true` when retained application logs are
required. Reused environments keep their existing logging configuration.
The initializer uses reusable config helpers in `scripts/DeploymentConfig.ps1`
so later hosted and cleanup workflows can consume the same defaults and
override precedence without duplicating parsing logic.

For an environment already bound to a Foundry project, set the viewer layer
explicitly. All sample-owned Azure resources use `AZURE_RESOURCE_GROUP`;
`STATE_RESOURCE_GROUP_NAME` and `VIEWER_RESOURCE_GROUP_NAME` are compatibility
outputs with that same value:

```powershell
$resourcePrefix = "fawin365-dev"
azd env set RESOURCE_PREFIX $resourcePrefix
azd env set DEPLOY_VIEWER true
azd env set VIEWER_IMAGE_NAME "win365-sample:v1"
azd env set VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID `
  "/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.App/managedEnvironments/<name>"
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAll `
    -ConfirmResourceChanges
```

The viewer bootstrap calculates a `build-<hash>` image tag from the Dockerfile,
NuGet configuration, and viewer source. It reuses that ACR image on unchanged
`azd up` runs instead of repeating the remote SDK pull, restore, build, and
push. The hash changes monthly even when the source does not, allowing the
floating .NET base-image tags to pick up servicing and security updates.

The viewer consumes the existing state outputs
`AZURE_RESOURCE_GROUP`, `STATE_STORAGE_ACCOUNT_NAME`,
`STATE_CONTAINER_NAME`, and `SESSION_BLOB_URI`. Any account, container, path,
query, fragment, or protocol mismatch fails before deployment.

`azd up` creates one environment resource group in the core Foundry layer and
reuses it for the shared W365 credential Key Vault, optional Blob state, and
optional viewer resources. Blob session state remains conditional on
`DEPLOY_STATE`, and
the ACA viewer remains conditional on `DEPLOY_VIEWER`. The command prints a
pre-provision table showing which components will be created, reused, or
skipped, deploys the Foundry agent, then
runs the Windows `postup` hook. The hook builds
the repository image in the newly created ACR, waits for `AcrPull` role
propagation, switches the Container App to that image, and verifies `/health`.
ACR names remove hyphens, use lowercase alphanumerics, include a deterministic
suffix, and stay within service-specific length limits.

Before enabling `DEPLOY_VIEWER`, preview the state and viewer layers separately:

```powershell
azd provision state --preview --no-prompt
azd provision viewer --preview --no-prompt
```

Layered projects do not support a combined `azd provision --preview`. If the
preview reports `MaxNumberOfGlobalEnvironmentsInSubExceeded`, select an
approved existing environment by full resource ID or request a quota increase.
The deployment never silently chooses an environment.

The [parameter example](../infra/viewer.parameters.example.json) contains only
identifiers and URLs, never secret values. Its phase-2 placeholders are not
requirements for bootstrap. Keep your copy untracked. Prefer an immutable image
digest for releases. The template defaults `w365Enabled` to `false`, creates
the viewer UAMI with ACR pull, grants Blob access through the state-resource
group module, and runs one
HTTPS-only replica. `/health` is healthy and other routes return 503; no OIDC
configuration is needed until active.

Phase-2 identity, operator, viewer and SDK parameters default to empty strings
in Bicep. The state layer creates the shared vault; no secret value or
reference is needed in viewer bootstrap.

Record `viewerHostname`, `viewerIdentityClientId` and
`viewerIdentityPrincipalId` from the deployment outputs. The **principal/object
ID** is the optional setup FIC subject; the **client ID** selects the UAMI as
`AZURE_CLIENT_ID` in the viewer. Do not exchange these identifiers.

## Phase 2: bind and enable

Confirm Intune pool, licensing and billing prerequisites; setup does not
purchase capacity. Prepare state, operator binding, and the selected credential
before running [W365 setup](W365-SETUP.md). Review inherited blueprint grants
on sibling agents. For an optional viewer FIC, obtain explicit administrator
approval for **blueprint impersonation**, not merely ARI access.

Prepare private shared Blob state before enabling; live runtime requires Blob.
`FileSessionStore` is an offline-test helper, not a local live backend.
Grant the correct deployed
Foundry identity model/project invocation under current Foundry RBAC guidance
and Storage Blob Data Contributor on the state container. In `client_secret`
mode the agent's principal is also granted Key Vault Secrets User (read-only)
on the shared vault so it can fetch `w365-blueprint-client-secret` directly
(see `infra/state/keyvault.bicep`); **it still does not need Key Vault
certificate access.** Ordinary Azure model/state credentials remain separate
from the W365 flow. Viewer Bicep grants roles only to its own UAMI, not to the
Foundry principal. Verify the actual Azure principal used for model/state
access rather than substituting an app/client ID in RBAC. Role assignments
need appropriately scoped authorization (for example Role Based Access Control
Administrator); do not blindly grant Owner.

The default `client_secret` E2E path is not self-contained. An authorized Entra
administrator must create and approve a short-lived credential for the existing
Foundry blueprint under tenant policy. The repository does not create that
credential. Transfer it outside source control, logs, command history, JSON,
and `.azure`; store it only through the secure
`Set-ViewerSecrets.ps1 -BlueprintOnly` prompt, record its owner and expiry,
rotate it under tenant policy, and revoke it after validation. Explicitly set
`W365_BLUEPRINT_CREDENTIAL_MODE`; never fall back between credential modes.

For the existing-project two-phase workflow, enable the dedicated azd state
layer after phase-1 identity discovery:

```powershell
$environment = "<azd-environment-name>"
azd env set DEPLOY_STATE true --environment $environment
azd env set STATE_AGENT_PRINCIPAL_ID "<Foundry-agent-object-principal-GUID>" `
    --environment $environment
azd provision state --environment $environment --preview --no-prompt
azd provision state --environment $environment --no-prompt
```

The core layer creates the sample-owned environment resource group once. The
state layer references that group and creates one shared W365 credential Key
Vault, emitting `W365_KEY_VAULT_NAME`. When
`DEPLOY_STATE=true`, it also derives a globally unique Storage account name,
creates the private `desktop-state` container, grants the supplied agent
principal Storage Blob Data Contributor only on that container, and emits
`SESSION_BLOB_URI`. Greenfield phase 1 defaults `DEPLOY_STATE=false` because
the agent principal is not available until the first hosted-agent deployment;
that does not skip the credential vault.

Legacy development deployments may still have state in a separate
`*-state-rg`. The templates do not move or delete those resources
automatically. A new deployment uses the environment resource group and a new
storage account; migrate any required session state deliberately before
removing the legacy resource group.

The earlier validated development deployment created:

| Item | Value |
| --- | --- |
| Resource group | `fawin365-dev-state-rg` |
| Storage account | `fawin365devstsq53oc` |
| Container | `desktop-state` |
| Session Blob URI | `https://fawin365devstsq53oc.blob.core.windows.net/desktop-state/slot.json` |
| Data principal | `5ff7789e-bb85-4e15-9667-bf83c94465e1` |

The application creates `slot.json` atomically on first enabled use; the
infrastructure deployment intentionally does not seed the Blob.

Configure the hosted operator and credential before W365 mutation:

```powershell
$environment = "<azd-environment-name>"
azd env set OPERATOR_TENANT_ID "<operator-tenant-guid>" --environment $environment
azd env set OPERATOR_OBJECT_ID "<operator-object-guid>" --environment $environment
azd env set HOSTED_ALLOWED_USER_ID pending --environment $environment
azd env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret --environment $environment
pwsh -NoProfile -File .\scripts\Set-ViewerSecrets.ps1 `
    -Environment $environment `
    -BlueprintOnly
```

`HOSTED_ALLOWED_USER_ID=pending` denies W365 access while exposing only a
correlatable hash for the first intended caller; finish the binding below.
For `managed_identity_federation`, omit the secret command and complete the
explicit hosted-runtime federation approval, understanding that this mode is
blocked on the tested host by `AADSTS700231`.

After all prerequisites above are present, client-secret mode uses:

```powershell
azd env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret `
    --environment "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
   -Environment "<azd-environment-name>" `
   -TenantId "<Foundry-and-W365-tenant-guid>" `
   -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
   -BillingConfirmed `
   -ConfirmResourceChanges `
   -UseDeviceCode
```

Managed-identity mode requires explicit authorization for the exact discovered
agent principal and remains blocked on the tested host:

```powershell
azd env set W365_BLUEPRINT_CREDENTIAL_MODE managed_identity_federation `
    --environment "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
   -Environment "<azd-environment-name>" `
   -TenantId "<Foundry-and-W365-tenant-guid>" `
   -HostedRuntimeIdentityObjectId "<Foundry-agent-object-principal-guid>" `
   -AuthorizeHostedRuntimeFederation `
   -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
   -BillingConfirmed `
   -ConfirmResourceChanges `
   -UseDeviceCode
```

`key_vault_certificate` mode uses a self-signed, non-exportable Key Vault
certificate instead of a shared secret; see
[W365 setup](W365-SETUP.md#staged-azd-flow) for the certificate
initialization/registration steps that must run before
`Invoke-W365SetupFlow.ps1`:

```powershell
azd env set W365_BLUEPRINT_CREDENTIAL_MODE key_vault_certificate `
    --environment "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Invoke-W365SetupFlow.ps1 `
   -Environment "<azd-environment-name>" `
   -TenantId "<Foundry-and-W365-tenant-guid>" `
   -PoolIdOrUrl "<existing-pool-guid-or-intune-url>" `
   -BillingConfirmed `
   -ConfirmResourceChanges `
   -UseDeviceCode
```

Before any W365 or Entra mutation, the wrapper verifies that Blob state exists,
the expected `desktop-state` container exists, the discovered Foundry agent has
container-scoped `Storage Blob Data Contributor`, operator binding values are
present, the credential mode is explicit, and client-secret and
key_vault_certificate modes each have their required Key Vault credential.
Managed-identity mode additionally requires explicit
federation authorization for the exact discovered agent principal. The wrapper
then persists the returned IDs and ownership manifest and redeploys the same
agent name.

Set non-secret values using `azd env set KEY VALUE`:

| Setting | Source |
| --- | --- |
| `W365_TENANT_ID`, `W365_BLUEPRINT_ID` | Setup output; Foundry/W365/viewer Azure tenant and blueprint app ID. |
| `W365_AGENT_ID`, `W365_AGENT_OBJECT_ID`, `W365_AGENT_USER_ID` | Setup output; agent app ID, agent object ID, agent-user object ID. |
| `SESSION_BLOB_URI` | `https://<storage>.blob.core.windows.net/desktop-state/slot.json` |
| `W365_KEY_VAULT_NAME` | State-layer output naming the shared vault for the blueprint secret or certificate, and the optional viewer OIDC secret. The hosted agent uses this (plus its own RBAC-granted identity) to fetch `w365-blueprint-client-secret` or sign with `w365-blueprint-certificate` directly; it never receives raw secret/private-key material as an environment variable. |
| `OPERATOR_TENANT_ID`, `OPERATOR_OBJECT_ID` | Exact human operator's tenant/object IDs. |
| `HOSTED_ALLOWED_USER_ID` | **Foundry agent only:** platform user partition or `sha256:` fingerprint; see binding below. Not a viewer parameter. |
| `VIEWER_PUBLIC_URL` | Optional for an agent-only deployment. When omitted, desktop execution remains available but live-view/take-control links are returned as unavailable. Required for the viewer itself. |
| `SCREENSHARE_APP_URL` | **Viewer only:** W365-hosted view-only application origin supplied by W365 onboarding. It is required only when `VIEWER_LIVE_ENABLED=true`. |
| `SCREENSHARE_SDK_URL`, `SCREENSHARE_FRAME_ORIGINS` | **Viewer only:** approved W365 SDK URL and exact space-separated frame origins. |
| `VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID` | Optional full ID of the approved existing ACA managed environment. Empty means create one. |
| `W365_BLUEPRINT_CREDENTIAL_MODE` | Explicitly `client_secret` for the proven E2E demo, `managed_identity_federation` for the separately approved FIC path, or `key_vault_certificate` for a self-signed non-exportable Key Vault certificate. There is no fallback. |
| `VIEWER_LIVE_ENABLED` | Explicit viewer phase switch. Leave `false` for bootstrap; set `true` only after OIDC, state, W365, SDK/frame-origin values, and the Key Vault secret are ready. |
| `VIEWER_LOG_ANALYTICS_ENABLED` | Optional for a newly created ACA environment; defaults to `false`. Ignored when an existing environment resource ID is supplied. |
| `W365_ENABLED` | Internal phase switch. Bootstrap sets it to `false`; `Setup-W365.ps1` persists `true` only after phase-2 prerequisites are ready. |

Enabled configuration requires valid identity IDs and same-tenant Foundry/W365/
viewer Azure identities. The human OIDC tenant can differ. The runtime requires
the **platform-injected** `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID` to match
`W365_BLUEPRINT_ID`; never manufacture the platform variable to bypass this check.

`W365_AGENT_OBJECT_ID` is required for **both** the enabled agent and enabled
viewer, separately from `W365_AGENT_ID` (app/client ID). Set viewer `agentObjectId`
from the corresponding setup output, not the agent's app ID. The viewer has no
`hostedAllowedUserId` Bicep parameter; its authorization uses the human OIDC claims.

Finish [OIDC/SDK configuration](VIEWER.md#enable-the-hosted-viewer). The lean
Windows activation sequence is:

```powershell
# Bootstrap must already have produced VIEWER_PUBLIC_URL. State provisioning
# always produces W365_KEY_VAULT_NAME.
$environment = "<azd-environment-name>"
pwsh -NoProfile -File .\scripts\Configure-ViewerOidc.ps1 -Environment $environment
pwsh -NoProfile -File .\scripts\Set-ViewerSecrets.ps1 `
    -Environment $environment `
    -BlueprintOnly
azd env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret --environment $environment
azd env set VIEWER_LIVE_ENABLED true --environment $environment
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
    -Mode DeployAll `
    -ConfirmResourceChanges
```

`Configure-ViewerOidc.ps1` creates or reconciles the single-tenant web app,
exact `https://<viewer-host>/signin-oidc` callback, service principal, operator
binding, and `w365-viewer-client-secret`. `Set-ViewerSecrets.ps1
-BlueprintOnly` prompts securely for the proven blueprint credential and stores
it as `w365-blueprint-client-secret`. Neither secret is stored in `.azure`,
JSON, Bicep parameters, `azure.yaml`, or the image. The deployment script loads
the blueprint secret into its process environment only while publishing the
hosted agent.

Only live activation references the two secrets. The Windows postup hook
configures the two least-privilege, vault-scoped built-in RBAC assignments from
one script: `Key Vault Secrets User` for the viewer UAMI when enabled and
`Key Vault Secrets Officer` for the signed-in setup operator. It then creates
or reuses the OIDC credential, prompts only when the blueprint secret is
absent, stores both in the same vault, and reprovisions the viewer.
`managed_identity_federation` does not require the blueprint secret, but fails
unless the exact viewer UAMI federation is present in the W365 ownership
manifest.

After phase 2 is complete, `azd up` can be used for routine reruns of the fully
configured environment. It prints a pre-provision resource plan and a final
resource table. Do not use it to bootstrap a fresh W365-enabled environment.
Set `SAMPLE_LOG_LEVEL` to `summary` (default), `verbose`, or `debug`:

```powershell
$environment = "<azd-environment-name>"
azd env set SAMPLE_LOG_LEVEL verbose --environment $environment
azd up --environment $environment
```

All Windows scripts also support PowerShell's common `-Verbose` and `-Debug`
parameters. Use `-Verbose` for phase and command progress. Add `-Debug` for
sanitized decisions, resource IDs, and parameter context; secret, token,
password, credential, and certificate values are always redacted.

```powershell
azd up --environment $environment
# For a focused rerun with detailed diagnostics:
$env:AZURE_ENV_NAME = $environment
pwsh -NoProfile -File .\scripts\Complete-AzdUp.ps1 `
    -Verbose `
    -Debug
```

Agent and enabled viewer must use **exactly the same W365 identities and state
Blob**. Their compute identities remain different. Viewer `AZURE_CLIENT_ID`
selects its UAMI; never overwrite Foundry's credential selection.

```powershell
# All phase-2 values above must already be set.
azd ai agent doctor --environment $environment
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment $environment `
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

After successful phase-2 redeployment and active-version verification, begin
the first task with a **fresh hosted-agent session pinned to that immutable
version**. Hosted sessions stay pinned to the version that created them; reusing
a bootstrap session can return `w365_not_configured`.

```powershell
$environment = "<azd-environment-name>"
$version = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment $environment
azd ai agent invoke win365-desktop-agent `
    --environment $environment `
    --version $version `
    --new-session "<task>"
```

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
`azd env set HOSTED_ALLOWED_USER_ID "sha256:<fingerprint>" --environment
$environment`, then redeploy with the same name and check identities again.
Never enroll an uncorrelated caller.
If the header is `missing`, stop and confirm platform support; do not disable
the gate.

This gate is trustworthy **only behind Foundry's platform ingress**, which owns
the headers. Agent mode refuses ordinary nonlocal hosting without the Foundry
hosting marker. A marker is not authentication: do not expose the agent
container as an independent public ACA endpoint with spoofable headers.

## Operations and rollback

> **Always redeploy `win365-desktop-agent` through
> `scripts/Invoke-AzdDeployment.ps1 -Mode DeployAgent -Environment <env>
> -ConfirmResourceChanges`.** In `client_secret` mode the hosted agent fetches
> its own blueprint client secret directly from Key Vault at startup using its
> runtime identity (see "Blueprint client secret delivery" in
> `docs/AUTHENTICATION.md`), so a direct `azd deploy win365-desktop-agent` or
> `azd up` no longer crashes with `Configure W365_CLIENT_SECRET.` Still prefer
> the wrapper: it confirms `w365-blueprint-client-secret` exists and the
> agent's Key Vault RBAC is in place before packaging/publishing, then runs
> `azd ai agent doctor` and an optional smoke invocation afterward — checks a
> raw `azd` command skips even for a quick redeploy.

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
compatibility. As recorded in the
[validation report](VALIDATION-REPORT.md), hosted version `15` completed the
bounded W365 lifecycle with the explicitly selected `client_secret` mode. The
temporary secret was then revoked and removed, and a clean version `16`
restored `managed_identity_federation`. That federation mode remains blocked on
the tested host by Entra `AADSTS700231`; it never falls back to the validated
secret mode.

1. Deploy phase 1 without W365/operator/state/OIDC configuration. Confirm healthy
   readiness, phase-2 503 responses and no W365/model/state credential access.
2. Discover the actual agent version's IDs. Confirm ordinary Responses hosting
   injects the matching blueprint client ID. Select only an explicitly approved
   credential mode; do not add an automatic certificate, secret, managed
   identity, or CLI fallback.
3. Run setup twice against the supplied identities. Confirm parent mismatches
   and existing grant/inheritance ambiguity fail before mutations, identity IDs
   stay unchanged, unrelated scopes/grants/
   policies are preserved and pool assignment is not duplicated.
4. Redeploy the same agent name, rediscover the new version and reject
   unexpected identity replacement. Confirm model availability, image inputs
   and live allowlisted tool discovery. Confirm the selected mode completes
   T1 -> T2 -> agent-user T3 and only T3 is sent to W365.
5. Start a benign task: Ready, screenshot, action, explicit end. Confirm release
   and absence of `/storage/responses` payload-size failures. Deny a second
   hosted caller.
6. If the optional viewer is approved, confirm its FIC has the exact UAMI
   object-ID subject, tenant issuer and audience. Deny another viewer account
   even when it possesses an opaque link. Inspect watch permissions: See-only,
   not Control. Take control during an action; verify pause ordering, explicit
   resume and no auto-resume on disconnect/token-refresh failure.
7. Cancel/expire tasks and inspect cleanup. Crash a test worker, verify the
   slot/lease blocks takeover and perform documented recovery. Validate actual
   ACA OIDC callback, PKCE, CSRF, no-store tokens, CSP/frame origins, refresh,
   and screenshot scaling only when the viewer is enabled.

[Foundry deployment reference](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent),
[Foundry agent identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[public token helper](https://github.com/microsoft-foundry/foundry-samples/blob/main/samples/csharp/foundry-autopilot-agent/src/hello_world_a365_agent/Services/AgentTokenHelper.cs).

## Next steps

- Use [W365 setup](W365-SETUP.md) for delegated Graph permissions, identity binding, pool creation or reuse, and cleanup ownership.
- Use [Viewer](VIEWER.md) only after the core hosted-agent and W365 path is working and viewer federation has been explicitly approved.
- Use [Architecture](ARCHITECTURE.md) when rollback or live validation points to slot recovery, ownership, or session lifecycle behavior.
