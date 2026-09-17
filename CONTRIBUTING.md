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
blueprint, blueprint principal, agent identity, certificate or secret.

Cover process-selected managed identity token paths with fake handlers, with no
DAC/CLI/certificate fallback for W365. Viewer federation must stay opt-in with
explicit administrator approval and documented blueprint/sibling-identity trust,
not an ARI-only claim. Keep Key Vault limited to the viewer's OIDC secret and
reserved Foundry identity variables platform-owned. Add cases for bootstrap 503/
health behavior, missing IDs, parent mismatch and unchanged identity reuse.

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
