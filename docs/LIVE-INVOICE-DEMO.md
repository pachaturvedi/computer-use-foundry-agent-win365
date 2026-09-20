# Live invoice-processing demo

This is the repeatable Windows workflow for demonstrating the deployed
Microsoft Foundry hosted agent, Windows 365 desktop interaction, authenticated
live viewing, Notepad output, and bounded cleanup. It does not provision or
migrate Azure or Blob infrastructure. It does create a Foundry session, allocate
or reuse a Windows 365 desktop through the agent, and modify that desktop.

## Expected outcome

One command:

1. resolves the selected azd environment;
2. verifies the exact active hosted-agent name, immutable version, and Foundry
   Responses endpoint;
3. creates a fresh agent session and conversation;
4. generates a unique Notepad filename from a local run GUID;
5. asks the agent to read the invoice visually in Edge;
6. opens the authenticated viewer in observation-only mode;
7. waits for the agent to save and verify the Notepad summary;
8. requires an explicit success or failure marker; and
9. relies on the agent runtime to close and end the Windows 365 session.

The basic scenario requires no human desktop control. The operator may need to
complete normal Entra sign-in when the browser has no valid viewer login. That
sign-in authenticates the observer; it is not an agent handoff or permission to
take control of the Cloud PC.

## Prerequisites

From Windows PowerShell 7.4 or later at the repository root:

- complete the [live-acceptance checks](DEPLOYMENT.md#live-acceptance);
- deploy an active `win365-desktop-agent` version;
- set `W365_ENABLED=true`;
- configure and enable the authenticated viewer with
  `VIEWER_LIVE_ENABLED=true`;
- configure `VIEWER_PUBLIC_URL` to the companion viewer HTTPS origin;
- authenticate `azd` to the intended tenant and subscription; and
- ensure the configured Windows 365 pool has capacity for one desktop.

Check the selected environment without exposing secrets:

```powershell
$environment = "<resource-prefix>-dev"
azd ai agent show win365-desktop-agent `
    --environment $environment `
    --output json
```

Confirm that the result names `win365-desktop-agent`, reports `status` as
`active`, and includes a Responses endpoint. Do not copy endpoint JSON into
logs or issues because hosted metadata can include sensitive configuration
names and identifiers.

## Recommended helper workflow

Run:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-InvoiceProcessingDemo.ps1 `
    -Environment "<resource-prefix>-dev"
```

The helper performs these phases.

### 1. Resolve the supported CLI and environment

The script uses the repository's azd resolver and requires azd 1.32.0 or later.
It sets `AZURE_DEV_USER_AGENT=microsoft_foundry_skill` only for the child
process and restores the previous value afterward.

The script reads these values from the selected environment:

- `W365_ENABLED`
- `VIEWER_LIVE_ENABLED`
- `VIEWER_PUBLIC_URL`
- `AGENT_WIN365_DESKTOP_AGENT_VERSION`

It stops before invoking when W365 or the live viewer is disabled.

### 2. Verify the deployed target

The helper calls `azd ai agent show` for the named service and selected
environment. It requires:

- exact agent name `win365-desktop-agent`;
- exact version matching `AGENT_WIN365_DESKTOP_AGENT_VERSION`;
- `active` deployment status;
- an HTTPS endpoint under `*.services.ai.azure.com`;
- the named agent's `/protocols/openai/responses` path; and
- `api-version=v1`.

The helper then invokes by service name, environment, and immutable version. It
does not accept or construct an arbitrary invocation endpoint.

### 3. Generate the task

The helper creates a local GUID and uses:

```text
Invoice-Processing-Summary-<32-character-guid>.txt
```

The suffix is a newly generated full local GUID without separators. It is not the
Foundry session ID, W365 session ID, viewer lookup ID, or conversation ID.
Repeated runs therefore use different filenames without exposing or depending
on service identifiers.

The script loads `samples\prompts\invoice-processing.txt` and replaces only:

- `{{INVOICE_URI}}`
- `{{OUTPUT_FILE_NAME}}`

The prompt retains the complete scenario: Edge navigation, visual invoice
reading, all invoice fields and line items, Notepad creation, exact save name,
save verification, desktop cleanup, and final result reporting.

### 4. Start a clean foreground run

The invocation is pinned to the verified version and uses:

```text
--new-session
--new-conversation
--timeout 1200
```

The helper remains attached until the request completes. It does not use
`--long-running --no-wait`.

For environments that require hosted caller partitioning, add:

```powershell
-UserIdentity "<caller-partition>"
```

This is the opaque Foundry caller partition, not an Entra object ID and not the
Windows 365 agent-user ID.

### 5. Observe without taking control

When the agent returns the companion viewer's authenticated
`/live/<opaque-id>` URL, the helper validates that it belongs to the configured
viewer origin and opens it in the default browser. It never opens the
`/view/<opaque-id>#control` route.

If prompted, sign in to the viewer using the configured operator account. Do
not click **Pause and take control** during this basic scenario. The agent
prompt explicitly forbids requesting handoff and reports failure instead of
waiting for an operator.

Use `-SkipOpenViewer` for unattended validation that should detect but not open
the live link.

### 6. Require explicit completion

The agent must finish with exactly one marker:

```text
DEMO_RESULT: SUCCESS; FILE: <expected-filename>
```

or:

```text
DEMO_RESULT: FAILED; REASON: <brief reason>
```

The helper fails when:

- azd returns a nonzero exit code;
- no valid authenticated live-view link appears;
- the browser cannot open the viewer;
- the agent reports failure;
- the success filename differs from the generated filename; or
- the invocation ends without a final marker.

Console output redacts viewer URLs and common session/conversation identifier
formats. Do not enable debug capture or copy unsanitized raw `azd` output into
shared logs.

## Direct azd alternative

Operators who do not want the helper can run:

```powershell
$environment = "<resource-prefix>-dev"
$runSuffix = [guid]::NewGuid().ToString("N")
$outputFile = "Invoice-Processing-Summary-$runSuffix.txt"
$prompt = Get-Content .\samples\prompts\invoice-processing.txt -Raw
$prompt = $prompt.Replace(
    "{{INVOICE_URI}}",
    "https://invoicemgmt.blob.core.windows.net/invoices/Invoice_6.png")
$prompt = $prompt.Replace("{{OUTPUT_FILE_NAME}}", $outputFile)
$version = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment $environment
azd ai agent invoke win365-desktop-agent `
    --environment $environment `
    --version $version `
    --new-session `
    --new-conversation `
    --timeout 1200 `
    $prompt
```

This command keeps the same no-handoff prompt and unique filename. It does not
verify or open the viewer automatically, and its output is not sanitized by the
repository helper.

## Evidence checklist

Record only sanitized evidence:

| Stage | Required evidence |
| --- | --- |
| Target | Environment name, agent name, active immutable version |
| Allocation | Viewer detected or opened; never record its URL or opaque ID |
| Invoice | Agent reports that the invoice was read visually |
| Output | Generated filename and explicit `DEMO_RESULT: SUCCESS` |
| Cleanup | Agent reports the desktop session was closed |
| Timing | Start time, completion time, and whether a retry was needed |

Do not record credentials, raw session/conversation IDs, viewer links,
screen-share links, tokens, assertions, or private session state.

## Failure and recovery

| Failure | Action |
| --- | --- |
| Agent target is missing, inactive, or version-mismatched | Redeploy or select the correct environment; do not invoke an unverified endpoint |
| `W365_ENABLED` or `VIEWER_LIVE_ENABLED` is false | Complete phase 2 or viewer activation; do not weaken the preflight |
| No pool capacity | Wait for capacity or clean up the known prior session; do not allocate a replacement idempotency key |
| Viewer opens at sign-in | Complete normal operator OIDC sign-in; do not take control |
| Viewer link never appears | Inspect sanitized agent logs and shared-state readiness; treat the run as failed |
| Agent requests human handoff | Treat as a prompt/orchestration failure for this scenario |
| Invocation disconnects or has an unknown result | Do not rerun. Follow the bounded recovery procedure below and do not report success or replay desktop actions. |
| Final marker is absent or filename differs | Treat the run as failed even if partial desktop work is visible |

For hosted logs:

```powershell
azd ai agent monitor --environment "<resource-prefix>-dev" --tail 100
```

Do not paste unsanitized monitor output into public issues. After an ambiguous
provider failure:

1. Inspect the local monitor output for successful `EndSession` cleanup and for
   the critical message `session slot remains blocked for operator recovery`.
2. If cleanup is proven and the slot is not blocked, a fresh helper invocation
   is safe.
3. If cleanup is absent or the slot is blocked, stop or drain the old hosted
   worker and viewer, inspect the private state Blob, and resolve the known W365
   session through the authorized service.
4. Only after remote ownership is resolved, break any stale state lease and
   clear the slot as described in
   [fail-closed recovery](ARCHITECTURE.md#fail-closed-recovery).

Never retry merely because the local command timed out.

## Repeat-run expectations

Every helper execution creates:

- a fresh Foundry hosted session;
- a fresh Responses conversation; and
- a new full local run GUID and output filename.

The single-desktop sample still allows only one active owner at a time. Wait
for cleanup to finish before starting another run. A second simultaneous run
must fail rather than steal or replace the active desktop.

## Offline validation

Before a live demo:

```powershell
pwsh -NoProfile -File .\tests\PowerShell\Test-InvoiceProcessingDemoOffline.ps1
pwsh -NoProfile -File .\scripts\Validate-PrePr.ps1
```

The focused test verifies prompt preservation, unique naming, endpoint
selection, viewer-link handling, identifier redaction, and fail-closed result
handling. Offline validation does not prove live Foundry, viewer, or Windows
365 behavior; record actual live evidence separately in
`docs\VALIDATION-REPORT.md`.
