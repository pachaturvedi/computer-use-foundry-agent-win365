# Live view and human control

The same application runs as the companion viewer with `--viewer`. It does not
host the model or expose an agent `/responses` endpoint in this mode.

## Local

`Run-Local.ps1 -Mode viewer` binds `http://localhost:5050` and loads the same
`.env` and user-secrets as the agent. Both use the same absolute `SESSION_FILE`.
Local mode trusts the local OS user and has no Entra sign-in. Keep it on a private
development host; never tunnel these ports.

Get `SCREENSHARE_SDK_URL` and `SCREENSHARE_FRAME_ORIGINS` from W365 onboarding.
The latter is a space-separated list of exact HTTPS origins, without paths,
wildcards or trailing slashes. These configure CSP's iframe allowlist. Do not
substitute an arbitrary CDN or weaken CSP to `*` to make an error disappear.

## Hosted

Create a **single-tenant web application** in Entra for the viewer. This is not
the W365 agent blueprint. Set its web redirect URI to
`https://<your-viewer-host>/signin-oidc` and record `VIEWER_CLIENT_ID`.
Create a short-lived client credential for this web app and store it as a Key
Vault secret; `infra/viewer.bicep` uses a Key Vault secret reference, not a literal
secret parameter. OIDC uses code flow with PKCE and a secure HttpOnly cookie.

Set `OPERATOR_TENANT_ID` and `OPERATOR_OBJECT_ID` to the **human operator's** Entra
tenant and object ID. Both claims must match before any viewer page or API is
accessible. Possession of a random URL alone is insufficient.

Configure `VIEWER_PUBLIC_URL` with the exact HTTPS origin used by the browser.
OIDC redirect and token redemption use this configured origin, not untrusted
forwarded headers. The ACA template allows HTTPS-only ingress. The viewer can
have a different human sign-in tenant from W365; its Azure identity must still
have access to the configured Key Vault and Blob resource.

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

Both live-view and take-control links open the same authenticated page. The
`#control` fragment is an affordance only; it never automatically takes control.
The human must click the button. At task expiry the browser stops its viewer,
the server denies new tokens/actions, and request cleanup attempts EndSession.

If the model returns without closing while a handoff is pending, the request
retains the slot until explicit resume or its deadline, then cleans up. For
continuing the task after handoff, the model has a `wait_for_human` function.
Client/model streaming may buffer links; the viewer root page is the independent
way to find the active task.

## Troubleshooting

401/redirect loops: check single-tenant app settings, public URL and exact callback
URI. 404: no active task, wrong link, owner mismatch or expiry. 409: desktop not
ready, an uncertain action, or missing W365 session link. `MODE_RESTRICTED`: use
the control button to construct an interactive viewer. `TOKEN_EXPIRED`: the
client refreshes the same permission purpose; a failed refresh stays paused.
Other SDK errors are displayed without logging tokens/session links.

[Official SDK documentation](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md).
