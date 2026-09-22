# Computer use with Microsoft Foundry and Windows 365

A Windows-first C#/.NET 10 sample where a Microsoft Foundry hosted agent uses
Windows 365 tools through Agent 365 MCP to complete a bounded Cloud PC task.

> **Preview sample:** Not a production multi-user service. Live use requires
> Foundry/W365 onboarding, billing, pool capacity, tenant administration, and
> [live acceptance](docs/DEPLOYMENT.md#live-acceptance). Review [security](SECURITY.md).

## What this sample does

The sample opens an invoice in Edge, summarizes it in Notepad, verifies the
result, and releases the desktop. It supports one operator and one fresh task
at a time. Transport-level conversation metadata from `azd` is accepted, while
`previous_response_id` and background execution are rejected. The optional
viewer adds authenticated live view and human control.

## Scenario and code map

| Area | Responsibility | Main path |
| --- | --- | --- |
| Hosted agent | Runs the Foundry Responses loop and invokes only live, allowlisted W365 tools | `src\Win365Agent` |
| Shared contracts | Owns configuration, identity exchanges, and durable session state | `src\Win365Shared` |
| Viewer | Provides authenticated live view, pause, take control, and resume | `src\Win365Viewer` |
| Deployment | Provisions Foundry, state, viewer, W365 binding, and immutable agent versions | `azure.yaml`, `infra`, `scripts` |
| Tests | Mirrors production projects and exercises deployment workflows offline | `tests` |

The primary demo is invoice processing. The same bounded desktop lifecycle also
supports observation-only automation and explicit human handoff. See
[architecture](docs/ARCHITECTURE.md) for the request, identity, state, and
cleanup flows.

## Choose a path

| Goal | Path | Azure or W365 changes |
| --- | --- | --- |
| Build and test the repository | [Offline validation](#offline-validation) | None |
| Create a dedicated Foundry project and bind W365 | [Fresh deployment](#bring-up-a-fresh-environment) | Billable and tenant-changing |
| Reuse an existing Foundry project | [Existing project deployment](docs/DEPLOYMENT.md#phase-1-deploy-bootstrap) | Validates and updates selected resources |
| Add live view and human handoff | [Viewer guide](docs/VIEWER.md) | Optional ACA and Entra resources |

## Before you start

Offline validation requires Windows, PowerShell 7.4+, the .NET 10 SDK, and Git.
Live deployment additionally requires:

- an Azure subscription and tenant onboarded for Foundry and W365 for Agents;
- Azure CLI, the Azure Developer CLI versions required by `azure.yaml`, and a
  model deployment such as `gpt-6-astra` supporting functions and images;
- access to an existing W365 agent pool or an approved pay-as-you-go billing
  plan; the deployment collects the tenant-specific choice after bootstrap;
- the Foundry and tenant-administrator permissions listed in
  [deployment](docs/DEPLOYMENT.md#prerequisites) and
  [W365 setup](docs/W365-SETUP.md#setup-permissions-delegated-not-runtime).

## Offline validation

From PowerShell 7 at the repository root:

```powershell
pwsh -NoProfile -File .\scripts\Setup-Local.ps1
pwsh -NoProfile -File .\scripts\Start-Local.ps1
```

Setup validates `.env`, restores, formats, builds, and tests. Start launches
the prebuilt agent and viewer bootstrap processes until you press `Ctrl+C`.

| Endpoint | Expected result |
| --- | --- |
| `http://localhost:8088/health` | Agent bootstrap is healthy |
| `http://localhost:5050/health` | Viewer bootstrap is healthy |
| Desktop or Responses route | HTTP 503 until live phase 2 is configured |

This path contacts no tenant, model, Graph, W365, or Cloud PC. Local ports are
unauthenticated and loopback-only; never publish or tunnel them.

## Bring up a fresh environment

A fresh managed environment defaults to the complete demo: Foundry project and
model, bootstrap agent, shared Blob state, W365 setup, ACA viewer, and the final
enabled hosted-agent version. `azd up` performs the required two internal
phases because the first agent version must exist before its identity can
receive state and W365 access.

Authenticate both CLIs to the same tenant and subscription:

```powershell
az login --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
azd auth login
azd ext install microsoft.foundry
pwsh -NoProfile -File .\tests\PowerShell\Test-AzdPrerequisites.ps1 -RequireLogin
```

Create the environment and deploy:

```powershell
azd env new demosept22-dev `
    --subscription "<subscription-id>" `
    --location eastus
azd up --environment demosept22-dev
```

The command deploys the Foundry bootstrap first. It then asks whether to reuse
an existing W365 agent pool, create a new pool, or keep a Foundry-only
deployment. New-pool setup uses the reviewed region and image defaults and asks
for a billing-plan GUID only when one cannot be discovered from the tenant.
It also asks whether to create a dedicated ACA managed environment (default),
reuse an existing compatible environment, or skip the viewer. Non-secret
choices are saved only in the selected azd environment.

After approval and delegated Graph sign-in, the command discovers the exact
Foundry principal, provisions shared state and the selected viewer topology,
configures W365, securely collects the existing blueprint credential, and
redeploys the same agent name. The reviewed model defaults are `gpt-6-astra`,
version `2026-09-03`, `GlobalStandard`, and capacity `200` (200K TPM).

The ACA viewer is deployed by default. To activate live view and take control
in the same run, set the three non-secret screen-share values supplied during
W365 onboarding before `azd up`:

```powershell
azd env set SCREENSHARE_APP_URL "<approved-app-url>" --environment demosept22-dev
azd env set SCREENSHARE_SDK_URL "<approved-sdk-url>" --environment demosept22-dev
azd env set SCREENSHARE_FRAME_ORIGINS "<approved-origin-list>" --environment demosept22-dev
```

Without those values, W365 and the ACA viewer still deploy, but the viewer
remains in healthy bootstrap mode and the final summary identifies the missing
activation settings.

See the [deployment guidance](docs/DEPLOYMENT.md#phase-1-deploy-bootstrap)
for prerequisites, defaults, quota, cost, existing-project rules, and opt-out
settings, and
[operations and rollback](docs/DEPLOYMENT.md#operations-and-rollback) for
partial deployments and teardown.

For a Foundry-only bootstrap:

```powershell
azd env set ENABLE_W365 false --environment demosept22-dev
azd up --environment demosept22-dev
```

Use the staged workflow below when you need separate previews and approvals,
or when reusing a shared Foundry project:

```powershell
pwsh -NoProfile -File .\scripts\Initialize-Greenfield.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>" `
    -Prefix "<resource-prefix>" `
    -Environment "dev"
```

Review the preview, then deploy only the disabled Foundry bootstrap:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode Validate
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode ProvisionFoundry `
    -ConfirmResourceChanges
pwsh -NoProfile -File .\scripts\Invoke-AzdDeployment.ps1 `
    -Environment "<resource-prefix>-dev" `
    -Mode DeployAgent `
    -ConfirmResourceChanges
azd ai agent doctor --environment "<resource-prefix>-dev"
```

The staged bootstrap is not desktop-capable. Continue with
[phase 2](docs/DEPLOYMENT.md#phase-2-bind-and-enable) to discover its exact
principal, provision shared Blob state, configure the approved W365 pool,
perform W365 setup, and redeploy the same agent name.

The validated `client_secret` path requires an administrator-approved,
short-lived blueprint credential stored through the secure phase-2 prompt.
Never place it in source, JSON, `.azure`, logs, or command history. See
[authentication](docs/AUTHENTICATION.md) for supported modes and cleanup.

Do not run `azd init` or `azd ai agent init` inside this clone. Direct `azd up`
is the complete path only for a new, dedicated managed environment. Use the
[deployment guide](docs/DEPLOYMENT.md) for shared-project safeguards, staged
changes, rollback, teardown, and recovery.

## Verify live behavior

Before real tasks, complete the
[live-acceptance checks](docs/DEPLOYMENT.md#live-acceptance):

- Foundry blueprint, agent identity, and agent-user continuity;
- the configured credential mode and T1/T2/T3 token boundaries;
- W365 pool readiness and live catalog discovery;
- exclusive ownership, bounded actions, and unknown-outcome recovery;
- `EndSession`, task/session cleanup, and recovery behavior.

After acceptance, run the included scenario helper:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-InvoiceProcessingDemo.ps1 `
    -Environment "<resource-prefix>-dev"
```

The helper creates a new agent session, generates a unique
`Invoice-Processing-Summary-<run-guid>.txt` filename, opens the authenticated
live viewer in the default browser, and waits for the final success or failure
result. The viewer is observation-only in this basic scenario; the prompt
forbids human handoff and fails instead of waiting for operator control.

To invoke the same scenario directly without the helper:

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

The direct command waits for completion but does not automatically open or
redact the viewer link. Use the helper when you want that behavior. See the
[live invoice demo workflow](docs/LIVE-INVOICE-DEMO.md) for detailed execution,
evidence, retry, and recovery steps.

Pass `-UserIdentity "<caller-partition>"` only when required. This is the opaque
Foundry caller partition, not `OPERATOR_OBJECT_ID` or an Entra object ID; see
[hosted operator binding](docs/DEPLOYMENT.md#bind-the-hosted-operator).

## Documentation map

| Topic | Document |
| --- | --- |
| Deployment, rollback, teardown, live acceptance | [Deployment](docs/DEPLOYMENT.md) |
| W365, Graph, Entra, agent user, and pool setup | [Windows 365 setup](docs/W365-SETUP.md) |
| Credential modes and token exchanges | [Authentication](docs/AUTHENTICATION.md) |
| Lifecycle, ownership, state, recovery, source layout | [Architecture](docs/ARCHITECTURE.md) |
| Optional live view and human handoff | [Viewer](docs/VIEWER.md) |
| Live invoice demo workflow | [Live invoice demo](docs/LIVE-INVOICE-DEMO.md) |
| Dated live evidence and unverified boundaries | [Validation report](docs/VALIDATION-REPORT.md) |
| Development and contribution checks | [Contributing](CONTRIBUTING.md) |
| Operational and computer-use risks | [Security](SECURITY.md) |
