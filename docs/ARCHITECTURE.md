# Architecture and code map

## Request path

`W365_ENABLED` defaults to `false` and is strictly `true`/`false`. Bootstrap
serves Foundry Responses with a phase-2-required 503 and healthy readiness,
starting before any model initialization and without accessing W365, model or
state credentials. Viewer bootstrap has
`/health` and 503 routes, requiring no OIDC configuration. Local mode is
loopback-only bootstrap/offline; enabled local desktop execution is refused.

After phase 2 enables W365, `Program.cs` constructs an `AIProjectClient.AsAIAgent`
with ordinary function tools, and registers the public hosting SDK's `AddFoundryResponses` /
`MapFoundryResponses` ASP.NET Core integration. The model calls:

| Function | Harness behavior |
| --- | --- |
| `open_desktop` | Initialize MCP, lock the shared slot, allocate once, persist identity, poll Ready, rediscover tools, return opaque viewer links. |
| `list_desktop_tools` | Return only allowlisted tool names and their live schemas. |
| `desktop_action` | Validate tool/arguments/ownership, wait if paused, persist in-flight marker, call W365 once, return text/image observations. |
| `request_human_control` | Persist Paused and return control link. |
| `wait_for_human` | Await explicit viewer resume without issuing W365 actions. |
| `close_desktop` | End W365 session and clear the durable slot only after acceptance. |

The generic `desktop_action` wrapper preserves W365's actual tool names and input
shapes rather than maintaining guessed hand-written schemas. It is still a
direct W365 function-tool agent, not a nested computer-use planner.
`AllowedTools` is a static allowlist; the live catalog must also contain the name.
Session lifecycle identifiers are supplied by the harness, never the model.
`execute_shell_command`, `execute_python_code` and `browser_eval_js` are excluded.
Pixel input can still launch powerful applications: an allowlist is not a desktop
sandbox or a guarantee that the model follows safety instructions.

## Session ownership and lifetime

Live deployed agent/viewer state uses one slot in a private shared Azure Blob.
`FileSessionStore` is an offline-test helper only; live runtime requires Blob,
with no active local-file backend. The record includes random link ID, task ID, human owner IDs,
W365 session/link, deadline, phase and in-flight marker. It contains sensitive
session metadata, but not OAuth tokens.

The lock covers ownership checks, in-flight persistence, the remote operation and
result persistence. The viewer uses that exact lock for pause/resume/token issuance.
Therefore a control token is not minted between an action's ownership check and
its execution. Each request gets a server-generated task ID; overlapping requests
cannot adopt another task's desktop, even for the same operator.
After closing, the same task cannot allocate a second desktop.

Graph setup IDs, MCP transport-session ID, W365 desktop-session ID, hosted user
partition, task ID and viewer link ID are distinct identifiers.

Normal cleanup runs on explicit close and in request `finally`, with an independent
75-second cleanup timeout. A task is limited to ten minutes. A crash may prevent
EndSession; the system does not claim exactly-once remote effects. Unknown results
remain blocked instead of replaying actions or allocating a replacement desktop.

## Identity ownership

Phase 1 lets Foundry provision the blueprint and agent identity. Read-only
discovery returns `blueprint.client_id` (blueprint app ID) and
`instance_identity.principal_id` (agent object ID). Phase 2 validates the existing
parents and existing grant/inheritance ambiguity before mutations, resolves the agent app ID, and reconciles W365 grants,
inheritance, agent user and pool assignment without creating separate identities.
Use the same Foundry agent name for new versions and reject unexpected identity
replacement after rediscovery.

The process selects `AgentUserTokens` mode, not the model; there is no separate
W365-auth mode setting. Foundry selects
the platform-injected blueprint client ID for `ManagedIdentityCredential` T1;
the viewer selects its UAMI and uses an explicitly approved blueprint FIC with
agent `fmi_path` for T1. Both then exchange T1 -> T2 -> user-FIC T3 for ATG/ARI.
No DAC/CLI/certificate fallback or IdentityRM auxiliary token is used. Model/state
access uses ordinary Azure credentials. See [authentication](AUTHENTICATION.md)
for same-tenant requirements and token boundaries.

Blueprint inherited grants and optional viewer federation may affect sibling
agents. The FIC grants blueprint impersonation, not ARI-only access. Shared
blueprints need explicit administrator approval; the viewer can stay disabled.
The public token helper is an activity/autopilot reference: ordinary Responses
hosting support requires actual live acceptance, with no fallback if unsupported.
This sample neither publishes autopilot nor requires a hiring workflow.

## Fail-closed recovery

A Blob transaction uses an infinite lease so a process crash cannot allow another
worker to execute concurrently with an operation of unknown status. This is an
intentional availability tradeoff. It needs an operator:

1. Stop/drain the old hosted worker and viewer. Ensure neither can execute again.
2. Inspect the private state Blob. End the known W365 session through the
   authorized W365 service, or establish that it was reclaimed. If StartSession's
   response was lost, inspect pool/session diagnostics with W365 support.
3. Only after remote ownership is resolved, break the stale Blob lease (if any)
   and clear the Blob slot to JSON `null`.
4. Restart and submit a fresh task. Never replay an uncertain desktop action.

Do not automatically clear an expired slot: expiry is not evidence that the
remote operation or screen-share connection ended. W365 idle reclamation is a
fallback, not the sample's correctness mechanism. Active screen sharing may
keep a remote session alive; verify release with W365.

## Bounded observations

The server caps each MCP response at 4 MiB and never automatically retries action
POSTs. JSON and SSE are supported with matching response IDs and negotiated MCP
version; empty initialized notifications are accepted. No general streaming
subscription/resumption client is implemented.

`Observations.cs` returns real `DataContent` image objects, not base64 text.
Screenshots become JPEGs with maximum dimension 1280 and maximum encoded size
128 KiB; four screenshots per task are allowed. Original/resized dimensions are
included so the model can map click coordinates. Oversize images fail explicitly.
Each textual observation is limited to 16000 characters; at most 40 desktop
action calls are allowed. Prefer accessibility observations.

`FreshTaskSessionStore` deliberately does not persist model history. New tasks
create new Agent Framework sessions, avoiding cross-request image accumulation.
This uses the SDK's public but experimental `AgentSessionStore` extension point:
only diagnostic `MAAI001` at that inheritance boundary is acknowledged locally.
No dependency-vulnerability or downgrade warnings are suppressed.

## Source files

| File | Responsibility |
| --- | --- |
| `Settings.cs`, `Program.cs`, `ResponseRequest.cs` | Configuration, hosted owner gate, 64 KiB fresh-request validation, tools, cleanup. |
| `AgentUserTokens.cs` | Process-selected Foundry blueprint / viewer UAMI federation, three-stage user-FIC and resource-scoped token cache. |
| `McpConnection.cs` | MCP handshake/catalog/call transport; safe errors, no action replay. |
| `SessionStore.cs` | Shared Blob leases for live runtime; `FileSessionStore` only for offline tests. |
| `DesktopRuntime.cs` | Desktop lifecycle, ownership, tool allowlist, pause and resume. |
| `Observations.cs`, `FreshTaskSessionStore.cs` | Bounded image handling and fresh task history. |
| `Viewer.cs`, `wwwroot` | OIDC owner authorization, CSRF, CSP, SDK integration. |
| `scripts/Get-FoundryIdentity.ps1` | Read-only discovery of the deployed version's blueprint client ID and agent principal ID. |
| `scripts/Setup-W365.ps1` | Offline `-WhatIf` / explicit reconciliation against existing Foundry identities, optional approved viewer FIC. |
