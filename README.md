# Computer use with Foundry and Windows 365

A C#/.NET sample in which a **Foundry hosted agent calls Windows 365 tools
directly** through Agent 365's MCP gateway. Agent Framework handles model/tool
iteration. There is no secondary computer-use model, native `computer` tool,
or custom screenshot/action planning loop.

The suggested model is **`gpt.6.astra`**. Set `AZURE_AI_MODEL_DEPLOYMENT_NAME` to
your actual Foundry deployment name. Availability is subscription/region
dependent; the sample does not provision an unverified model SKU. The deployment
must support function calling and image inputs.

> Preview sample, not a production service. W365 onboarding, licenses and paid
> capacity are required. Review [security](SECURITY.md) before using real data.
> [Live acceptance](docs/DEPLOYMENT.md#live-acceptance) is required before publication.

## Included

| Component | Purpose |
| --- | --- |
| Hosted Responses agent | One model discovers allowed W365 schemas and selects desktop/browser/accessibility actions. |
| Desktop harness | Exclusive ownership, readiness polling, cleanup, action/image/time limits and human pause/resume. |
| Companion viewer | Bootstrap locally or on ACA; enabled, Entra-authenticated ACA viewer provides opaque live-view and take-control links. |
| W365 setup | Reuse Foundry's blueprint/agent identity; reconcile consent, inheritance, agent user and existing pool assignment. |
| Deployment | Foundry `azure.yaml`, non-root Docker image, ACA viewer Bicep and deployment guide. |
| Offline tests | Fake MCP/token handlers, ownership, handoff, ambiguous failures and screenshot conversion. |

This sample supports **one operator and one fresh task at a time**. Each task
releases its Cloud PC; subsequent requests do not inherit desktop or image
history. `previous_response_id`, `conversation` and background execution are
rejected. This trades multi-turn desktop continuity for explicit ownership and
bounded screenshot payloads.

## Architecture

```text
User -> Foundry Responses -> Agent Framework -> configured model
                                   |
                          curated function tools
                                   |
                      exclusive desktop action gate
                                   |
                 agent-user ATG token -> W365 MCP -> Cloud PC

Human -> Entra OIDC viewer -> same action gate (pause/resume)
                          -> ARI token -> ScreenShare SDK -> same PC

Local mode: bootstrap/offline only, no live desktop
Hosted state: private Blob + lease shared by agent and viewer
Agent authentication: Foundry-provided blueprint managed identity token
Viewer authentication: explicitly approved UAMI federation to that blueprint
```

See [architecture](docs/ARCHITECTURE.md) and [authentication](docs/AUTHENTICATION.md).

## Quickstart: two-phase deployment

1. Install [.NET 10](https://dotnet.microsoft.com/download/dotnet/10.0),
   [PowerShell 7.5+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
   and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), plus
   [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd).
   Prepare an existing Foundry project and compatible model deployment.
2. Follow [phase 1](docs/DEPLOYMENT.md#phase-1-deploy-bootstrap) to initialize and
   deploy with `W365_ENABLED=false`. Foundry provisions the blueprint and agent
   identity. No W365 IDs, operator, state or viewer configuration is mandatory
   yet. Healthy readiness and a Responses **503 explaining phase 2** are expected;
   bootstrap starts before model initialization and does not access W365, model
   or state credentials.
3. Run the read-only [identity discovery](docs/DEPLOYMENT.md#discover-the-foundry-identity)
   for the deployed agent name/version. Keep blueprint app/client ID distinct
   from agent object/principal ID.
4. Complete [phase 2 W365 setup](docs/W365-SETUP.md) using those existing IDs.
   Confirm Intune licensing, billing and pool capacity explicitly. Setup never
   creates a blueprint, blueprint principal, agent identity, certificate or secret.
5. Configure shared state and the operator, then enable W365 and redeploy using
   the **same agent name**. Rediscover IDs for the new version and reject unexpected
   identity replacement. An optional [hosted viewer](docs/VIEWER.md) requires
   administrator-approved federation plus separate human OIDC configuration.

`W365_ENABLED` defaults to `false` and accepts only `true` or `false`. Real W365
requires a deployed identity endpoint; an enabled local desktop is refused.
The Foundry, W365 and viewer Azure identities must share a tenant; the human
OIDC tenant can differ.

**Hosting caveat:** the public blueprint-token helper is an activity/autopilot
sample. Its `ManagedIdentityCredential` blueprint selection must be tested on
ordinary Responses hosting; it is not proof that this host supports the flow.
No live deployment has been performed for this implementation. If the host
cannot issue the required token, stop: there is no certificate, secret or
CLI-token fallback. This sample does not publish autopilot or require hiring.
See [authentication](docs/AUTHENTICATION.md#sdk-and-hosting-boundary) and
[live acceptance](docs/DEPLOYMENT.md#live-acceptance).

## Local bootstrap and offline development

From the repository root:

```powershell
Copy-Item .env.example .env
# Keep SAMPLE_LOCAL_MODE=true and W365_ENABLED=false.
dotnet restore .\Win365FoundrySample.slnx
dotnet build .\Win365FoundrySample.slnx --no-restore
```

Bootstrap requires no project, model, W365, state or OIDC configuration.
Restrict `.local` to your OS account and never commit `.env` or desktop state.
The launcher loads `.env` without executing shell expressions; existing process
environment values take precedence.

In two terminals at the repository root:

```powershell
# Terminal 1
.\scripts\Run-Local.ps1 -Mode agent
# Terminal 2
.\scripts\Run-Local.ps1 -Mode viewer
```

The viewer's `http://localhost:5050/health` is healthy; its other routes return
503 until phase 2. The agent's `http://localhost:8088/responses` returns the
phase-2-required 503 rather than starting a model or desktop task. This is an
offline/bootstrap check, not a live W365 quickstart.

Local mode is **unauthenticated and loopback-only**, including the viewer.
Never tunnel/publish these ports or use a shared development host.

## Deploy and develop

Follow [deployment](docs/DEPLOYMENT.md) for the Foundry agent, shared Blob state
and ACA viewer. Key Vault is used **only for the viewer OIDC secret**, not a
blueprint credential. Agent and viewer are separate processes built from the
same project; the viewer runs with `--viewer`. Never enable local mode in Azure.
See [viewer setup](docs/VIEWER.md) for its separate OIDC web application.

```powershell
dotnet test .\Win365FoundrySample.slnx
pwsh -NoProfile -File .\scripts\Test-SetupOffline.ps1
pwsh -NoProfile -File .\scripts\Test-DiscoveryOffline.ps1
az bicep build --file .\infra\viewer.bicep --stdout
```

Tests do not contact a Cloud PC or model. NuGet dependencies are pinned in project
files; upgrade the preview hosting packages as a compatible set.

## References

- [W365 getting started](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/getting-started.md)
- [W365 authentication](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/authentication.md)
- [W365 MCP API](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/api-reference.md)
- [W365 screen sharing](https://github.com/microsoft/windows-365-for-agents/blob/main/docs/screen-sharing.md)
- [Foundry C# hosted sample](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/csharp/hosted-agents/agent-framework/hello-world)
- [Foundry agent identity](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)
- [Public blueprint token helper (activity/autopilot reference)](https://github.com/microsoft-foundry/foundry-samples/blob/main/samples/csharp/foundry-autopilot-agent/src/hello_world_a365_agent/Services/AgentTokenHelper.cs)
- [Foundry Python onboarding reference](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/01-basic)
- [OpenAI native computer tool](https://developers.openai.com/api/docs/guides/tools-computer-use#use-the-computer-tool): an alternative architecture, **not** this sample's tool protocol.

See [contributing](CONTRIBUTING.md), [security](SECURITY.md), and [license](LICENSE).
