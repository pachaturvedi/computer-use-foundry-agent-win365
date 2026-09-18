# Repository instructions

## Purpose and architecture

- This is a Windows-first .NET 10 sample in which one Microsoft Foundry hosted Responses agent calls Windows 365 Computer Use tools through Agent 365 MCP.
- Keep the application a modular monolith under `src/Win365Agent`; mirror feature folders under `tests/Win365Agent.Tests`.
- Keep `Program.cs` as a composition root. Reuse existing configuration, identity, MCP, state, desktop, hosting, responses, and viewer abstractions.
- The optional viewer is separate from direct W365 execution. Do not make `VIEWER_PUBLIC_URL` mandatory for agent-only operation.

## Working rules

- Inspect the relevant implementation, tests, and documentation before editing.
- Before editing, inspect `git status --short` and the relevant diff so unrelated user changes are preserved.
- Trace the entry point, callers, dependency registration, configuration consumers, mirrored tests, scripts, and owning documentation for the requested behavior.
- Define the user-visible outcome, measurable acceptance criteria, in-scope files, and explicitly out-of-scope behavior before implementation.
- Make surgical changes and preserve unrelated worktree changes.
- Prefer existing helpers and patterns. Do not duplicate token exchange, MCP parsing, state ownership, or validation logic.
- Preserve type safety, cancellation propagation, structured logging, and fail-closed behavior.
- Do not add packages or infrastructure unless the task requires them.
- Do not initialize a new azd project inside this repository; `azure.yaml` already exists.
- Use Windows PowerShell examples and repository-relative Windows paths in user-facing instructions.

## Security and identity invariants

- Never log, print, commit, or return credentials, OAuth assertions, bearer tokens, raw session IDs, private state, or unredacted session links.
- Authentication mode is selected only by `W365_BLUEPRINT_CREDENTIAL_MODE`; never select it from model or request input.
- Never fall back automatically between `managed_identity_federation`, `client_secret`, and `key_vault_certificate`.
- `client_secret` is implemented for explicitly configured validation scenarios.
- `managed_identity_federation` remains selectable but the tested Foundry host is blocked by Entra `AADSTS700231`.
- `key_vault_certificate` must fail closed until its complete retrieval, signing, deployment, and test path is implemented.
- T1 is credential-mode specific. T2 and T3 remain shared, and only the agent-user T3 token is sent to W365.

## W365 lifecycle invariants

- Persist ownership and a stable idempotency key before `StartSession`.
- Reuse the same key after an ambiguous start; never allocate a replacement automatically.
- Treat a valid HTTPS `screenShareUrl` from `GetSessionDetails` as readiness. Do not require a nonexistent `status` field.
- Reconnect MCP after readiness before refreshing session-scoped tools.
- Use only tools advertised by the live catalog and allowed by policy. Never invent tool names or schemas.
- Inject session identifiers in the harness; never accept them from the model.
- Preserve operation-in-flight state before remote mutations.
- Unknown remote outcomes require recovery and must not be reported as success.
- Always perform bounded cleanup and call `EndSession` when a session ID is known.

## Validation

- Run the smallest tests that cover the change, then escalate when needed.
- By default, after implementing any non-trivial repository change and before
  presenting the final response, invoke `final-change-gate`. Do this
  automatically without waiting for the user to request a review.
- The only exemptions are responses that change no files and clearly trivial
  typo-only edits with no behavioral, command, configuration, security, test,
  deployment, or operational impact.
- Provide the gate with the user outcome, acceptance criteria, intended changed
  paths, known pre-existing worktree changes, commands run, and validation
  evidence. Resolve every blocker and required finding, then rerun the gate.
- Do not claim completion when the gate decision is `NOT_READY`. Include
  `READY_WITH_DECLARED_LIMITS` limitations explicitly in the final response.
- Canonical full local validation:

  ```powershell
  pwsh -NoProfile -File .\scripts\Setup-Local.ps1
  ```

- Focused .NET validation:

  ```powershell
  dotnet build .\Win365FoundrySample.slnx --configuration Release
  dotnet test .\tests\Win365Agent.Tests\Win365Agent.Tests.csproj --configuration Release --no-build
  dotnet format .\Win365FoundrySample.slnx --verify-no-changes --no-restore --verbosity minimal
  ```

- Azure changes require available Azure tooling and applicable Azure guidance before resource mutation. If required tooling is unavailable, stop before mutation and report the missing prerequisite.
- If the required SDK, PowerShell version, azd extension, authentication, or external capacity is unavailable, preserve the worktree and report checks that could not run instead of substituting weaker evidence.
- Offline tests must not contact a tenant, model, Microsoft Graph, or W365.
- Never claim live acceptance from builds or mocks; record actual live evidence separately.

## Documentation

- Update documentation in the same change when behavior, commands, configuration, authentication, ownership, recovery, cleanup, or deployment changes.
- Keep `README.md` task-oriented.
- Use `docs/DEPLOYMENT.md` for azd/deployment behavior, `docs/W365-SETUP.md` for W365/Entra setup, `docs/AUTHENTICATION.md` for identity/token behavior, `docs/ARCHITECTURE.md` for lifecycle/state design, and `docs/VIEWER.md` for viewer/handoff behavior.
- If no documentation change is required, state why in the final response.
