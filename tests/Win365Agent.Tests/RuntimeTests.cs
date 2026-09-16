using System.Net;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using SkiaSharp;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class RuntimeTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "w365-sample-tests", Guid.NewGuid().ToString());
    private Settings Config() => new(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
    {
        ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111", ["VIEWER_PUBLIC_URL"] = "http://localhost:5050",
        ["SAMPLE_LOCAL_MODE"] = "true", ["OPERATOR_TENANT_ID"] = "tenant", ["OPERATOR_OBJECT_ID"] = "owner"
    }).Build());
    private static JsonElement Json(string json) => JsonDocument.Parse(json).RootElement.Clone();
    private FileSessionStore Store() => new(Path.Combine(folder, "session.json"));

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InitializeSupportsEmptyNotificationAndJsonOrSse(bool sse)
    {
        using var handler = new McpHandler { Sse = sse };
        using var http = new HttpClient(handler);
        var mcp = new McpConnection(http, new FakeTokens(), Config());
        await mcp.InitializeAsync(default);
        Assert.NotEmpty(await mcp.ListAsync(default));
        Assert.Equal(["initialize", "notifications/initialized", "tools/list"], handler.Methods);
        Assert.True(handler.SawTransportSession);
        Assert.Equal(3, handler.AuthorizationCount);
    }

    [Fact]
    public void MismatchedResponseCannotBeUsed() => Assert.Null(McpConnection.Parse("""{"id":2,"result":{}}""", 1));
    [Fact]
    public void RpcErrorDoesNotExposeBody() =>
        Assert.DoesNotContain("secret", Assert.Throws<InvalidOperationException>(() =>
            McpConnection.Parse("""{"id":1,"error":{"message":"secret"}}""", 1)).Message);
    [Fact]
    public void FieldReadsEmbeddedMcpText() =>
        Assert.Equal("abc", McpConnection.Field(Json("""{"content":[{"type":"text","text":"{\"sessionId\":\"abc\"}"}]}"""), "sessionId"));
    [Fact]
    public void OrdinaryTextDoesNotBecomeASession() =>
        Assert.Null(McpConnection.Field(Json("""{"content":[{"type":"text","text":"{not json"}]}"""), "sessionId"));

    [Fact]
    public async Task FileStatePersistsAndLockSerializesRequests()
    {
        var store = Store();
        await using (var first = await store.OpenAsync(default))
        {
            first.State = Session();
            await first.SaveAsync(default);
            using var timeout = new CancellationTokenSource(150);
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.OpenAsync(timeout.Token));
        }
        await using var second = await store.OpenAsync(default);
        Assert.Equal("owner", second.State!.OwnerObjectId);
    }

    [Theory]
    [InlineData("owner", "tenant", true)]
    [InlineData("other", "tenant", false)]
    [InlineData("owner", "other", false)]
    public void OpaqueLinkAloneDoesNotAuthorizeViewer(string owner, string tenant, bool allowed)
    {
        var state = Session();
        var user = new ClaimsPrincipal(new ClaimsIdentity([new Claim("oid", owner), new Claim("tid", tenant)]));
        Assert.Equal(allowed, Viewer.Owns(state, state.LinkId, user));
        Assert.False(Viewer.Owns(state, "wrong-link", user));
        state.ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1);
        Assert.False(Viewer.Owns(state, state.LinkId, user));
    }
    private static DesktopSession Session() => new()
    { RequestId = "task", OwnerObjectId = "owner", OwnerTenantId = "tenant", Phase = "Active", SessionId = "desktop" };

    [Theory]
    [InlineData("execute_shell_command")]
    [InlineData("execute_python_code")]
    [InlineData("browser_eval_js")]
    [InlineData("EndSession")]
    [InlineData("mcp_W365ComputerUse_click")]
    public void UnsafeOrInventedToolsAreNotExposed(string name) => Assert.DoesNotContain(name, DesktopRuntime.AllowedTools);

    [Fact]
    public void ScreenshotBecomesBoundedImageAndReportsCoordinateScale()
    {
        using var bitmap = new SKBitmap(2000, 1000);
        bitmap.Erase(SKColors.White);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        var result = JsonSerializer.SerializeToElement(new { content = new[] {
            new { type = "image", data = Convert.ToBase64String(data.ToArray()), mimeType = "image/png" } } });
        var count = 0;
        var output = Observations.Convert(result, ref count);
        Assert.Contains("2000x1000 to 1280x640", ((Microsoft.Extensions.AI.TextContent)output[0]).Text);
        var content = Assert.IsType<Microsoft.Extensions.AI.DataContent>(output[1]);
        Assert.Equal("image/jpeg", content.MediaType);
        Assert.True(content.Data.Length <= 128 * 1024);
        count = 4;
        Assert.Throws<InvalidOperationException>(() => Observations.Convert(result, ref count));
    }

    [Fact]
    public async Task ConcurrentOwnerIsDeniedAndPauseBlocksActionsUntilResume()
    {
        var store = Store();
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        DesktopRuntime Runtime(string id) => new(new McpConnection(http, new FakeTokens(), Config()), store,
            Config(), id, NullLogger.Instance);
        var first = Runtime("one");
        await first.OpenAsync(default);
        var other = Runtime("two");
        await Assert.ThrowsAsync<InvalidOperationException>(() => other.OpenAsync(default));
        Assert.Equal(1, handler.StartCount);
        await first.HandoffAsync(default);
        using var timeout = new CancellationTokenSource(150);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first.ExecuteAsync("click", Json("{}"), timeout.Token));
        Assert.Equal(0, handler.ClickCount);
        await using (var tx = await store.OpenAsync(default)) { tx.State!.Phase = "Active"; await tx.SaveAsync(default); }
        await first.ExecuteAsync("click", Json("{}"), default);
        Assert.Equal(1, handler.ClickCount);
        await first.CloseAsync(default);
        await using var ended = await store.OpenAsync(default);
        Assert.Null(ended.State);
    }

    [Fact]
    public async Task ClosingDoesNotAllowAnotherAllocationInTheSameTask()
    {
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        var runtime = new DesktopRuntime(new McpConnection(http, new FakeTokens(), Config()), Store(), Config(), "one", NullLogger.Instance);
        await runtime.OpenAsync(default);
        await runtime.CloseAsync(default);
        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.OpenAsync(default));
        Assert.Equal(1, handler.StartCount);
    }

    [Fact]
    public async Task AmbiguousActionIsNotReplayedAndBlocksFurtherActions()
    {
        using var handler = new McpHandler { FailClick = true };
        using var http = new HttpClient(handler);
        var runtime = new DesktopRuntime(new McpConnection(http, new FakeTokens(), Config()), Store(), Config(), "one", NullLogger.Instance);
        await runtime.OpenAsync(default);
        await Assert.ThrowsAsync<HttpRequestException>(() => runtime.ExecuteAsync("click", Json("{}"), default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.ExecuteAsync("click", Json("{}"), default));
        Assert.Equal(1, handler.ClickCount);
        await runtime.CloseAsync(default);
    }

    [Fact]
    public async Task UnknownStartOutcomeIsDurablyBlocked()
    {
        using var handler = new McpHandler { FailStart = true };
        using var http = new HttpClient(handler);
        var runtime = new DesktopRuntime(new McpConnection(http, new FakeTokens(), Config()), Store(), Config(), "one", NullLogger.Instance);
        await Assert.ThrowsAsync<HttpRequestException>(() => runtime.OpenAsync(default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.CloseAsync(default));
        await using var tx = await Store().OpenAsync(default);
        Assert.Equal("RecoveryRequired", tx.State!.Phase);
        Assert.Equal(1, handler.StartCount);
    }

    [Fact]
    public async Task ModelCannotSupplyAnotherSession()
    {
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        var runtime = new DesktopRuntime(new McpConnection(http, new FakeTokens(), Config()), Store(), Config(), "one", NullLogger.Instance);
        await runtime.OpenAsync(default);
        await Assert.ThrowsAsync<ArgumentException>(() => runtime.ExecuteAsync("click", Json("""{"sessionId":"other"}"""), default));
        Assert.Equal(0, handler.ClickCount);
        await runtime.CloseAsync(default);
    }

    public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
}

internal sealed class FakeTokens : IAgentUserTokens
{
    public Task<AccessToken> GetAsync(string audience, CancellationToken ct) =>
        Task.FromResult(new AccessToken("fake-test-token", DateTimeOffset.UtcNow.AddHours(1)));
}
internal sealed class McpHandler : HttpMessageHandler
{
    public bool Sse, FailClick, FailStart, SawTransportSession;
    public int StartCount, ClickCount, AuthorizationCount;
    public List<string> Methods { get; } = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Assert.Equal("agent365.svc.cloud.microsoft", request.RequestUri!.Host);
        Assert.Equal("fake-test-token", request.Headers.Authorization!.Parameter);
        AuthorizationCount++;
        using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
        var method = body.RootElement.GetProperty("method").GetString()!;
        Methods.Add(method);
        if (method == "notifications/initialized") return new(HttpStatusCode.Accepted);
        var id = body.RootElement.GetProperty("id").GetInt32();
        object result;
        switch (method)
        {
            case "initialize": result = new { protocolVersion = "2025-06-18" }; break;
            case "tools/list":
                SawTransportSession = request.Headers.Contains("Mcp-Session-Id");
                result = new { tools = new[] { "StartSession", "GetSessionDetails", "EndSession", "click" }
                    .Select(name => new { name, description = name, inputSchema = new { type = "object", properties = new { } } }) };
                break;
            case "tools/call":
                var name = body.RootElement.GetProperty("params").GetProperty("name").GetString();
                if (name == "StartSession") { StartCount++; if (FailStart) throw new HttpRequestException("ambiguous start"); }
                if (name == "click") { ClickCount++; if (FailClick) throw new HttpRequestException("ambiguous action"); }
                result = new { content = new[] { new { type = "text", text = name switch
                {
                    "StartSession" => """{"sessionId":"desktop","sessionLink":"https://screen.example/session"}""",
                    "GetSessionDetails" => """{"status":"Ready"}""", _ => "ok"
                } } } };
                break;
            default: throw new InvalidOperationException(method);
        }
        var json = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result });
        var response = new HttpResponseMessage(HttpStatusCode.OK);
        response.Headers.Add("Mcp-Session-Id", "transport");
        response.Content = new StringContent(Sse ? $"data: {json}\n\n" : json, Encoding.UTF8, Sse ? "text/event-stream" : "application/json");
        return response;
    }
}
