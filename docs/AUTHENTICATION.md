# Authentication

| Identity | Purpose |
| --- | --- |
| Human operator | Invokes Foundry and signs in to the viewer. Not impersonated for W365. |
| Foundry hosting identity | Model access, Key Vault certificate read and Blob access. |
| W365 blueprint / agent identity / agent user | W365 actions and screen sharing. The agent user is the pool assignee. |
| Viewer web app / managed identity | OIDC human sign-in; Key Vault and Blob access from ACA. |

`AgentUserTokens.cs` implements the documented thin three-stage user-FIC flow:

1. Blueprint authenticates with a short-lived certificate-signed assertion and
   requests T1 with `fmi_path=<agent-id>` and `api://AzureADTokenExchange/.default`.
2. Agent identity requests T2 with T1 as `client_assertion` and the exchange scope.
3. Agent identity requests a resource token with `grant_type=user_fic`, T1 as
   `client_assertion`, T2 as `user_federated_identity_credential`, and the agent
   user's object ID as `user_id`.

Only step 3's token is sent to W365. Tokens are cached by resource/permission
purpose with a five-minute refresh margin and serialized refresh.

| Purpose | Scope |
| --- | --- |
| MCP through ATG | `da81128c-e5b5-4f9e-8d89-50d906f107c5/.default` |
| Watch only | `90ecec28-f5a6-42b3-9bde-dae1ca98f8b5/Computer.See` |
| Take control | ARI `Computer.See` plus `Computer.Control` |

The viewer does not treat the SDK's `viewOnly` flag as an authorization boundary:
watch requests ask Entra for See-only scope. Control token issuance pauses the
desktop under the same lock used for actions. Validate returned scopes during
live acceptance; never fall back to an overprivileged watch token.

The browser necessarily receives an ARI bearer for the screen-share SDK. It is
returned only to the authenticated session owner in a CSRF-protected, `no-store`
response, held in memory, and never put in a URL, localStorage or model message.
Previously issued bearer tokens cannot be revoked by the sample's pause flag.
The authorized operator/browser is trusted, not a hostile competing controller.

## Avoiding the blueprint secret

**No blueprint client secret is created or accepted.** Local development uses an
encrypted RSA PFX. Hosted processes retrieve the certificate's backing secret
from Key Vault through Azure credentials and load its private key ephemerally.
Register the matching public certificate on the blueprint.

Use an exportable RSA Key Vault certificate with a base64 PKCS#12/PFX backing
secret. Its backing PFX is passwordless; do not carry the local PFX password into
hosted configuration. Both hosted identities need secret read access. Rotate the
certificate and register the new public certificate before switching versions.

Entra recommends managed identity federation when supported. Foundry model/project
credentials do not automatically prove that a same-tenant UAMI token endpoint for
AzureADTokenExchange exists. This sample does not assume one; a certificate is the
explicit alternative. Key Vault protects storage but is not a non-exportable
remote-signing implementation.

The viewer OIDC client secret is a **separate credential** for the human sign-in
web app, not the W365 blueprint. ACA retrieves it from a Key Vault secret reference.

## SDK boundary

Microsoft recommends Agent 365 SDK / Microsoft.Identity.Web integration for
production identity handling. This sample illustrates the thin protocol boundary
explicitly. Replace `IAgentUserTokens` with the applicable SDK-backed provider
when adopting that integration; preserve scope separation and never expose T1/T2.

No IdentityRM auxiliary token is sent. The public W365 contract uses an agent-user
Authorization bearer for ATG and a separate ARI bearer for the viewer.

Sources: [W365 auth](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/authentication.md),
[user-FIC](https://learn.microsoft.com/entra/agent-id/agent-user-oauth-flow),
[credentials](https://learn.microsoft.com/entra/agent-id/create-blueprint),
[screen sharing](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md).
