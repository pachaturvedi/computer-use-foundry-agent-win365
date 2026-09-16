# Contributing

Keep this sample small, understandable and safe for a new tenant.

Use .NET 10 and PowerShell 7.5+. Build and run `dotnet test` from the repository
root. Add fake-handler tests for behavior changes; tests must never acquire
tokens from a real tenant, allocate a Cloud PC, or call a live model by default.
Validate Bicep locally and exercise setup `-WhatIf` without a Graph sign-in.

Preserve the tool allowlist, explicit ownership, independent cleanup, separate
watch/control scopes and blocked-on-ambiguity behavior. Document changes to
permissions, billing, credential requirements and preview service contracts.
Update preview Agent Framework/hosting dependencies together. Do not suppress
NuGet vulnerability/downgrade warnings to force a build.

Never contribute tenant IDs, private endpoints, credentials, session state or
screenshots from real users. The existing [license](LICENSE) governs this repo;
follow the destination organization's contribution/CLA process when publishing.
