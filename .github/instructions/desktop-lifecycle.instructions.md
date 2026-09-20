---
applyTo: "src/Win365Agent/Desktop/**/*.cs,src/Win365Agent/Mcp/**/*.cs,src/Win365Shared/State/**/*.cs,src/Win365Agent/Hosting/Desktop*.cs,tests/Win365Agent.Tests/Desktop/**/*.cs,tests/Win365Agent.Tests/Mcp/**/*.cs,tests/Win365Shared.Tests/State/**/*.cs"
---

# Desktop, MCP, and state lifecycle

- Maintain exclusive ownership through the shared session store and lease. Never bypass the store for live execution.
- Persist `RequestId`, owner IDs, phase, operation-in-flight state, and allocation idempotency key before calling state-changing remote tools.
- Retry an ambiguous `StartSession` only with the same persisted idempotency key and only through the authorized recovery path.
- Do not replay ambiguous desktop actions or `EndSession` automatically.
- A W365 session is ready when `GetSessionDetails` returns a valid absolute HTTPS `screenShareUrl`; the observed contract does not include a required `status` field.
- After readiness, establish a fresh MCP transport and list tools again.
- Accept only advertised tools that also pass `DesktopRuntimePolicy`. Never guess a W365 tool schema.
- Supply `sessionId` from durable state only; reject model-provided session fields.
- Keep task, tool-call, screenshot, argument-size, polling, HTTP, and cleanup budgets bounded.
- Viewer links are optional. Missing viewer configuration must not block direct MCP execution.
- A lost or invalid remote result must leave recoverable/blocked state, not clear ownership or report success.
- Cleanup must use an independent bounded token and clear durable state only after successful `EndSession`.
- Tests must cover concurrency, ambiguous start/action/end behavior, idempotency-key reuse, readiness by screen-share URL, reconnect/catalog refresh, expiry, and cleanup.
- Update `docs/ARCHITECTURE.md` when ownership, state shape, readiness, recovery, or cleanup changes.
