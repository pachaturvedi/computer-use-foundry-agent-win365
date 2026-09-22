# Security

This preview is a single-operator sample, not a production-ready multi-tenant
computer-use service. Use a dedicated Cloud PC and test accounts with minimum
permissions. Do not point it at a desktop with production credentials/data.

## Boundaries

- Hosted requests require the configured Foundry-injected operator partition.
  This is not safe behind an arbitrary proxy that allows header spoofing.
- The hosted viewer requires single-tenant OIDC and exact human tenant/object
  claims. Opaque links are not bearer authorization.
- `W365_ENABLED=false` is the default bootstrap: healthy readiness, phase-2 503
  requests, startup before any model initialization and no W365/model/state
  credential access. Viewer bootstrap needs no
  OIDC configuration. The switch accepts only `true` or `false`.
- Local mode is unauthenticated, restricted to loopback and bootstrap/offline
  use, and unsuitable for shared machines, tunnels or public ingress. Enabled
  local W365 is refused; live W365 requires a deployed identity endpoint.
- W365 tokens are held in memory, not included in links/model output/logs.
  The authorized browser must receive the ARI token to use the official SDK.
- W365 reuses Foundry's blueprint and agent identity through one explicitly
  selected credential mode: Key Vault-backed client secret, managed-identity
  federation, or Key Vault certificate. There is no DAC/CLI or cross-mode
  fallback, no logged token-exchange bodies, and no IdentityRM auxiliary token.
  Key Vault can store the blueprint secret or certificate and the separate
  viewer OIDC secret. Agent-user IDs are not credentials.
- Enabled identity IDs must be valid and Foundry/W365/viewer Azure identities
  must share a tenant (the human OIDC tenant can differ). Foundry's injected
  blueprint client ID must match configuration; never set reserved variables
  yourself. Object/principal IDs are not interchangeable with app/client IDs.
- Live runtime requires Blob state; file state is only an offline-test helper.
  Blob state contains W365 session metadata. Protect it with private access,
  Entra RBAC, TLS, encryption, and an organizational retention policy.
- CSRF protection covers viewer POSTs. CSP uses exact onboarding SDK/frame
  origins. Do not weaken it to permit arbitrary scripts or iframes.

## Administrator and hosting trust

Setup must find the exact supplied existing blueprint and agent identity, then
validate the agent parent and any existing agent-user parent before mutations.
Existing grant/inheritance ambiguity is also rejected before writes; setup does
not look up `/me` or take over ownership.
The core setup does not create a blueprint, blueprint principal, or agent
identity. Credential creation or registration is a separate, explicitly
approved workflow. Setup preserves unrelated declarations and consent and
refuses takeover of different inheritance policies. Reusing Foundry identities
does not authorize changing administrator-managed policy.

Inherited blueprint grants may affect sibling agents. Optional viewer federation
trusts an existing UAMI object ID with the tenant v2.0 issuer and
`api://AzureADTokenExchange` audience. This grants **blueprint impersonation,
potentially including sibling identities, not ARI-only access**. Explicit
administrator approval is required; a dedicated blueprint is recommended.
Do not add the FIC if shared-blueprint or tenant policy disallows it. Keep the
viewer disabled instead, recognizing that viewer links/handoff may be unavailable.

The public managed-identity helper is an activity/autopilot reference; ordinary
Responses hosting support must be proven in the actual host. The explicit
client-secret path has completed live validation, managed-identity federation
is blocked on the tested host by `AADSTS700231`, and certificate mode has only
offline validation. Stop on unsupported blueprint selection; never change
credential modes automatically. This sample does not require autopilot
publication or a hiring workflow and is not a production identity guarantee.

Preserve the same agent name across deployments, rediscover the new version's
IDs and reject unexpected identity replacement. For migration, stop tasks and
rebind to the verified Foundry identities; do not automatically delete old
resources or reparent an old agent user. Choose a different correctly bound UPN,
and retire old separate identities/certificates only after checking consumers.
See [setup and migration](docs/W365-SETUP.md).

## Computer-use risks

The harness denies shell, Python and JavaScript-evaluation tools. This does not
prevent a model from using ordinary keyboard/mouse input to launch a terminal,
send a message or perform another dangerous action. Prompt instructions are not
a security boundary. Apply OS/application/network policy, prevent access to
privileged systems, supervise execution and use a restricted Cloud PC.

Treat web pages, documents, accessibility text, screenshots and tool outputs as
untrusted input. They can contain prompt injection or sensitive information.
The model provider necessarily sees tool observations; do not enable content
tracing or run tasks over data you are not authorized to transmit.

The operator must perform sign-in, MFA and sensitive/irreversible operations
through handoff. This instruction is behavioral guidance, not a general-purpose
transaction approval engine. Do not use the sample where code-enforced semantic
approval of every desktop action is required.

Already issued control tokens may remain usable after resume. The authorized
operator/browser is trusted. Session expiry stops new sample actions/tokens but
does not revoke a bearer or prove remote release. Crash recovery requires an
operator; never clear a blocked state/lease without resolving the old session.

## Reporting

Do not publish credentials, tokens, screenshots or exploit details in public
issues. For Microsoft product vulnerabilities, use
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report).
For sample bugs, open an issue with redacted reproduction steps and package
versions. See the current Microsoft reporting policy before disclosure.
