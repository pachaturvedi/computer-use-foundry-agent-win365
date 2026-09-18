# Live view and human control

The same application runs as the companion viewer with `--viewer`. It does not
host the model or expose an agent `/responses` endpoint in this mode.

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
and other routes return a phase-2-required 503. No OIDC, W365 or state configuration
or credential access is required. This applies to local and ACA bootstrap.

Deploy [phase-1 viewer bootstrap](DEPLOYMENT.md#optional-phase-1-viewer-bootstrap)
to create the UAMI with ACR pull and Blob roles. Record the outputs:
`viewerIdentityClientId` selects the UAMI with `AZURE_CLIENT_ID`;
`viewerIdentityPrincipalId` is its object ID for optional federation.
`infra/viewer.bicep` defaults `w365Enabled` to `false`; it references the OIDC
Key Vault secret and grants secret access only when enabled.

## Enable the hosted viewer

First obtain explicit administrator approval and use
[setup's optional FIC](W365-SETUP.md#optional-viewer-federation) to trust the
**existing viewer UAMI object ID** on the Foundry blueprint. Its issuer is
`https://login.microsoftonline.com/<tenant>/v2.0` and audience is
`api://AzureADTokenExchange`. This authorizes **blueprint impersonation,
potentially including sibling agent identities**, not ARI-only access. Do not
grant it if shared-blueprint or administrator policy disallows it. The viewer
may remain disabled; agent links may then be unavailable. Configure only an
approved viewer and avoid workflows requiring handoff without one.

The viewer selects its UAMI using `AZURE_CLIENT_ID`, obtains a managed identity
token, and uses the FIC plus `fmi_path` for the agent to authenticate the blueprint
for T1, then the same T2/user-FIC T3 exchanges as the agent. There is no DAC,
CLI-token, certificate or secret fallback for W365. See
[authentication](AUTHENTICATION.md).

Create a **single-tenant web application** in Entra for the viewer. This is not
the W365 agent blueprint. Set its web redirect URI to
`https://<your-viewer-host>/signin-oidc` and record `VIEWER_CLIENT_ID`.
Create a short-lived client credential for this web app and store it as a Key
Vault secret; `infra/viewer.bicep` uses a Key Vault secret reference, not a literal
secret parameter. Key Vault is used only for this OIDC secret, never a blueprint
credential. OIDC uses code flow with PKCE and a secure HttpOnly cookie.

Set `OPERATOR_TENANT_ID` and `OPERATOR_OBJECT_ID` to the **human operator's** Entra
tenant and object ID. Both claims must match before any protected viewer page or
API is accessible; `/health` remains public. Possession of a random URL alone
is insufficient. Token endpoints use CSRF protection and `no-store` responses;
the browser does not persist tokens in localStorage or azd state, and the
live-view flow passes the short-lived W365 token only in the redirect fragment.

Configure `VIEWER_PUBLIC_URL` with the exact HTTPS origin used by the browser.
OIDC redirect and token redemption use this configured origin, not untrusted
forwarded headers. The ACA template allows HTTPS-only ingress. The viewer can
have a different human sign-in tenant from W365, but its **Azure UAMI, Foundry
and W365 must share the same tenant**. Its Azure identity must have access to
the configured Key Vault and Blob resource.

`SCREENSHARE_APP_URL` selects the W365-hosted view-only application. Pass it
through the azd environment or viewer deployment parameters. The sample defaults
to `https://w365ssviewer7f05ac.z13.web.core.windows.net`; override it only when
W365 onboarding supplies a different approved endpoint.

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
the exact `SESSION_BLOB_URI`. Both require `W365_AGENT_OBJECT_ID` when active;
set Bicep `agentObjectId` to the agent object/principal ID, not `agentId`
(app/client ID). `HOSTED_ALLOWED_USER_ID` belongs only to Foundry, not the
viewer; Bicep has no `hostedAllowedUserId` parameter. Get `SCREENSHARE_SDK_URL` and
`SCREENSHARE_FRAME_ORIGINS` from W365 onboarding. The latter is a space-separated
list of exact HTTPS origins, without paths, wildcards or trailing slashes,
for CSP's iframe allowlist. Do not substitute an arbitrary CDN or weaken CSP.

Fill the [viewer parameter example](../infra/viewer.parameters.example.json),
then set `VIEWER_LIVE_ENABLED=true` only after FIC/OIDC/state configuration,
the Key Vault OIDC secret, and all screen-share values are ready. The template
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

**Watch live** requests a See-only token. **Pause and take control** waits for
any in-flight action's shared lock, persists Paused, then issues a control token.
**Release control and resume agent** first releases/stops the SDK viewer, then
performs an explicit CSRF-protected resume. Closing a tab, reconnecting,
switching to watch mode or a token-refresh error does not resume automation.

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
