using System.Net;
using System.Text;
using System.Text.Json;

namespace Win365Agent.Tests;

internal sealed class McpHandler : HttpMessageHandler
{
    private static readonly string[] _toolNames =
        ["StartSession", "GetSessionDetails", "EndSession", "click"];

    public bool FailClick { get; set; }
    public bool FailStart { get; set; }
    public int AmbiguousStartsRemaining { get; set; }
    public bool SessionScopedCatalog { get; set; }
    public bool SawTransportSession { get; private set; }
    public bool Sse { get; set; }
    public int AuthorizationCount { get; private set; }
    public int ClickCount { get; private set; }
    public List<string> Methods { get; } = [];
    public List<string> StartIdempotencyKeys { get; } = [];
    public int StartCount { get; private set; }
    private bool _desktopBound;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Assert.Equal("agent365.svc.cloud.microsoft", request.RequestUri!.Host);
        Assert.Equal("fake-test-token", request.Headers.Authorization!.Parameter);
        AuthorizationCount++;
        using var body = JsonDocument.Parse(
            await request.Content!.ReadAsStringAsync(cancellationToken));
        var method = body.RootElement.GetProperty("method").GetString()!;
        Methods.Add(method);
        if (method == "notifications/initialized")
        {
            return new HttpResponseMessage(HttpStatusCode.Accepted);
        }

        var id = body.RootElement.GetProperty("id").GetInt32();
        object result;
        switch (method)
        {
            case "initialize":
                _desktopBound = false;
                result = new { protocolVersion = "2025-06-18" };
                break;
            case "tools/list":
                SawTransportSession = request.Headers.Contains("Mcp-Session-Id");
                var advertisedTools = SessionScopedCatalog && !_desktopBound
                    ? _toolNames.Take(3)
                    : _toolNames;
                result = new
                {
                    tools = advertisedTools.Select(name => new
                    {
                        name,
                        description = name,
                        inputSchema = new
                        {
                            type = "object",
                            properties = name == "StartSession"
                                ? new Dictionary<string, object>
                                {
                                    ["idempotencyKey"] = new { type = "string" }
                                }
                                : []
                        }
                    })
                };
                break;
            case "tools/call":
                var name = body.RootElement
                    .GetProperty("params")
                    .GetProperty("name")
                    .GetString();
                if (name == "StartSession")
                {
                    StartCount++;
                    _desktopBound = true;
                    StartIdempotencyKeys.Add(body.RootElement
                        .GetProperty("params")
                        .GetProperty("arguments")
                        .GetProperty("idempotencyKey")
                        .GetString()!);
                    if (FailStart || AmbiguousStartsRemaining-- > 0)
                    {
                        throw new HttpRequestException("ambiguous start");
                    }
                }

                if (name == "click")
                {
                    ClickCount++;
                    if (FailClick)
                    {
                        throw new HttpRequestException("ambiguous action");
                    }

                    if (name == "EndSession")
                    {
                        _desktopBound = false;
                    }
                }

                result = new
                {
                    content = new[]
                    {
                        new
                        {
                            type = "text",
                            text = name switch
                            {
                                "StartSession" =>
                                    """{"sessionId":"desktop"}""",
                                "GetSessionDetails" =>
                                    """{"sessionId":"desktop","environment":"PROD","screenShareUrl":"https://screen.example/session"}""",
                                _ => "ok"
                            }
                        }
                    }
                };
                break;
            default:
                throw new InvalidOperationException(method);
        }

        var json = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result });
        var response = new HttpResponseMessage(HttpStatusCode.OK);
        response.Headers.Add("Mcp-Session-Id", "transport");
        response.Content = new StringContent(
            Sse ? $"data: {json}\n\n" : json,
            Encoding.UTF8,
            Sse ? "text/event-stream" : "application/json");
        return response;
    }
}
