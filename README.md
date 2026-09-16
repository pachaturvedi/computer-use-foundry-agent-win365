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
| Companion viewer | Local loopback or Entra-authenticated ACA app; opaque live-view and take-control links. |
| W365 setup | Graph identity, public certificate, consent, inheritance and existing pool assignment automation. |
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

Local state: private file + file lock
Hosted state: private Blob + lease shared by agent and viewer
Blueprint credential: encrypted local PFX or Key Vault certificate
```

See [architecture](docs/ARCHITECTURE.md) and [authentication](docs/AUTHENTICATION.md).

## Quickstart

1. Install [.NET 10](https://dotnet.microsoft.com/download/dotnet/10.0),
   [PowerShell 7.5+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
   and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
   Prepare an existing Foundry project and compatible model deployment.
2. Complete [W365 setup](docs/W365-SETUP.md): billing, licenses, administrator
   roles, certificate, identity script, pool assignment and readiness.
3. From this repository root:

```powershell
Copy-Item .env.example .env
# Edit .env with the setup identifiers, your project and W365 viewer SDK URL.
dotnet user-secrets set W365_CERTIFICATE_PASSWORD "<PFX-password>" --project .\src\Win365Agent
az login --tenant "<Foundry-tenant-id>"
dotnet restore .\Win365FoundrySample.slnx
dotnet build .\Win365FoundrySample.slnx --no-restore
```

User-secrets is local development storage, not an encrypted vault. Restrict
`.local` to your OS account and never commit `.env`, certificates or desktop state.
The launcher loads `.env` without executing shell expressions; existing process
environment values take precedence. It enables Development for user-secrets.

4. In two terminals at the repository root:

```powershell
# Terminal 1
.\scripts\Run-Local.ps1 -Mode agent
# Terminal 2
.\scripts\Run-Local.ps1 -Mode viewer
```

5. Open `http://localhost:5050`. Start a fresh task:

```powershell
$request = @{
    input = "Open the desktop and describe what is visible. Do not change data."
    stream = $false
} | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri http://localhost:8088/responses `
    -ContentType application/json -Body $request -TimeoutSec 660
```

The harness supplies live-view and take-control links. Refresh the viewer's root
page to find the active task even if your client buffers the response. Links
stop working after release. Try human handoff with:
`Open the desktop, ask me to take control, wait until I resume, then describe the screen.`

Local mode is **unauthenticated and loopback-only**, including the viewer.
Never tunnel/publish these ports or use a shared development host.

## Deploy and develop

Follow [deployment](docs/DEPLOYMENT.md) for the Foundry agent, shared Blob state,
Key Vault credential and ACA viewer. They are separate processes built from the
same project; the viewer runs with `--viewer`. Never enable local mode in Azure.
See [viewer setup](docs/VIEWER.md) for its separate OIDC web application.

```powershell
dotnet test .\Win365FoundrySample.slnx
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
- [Foundry Python onboarding reference](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/01-basic)
- [OpenAI native computer tool](https://developers.openai.com/api/docs/guides/tools-computer-use#use-the-computer-tool): an alternative architecture, **not** this sample's tool protocol.

See [contributing](CONTRIBUTING.md), [security](SECURITY.md), and [license](LICENSE).
