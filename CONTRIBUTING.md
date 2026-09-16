# Contributing

Keep this sample small, understandable and safe for a new tenant.

Use .NET 10 and PowerShell 7.5+. Build and run `dotnet test` from the repository
root. Add fake-handler tests for behavior changes; tests must never acquire
tokens from a real tenant, allocate a Cloud PC, or call a live model by default.
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
