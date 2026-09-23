# Authentication

This guide defines the identity and token boundaries used by the hosted agent
and optional viewer. Setup commands belong in
[Windows 365 setup](W365-SETUP.md); deployment sequencing belongs in
[Deployment](DEPLOYMENT.md).

## Identities and activation

| Identity or setting | Meaning |
| --- | --- |
| Human operator | Invokes Foundry and signs in to the viewer. The runtime does not impersonate this user for W365. |
| Foundry hosting credential | Provides ordinary model/project and Blob access. It is separate from W365 token acquisition. |
| `W365_BLUEPRINT_ID` | Foundry-provisioned blueprint app/client ID. |
| `W365_AGENT_OBJECT_ID` | Foundry agent object/principal ID, used for Graph parent validation, Azure RBAC, and an optional FIC subject. |
| `W365_AGENT_ID` | Agent app/client ID resolved from the object ID and used in token exchanges. |
| `W365_AGENT_USER_ID` | Agent-user object ID assigned to the W365 pool. It is an identifier, not a credential. |
| Viewer UAMI | Authenticates the ACA viewer process. |
| Viewer OIDC web app | Authenticates the human operator separately from the W365 identity chain. |

App/client IDs and object/principal IDs are different types even when a service
currently returns the same GUID for both. Never substitute one for the other.

When enabled, all W365 IDs must be valid. `W365_AGENT_OBJECT_ID` is required in
both agent and viewer configuration, separately from the app/client ID in
`W365_AGENT_ID`. The credential mode is selected only by
`W365_BLUEPRINT_CREDENTIAL_MODE`, never by a model or request. An existing azd
environment keeps the mode it already has; the fresh-deployment default does
not migrate it.

`W365_ENABLED=false` is the bootstrap default. Bootstrap starts without W365,
state, model, or viewer credentials; health is available and Responses requests
return a phase-two-required 503. Live W365 requires:

- valid W365 identity IDs;
- private Blob state;
- one explicitly selected blueprint credential mode;
- Foundry, W365, and the viewer Azure identity in the same tenant; and
- the platform-injected `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID` matching
  `W365_BLUEPRINT_ID`.

The human OIDC tenant may differ. Never set reserved Foundry variables
yourself. `SAMPLE_LOCAL_MODE=true` is loopback-only bootstrap/offline; enabled
local W365 is refused.

| `W365_BLUEPRINT_CREDENTIAL_MODE` | Current boundary |
| --- | --- |
| `client_secret` | Explicit legacy opt-in, validated end to end. The shared state-layer Key Vault stores the blueprint secret independently of whether the ACA viewer is enabled. |
| `managed_identity_federation` | Optional hardening path. The tested Foundry-hosted identity could not chain its federated token into the blueprint exchange (`AADSTS700231`). |
| `key_vault_certificate` | Default for fresh/unset deployments. A self-signed, non-exportable Key Vault certificate is shared by the agent and optional viewer; each runtime signs remotely with its own managed identity. The private key never leaves Key Vault. Implemented and offline-validated; live tenant acceptance is still required. |

Modes are explicit and mutually exclusive. A failure never falls back to
another mode, Azure CLI, developer credentials, or an interactive user.

## Blueprint client secret delivery

In `client_secret` mode, the hosted agent receives only
`W365_KEY_VAULT_NAME`. Its runtime principal has **Key Vault Secrets User** on
the shared vault and retrieves `w365-blueprint-client-secret` directly at
startup. The value is cached only in process memory; rotation requires a
redeploy so a new process retrieves the new version.

The viewer uses its own UAMI for Blob access and, in certificate mode, scoped
certificate/key access. It does not share the agent's Azure identity. The
shared vault exists even when the viewer is disabled.

The viewer OIDC web app is secretless. Its federated identity credential trusts
only the deployed viewer UAMI object ID, with issuer
`https://login.microsoftonline.com/<tenant>/v2.0`, subject equal to that object
ID, and audience `api://AzureADTokenExchange`. At authorization-code redemption,
the viewer uses its exact UAMI-bound `ManagedIdentityCredential` to obtain the
client assertion. No OIDC client secret, `DefaultAzureCredential`, Azure CLI
credential, or developer credential is accepted.

The explicit `VIEWER_OIDC_CREDENTIAL_MODE=client_secret` mode is the supported
operator-selected fallback when managed-identity assertion redemption is not
reliable in a tenant. `azd up` provisions `w365-viewer-client-secret` in
Key Vault and the viewer uses it for code redemption. This mode is never
selected automatically and has the normal client-secret rotation and
exfiltration risks; it does not change W365 T1/T2/T3 behavior.

Never place the secret in source, JSON, azd state, logs, documentation, or a
plain hosted-agent environment variable.

## Blueprint certificate delivery

In `key_vault_certificate` mode, the hosted agent receives only
`W365_KEY_VAULT_NAME`. It reads the public bytes of
`w365-blueprint-certificate`, builds a JWT client assertion, and asks Key Vault
to sign it. The private key is non-exportable and is never returned to the
agent process. Certificate metadata is cached only in process memory; rotation
requires a redeploy.

The agent and the viewer each use their own identity and receive **Key Vault
Certificate User** and **Key Vault Crypto User** scoped to that certificate and
its backing key, not to the vault. Neither identity can read unrelated secrets
in the shared vault, including the viewer OIDC secret.

Provisioning has two explicit steps, which `azd up` runs for you:

1. `Initialize-W365BlueprintCertificate.ps1` creates or rotates
   `w365-blueprint-certificate` in Key Vault.
2. `Register-W365BlueprintCertificate.ps1` registers only its public bytes as a
   blueprint `keyCredential` and preserves existing credentials.

Setup verifies that the exact certificate is registered on the discovered
blueprint before any W365 mutation. Key Vault presence alone is insufficient.
Neither script reads, exports, or transmits private key material.

## Three-stage agent-user tokens

The selected mode changes only how the runtime obtains blueprint T1:

1. **T1 — blueprint assertion:** authenticate the blueprint using the approved
   managed-identity FIC, Key Vault-backed client secret, or Key Vault-backed
   certificate assertion.
2. **T2 — agent assertion:** the agent app/client ID uses T1 as
   `client_assertion` to request the exchange scope.
3. **T3 — resource token:** the agent identity uses T1, T2, and
   `W365_AGENT_USER_ID` with `grant_type=user_fic` to request the ATG or ARI
   resource token.

Only T3 is sent to Agent 365/W365. T1 and T2 stay in process memory. Tokens are
cached by resource and permission purpose with bounded refresh; token values
and exchange bodies are never logged.

| Purpose | Scope |
| --- | --- |
| MCP through ATG | `da81128c-e5b5-4f9e-8d89-50d906f107c5/.default` |
| Observe | `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5/Computer.See` |
| Control | ARI `Computer.See`, `Computer.Control`, `Computer.Do`, and `Computer.Get` |

There is no DefaultAzureCredential or Azure CLI fallback for W365. Ordinary
Azure model and Blob access continues to use the normal hosting credential.

## Stale-state recovery identity

The recovery workflow exchanges through the configured blueprint mode for one
fixed `https://storage.azure.com/.default` token. Its credential rejects every
other scope and does not print tokens or claims.

Before breaking a lease, recovery compares persisted owner tenant/object IDs
with `OPERATOR_TENANT_ID` and `OPERATOR_OBJECT_ID`, resolves the deployed agent
name/version from the selected azd environment, and verifies hosted and W365
session state independently. This is authority to repair the selected
environment's state, not to adopt another environment's session.

Use the complete [fail-closed recovery workflow](ARCHITECTURE.md#fail-closed-recovery).

## Runtime federation is a blueprint trust

Hosted-runtime federation requires both:

- `-HostedRuntimeIdentityObjectId` matching the discovered agent object ID; and
- `-AuthorizeHostedRuntimeFederation`.

Viewer federation separately requires:

- `-ViewerManagedIdentityObjectId` containing the viewer UAMI object/principal
  ID, not its client ID; and
- `-AuthorizeViewerFederation`.

Both FICs use the tenant v2.0 issuer and
`api://AzureADTokenExchange` audience. They authorize blueprint
impersonation, potentially including sibling agent identities; they are not
limited to W365 or screen sharing. Use a dedicated blueprint where possible
and do not grant either trust when shared-blueprint or tenant policy disallows
it.

The viewer OIDC credential is unrelated to blueprint federation. It
authenticates the human to the companion viewer only.

## Browser authorization

Observation requests obtain `Computer.See` only. Control token issuance first
pauses the agent under the same state lock used for desktop actions, then
requests the broader control scopes. Do not use the SDK's `viewOnly` flag as
the authorization boundary.

The authenticated browser necessarily receives a short-lived ARI token:

- control tokens are returned in CSRF-protected, `no-store` responses;
- See-only tokens are passed in the URL fragment to the approved W365 static
  viewer, so the fragment is not sent to the companion viewer server;
- tokens remain in browser memory and are not stored in localStorage or
  returned to the model.

Pause cannot revoke an already issued bearer token. The authorized
operator/browser is trusted; it is not treated as a hostile competing
controller.

## SDK and hosting boundary

The public managed-identity helper comes from an activity/autopilot sample and
does not prove support on ordinary Responses hosting. This sample uses the
discovered Foundry agent identity and requires live acceptance for the actual
host.

The tested hosted managed-identity path obtains an initial assertion, but Entra
rejects the chained federation with `AADSTS700231`. The explicit
`client_secret` path validates the downstream T1/T2/T3 and W365 lifecycle
independently. Certificate mode requires separate live acceptance.

For production, use an approved identity SDK when the host provides one while
preserving the same scope separation and never exposing T1 or T2. Preview
contracts and offline tests are not production compatibility guarantees.

Sources: [Foundry agent identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity),
[agent-user OAuth flow](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow),
[managed identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity),
[W365 authentication](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/authentication.md),
and [screen sharing](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md).
