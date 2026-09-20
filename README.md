# Computer use with Microsoft Foundry and Windows 365

A Windows-first C#/.NET 10 sample where a Microsoft Foundry hosted agent uses
Windows 365 tools through Agent 365 MCP to complete a bounded Cloud PC task.

> **Preview sample:** Not a production multi-user service. Live use requires
> Foundry/W365 onboarding, billing, pool capacity, tenant administration, and
> [live acceptance](docs/DEPLOYMENT.md#live-acceptance). Review [security](SECURITY.md).

## What this sample does

The sample opens an invoice in Edge, summarizes it in Notepad, verifies the
result, and releases the desktop. It supports one operator and one fresh task
at a time. The optional viewer adds authenticated live view and human control.

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
- a reviewed W365 billing plan, image, region, and pool-capacity choice;
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

Live deployment is staged because Foundry must create the agent identity before
state and W365 can be bound to it. Each mutation requires explicit approval.

Authenticate both CLIs to the same tenant and subscription:

```powershell
az login --tenant "<tenant-id>"
az account set --subscription "<subscription-id>"
azd auth login
azd ext install microsoft.foundry
pwsh -NoProfile -File .\tests\PowerShell\Test-AzdPrerequisites.ps1 -RequireLogin
```

Initialize a dedicated environment:

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

The bootstrap is not desktop-capable. Continue with
[phase 2](docs/DEPLOYMENT.md#phase-2-bind-and-enable) to discover its exact
principal, provision shared Blob state, configure the approved W365 pool,
perform W365 setup, and redeploy the same agent name.

The validated `client_secret` path requires an administrator-approved,
short-lived blueprint credential stored through the secure phase-2 prompt.
Never place it in source, JSON, `.azure`, logs, or command history. See
[authentication](docs/AUTHENTICATION.md) for supported modes and cleanup.

Do not run `azd init`, `azd ai agent init`, or an unreviewed one-shot `azd up`
inside this clone. Use the [deployment guide](docs/DEPLOYMENT.md) for phase 2,
existing-project configuration, rollback, teardown, and recovery.

## Verify live behavior

Before real tasks, complete the
[live-acceptance checks](docs/DEPLOYMENT.md#live-acceptance):

- Foundry blueprint, agent identity, and agent-user continuity;
- the configured credential mode and T1/T2/T3 token boundaries;
- W365 pool readiness and live catalog discovery;
- exclusive ownership, bounded actions, and unknown-outcome recovery;
- `EndSession`, task/session cleanup, and recovery behavior.

After acceptance, invoke the included scenario with a fresh agent session:

```powershell
$environment = "<resource-prefix>-dev"
$prompt = Get-Content .\samples\prompts\invoice-processing.txt -Raw
$version = azd env get-value AGENT_WIN365_DESKTOP_AGENT_VERSION `
    --environment $environment
azd ai agent invoke win365-desktop-agent `
    --environment $environment `
    --version $version `
    --new-session $prompt
```

Add `--user-identity "<caller-partition>"` only when required. This is the
opaque Foundry caller partition, not `OPERATOR_OBJECT_ID` or an Entra object ID;
see [hosted operator binding](docs/DEPLOYMENT.md#bind-the-hosted-operator).

## Documentation map

| Topic | Document |
| --- | --- |
| Deployment, rollback, teardown, live acceptance | [Deployment](docs/DEPLOYMENT.md) |
| W365, Graph, Entra, agent user, and pool setup | [Windows 365 setup](docs/W365-SETUP.md) |
| Credential modes and token exchanges | [Authentication](docs/AUTHENTICATION.md) |
| Lifecycle, ownership, state, recovery, source layout | [Architecture](docs/ARCHITECTURE.md) |
| Optional live view and human handoff | [Viewer](docs/VIEWER.md) |
| Dated live evidence and unverified boundaries | [Validation report](docs/VALIDATION-REPORT.md) |
| Development and contribution checks | [Contributing](CONTRIBUTING.md) |
| Operational and computer-use risks | [Security](SECURITY.md) |
