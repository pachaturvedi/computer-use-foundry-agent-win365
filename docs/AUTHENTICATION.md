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
does not require identity, operator, model, state or OIDC configuration, and
does not access W365/model/state credentials. Bootstrap starts before any model
initialization. The agent exposes healthy readiness
and a Responses 503 explaining phase 2; the viewer exposes `/health` and 503
on other routes. `SAMPLE_LOCAL_MODE=true` is loopback-only bootstrap/offline.
Live W365 requires a deployed identity endpoint; enabled local mode is refused.

When enabled, all W365 IDs must be valid. `W365_AGENT_OBJECT_ID` is required
in both agent and viewer configuration, separately from the app/client ID in
`W365_AGENT_ID`. Foundry, W365 and the viewer Azure
identity must be in the same tenant (`W365_TENANT_ID`); the human OIDC tenant
may differ. Foundry must inject `FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID`, matching
`W365_BLUEPRINT_ID`. Never set or override reserved platform variables yourself.
Identity mode is selected by the process (agent or viewer), never by a model,
request argument, page or user-supplied credential. There is no separate
W365-auth mode setting. Active runtime requires shared Blob state;
`FileSessionStore` is only an offline-test helper.

## Three-stage agent-user tokens

`AgentUserTokens.cs` selects one of two deployed authentication paths:

1. **Foundry agent T1:** select `ManagedIdentityCredential` using the blueprint
   client ID and request `api://AzureADTokenExchange/.default` from the
   platform identity endpoint. This is blueprint T1, following the public
   [AgentTokenHelper reference](https://github.com/microsoft-foundry/foundry-samples/blob/main/samples/csharp/foundry-autopilot-agent/src/hello_world_a365_agent/Services/AgentTokenHelper.cs).
2. **Viewer T1:** select its UAMI with `AZURE_CLIENT_ID` (the UAMI's client ID),
   obtain a managed identity exchange token, and authenticate the blueprint
   using the explicitly approved federated identity credential (FIC) and
   `fmi_path` targeting the agent. This produces blueprint T1.
3. **Both processes T2:** the agent identity (`W365_AGENT_ID`, app/client ID)
   uses T1 as `client_assertion` to request the exchange scope.
4. **Both processes T3:** the agent identity requests the resource token with
   `grant_type=user_fic`, T1 as `client_assertion`, T2 as
   `user_federated_identity_credential`, and the agent-user ID as `user_id`.

Only T3 is sent to ATG/W365 or ARI. Tokens remain in memory and are cached by
resource/permission purpose with a five-minute refresh margin and serialized
refresh. No token or exchange request/response body is logged.

There is **no DefaultAzureCredential (DAC), Azure CLI, certificate or secret
fallback for W365**. Ordinary Azure model/state access still uses the normal
Azure credential path; an `az login` session is not an alternative W365 identity.
No IdentityRM auxiliary token is sent.

| Purpose | Scope |
| --- | --- |
| MCP through ATG | `da81128c-e5b5-4f9e-8d89-50d906f107c5/.default` |
| Watch only | `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5/Computer.See` |
| Take control | ARI `Computer.See` plus `Computer.Control` |

## Viewer federation is a blueprint trust

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
web app. ACA retrieves it through a Key Vault secret reference **only when
enabled**. Key Vault is not used for blueprint credentials.

## Browser authorization

The viewer does not treat the SDK's `viewOnly` flag as an authorization boundary:
watch requests ask Entra for See-only scope. Control token issuance pauses the
desktop under the same lock used for actions. Validate returned scopes during
live acceptance; never fall back to an overprivileged watch token.

The browser necessarily receives an ARI bearer for the screen-share SDK. It is
returned only to the authenticated session owner in a CSRF-protected, `no-store`
response, held in memory, and never put in a URL, localStorage or model message.
Previously issued bearer tokens cannot be revoked by the sample's pause flag.
The authorized operator/browser is trusted, not a hostile competing controller.

## SDK and hosting boundary

The public helper uses blueprint-selected managed identity in an
**activity/autopilot sample**. It does not establish support on ordinary
Responses hosted agents. Test the actual hosting endpoint and injected
blueprint identity before claiming support; if unavailable, stop without a
token/secret fallback. This sample does not publish autopilot and does not
require a hiring workflow. No live deployment has been performed for this
implementation.

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
