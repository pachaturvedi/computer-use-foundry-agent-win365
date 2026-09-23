# Computer use with Microsoft Foundry and Windows 365

A Windows-first C#/.NET 10 sample where a Microsoft Foundry hosted agent uses
Windows 365 tools through Agent 365 MCP to complete a bounded Cloud PC task.

The included scenario processes a sample invoice entirely through the Cloud PC
desktop. The agent opens the invoice image in Microsoft Edge, reads the visible
fields, writes a structured summary in Notepad, saves the file to Documents,
verifies the saved result, and closes the Windows 365 session.

> **Preview sample:** Not a production multi-user service. Live use requires
> Foundry/W365 onboarding, billing, pool capacity, tenant administration, and
> [live acceptance](docs/DEPLOYMENT.md#live-acceptance). Review [security](SECURITY.md).

## What this sample does

The invoice-processing run demonstrates the complete bounded desktop lifecycle:

1. Acquire one Windows 365 Cloud PC for one fresh task.
2. Open the fixed sample invoice in Microsoft Edge:
   `https://invoicemgmt.blob.core.windows.net/invoices/Invoice_6.png`.
3. Read the invoice visually from the desktop and extract the invoice number,
   vendor, addresses, dates, bill-to details, every line item, subtotal, tax,
   and total.
4. Open Notepad and save the structured result as
   `Documents\Invoice-Processing-Summary.txt`.
5. Verify the filename and saved content in Notepad.
6. End the Windows 365 session even when the task fails.

The sample supports one operator and one fresh task at a time. The ACA viewer
is deployed in bootstrap mode by default. After tenant-specific activation it
supports authenticated observation and controlled human handoff, although the
basic invoice prompt remains observation-only.

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
| Configure live view and human handoff | [Viewer guide](docs/VIEWER.md) | ACA viewer is deployed by default; live activation is tenant-specific |

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

A fresh managed environment defaults to the complete agent path: Foundry
project and model, bootstrap agent, shared Blob state, W365 setup, ACA viewer
bootstrap, and the final enabled hosted-agent version. `azd up` performs the
required two internal phases because the first agent version must exist before
its identity can receive state and W365 access. Live viewer activation occurs
in the same run only when its tenant-specific inputs are available.

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
azd env new "<resource-prefix>-dev" `
    --subscription "<subscription-id>" `
    --location eastus
azd up --environment "<resource-prefix>-dev"
```

The checked-in azd hooks perform both deployment phases. Wait for the final
sample deployment table and scenario-specific `Next` section; Foundry may print
generic service-level guidance after the bootstrap agent deploys, before W365
and the optional viewer finish.

The command deploys the Foundry bootstrap first. It then asks whether to reuse
an existing W365 agent pool, create a new pool, or keep a Foundry-only
deployment. New-pool setup uses the reviewed region and image defaults and asks
for a billing-plan GUID only when one cannot be discovered from the tenant.
It also asks whether to create a dedicated ACA managed environment (default),
reuse an existing compatible environment, or skip the viewer. Non-secret
choices are saved only in the selected azd environment.

After approval and delegated Graph sign-in, the command discovers the exact
Foundry principal, provisions shared state and the selected viewer topology,
configures W365, and redeploys the same agent name. The default demo collects
the existing blueprint credential through a secure prompt and stores it in
Azure Key Vault; it is not written to source, JSON, `.azure`, logs, or command
history.

The reviewed model defaults are `gpt-6-astra`, version `2026-09-03`,
`GlobalStandard`, and capacity `200` (200K TPM). If approved screen-share
values are already present in the selected azd environment or ignored local
deployment profile, `azd up` uses them to activate the viewer. Otherwise it
leaves the viewer in healthy bootstrap mode and identifies the missing
tenant-specific inputs. Screen-share values are not required for agent-only
desktop execution.

See the [deployment guide](docs/DEPLOYMENT.md) for quota, cost, shared-project
deployment, staged previews, opt-out settings, rollback, and teardown. See the
[viewer guide](docs/VIEWER.md) for tenant-specific screen-share onboarding and
human-handoff behavior, and [authentication](docs/AUTHENTICATION.md) for the
Key Vault credential boundary and other explicitly selected modes.

For a Foundry-only bootstrap:

```powershell
azd env set ENABLE_W365 false --environment "<resource-prefix>-dev"
azd up --environment "<resource-prefix>-dev"
```

Do not run `azd init` or `azd ai agent init` inside this clone. Use the
[deployment guide](docs/DEPLOYMENT.md) when reusing a shared Foundry project,
requiring separate previews and approvals, or using the optional guarded
PowerShell wrapper for unattended execution and stricter cancellation handling.

## Verify live behavior

Before real tasks, complete the
[live-acceptance checks](docs/DEPLOYMENT.md#live-acceptance):

- Foundry blueprint, agent identity, and agent-user continuity;
- the configured credential mode and T1/T2/T3 token boundaries;
- W365 pool readiness and live catalog discovery;
- exclusive ownership, bounded actions, and unknown-outcome recovery;
- `EndSession`, task/session cleanup, and recovery behavior.

After acceptance, invoke the ready-to-run invoice scenario directly. The
checked-in prompt already contains the sample Blob URL and output filename, so
no prompt replacement or preprocessing is required:

```powershell
$version = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment "<resource-prefix>-dev"
azd ai agent invoke win365-desktop-agent `
    --environment "<resource-prefix>-dev" `
    --version $version `
    --new-session `
    --new-conversation `
    --timeout 1200 `
    (Get-Content .\samples\prompts\invoice-processing-direct.txt -Raw)
```

Expected completion:

```text
DEMO_RESULT: SUCCESS; FILE: Invoice-Processing-Summary.txt
```

The command waits for completion but does not automatically open or redact the
viewer link. To generate a unique output filename and open the authenticated
viewer automatically, use the helper:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-InvoiceProcessingDemo.ps1 `
    -Environment "<resource-prefix>-dev"
```

The viewer remains observation-only for this basic scenario. The prompt forbids
human handoff and reports failure rather than waiting for operator control. If
the result is ambiguous, do not rerun the task until the
[fail-closed recovery workflow](docs/ARCHITECTURE.md#fail-closed-recovery)
confirms that no remote session remains.

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
| Development and contribution checks | [Contributing](CONTRIBUTING.md) |
| Operational and computer-use risks | [Security](SECURITY.md) |
