# Implementation plan

Approved scope: C#/.NET Foundry hosted agent calling W365 tools directly, with no
native computer-tool model loop. Separately hosted authenticated screen viewer,
W365 setup automation, local and hosted instructions, and offline tests.

- [x] Restore public dependencies and build hosted Responses entry point.
- [x] Implement certificate-backed Agent User auth and MCP transport.
- [x] Implement exclusive session ownership, action bounds and human handoff.
- [x] Implement authenticated viewer with CSRF protection and opaque links.
- [x] Implement safe, idempotent W365 identity/pool setup.
- [x] Document deploy, credentials, costs, cleanup and operational limits.
- [x] Run offline tests, build, local HTTP smoke and configuration checks.
- [ ] Live acceptance (separate authorization required): tenant setup, Foundry
  invoke, real W365 actions, live view, handoff/resume and release.

Release gate: offline validation does not establish live service compatibility.
The recommended model is `gpt.6.astra`; deployment name must be configured.

Local validation covered the token exchange with fake HTTP handlers, setup
creation/reconciliation with a mocked Graph module, MCP/session/observation
tests, loopback startup, viewer CSRF/resume and hosted owner/request gates.
The Bicep template compiled. No actual tenant provisioning, model invocation,
W365 allocation, browser screen sharing, Linux container run or deployment was
performed. Direct nuget.org restore hit an environment TLS failure; the local
restore used the environment's existing package proxy. The shipped NuGet
configuration remains public nuget.org only.
