# Authentication

## Identities and activation

| Identity or setting | Meaning |
| --- | --- |
| Human operator | Invokes Foundry and signs in to the viewer. Not impersonated for W365. |
| Foundry hosting Azure credential | Ordinary model/project and Blob access, separate from W365 token acquisition. |
| `W365_BLUEPRINT_ID` | App/client ID of the blueprint provisioned by Foundry, not its object ID. |
| `W365_AGENT_OBJECT_ID` | Object/principal ID of Foundry's existing agent identity. Setup accepts this as `-AgentIdentityId`. |
| `W365_AGENT_ID` | App/client ID resolved by setup from that agent object ID; used in token exchanges. |
| `W365_AGENT_USER_ID` | Agent-user object ID and pool assignee. An identifier, not a credential. |
| Viewer UAMI / OIDC web app | UAMI authenticates the viewer process; a separate web app authenticates the human through OIDC. |

`W365_ENABLED` defaults to `false` and accepts only `true` or `false`. Bootstrap
always pins it to `false`; successful phase-2 setup persists `true` into the
selected azd environment. Bootstrap does not require identity, operator, model,
state or OIDC configuration, and does not access W365/model/state credentials.
Bootstrap starts before any model initialization. The agent exposes healthy readiness
and a Responses 503 explaining phase 2; the viewer exposes `/health` and 503
on other routes. `SAMPLE_LOCAL_MODE=true` is loopback-only bootstrap/offline.
Live W365 requires a deployed identity endpoint; enabled local mode is refused.

When enabled, all W365 IDs must be valid. `W365_AGENT_OBJECT_ID` is required
in both agent and viewer configuration, separately from the app/client ID in
`W365_AGENT_ID`. Foundry, W365 and the viewer Azure
identity must be in the same tenant (`W365_TENANT_ID`); the human OIDC tenant
may differ. Foundry must inject `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID`, matching
`W365_BLUEPRINT_ID`. Never set or override reserved platform variables yourself.
Identity mode is selected by `W365_BLUEPRINT_CREDENTIAL_MODE`, never by a model,
request argument, page or user-supplied credential. Active runtime requires shared Blob state;
`FileSessionStore` is only an offline-test helper.

| `W365_BLUEPRINT_CREDENTIAL_MODE` | Status |
| --- | --- |
| `client_secret` | Default for the E2E demo and validated end to end. The shared state-layer Key Vault stores the blueprint secret independently of whether the ACA viewer is enabled. |
| `managed_identity_federation` | Optional hardening path. The tested Foundry-hosted identity could not chain its federated token into the blueprint exchange (`AADSTS700231`). |
| `key_vault_certificate` | Self-signed, non-exportable Key Vault certificate. The agent's runtime principal signs the client assertion remotely inside Key Vault; the private key never leaves Key Vault and is never read by the agent process. Agent-only (not selectable for the viewer). |

The modes are explicit and mutually exclusive. There is no fallback from one
mode to another. In particular, a managed-identity failure never falls back to
a secret, certificate, Azure CLI token or local user credential.

## Blueprint client secret delivery

In `client_secret` mode, the hosted agent never receives the raw secret value
as an environment variable. `infra/state/keyvault.bicep` grants the agent's
own runtime principal (the same principal already used for shared Blob state
access; see `STATE_AGENT_PRINCIPAL_ID`) a least-privilege **Key Vault Secrets
User** role on the shared vault. At startup, `KeyVaultBlueprintSecretResolver`
uses that identity to fetch `w365-blueprint-client-secret` directly from
`W365_KEY_VAULT_NAME` (the only client-secret-mode configuration the agent
requires) and caches it in memory for the process lifetime; rotating the
secret requires a redeploy so a fresh process fetches the new value.
`BlueprintTokenProvider` falls back to reading a plain `W365_CLIENT_SECRET`
value only when no resolver is configured, which keeps the **viewer**
(a Container App) working unchanged: it still receives the secret through its
own native Key Vault secret reference (`infra/viewer.bicep`), using its own
UAMI's separately granted Key Vault Secrets User role. Never print, hash for
display, serialize into documentation, or commit the resolved value.

## Blueprint certificate delivery

In `key_vault_certificate` mode, the agent authenticates the blueprint using a
signed JWT client assertion instead of a shared secret. `infra/state/keyvault.bicep`
grants the agent's runtime principal least-privilege **Key Vault Certificate
User** (read public certificate metadata) and **Key Vault Crypto User**
(sign/verify only) roles scoped to only the `w365-blueprint-certificate`
certificate and its backing key objects — not the shared vault as a whole, so
the agent's runtime identity has no standing access to unrelated secrets
(such as the viewer OIDC client secret) also stored there, and never the
roles needed to retrieve the private key or the paired secret. At startup,
`KeyVaultBlueprintCertificateAssertionProvider` reads the public bytes of the
`w365-blueprint-certificate` certificate from `W365_KEY_VAULT_NAME` (the only
key_vault_certificate-mode configuration the agent requires), builds a JWT
client assertion, and signs it by calling Key Vault's `sign` REST API — the
private key is never retrieved, exported, or held in agent process memory.
Certificate metadata is cached in memory for the process lifetime and retried
after a failure; rotating the certificate requires a redeploy so a fresh
process picks up the new key. This mode is agent-only: `Settings.Validate`
rejects it for the viewer.

Provisioning is a two-step, explicitly confirmed process (see
`docs/W365-SETUP.md`): `scripts\Initialize-W365BlueprintCertificate.ps1`
creates or rotates the self-signed, non-exportable certificate in Key Vault,
and `scripts\Register-W365BlueprintCertificate.ps1` registers only its public
bytes as a `keyCredential` on the Foundry Agent ID Blueprint application via
Microsoft Graph (`AgentIdentityBlueprint.AddRemoveCreds.All`, the least
privileged credential-management scope for the blueprint — not tenant-wide
application write), preserving any existing credentials already on the
blueprint. `scripts\Invoke-W365SetupFlow.ps1` also verifies, via a read-only
Graph call, that the exact same certificate is registered exactly once on the
discovered blueprint before proceeding — Key Vault presence alone is not
sufficient. Neither script reads, exports, or transmits private key material.

## Three-stage agent-user tokens

The selected credential mode changes only how the runtime obtains blueprint
T1:

1. **T1:** authenticate the blueprint with either the explicitly approved
   managed-identity FIC, the Key Vault-backed client secret, or the
   Key Vault-backed certificate assertion. The viewer supports the first two
   paths; certificate mode is agent-only.
2. **T2:** the agent identity (`W365_AGENT_ID`, app/client ID) uses T1 as
   `client_assertion` to request the exchange scope.
3. **T3:** the agent identity requests the resource token with
   `grant_type=user_fic`, T1 as `client_assertion`, T2 as
   `user_federated_identity_credential`, and the agent-user ID as `user_id`.

Only T3 is sent to ATG/W365 or ARI. Tokens remain in memory and are cached by
resource/permission purpose with a five-minute refresh margin and serialized
refresh. No token or exchange request/response body is logged.

There is **no DefaultAzureCredential (DAC) or Azure CLI fallback for W365**.
The checked-in deployment default is the explicit `client_secret` mode, with
the secret stored in Key Vault rather than an environment variable. Ordinary
Azure model/state access uses the normal Azure credential path; an `az login`
session is not an alternative W365 identity. No IdentityRM auxiliary token is
sent.

## Stale-state recovery identity

The guarded stale-state command uses the configured blueprint path to exchange
for the deployed agent identity's `https://storage.azure.com/.default` token.
This method is internal and fixed to that one scope. Its one-token credential
rejects any other scope and, when the token is a parseable JWT, requires the
`https://storage.azure.com` audience. Tokens and claims are never printed.

Recovery also compares persisted `OwnerTenantId` and `OwnerObjectId` with the
selected azd environment's `OPERATOR_TENANT_ID` and `OPERATOR_OBJECT_ID` before
breaking a lease. This is an ownership check, not permission to adopt state from
another environment or agent. The mutating process independently resolves the
deployed agent name/version from the selected environment and checks its hosted
sessions; it does not accept a caller assertion that this check already happened.

`client_secret` mode has completed the bounded W365 lifecycle: blueprint T1,
agent-identity T2, agent-user T3, MCP initialization, `StartSession`, readiness
identified by the returned HTTPS `screenShareUrl`, fresh transport/catalog
discovery, and `EndSession`. Optional tools are used only when advertised by
the live catalog.

| Purpose | Scope |
| --- | --- |
| MCP through ATG | `da81128c-e5b5-4f9e-8d89-50d906f107c5/.default` |
| Watch only | `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5/Computer.See` |
| Take control | ARI `Computer.See`, `Computer.Control`, `Computer.Do`, and `Computer.Get` |

## Runtime federation is a blueprint trust

Hosted setup adds a FIC only with both
`-HostedRuntimeIdentityObjectId` and
`-AuthorizeHostedRuntimeFederation`. The hosted subject must exactly match the
existing Foundry agent identity object ID. Viewer federation remains separately
opt-in.

Setup adds a viewer FIC only with both `-ViewerManagedIdentityObjectId` and
`-AuthorizeViewerFederation`. The subject is the **existing UAMI object/principal
ID**, not its client ID; issuer is
`https://login.microsoftonline.com/<tenant>/v2.0` and audience is
`api://AzureADTokenExchange`.

This trust authorizes the UAMI to impersonate the **blueprint**, potentially
including sibling agent identities. It is **not ARI-only**, even though the
viewer normally requests screen-share tokens. An administrator must explicitly
approve this boundary. Use a dedicated blueprint when possible; do not grant
the trust if a shared blueprint or administrator policy disallows it. Leave
the viewer disabled instead; the agent may return unavailable viewer links.
Configure only an approved viewer, and do not run workflows needing human
handoff without a usable approved viewer.

The viewer OIDC client secret is a separate credential for the human sign-in
web app. The shared W365 vault exists even in agent-only deployments. When the
viewer is enabled, ACA retrieves the OIDC and blueprint credentials through
separate secret references in that vault.

## Browser authorization

The viewer does not treat the SDK's `viewOnly` flag as an authorization boundary:
watch requests ask Entra for See-only scope. Control token issuance pauses the
desktop under the same lock used for actions. Validate returned scopes during
live acceptance; never fall back to an overprivileged watch token.

The browser necessarily receives an ARI bearer for the screen-share SDK. A
control token is returned only to the authenticated session owner in a
CSRF-protected, `no-store` response and held in memory. The See-only redirect
passes its short-lived token in the URL fragment to the approved W365 static
viewer; fragments are not sent to the companion viewer server. Tokens are
never stored in localStorage or returned to the model. Previously issued bearer
tokens cannot be revoked by the sample's pause flag. The authorized
operator/browser is trusted, not a hostile competing controller.

## SDK and hosting boundary

The public helper uses blueprint-selected managed identity in an
**activity/autopilot sample**. It does not establish support on ordinary
Responses hosted agents. This implementation instead selects the discovered
hosted agent identity and, when explicitly approved, uses its exact-subject FIC
to authenticate the blueprint with `fmi_path`. This sample does not publish
autopilot and does not require a hiring workflow.

The tested Foundry-hosted managed-identity path acquires the initial assertion,
but Entra rejects using that federated token as another federated credential
with `AADSTS700231`. The explicit client-secret mode proved the downstream
agent-user and W365 path independently. Certificate mode is implemented and
offline-validated but has not completed live tenant acceptance.

The Foundry T1 -> T2 -> T3 flow follows the public helper; narrow raw protocol
handling is retained for the final exchanges with no bodies logged. For
production, use the approved identity SDK when the host offers it (for example,
the applicable Agent 365 SDK / Microsoft.Identity.Web integration), preserving
scope separation and never exposing T1/T2. Preview contracts and offline tests
are not a production compatibility guarantee.

Sources: [Foundry agent identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[agent-user OAuth flow](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow),
[managed identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity),
[W365 auth](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/authentication.md),
[screen sharing](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md).
