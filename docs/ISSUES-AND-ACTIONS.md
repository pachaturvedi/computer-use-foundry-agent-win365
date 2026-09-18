# Validation issues and incorporated actions

This register summarizes issues encountered during Windows, Foundry, and
Windows 365 validation through September 18, 2026. It distinguishes resolved
sample defects from external platform constraints and deferred work.

| Issue | Root cause | Incorporated action | Current status |
| --- | --- | --- | --- |
| Older Visual Studio/MSBuild could not resolve .NET 10 SDK targets | The IDE toolset did not support the repository SDK | Added `global.json`, CLI-first Windows setup, and explicit diagnostics | Resolved with standalone .NET SDK 10.0.401 |
| Restore inherited disabled or unreachable NuGet sources | Parent configuration and managed-workstation TLS behavior affected `nuget.org` | Added repository-scoped source configuration and deterministic setup checks | Restore and build pass |
| An older azd executable appeared first on `PATH` | Machine-wide installation preceded the supported user installation | Prerequisite script discovers a compatible azd and prints the Windows `PATH` correction | Resolved; compatible azd and Foundry extensions validate |
| Template initialization produced an overlapping directory | Initialization was run inside an existing clone | Documentation separates existing-clone setup from empty-directory initialization | Resolved |
| Foundry management-plane access returned 403 | Subscription Owner does not imply Foundry data-plane access | Documented least-privilege Foundry project role assignment | Resolved after RBAC propagation |
| Existing project had no compatible model deployment | Agent hosting requires an explicit compatible deployment | Added model configuration and exact deployment-name validation | Resolved |
| Fixed resource names prevented reuse | Storage and registry names have stricter global naming rules | Prefix-based deterministic names, service-safe normalization, truncation, and suffixing | Resolved |
| Foundry layer rejected a root path | azd infrastructure layers require project-relative child paths | Added the dedicated `infra/foundry` entry point | Resolved |
| Combined layered preview failed | azd previews infrastructure layers independently | Documented and scripted per-layer preview | Resolved |
| Conditional Bicep modules emitted nullability warnings | Conditional module outputs require guarded non-null references | Added guarded output expressions and compiled all entry points | Resolved |
| Managed workstation could not open WAM from the embedded terminal | Interactive Graph authentication lacked a parent window handle | Added and documented device-code authentication | Resolved operator path |
| Azure CLI and azd used different cached contexts | The tools maintain independent authentication state | Added explicit tenant/subscription validation and safe azd-based workflows | Documented; operators must keep contexts aligned |
| Viewer preview exceeded the Container Apps environment quota | The subscription had no remaining managed-environment capacity | Viewer remains explicitly opt-in and no unrelated environment is reused | External quota action required before viewer deployment |
| Foundry invocation added conversation state | The sample permits only fresh foreground requests | Used a minimal Responses request for live validation | Resolved |
| Blueprint client ID was treated as an available managed identity | A client ID alone is not a managed identity available to the hosted process | Added explicit credential modes and mode-specific token acquisition | Resolved in code |
| Hosted managed-identity federation returned HTTP 401 | The blueprint lacked an exact trust for the hosted identity | Tested a narrowly scoped federated credential | Investigation advanced to the definitive Entra boundary |
| Chained federation failed with `AADSTS700231` | Entra does not allow a token obtained through federation to be reused as another federated assertion | Removed the temporary federated credential; retained fail-closed diagnostics | External platform constraint remains |
| Initial client-secret call returned `AADSTS7000215` | Newly created credential had not propagated | Added bounded propagation waits and credential read-back checks | Resolved; secret flow later passed |
| StartSession exceeded the original 60-second HTTP timeout | W365 allocation can take longer than a normal request timeout | Increased MCP timeout to three minutes | Resolved |
| Ambiguous StartSession consumed the only pool slot | The remote allocation could succeed after the local request timed out | Persist and reuse a stable idempotency key before allocation | Resolved |
| Resume cleanup masked the original tool failure | Recoverable allocation intent was treated as an unrecoverable owned session | Preserve recoverable state and avoid throwing from failure cleanup | Resolved |
| Readiness waited for a `status` property that W365 did not return | `GetSessionDetails` returned session metadata and `screenShareUrl`, but no required status | Treat a valid HTTPS screen-share URL as readiness | Resolved |
| Ready-session tools were not visible on the original MCP connection | Tool availability changes after session readiness | Reconnect MCP and refresh the catalog after readiness | Resolved |
| `get_screen_size` was unavailable | The ready catalog exposed lifecycle tools but not that optional operation | Skip absent optional tools rather than failing the lifecycle | Resolved |
| Setup reruns overwrote cleanup restore baselines | The ownership manifest initially refreshed already-mutated shared state | Preserve original baselines and record exact setup-added permissions | Resolved with regression coverage |
| Teardown could target a pool with unrelated assignments | Pool ownership alone did not prove all assignments were sample-owned | Block cleanup before mutation when unexpected assignments exist | Resolved with regression coverage |
| Graph lookup failures could look like absence | Broad error handling treated provider failures as a missing pool | Only treat an explicit not-found response as absence; rethrow other failures | Resolved |
| Legacy W365 environments may lack an ownership manifest | Older deployments did not record creation/reuse dispositions | Fail closed rather than guessing ownership | Intentional safety limitation; manual reconciliation required |

## End-to-end result

The explicit `client_secret` mode proved the complete hosted chain:

- blueprint assertion;
- agent assertion;
- Agent 365 user token;
- W365 MCP initialization;
- session allocation and readiness;
- ready-session catalog refresh;
- benign desktop discovery;
- desktop close and session end.

The temporary credential was revoked and removed after validation. The clean
post-validation deployment uses `managed_identity_federation`, which remains
blocked at the documented Entra chained-federation boundary. The reserved
`key_vault_certificate` mode remains fail-closed until implemented.

## Deferred work

1. Implement and validate Key Vault certificate authentication only after its
   trust, rotation, and operator model are approved.
2. Revalidate managed-identity federation if Foundry or Entra introduces a
   supported non-chained assertion path.
3. Deploy the optional viewer only after quota and resource-change approval.
4. Reconcile or recreate legacy environments before teardown if they predate
   ownership-manifest recording.
