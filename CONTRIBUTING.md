# Contributing

Keep this sample small, understandable and safe for a new tenant.

Use Windows, .NET 10 and PowerShell 7.4+. Run the repository's complete local
validation from the root:

```powershell
pwsh -NoProfile -File .\scripts\Setup-Local.ps1
```

Visual Studio is optional. IDE builds targeting `net10.0` require Visual Studio
2026 version 18.0 or newer. Do not diagnose `MSB4236`, `NETSDK1209`, or an
`Microsoft.NET.Sdk(.Web) could not be found` message as a missing SDK until both
`dotnet --info` and the Visual Studio/MSBuild version have been checked.
The canonical validation command intentionally uses the standalone .NET CLI.
Keep `global.json` on the .NET 10 SDK family; update its baseline only after the
Windows quickstart and CI pass with the new feature band.

Code style is defined in the repository root `.editorconfig` and enforced by
`dotnet format --verify-no-changes`. Keep public APIs PascalCase, interfaces
`I`-prefixed, private instance fields `_camelCase`, and asynchronous methods
suffixed with `Async`.

Keep the application as a small modular monolith. Put code in the existing
feature folders under `src\Win365Agent`: `Configuration`, `Hosting`, `Desktop`,
`Mcp`, `Identity`, `State`, `Responses`, and `Viewer`. Prefer one primary public
type per file, keep `Program.cs` limited to composition, and mirror feature
folders under `tests\Win365Agent.Tests`. Shared test-only handlers and fixtures
belong in `TestInfrastructure`; do not add production abstractions solely for
tests. See the [architecture code map](docs/ARCHITECTURE.md#source-layout).

Add fake-handler tests for behavior changes; tests must never acquire tokens
from a real tenant, allocate a Cloud PC, or call a live model by default.

For azd changes, keep `azure.yaml` aligned with the current official Foundry
hosted-agent schema and preserve its minimum CLI/extension versions. Validate
tooling before authenticated tests:

```powershell
pwsh -NoProfile -File .\scripts\Test-AzdPrerequisites.ps1
azd ai agent doctor --local-only
```

Keep `README.md` as the short entry point. Put detailed cloud deployment steps
in `docs/DEPLOYMENT.md`, W365 tenant changes in `docs/W365-SETUP.md`, and viewer
identity/OIDC steps in `docs/VIEWER.md`. When a command changes, update every
guide that references it and keep Windows PowerShell examples copy/paste ready.
When a code change affects architecture, lifecycle, ownership, cleanup,
authentication, environment variables, or operational behavior, read the
affected docs before editing and update them in the same change. Reflect
component or control-flow changes in `docs/ARCHITECTURE.md`, deployment and
teardown flow changes in `docs/DEPLOYMENT.md`, and W365 or Entra changes in
`docs/W365-SETUP.md`.

Use this documentation impact matrix when changing code:

| If you change... | Update at least... |
| --- | --- |
| Public entry points, setup shortcuts, or quickstart wording | `README.md` |
| Component boundaries, request flow, state ownership, recovery, teardown design, or resource lifecycle | `docs/ARCHITECTURE.md` |
| `azure.yaml`, Bicep, azd workflows, environment variables, deployment modes, provision/deploy/down behavior, or rollback steps | `docs/DEPLOYMENT.md` |
| W365 pool behavior, Intune steps, Entra agent users, Graph permissions, billing confirmations, or tenant cleanup | `docs/W365-SETUP.md` |
| Token exchange, caller binding, permission model, blueprint trust, or identity sourcing | `docs/AUTHENTICATION.md` |
| Viewer deployment, OIDC secrets, federation, screen-sharing, or handoff behavior | `docs/VIEWER.md` |
| Checked-in live validation outcomes or operator-tested status | `docs/VALIDATION-REPORT.md` |

For mixed changes, update every affected guide, not only the most obvious one.
Examples:

- A teardown change usually requires `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, and `docs/W365-SETUP.md`.
- A new environment variable usually requires `README.md` if user-facing and `docs/DEPLOYMENT.md` or `docs/AUTHENTICATION.md` depending on behavior.
- A change to identity or permissions should update both the behavioral guide and the operator workflow guide.

Do not run template initialization inside a repository clone; its checked-in
`azure.yaml` is already the project manifest. Create or select only the local
azd environment with `azd env new` / `azd env select`. Do not rerun template
initialization over an existing `.azure\` environment.
Do not change this existing-project sample to provision a model or use `azd up`
without documenting SKU, quota, cost, region support, and teardown behavior.
Validate Bicep locally and exercise setup `-WhatIf` without a Graph sign-in.

Run the setup/discovery regressions without Azure or Graph sign-in:

```powershell
pwsh -NoProfile -File .\scripts\Test-SetupOffline.ps1
pwsh -NoProfile -File .\scripts\Test-DiscoveryOffline.ps1
```

Both scripts mock their external endpoints and must remain offline. See
[offline setup tests](docs/W365-SETUP.md#offline-setup-tests) for their coverage.
CI invokes the discovery regression as well; preserve that offline coverage.

Preserve two-phase onboarding: default-disabled bootstrap must require no W365,
model/state credential or OIDC access and must start before model initialization;
enabled local desktops must fail closed. Live state requires Blob;
`FileSessionStore` is only an offline-test helper.
Keep discovery read-only and distinguish blueprint/agent app IDs from object
IDs. Setup must validate supplied existing identities and parents before any
mutation, reject existing grant/inheritance ambiguity before writes, preserve
unrelated grants/policies, and never create a separate
blueprint, blueprint principal, or agent identity. Credential creation and
rotation are separate, explicitly authorized authentication-mode operations;
setup must not create them implicitly.

Cover every process-selected authentication mode with fake handlers and prove
there is no automatic fallback. Never use DAC, Azure CLI, developer credentials,
or an interactive user as a hidden W365 credential source. Viewer federation
must stay opt-in with explicit administrator approval and documented
blueprint/sibling-identity trust, not an ARI-only claim. Keep reserved Foundry
identity variables platform-owned. Add cases for bootstrap 503/health behavior,
missing IDs, invalid modes, missing credential material, parent mismatch, and
unchanged identity reuse.

Do not infer ordinary Responses hosting support from the activity/autopilot
reference helper. Record actual authorized live acceptance separately before
claiming compatibility; neither offline tests nor this documentation revision
constitute a live deployment. Do not introduce an autopilot/hiring requirement
as a workaround. See [deployment acceptance](docs/DEPLOYMENT.md#live-acceptance).

Preserve the tool allowlist, explicit ownership, independent cleanup, separate
watch/control scopes and blocked-on-ambiguity behavior. Document changes to
permissions, billing, credential requirements and preview service contracts.
Update preview Agent Framework/hosting dependencies together. Do not suppress
NuGet vulnerability/downgrade warnings to force a build.

Never contribute tenant IDs, private endpoints, credentials, session state or
screenshots from real users. The existing [license](LICENSE) governs this repo;
follow the destination organization's contribution/CLA process when publishing.

## Copilot customization

Repository AI guidance is intentionally modular:

- `.github\copilot-instructions.md` contains short, repository-wide invariants.
- `.github\instructions\*.instructions.md` adds path-specific .NET, identity,
  lifecycle, PowerShell, Azure, and documentation rules.
- `.github\agents\*.agent.md` defines specialist implementation and validation
  agents.
- `.github\prompts\*.prompt.md` provides reusable feature, authentication, and
  validation entry points.

Instruction precedence and routing:

1. The user's explicit request and safety constraints define the task.
2. Repository-wide instructions define invariants that cannot be weakened.
3. Matching path-specific instructions refine those invariants.
4. The selected custom agent defines role, workflow, deliverables, and tools.
5. A prompt file frames a repeatable invocation.
6. Documentation examples are operational guidance, not permission to bypass a
   higher-level safety or ownership rule.

Use `auth-mode-implementer` for credential modes, token providers, FICs, or
identity configuration. Use `w365-implementer` for runtime lifecycle, MCP,
state, hosting, or viewer behavior. Use `validation-reviewer` after
implementation; it is read-only. Use the principal reviewer personas for
independent architecture, engineering, QA, product, and field-readiness reviews.
Use `principal-operations-documentation-engineer` to create Windows-first
runbooks, diagnostic query catalogs, troubleshooting decision trees, evidence
templates, rollback procedures, and administrator handoff documentation.
Use `final-change-gate` before the final proposal for any non-trivial code,
configuration, authentication, lifecycle, deployment, infrastructure, or
operational documentation change. The gate invokes the relevant principal
reviewers, consolidates findings, validates evidence, and returns `READY`,
`READY_WITH_DECLARED_LIMITS`, or `NOT_READY`. This is the default automatic
completion step; implementation agents must not wait for the user to request
it. Only no-file-change responses and clearly trivial typo-only edits with no
behavioral or operational impact are exempt.

Put durable rules in the narrowest applicable instruction file. Put a repeatable
task workflow in a prompt, and use a custom agent only when the task benefits
from a distinct role or tool boundary. Avoid copying the same rule into every
layer: custom agents inherit repository and matching path-specific instructions.

When architecture or repository policy changes, update the appropriate
instruction module in the same pull request. Validate YAML frontmatter, links,
referenced commands, and path globs before merging.

Before implementation, record the initial `git status --short`, identify
pre-existing changes, and trace entry points, callers, registrations,
configuration consumers, tests, scripts, and owning documentation. At
completion, review only the intended changed paths, run `git diff --check`, and
report any checks that could not run.
