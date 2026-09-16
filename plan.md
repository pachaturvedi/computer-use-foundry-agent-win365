# Implementation plan

Approved scope: C#/.NET Foundry hosted agent calling W365 tools directly, with no
native computer-tool model loop. Separately hosted authenticated screen viewer,
W365 setup automation, local and hosted instructions, and offline tests.

- [x] Restore public dependencies and build hosted Responses entry point.
- [x] Implement Foundry-provided blueprint authentication and agent-user MCP transport.
- [x] Implement exclusive session ownership, action bounds and human handoff.
- [x] Implement authenticated viewer with CSRF protection and opaque links.
- [x] Implement safe, idempotent W365 user/pool setup using existing Foundry identities.
- [x] Document deploy, credentials, costs, cleanup and operational limits.
- [x] Run offline tests, build, local HTTP smoke and configuration checks.
- [ ] Live acceptance (separate authorization required): tenant setup, Foundry
  invoke, real W365 actions, live view, handoff/resume and release.

Release gate: offline validation does not establish live service compatibility.
The recommended model is `gpt.6.astra`; deployment name must be configured.

Local validation covered the token exchange with fake HTTP handlers, setup
reconciliation with a mocked Graph module, MCP/session/observation tests and
loopback bootstrap startup without W365/model credentials. Viewer CSRF/resume
and hosted owner/request guards were covered in the preceding implementation.
The Bicep template compiled. No actual tenant provisioning, model invocation,
W365 allocation, browser screen sharing, Linux container run or deployment was
performed. Direct nuget.org restore hit an environment TLS failure; the local
restore used the environment's existing package proxy. The shipped NuGet
configuration remains public nuget.org only.

## Two-phase identity migration

- [x] Phase 1 defaults to `W365_ENABLED=false`; bootstrap starts without W365 IDs,
  credentials, state access, OIDC or model initialization and refuses task requests.
- [x] Read deployed version metadata through `Get-FoundryIdentity.ps1` without
  creating resources; distinguish blueprint client ID and agent principal ID.
- [x] Phase 2 validates the complete existing identity chain before mutations.
  Never create a replacement blueprint, blueprint principal or agent identity.
- [x] Create/reuse only the associated agent user, configure consent/inheritance,
  and assign the user to an existing W365 pool.
- [x] Replace certificate credentials with the Foundry identity endpoint; support
  separately approved viewer-UAMI federation to the same blueprint.
- [x] Remove certificate provisioning, configuration and the Key Vault certificate
  client dependency. Key Vault remains only for the viewer OIDC web-app secret.
- [x] Exercise reuse, parent mismatch, inherited-policy mismatch, distinct IDs,
  optional federation, discovery, configuration guards and both token paths offline.
- [x] Update and reconcile all public guides with the final two-phase contract.

No live Foundry/W365 compatibility is implied. The public Foundry token helper
reference is an activity/autopilot sample: confirm blueprint identity-endpoint
selection on ordinary hosted Responses agents before publication. There is no
certificate, secret or developer-user fallback if the host does not support it.
Live local desktop access is no longer supported; local execution is bootstrap
and offline development only. No actual Azure/Entra/W365 changes were performed.
