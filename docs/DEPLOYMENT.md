# Deploy to Foundry and Azure Container Apps

Deployment is explicit and billable. No script runs it automatically. Use a
dedicated resource group and identities. Review the resource/role changes first.
Do not deploy this sample as a shared multi-user service.

## Required Azure resources

Prepare an existing Foundry project with hosted-agent support and a compatible
vision/function-calling model deployment. `gpt.6.astra` is the suggested model;
use its actual deployment name if available to you. No model version/SKU is
invented by the template.

For the viewer, `infra/viewer.bicep` expects these existing resources in the
deployment resource group: ACA environment, ACR registry, RBAC-enabled Key Vault,
Storage account, and private Blob container (`desktop-state` by default).
Disable anonymous Blob access, use HTTPS/TLS 1.2+, disallow shared-key access where
your environment permits, and configure storage retention according to policy.
Do not enable public container access or create a SAS for this sample.

Create/import the exportable RSA blueprint certificate in Key Vault; register its
public certificate using [W365 setup](W365-SETUP.md). Create the viewer's web app
and client secret as described in [viewer setup](VIEWER.md). Store that secret
in Key Vault as `w365-viewer-client-secret`. Never put it in `.azure` environment
files, Bicep parameters, `azure.yaml` or the image.

Network policies must allow Entra token exchange, Key Vault, Blob, the Foundry
project/model, and `agent365.svc.cloud.microsoft`. The browser also needs the
W365 screen-share/WebRTC endpoints supplied during onboarding.

## Hosted agent configuration

The manifest follows the public C# Foundry sample. Current documentation installs
the `microsoft.foundry` extension; the manifest requires its `azure.ai.agents`
extension capability. Check your installed extension help if these preview names
change:

```powershell
azd ext install microsoft.foundry
azd auth login
azd ai agent init -m .\azure.yaml
```

Select your **existing** project and deployment. Do not use `azd provision` to
implicitly create a model whose availability/version you have not confirmed.
Set the following non-secret azd environment values with `azd env set KEY VALUE`:

| Setting | Source |
| --- | --- |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | Existing compatible deployment. |
| `W365_TENANT_ID`, `W365_BLUEPRINT_ID`, `W365_AGENT_ID`, `W365_AGENT_USER_ID` | Setup script output. |
| `W365_KEY_VAULT_URL` | `https://<vault>.vault.azure.net` |
| `W365_CERTIFICATE_SECRET_NAME` | Certificate backing secret name, e.g. `w365-blueprint`. |
| `SESSION_BLOB_URI` | `https://<storage>.blob.core.windows.net/desktop-state/slot.json` |
| `OPERATOR_TENANT_ID`, `OPERATOR_OBJECT_ID` | Human viewer operator's Entra IDs. |
| `HOSTED_ALLOWED_USER_ID` | Foundry's platform user partition (or `sha256:` fingerprint); see below. |
| `VIEWER_PUBLIC_URL` | Exact HTTPS origin of the ACA viewer. |

Foundry injects `FOUNDRY_PROJECT_ENDPOINT` and its hosting environment/credentials.
Do not override reserved platform variables, inject the local certificate path,
set a blueprint secret, or enable content tracing.

```powershell
azd deploy
```

Grant the resulting **Foundry hosted identity** only the access it needs:
model/project invocation per the current Foundry RBAC guidance, Key Vault Secrets
User for the dedicated certificate vault/secret, and Storage Blob Data Contributor
on the state container. The viewer Bicep grants roles only to its own UAMI; it
does not silently grant roles to an unknown Foundry principal.

Use your organization's model/project role guidance; do not blindly grant Owner.
Creating resource role assignments requires an appropriately scoped role such as
Role Based Access Control Administrator in addition to deployment rights.

## Bind the hosted operator

`x-agent-user-id` is a **platform-injected opaque partition**, not necessarily the
operator's Entra object ID. `OPERATOR_OBJECT_ID` independently controls OIDC.
Do not copy one into the other without confirming the platform contract.

If the partition is not known, initially set `HOSTED_ALLOWED_USER_ID=pending`,
deploy, and have only the intended operator issue one identifiable invocation.
It is denied before W365 access. The warning includes a `sha256:` partition
fingerprint and request correlation ID, not the raw user identity or tokens.
Have the deployment administrator correlate that invocation and bind its
fingerprint with `azd env set HOSTED_ALLOWED_USER_ID "sha256:<fingerprint>"`,
then redeploy. Never enroll an arbitrary fingerprint from an uncorrelated request.
If the header is `missing`, stop and confirm platform context support; do not
disable the gate.

This gate is trustworthy **only behind Foundry's platform ingress**, which owns
these headers. Agent mode refuses ordinary nonlocal hosting without the Foundry
hosting marker. A marker is not authentication: do not deploy the agent container
as an independently reachable public ACA endpoint with spoofable headers.

## Deploy the viewer

Build the root Dockerfile into your ACR; the build context allowlist excludes
certificates, `.env` and unrelated files:

```powershell
az acr build --registry "<registry>" --image "win365-sample:v1" --file .\Dockerfile .
Copy-Item .\infra\viewer.parameters.example.json .\viewer.parameters.json
# Replace YOUR-* values with your identifiers and URLs before the next commands.
az deployment group what-if --resource-group "<sample-rg>" `
    --template-file .\infra\viewer.bicep --parameters "@viewer.parameters.json"
az deployment group create --resource-group "<sample-rg>" `
    --template-file .\infra\viewer.bicep --parameters "@viewer.parameters.json"
```

Copy the [parameter example](../infra/viewer.parameters.example.json) into your
untracked `viewer.parameters.json` and replace its placeholders.
It contains identifiers/URLs only, never secret values. Set `imageName` to the
image tag (prefer an immutable `repository@sha256:digest` for release).
The template creates one viewer UAMI with ACR pull, dedicated Key Vault secret
read and container-scoped Blob access; it runs one HTTPS-only viewer replica.

`viewerPublicUrl` must match the eventual browser origin. For the default ACA
hostname, construct it from the chosen app name and the existing environment's
`properties.defaultDomain`, or deploy once and update the value to the
`viewerHostname` output. Confirm the viewer Entra callback URI and the agent's
`VIEWER_PUBLIC_URL` match before using sign-in. For a custom domain, configure
its binding/certificate separately.

The agent and viewer must use **exactly the same W365 identities and state Blob**.
Their compute identities remain different. Use the viewer's UAMI client ID only
for viewer `AZURE_CLIENT_ID`; do not overwrite Foundry's platform credential.
If RBAC propagation delays block startup, wait and restart the affected revision;
do not switch to storage keys or bake a token into the image.

## Operations and rollback

Keep one active revision/replica per component. Stop/drain active tasks before
deploying. Do not clear a slot to make a stalled deployment appear healthy:
follow [recovery](ARCHITECTURE.md#fail-closed-recovery) after resolving the
remote session. Health probes confirm process readiness, not W365/model access.

Pin image digests and retain the previous release for rollback. Rotate the
blueprint certificate and viewer secret independently. Keep request content,
screenshots and tokens out of Application Insights/content traces. Logs include
safe status/type/correlation metadata and explicit critical cleanup failures.

Remove viewer resources and sample-only RBAC assignments when finished. Delete
Entra/W365 resources separately following [cleanup](W365-SETUP.md#cleanup);
removing an Azure resource group does not cancel Windows 365 billing.

## Live acceptance

Offline compilation/tests cannot prove current tenant, preview SDK or service
compatibility. Before publishing, execute these in an authorized test tenant:

1. Run setup twice; confirm IDs are reused, certificates/scopes are preserved,
   parent mismatches fail, and pool assignment is not duplicated.
2. Confirm the deployed model is available, image inputs reach it as image
   content, and allowed tools are discovered from the live catalog.
3. Start a task: Ready, screenshot, a benign action, explicit end. Confirm Cloud
   PC release and absence of `/storage/responses` payload-size failures.
4. Confirm the correct hosted operator is allowed; a second caller is denied.
   Confirm another viewer account cannot access an opaque link or token API.
5. Inspect watch token permissions securely: See-only, not Control. Take control
   during an action; verify pause ordering, explicit resume and no auto-resume
   on browser disconnect/token-refresh failure.
6. Cancel and expire tasks; inspect cleanup. Crash a test worker, confirm the
   slot/lease blocks takeover, and perform the documented recovery.
7. Validate ACA OIDC callback, CSP/frame origins, token refresh and screenshot
   scaling in the actual W365 SDK/browser combination.

[Foundry deployment reference](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent).
