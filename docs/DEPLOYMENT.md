# Deploy to Foundry and Azure Container Apps

Deployment is explicit and billable. No script runs it automatically. Use a
dedicated resource group and, where possible, a dedicated Foundry blueprint.
Review resource, role and blueprint trust changes before execution. This is
a single-operator preview sample, not a production multi-user service.

Deployment has two phases: **bootstrap to obtain Foundry-owned identities**,
then **bind W365 to those exact identities and enable the runtime**. No live
deployment has been performed for this implementation. In particular, ordinary
Responses hosting must be validated for blueprint-selected managed identity;
the public reference helper is from an activity/autopilot sample, not evidence
that this host supports it. No autopilot publication or hiring workflow is
required here. See [authentication](AUTHENTICATION.md#sdk-and-hosting-boundary).

## Phase 1: deploy bootstrap

Prepare an existing Foundry project with hosted-agent support and an existing
vision/function-calling model deployment. `gpt.6.astra` is the suggested model;
use its actual deployment name if available in your subscription/region. The
template does not invent a model version or SKU.

Install .NET 10, PowerShell 7.5+, Azure CLI and Azure Developer CLI. From the
repository root initialize the existing-project deployment:

```powershell
azd ext install microsoft.foundry
azd auth login
azd ai agent init -m .\azure.yaml
# Select the existing project and model; retain the agent name for phase 2.
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "<existing-model-deployment-name>"
azd env set W365_ENABLED false
azd deploy
```

The manifest requires the extension's `azure.ai.agents` capability. Preview
extension names/commands can change; check installed extension help if needed.
Do not run `azd provision` to implicitly create an unconfirmed model SKU.

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

An object ID is not an app ID. Setup resolves the agent app/client ID from the
existing agent object ID and emits both as separate `W365_AGENT_ID` and
`W365_AGENT_OBJECT_ID` values. If discovery does not return the required fields
or the actual host cannot provide a matching blueprint identity endpoint, stop
and investigate the preview hosting contract; do not create a substitute identity.

## Optional phase-1 viewer bootstrap

The viewer is a separate process built from the same project (`--viewer`).
It may stay disabled if blueprint federation is not approved. Deploy bootstrap
first when you need the viewer UAMI IDs for approval.

`infra/viewer.bicep` expects an existing ACA environment, ACR registry, Storage
account/private container (`desktop-state` by default), and a Key Vault name in
the deployment resource group. Key Vault is **only for the phase-2 OIDC secret**;
bootstrap does not reference an OIDC secret or grant its read role.
Keep Blob private, require HTTPS/TLS 1.2+, disallow shared-key access where
possible, and set organizational retention policy. Do not create a SAS.

```powershell
az acr build --registry "<registry>" --image "win365-sample:v1" --file .\Dockerfile .
Copy-Item .\infra\viewer.parameters.example.json .\viewer.parameters.json
# Edit the copied file: set existing infrastructure names and imageName.
# Keep w365Enabled=false; omit or empty phase-2 identity/operator/OIDC/SDK fields.
az deployment group what-if --resource-group "<sample-rg>" `
    --template-file .\infra\viewer.bicep --parameters "@viewer.parameters.json"
az deployment group create --resource-group "<sample-rg>" `
    --template-file .\infra\viewer.bicep --parameters "@viewer.parameters.json"
```

The [parameter example](../infra/viewer.parameters.example.json) contains only
identifiers and URLs, never secret values. Its phase-2 placeholders are not
requirements for bootstrap. Keep your copy untracked. Prefer an immutable image
digest for releases. The template defaults `w365Enabled` to `false`, creates
the viewer UAMI with ACR pull and container-scoped Blob roles, and runs one
HTTPS-only replica. `/health` is healthy and other routes return 503; no OIDC
configuration is needed until active.

Phase-2 identity, operator, viewer and SDK parameters default to empty strings
in Bicep. `keyVaultName` remains a required existing-resource name for future
OIDC use; no OIDC secret value or reference is needed in bootstrap.

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

Set non-secret values using `azd env set KEY VALUE`:

| Setting | Source |
| --- | --- |
| `W365_TENANT_ID`, `W365_BLUEPRINT_ID` | Setup output; Foundry/W365/viewer Azure tenant and blueprint app ID. |
| `W365_AGENT_ID`, `W365_AGENT_OBJECT_ID`, `W365_AGENT_USER_ID` | Setup output; agent app ID, agent object ID, agent-user object ID. |
| `SESSION_BLOB_URI` | `https://<storage>.blob.core.windows.net/desktop-state/slot.json` |
| `OPERATOR_TENANT_ID`, `OPERATOR_OBJECT_ID` | Exact human operator's tenant/object IDs. |
| `HOSTED_ALLOWED_USER_ID` | **Foundry agent only:** platform user partition or `sha256:` fingerprint; see binding below. Not a viewer parameter. |
| `VIEWER_PUBLIC_URL` | Approved viewer's exact HTTPS origin; an unavailable viewer cannot support handoff. |
| `W365_ENABLED` | Set to `true` only after the phase-2 prerequisites are ready. |

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
phase-2 viewer parameters, set `w365Enabled=true`, review the deployment what-if,
and redeploy using the same viewer name/UAMI. Only then does the template reference
the OIDC secret and grant Key Vault access. No blueprint certificate parameter
or W365 Key Vault credential setting is used.

Agent and enabled viewer must use **exactly the same W365 identities and state
Blob**. Their compute identities remain different. Viewer `AZURE_CLIENT_ID`
selects its UAMI; never overwrite Foundry's credential selection.

```powershell
# All phase-2 values above must already be set.
azd env set W365_ENABLED true
azd deploy
```

Use the **same Foundry agent name**, deploying a new version rather than a new
agent. Rerun discovery for the new version and compare all IDs with phase 1.
Reject unexpected identity replacement before permitting tasks; do not silently
rebind users, consent or FICs to replacements. A rollback must also preserve
the accepted identity binding.

Network policies must allow Entra exchange, Blob, the Foundry project/model
and `agent365.svc.cloud.microsoft`; the viewer additionally needs its OIDC
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
correlation ID, not the raw user identity or tokens. Have the administrator
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

## Live acceptance

Offline compilation/tests cannot prove tenant, preview SDK or service
compatibility. **No actual live deployment has been performed for this
implementation.** Before claiming hosted support, run these in an authorized
test tenant:

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
