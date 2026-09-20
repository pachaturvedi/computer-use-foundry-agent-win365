# Validation report

Validated on Windows through September 18, 2026. Evidence is sanitized: no
secret values, access tokens, assertions, raw caller identifiers, or
environment files are included.

## September 20, 2026 offline change validation

The current branch adds bundled hosted-agent dependency resolution and a
Windows invoice-demo helper. These changes have **offline validation only**:

- `scripts\Validate-PrePr.ps1` completed with a Release build containing
  0 warnings and 0 errors.
- 74 .NET tests passed: 34 agent, 32 shared, and 8 viewer tests.
- 54 PowerShell files parsed and all 19 offline PowerShell tests passed.
- The focused invoice-demo test validates active endpoint selection, fresh
  session/conversation flags, full-GUID filenames, view-only link validation,
  output redaction, exact terminal result markers, and fail-closed recovery
  guidance.
- `azd ai agent doctor --local-only` validated the bundled manifest, and a
  local `linux-x64` framework-dependent publish completed.

No bundled version from this branch has been deployed to Foundry. The invoice
demo has not been run against a live Windows 365 desktop, viewer, or the
external invoice URL. The September 18 live evidence below applies to the
previously deployed versions and must not be interpreted as acceptance of this
branch.

## Current result

The sample is validated end to end with the explicit `client_secret` blueprint
credential mode:

1. Acquire the blueprint assertion (T1).
2. Exchange T1 for the agent assertion (T2).
3. Exchange T1 and T2 for the Agent 365 user token (T3).
4. Initialize the Windows 365 Computer Use MCP connection.
5. Start a desktop session with a persisted idempotency key.
6. Wait for readiness using the returned HTTPS screen-share URL.
7. Reconnect and refresh the ready-session tool catalog.
8. Run the available benign desktop discovery operations.
9. Close the desktop and end the W365 session.

Hosted agent version 15 completed this sequence. `get_screen_size` was skipped
because the ready-session catalog did not advertise that tool; optional tool
absence is handled without failing the lifecycle.

The temporary blueprint client secret used for validation was revoked, removed
from the azd environment, and never written to source or this report. A clean
version 16 was deployed afterward with `managed_identity_federation` restored.

## Scenario results

| Scenario | Result | Evidence |
| --- | --- | --- |
| Greenfield Foundry bootstrap in separate env | Passed | `fawsep18-dev` created with `Initialize-Greenfield.ps1`; staged `Validate`, `ProvisionFoundry`, `azd deploy`, `azd ai agent doctor`, and `azd ai agent show` succeeded on September 18, 2026 |
| Windows setup | Passed | `scripts/Setup-Local.ps1` completed restore, formatting, build, and offline tests |
| Restore and formatting | Passed | `dotnet restore` and `dotnet format --verify-no-changes` |
| Release tests | Passed | 53 passed, 0 failed, 0 skipped |
| PowerShell parsing | Passed | All repository scripts parsed under PowerShell 7.4+ |
| W365 setup regression | Passed | Identity reuse, parent validation, idempotency, federation checks, and manifest preservation |
| W365 teardown regression | Passed | Reverse-order deletion, reused-state restoration, shared-assignment blocking, and idempotent rerun |
| Composed lifecycle regression | Passed | Setup-created ownership manifest drove safe teardown and preserved unrelated state |
| Foundry discovery regression | Passed | Exact-version lookup, tenant binding, missing metadata, and untrusted endpoint rejection |
| Bicep compilation | Passed | Foundry, state, and viewer entry-point templates compile |
| Generated ARM consistency | Passed | `infra/foundry/main.json` regenerated from `main.bicep` |
| azd prerequisites | Passed | Compatible azd and required Foundry extensions detected |
| Foundry project/model | Passed | Existing project and compatible hosted-agent model validated |
| Hosted-agent deployment | Passed | Immutable hosted versions deployed and invoked through the Responses protocol |
| Agent-user identity chain | Passed with client secret | T1, T2, T3, and W365 MCP initialization succeeded |
| W365 desktop lifecycle | Passed with client secret | Start, readiness, catalog refresh, benign discovery, close, and end completed |
| Shared Blob state | Passed | Private state storage and container-scoped data access validated |
| Optional viewer | Not required | Direct MCP operation remains valid without `VIEWER_PUBLIC_URL` |
| Managed-identity federation | Blocked by platform boundary | Chained federation returns Entra `AADSTS700231` |
| Key Vault certificate mode | Not implemented | Reserved mode fails closed until separately implemented and validated |

## Live greenfield bootstrap evidence

Validated on September 18, 2026 in dedicated azd environment `fawsep18-dev`
with W365, state, and viewer still disabled for the bootstrap pass.

Commands and sanitized outcomes:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" -Prefix "fawsep18" -Environment "dev"
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Mode Validate -Environment fawsep18-dev
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 -Mode ProvisionFoundry -Environment fawsep18-dev -ConfirmResourceChanges
azd deploy win365-desktop-agent --no-prompt
azd ai agent doctor --environment fawsep18-dev
azd ai agent show win365-desktop-agent --environment fawsep18-dev
```

Observed results:

- `Initialize-Greenfield.ps1` created azd environment `fawsep18-dev` and
  previewed creation of resource group `fawsep18-dev-foundry-rg`, account
  `fawsep18devaifa4b94`, project `fawsep18-dev-project`, and model deployment
  `gpt-6-astra`.
- `Validate` completed before any hosted-agent version existed.
- `ProvisionFoundry` completed after the Foundry layer serialized child
  resources under the account and granted the bootstrap roles needed for
  subsequent agent deployment.
- `azd deploy win365-desktop-agent --no-prompt` published hosted-agent version
  `1` and returned a Responses endpoint.
- `azd ai agent doctor --environment fawsep18-dev` finished with 11 passed,
  0 failed, and 2 skipped checks.
- `azd ai agent show win365-desktop-agent --environment fawsep18-dev` reported
  status `active`, version `1`, a project endpoint, blueprint principal/client
  IDs, and a Responses endpoint.

## Reliability findings incorporated

- The MCP HTTP timeout is three minutes rather than the original 60 seconds.
- A stable StartSession idempotency key is persisted before allocation and
  reused after ambiguous outcomes.
- Recoverable allocation intent is preserved instead of being converted into
  irreversible recovery state.
- Readiness is based on a valid HTTPS `screenShareUrl`; W365 does not return a
  required `status` field from `GetSessionDetails`.
- MCP reconnects after readiness before refreshing the tool catalog.
- Cleanup no longer masks an already-reported open failure.

## Authentication modes

| Mode | Status |
| --- | --- |
| `client_secret` | Implemented and live E2E validated |
| `managed_identity_federation` | Implemented, but hosted chained federation is blocked by `AADSTS700231` |
| `key_vault_certificate` | Reserved and fail-closed; implementation pending |

`client_secret` proves the complete W365 identity and desktop path, but it is
not the preferred long-lived production credential. Production adoption still
requires an approved certificate-backed or platform-supported federation path.

## Cleanup and current state

- The temporary validation credential was revoked and unset.
- The unsupported extra federated credential created during investigation was
  removed; the Foundry-managed credential remains intact.
- Managed-identity mode was restored for the clean post-validation deployment.
- No viewer or App Service resources were required for direct MCP validation.
- W365 and Entra teardown is ownership-manifest-driven and fails closed for
  missing ownership proof, shared assignments, identity drift, or provider
  failures.

## Reproduce offline validation

```powershell
dotnet restore .\Win365FoundrySample.slnx
dotnet format .\Win365FoundrySample.slnx --verify-no-changes --no-restore --verbosity minimal
dotnet test .\Win365FoundrySample.slnx -c Release --no-restore

pwsh -NoProfile -File .\tests\PowerShell\Test-SetupOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-RemoveW365ResourcesOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-W365TeardownFlowOffline.ps1
pwsh -NoProfile -File .\tests\PowerShell\Test-DiscoveryOffline.ps1
```

These commands do not authenticate to Microsoft Graph, allocate a Cloud PC, or
mutate Azure, Foundry, W365, or Entra resources.
