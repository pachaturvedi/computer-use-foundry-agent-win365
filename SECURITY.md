# Security

This preview is a single-operator sample, not a production-ready multi-tenant
computer-use service. Use a dedicated Cloud PC and test accounts with minimum
permissions. Do not point it at a desktop with production credentials/data.

## Boundaries

- Hosted requests require the configured Foundry-injected operator partition.
  This is not safe behind an arbitrary proxy that allows header spoofing.
- The hosted viewer requires single-tenant OIDC and exact human tenant/object
  claims. Opaque links are not bearer authorization.
- Local mode is unauthenticated, restricted to loopback, and unsuitable for
  shared machines, tunnels or public ingress.
- W365 tokens are held in memory, not included in links/model output/logs.
  The authorized browser must receive the ARI token to use the official SDK.
- Blueprint certificates live in encrypted local PFX or Key Vault. The sample
  does not implement non-exportable remote signing or instant token revocation.
- Blob state contains W365 session metadata. Protect it with private access,
  Entra RBAC, TLS, encryption, and an organizational retention policy.
- CSRF protection covers viewer POSTs. CSP uses exact onboarding SDK/frame
  origins. Do not weaken it to permit arbitrary scripts or iframes.

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
