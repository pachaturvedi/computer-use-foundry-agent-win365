# Live view and human control

The companion ACA runs the dedicated `src\Win365Viewer` executable. It
references configuration, identity, and state contracts from the independent
`src\Win365Shared` class library. It does not reference `Win365Agent`, host the
model, or expose an agent `/responses` endpoint. This dependency and process
boundary prevents viewer bootstrap configuration from changing hosted-agent
startup behavior.

## Prerequisites

The viewer is optional for direct W365 MCP execution, but a fresh managed
`azd up` deploys it by default so the demo can expose authenticated live view
and human handoff. Set `DEPLOY_VIEWER=false` only for an intentional
agent-only deployment.

- For a direct fresh deployment, the `postup` hook creates the viewer after the
  phase-1 agent principal, shared state, certificate registration, and
  certificate-scoped RBAC are ready.
- For the staged path, record the viewer bootstrap outputs from
  [deployment](DEPLOYMENT.md#optional-phase-1-viewer-bootstrap), especially
  `viewerIdentityClientId`, `viewerIdentityPrincipalId`, and `viewerHostname`.
- The default non-exportable Key Vault blueprint certificate. A blueprint
  client secret is required only for explicit legacy `client_secret` mode;
  viewer federation is required only for `managed_identity_federation`.
- Approved W365 screen-share values available from onboarding:
  `SCREENSHARE_APP_URL`, `SCREENSHARE_SDK_URL`, and
  `SCREENSHARE_FRAME_ORIGINS`. These are required only for live viewer
  activation, not agent-only execution or viewer bootstrap.
- A shared W365 Key Vault, provisioned independently of the viewer, and a
  single-tenant Entra web application for the viewer OIDC sign-in flow.

## Fresh managed deployment

After Foundry bootstrap, `azd up` asks how to host the viewer:

1. create a new dedicated ACA managed environment (default);
2. reuse an existing successfully provisioned ACA managed environment; or
3. skip the viewer.

The existing-environment path lists candidates in the selected Azure
subscription and persists the chosen full resource ID only in the selected azd
environment. It never silently selects shared infrastructure. If creation of a
new managed environment fails specifically because of ACA environment quota or
capacity, the hook offers the same existing-environment selection and retries
only viewer provisioning. The retry changes only the ACA selection; the
validated phase-two flow owns viewer activation. Unrelated deployment failures
remain failures.

Viewer infrastructure is requested only after the shared storage account,
container, and exact undecorated HTTPS Blob URI are validated. Missing or
inconsistent outputs stop before ACA provisioning. Fix the reported state
configuration and rerun
`azd up --environment "<azd-environment-name>"`;
the onboarding retry re-enters phase two, and no viewer cleanup is required for
a failure before viewer provisioning.

The one-command deployment provisions the ACA/ACR/UAMI bootstrap after shared
state, builds and health-checks the viewer image, completes W365 setup,
configures OIDC and Key Vault secrets, enables live mode when the approved
screen-share values are available, and republishes the hosted agent so it
advertises viewer links. Values already present in the selected azd environment
or ignored `config\deployment.local.json` are carried through automatically.

If the onboarding values are absent, the ACA viewer still deploys and reports
healthy bootstrap status, but live-view and take-control routes remain disabled.
The final summary lists the missing values; set them and rerun
`azd up --environment "<azd-environment-name>"`.

If deployment is interrupted after viewer bootstrap or activation begins,
rerun that same command for the same azd environment. Post-up retains the
pre-mutation viewer baseline and will either confirm that nothing changed or
redeploy the hosted agent before reporting completion. Do not clear
`W365_AGENT_REDEPLOY_CHECK_PENDING` or `W365_AGENT_REDEPLOY_PENDING` manually,
and do not substitute a standalone `DeployAgent` run for this recovery path.

## Bootstrap and local mode

Use the canonical Windows workflow from the repository root:

```powershell
pwsh -NoProfile -File .\scripts\Setup-Local.ps1
pwsh -NoProfile -File .\scripts\Start-Local.ps1
```

`Start-Local.ps1` launches both the agent and viewer, waits for health, and
stops both with `Ctrl+C`. The viewer defaults to `http://localhost:5050`;
choose another port with `-ViewerPort` when needed. Logs are written under
`.local\`.

`SAMPLE_LOCAL_MODE=true` remains unauthenticated and loopback-only, for
bootstrap/offline use; **enabled local W365 is refused**. Live W365 needs the
deployed managed identity endpoint, not CLI credentials. Keep the local host
private; never tunnel these ports.

With `W365_ENABLED=false` (default, strictly `true`/`false`), `/health` is healthy
and other routes return a viewer-specific 503. No OIDC, W365 or state
configuration or credential access is required. The hosted agent advertises no
viewer links until `VIEWER_LIVE_ENABLED=true`, even when the ACA hostname has
already been provisioned.

Deploy [phase-1 viewer bootstrap](DEPLOYMENT.md#optional-phase-1-viewer-bootstrap)
to create the UAMI with ACR pull and Blob roles. Record the outputs:
`viewerIdentityClientId` selects the UAMI with `AZURE_CLIENT_ID`;
`viewerIdentityPrincipalId` is its object ID for optional federation.
`infra/viewer.bicep` defaults `w365Enabled` to `false`; it references secrets
only when enabled. The postup workflow configures vault-scoped Azure RBAC in
one place: `Key Vault Secrets User` for the viewer identity when enabled and
`Key Vault Secrets Officer` for the setup operator.

## Enable the hosted viewer

Fresh deployments default to `W365_BLUEPRINT_CREDENTIAL_MODE=key_vault_certificate`.
The viewer UAMI receives certificate/key-scoped Key Vault read/sign roles and
uses the same non-exportable certificate as the agent; no blueprint secret is
injected. `client_secret` remains an explicit legacy opt-in.
The viewer still requires its separate `w365-viewer-client-secret` for human
OIDC sign-in. That OIDC credential is not a blueprint credential and is needed
in every live-viewer credential mode. The same T2/user-FIC T3 exchanges and
resource-scoped tokens remain unchanged.
Managed-identity federation remains an explicit alternative and requires the
approved viewer FIC documented in
[W365 setup](W365-SETUP.md#optional-viewer-federation). There is no automatic
fallback between credential modes.

Create a **single-tenant web application** in Entra for the viewer. This is not
the W365 agent blueprint. Set its web redirect URI to
`https://<your-viewer-host>/signin-oidc` and record `VIEWER_CLIENT_ID`.
Create a short-lived client credential for this web app and store it as
`w365-viewer-client-secret`. `infra/viewer.bicep` uses a Key Vault reference for the OIDC credential and,
only in legacy `client_secret` mode, a separate blueprint-secret reference.
OIDC uses code flow
with PKCE and a secure HttpOnly cookie.

Set `OPERATOR_TENANT_ID` and `OPERATOR_OBJECT_ID` to the **human operator's** Entra
tenant and object ID. Both claims must match before any protected viewer page or
API is accessible; `/health` remains public. Possession of a random URL alone
is insufficient. Token endpoints use CSRF protection and `no-store` responses;
the browser does not persist tokens in localStorage or azd state, and the
live-view flow passes the short-lived W365 token only in the redirect fragment.

Configure `VIEWER_PUBLIC_URL` with the exact HTTPS origin used by the browser.
OIDC redirect and token redemption use this configured origin, not untrusted
host values. The ACA template allows HTTPS-only ingress, and the application
trusts one forwarded-protocol hop from that ingress so secure authentication
and antiforgery cookies remain valid after TLS termination. The viewer can have
a different human sign-in tenant from W365, but its **Azure UAMI, Foundry and
W365 must share the same tenant**. Its Azure identity must have access to the
configured Key Vault and Blob resource.

`VIEWER_PUBLIC_URL` is the only viewer setting consumed by the hosted agent.
When it contains the origin of a fully configured companion ACA deployment,
`open_desktop` automatically returns
`https://<viewer-origin>/live/<opaque-id>` and
`https://<viewer-origin>/view/<opaque-id>#control`. The session-specific
computer URL and tokens do not exist during provisioning; the companion viewer
resolves them after the desktop session starts. If viewer bootstrap discovers a
new ACA hostname during `azd up`, the postup hook persists the URL and redeploys
the hosted agent in the same run.

Do not set `VIEWER_PUBLIC_URL` to `SCREENSHARE_APP_URL`. The former must run this
repository's authenticated companion service and expose `/live`, `/view`, and
`/api` routes. The latter is the W365-hosted static view-only application used
only after the companion viewer verifies ownership and mints a short-lived
`Computer.See` token.

For an already deployed and fully configured companion ACA, the agent-side
configuration is one setting:

```powershell
azd env set VIEWER_PUBLIC_URL https://<companion-viewer-aca-hostname>
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Mode DeployAgent `
    -ConfirmResourceChanges
```

The next `open_desktop` call creates the opaque session identifier and returns
the completed live-view and take-control links. An arbitrary Container App or
the W365 static viewer URL cannot be used because it does not have the shared
session state, operator authentication, or token endpoints.

Do not switch credential mode to activate the viewer. Established
`key_vault_certificate` deployments remain on certificate mode during preview,
activation, and routine redeployment; `W365_ENABLED=true` is the fail-closed
readiness proof used by the Bicep layer.

`SCREENSHARE_APP_URL` selects the W365-hosted view-only application. Pass it
through the azd environment or an untracked viewer deployment parameter file.
Use only the approved endpoint supplied by W365 onboarding; the repository does
not contain a concrete live-screen hostname.

`Initialize-Greenfield.ps1` persists this non-secret endpoint in the azd
environment, and the viewer Bicep layer passes it to the companion viewer. The
agent still returns only its authenticated opaque `/live/<id>` URL. After the
operator signs in and ownership is verified, that endpoint mints a short-lived
`Computer.See` token and redirects the browser to the W365 viewer with
`mode=viewOnly`, the W365 `screenShareUrl`, and token in the URL fragment. The
token is never stored in azd state or returned in the agent/model response.
Take-control continues to use the authenticated companion `/view/<id>#control`
flow.

Agent and viewer must share the same valid W365 blueprint/agent/user IDs and
the exact `SESSION_BLOB_URI`. Viewer deployment references the existing state
account and grants its UAMI access to that exact container; it does not create
a second session store. Both require `W365_AGENT_OBJECT_ID` when active;
set Bicep `agentObjectId` to the agent object/principal ID, not `agentId`
(app/client ID). `HOSTED_ALLOWED_USER_ID` belongs only to Foundry, not the
viewer; Bicep has no `hostedAllowedUserId` parameter. Get `SCREENSHARE_SDK_URL` and
`SCREENSHARE_FRAME_ORIGINS` from W365 onboarding. The latter is a space-separated
list of exact HTTPS origins, without paths, wildcards or trailing slashes,
for CSP's iframe allowlist. Do not substitute an arbitrary CDN or weaken CSP.

Fill the [viewer parameter example](../infra/viewer.parameters.example.json),
then set `VIEWER_LIVE_ENABLED=true` only after credential/OIDC/state
configuration, both required Key Vault secrets, and all screen-share values
are ready. The template
rejects live viewer activation unless `W365_ENABLED=true` and the required
non-secret values are present. Redeploy the same app/UAMI. For the default
ACA hostname, use `viewerHostname` from phase 1; make `viewerPublicUrl`, the
web-app callback and the agent's `VIEWER_PUBLIC_URL` agree. A custom domain
needs its own binding/certificate. Bicep manages the
viewer UAMI's `AZURE_CLIENT_ID`; do not set Foundry's platform-owned identity
variables on the viewer.

Keep one viewer replica. Data-protection keys are intentionally ephemeral:
restart or deployment signs users out; reauthenticate rather than sharing a
development key. Multi-replica cookie-key persistence is outside this sample.

## Interaction

Open `/` to find the operator's active task or use the opaque link returned by
`open_desktop`. The path contains only a random 256-bit lookup identifier.
The viewer uses the public W365 API:
`new ScreenShareViewer({container, sessionLink, mode})`, `connect(token)`,
`takeControl()`, `releaseControl()`, `updateToken()` and `stop()`.

The hosted agent stays agent-first for safe, reversible desktop work. Expect it
to continue ordinary navigation, reading, typing, save dialogs, verification,
and routine data entry on its own. Human control is reserved for sign-in, MFA,
secret entry, approvals, purchases, sending messages as the user, deleting data,
and other sensitive, privileged, identity-bound, or irreversible steps.

**Watch live** requests a See-only token. **Pause and take control** waits for
any in-flight action's shared lock, persists Paused, then issues a control token.
**Release control and resume agent** first releases/stops the SDK viewer, then
performs an explicit CSRF-protected resume. Closing a tab, reconnecting,
switching to watch mode or a token-refresh error does not resume automation.

### Observation-only invoice demo

Run the basic invoice scenario from Windows PowerShell with:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-InvoiceProcessingDemo.ps1 `
    -Environment "<resource-prefix>-dev"
```

The helper opens only the `/live/<opaque-id>` view and never the control route.
Its prompt forbids pause, takeover, or human handoff because the basic scenario
needs no authentication or sensitive action. If an unexpected page requires
human action, the agent reports failure instead of waiting. Each run uses a
locally generated run GUID in the Notepad filename; it does not expose or reuse
the hosted session ID. Use the direct invocation in [README](../README.md#verify-live-behavior). Treat
an ambiguous result as unresolved and follow
[fail-closed recovery](ARCHITECTURE.md#fail-closed-recovery) before retrying.

Live-view links enter through the authenticated `/live/<id>` route and then
redirect into the W365-hosted view-only app. Take-control links stay on the
authenticated companion `/view/<id>#control` page. The `#control` fragment is
an affordance only; it never automatically takes control. The human must click
the button. At task expiry the browser stops its viewer, the server denies new
tokens/actions, and request cleanup attempts EndSession.

If the model returns without closing while a handoff is pending, the request
retains the slot until explicit resume or its deadline, then cleans up. For
continuing the task after handoff, the model has a `wait_for_human` function.
Client/model streaming may buffer links; the viewer root page is the independent
way to find the active task.

## Troubleshooting

503: bootstrap is still disabled; finish phase 2 rather than trying local
credentials. Identity failures: check ID types, same-tenant UAMI, exact FIC
subject/issuer/audience and administrator approval. There is no credential
fallback. Health alone does not verify OIDC, FIC, W365 or shared state.

401/redirect loops: check single-tenant app settings, public URL and exact callback
URI. 404: no active task, wrong link, owner mismatch or expiry. 409: desktop not
ready, an uncertain action, or missing W365 session link. `MODE_RESTRICTED`: use
the control button to construct an interactive viewer. `TOKEN_EXPIRED`: the
client refreshes the same permission purpose; a failed refresh stays paused.
Other SDK errors are displayed without logging tokens/session links.

[Official SDK documentation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md).

## Next steps

- Return to [deployment phase 2](DEPLOYMENT.md#phase-2-bind-and-enable) when the viewer needs to be enabled together with shared state and the hosted agent.
- Return to [W365 setup](W365-SETUP.md#optional-viewer-federation) for the optional viewer FIC approval and identity-binding details.
- Use [authentication](AUTHENTICATION.md) when you need the credential and token-exchange boundaries behind the hosted viewer flow.
