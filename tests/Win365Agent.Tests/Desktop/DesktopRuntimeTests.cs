using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class DesktopRuntimeTests
{
    [Theory]
    [InlineData("execute_shell_command")]
    [InlineData("execute_python_code")]
    [InlineData("browser_eval_js")]
    [InlineData("EndSession")]
    [InlineData("mcp_W365ComputerUse_click")]
    public void UnsafeOrInventedToolsAreNotExposed(string name) =>
        Assert.DoesNotContain(name, DesktopRuntime.AllowedTools);

    [Fact]
    public async Task ConcurrentOwnerIsDeniedAndPauseBlocksActionsUntilResumeAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        var store = temporaryStore.Create();
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        DesktopRuntime Runtime(string id) => new(
            new McpConnection(http, new FakeAgentUserTokenProvider(), TestSettings.Create()),
            store,
            TestSettings.Create(),
            id,
            NullLogger.Instance);
        using var first = Runtime("one");
        await first.OpenAsync(default);
        using var other = Runtime("two");

        await Assert.ThrowsAsync<InvalidOperationException>(() => other.OpenAsync(default));
        Assert.Equal(1, handler.StartCount);
        await first.HandoffAsync(default);
        using var timeout = new CancellationTokenSource(150);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => first.ExecuteAsync("click", TestSettings.Json("{}"), timeout.Token));
        Assert.Equal(0, handler.ClickCount);
        await using (var transaction = await store.OpenAsync(default))
        {
            transaction.State!.Phase = DesktopSessionPhase.Active;
            await transaction.SaveAsync(default);
        }

        await first.ExecuteAsync("click", TestSettings.Json("{}"), default);
        Assert.Equal(1, handler.ClickCount);
        await first.CloseAsync(default);
        await using var ended = await store.OpenAsync(default);
        Assert.Null(ended.State);
    }

    [Fact]
    public async Task ClosingDoesNotAllowAnotherAllocationInTheSameTaskAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        using var runtime = Runtime(http, handler, temporaryStore.Create());

        await runtime.OpenAsync(default);
        await runtime.CloseAsync(default);

        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.OpenAsync(default));
        Assert.Equal(1, handler.StartCount);
    }

    [Fact]
    public async Task SessionToolsAreRediscoveredWithoutReplacingTheAllocationTransportAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler { SessionScopedCatalog = true };
        using var http = new HttpClient(handler);
        using var runtime = Runtime(http, handler, temporaryStore.Create());

        await runtime.OpenAsync(default);

        var tools = JsonSerializer.SerializeToElement(runtime.Tools());
        Assert.Contains(tools.EnumerateArray(), tool => tool.GetProperty("name").GetString() == "click");
        Assert.DoesNotContain(
            tools.EnumerateArray(),
            tool => tool.GetProperty("inputSchema").GetRawText().Contains("sessionId", StringComparison.Ordinal));
        // One initialization proves allocation and interaction share the same live-compatible transport.
        Assert.Equal(1, handler.Methods.Count(method => method == "initialize"));
        await runtime.ExecuteAsync(
            "click",
            TestSettings.Json("""{"x":100,"y":200,"button":"Left","clickCount":1}"""),
            default);
        Assert.Equal(1, handler.ClickCount);
        await runtime.CloseAsync(default);
    }

    [Fact]
    public async Task AmbiguousActionIsNotReplayedAndBlocksFurtherActionsAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler { FailClick = true };
        using var http = new HttpClient(handler);
        using var runtime = Runtime(http, handler, temporaryStore.Create());

        await runtime.OpenAsync(default);
        await Assert.ThrowsAsync<HttpRequestException>(
            () => runtime.ExecuteAsync("click", TestSettings.Json("{}"), default));
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => runtime.ExecuteAsync("click", TestSettings.Json("{}"), default));
        Assert.Equal(1, handler.ClickCount);
        await runtime.CloseAsync(default);
    }

    [Fact]
    public async Task UnknownStartOutcomeIsDurablyBlockedAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler { FailStart = true };
        using var http = new HttpClient(handler);
        var store = temporaryStore.Create();
        using var runtime = Runtime(http, handler, store);

        await Assert.ThrowsAsync<HttpRequestException>(() => runtime.OpenAsync(default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.CloseAsync(default));
        await using var transaction = await store.OpenAsync(default);
        Assert.Equal(DesktopSessionPhase.Starting, transaction.State!.Phase);
        Assert.False(string.IsNullOrWhiteSpace(transaction.State.AllocationIdempotencyKey));
        Assert.Equal(1, handler.StartCount);
    }

    [Fact]
    public async Task AmbiguousStartIsRecoveredWithTheSameIdempotencyKeyAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler { AmbiguousStartsRemaining = 1 };
        using var http = new HttpClient(handler);
        var store = temporaryStore.Create();
        using (var originalRequest = Runtime(http, handler, store))
        {
            await Assert.ThrowsAsync<HttpRequestException>(() => originalRequest.OpenAsync(default));
            Assert.Equal("No operator resume is pending.", await originalRequest.WaitForResumeAsync(default));
            await Assert.ThrowsAsync<InvalidOperationException>(() => originalRequest.CloseAsync(default));
        }

        using var recoveryRequest = new DesktopRuntime(
            new McpConnection(http, new FakeAgentUserTokenProvider(), TestSettings.Create()),
            store,
            TestSettings.Create(),
            "recovery",
            NullLogger.Instance);

        await recoveryRequest.OpenAsync(default);
        Assert.Equal(2, handler.StartCount);
        Assert.Equal(handler.StartIdempotencyKeys[0], handler.StartIdempotencyKeys[1]);
        await recoveryRequest.CloseAsync(default);
    }

    [Fact]
    public async Task ModelCannotSupplyAnotherSessionAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        using var runtime = Runtime(http, handler, temporaryStore.Create());

        await runtime.OpenAsync(default);
        await Assert.ThrowsAsync<ArgumentException>(
            () => runtime.ExecuteAsync(
                "click",
                TestSettings.Json("""{"sessionId":"other"}"""),
                default));
        Assert.Equal(0, handler.ClickCount);
        await runtime.CloseAsync(default);
    }

    [Fact]
    public async Task OpenReturnsSeparateViewOnlyAndControlRoutesAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        using var handler = new McpHandler();
        using var http = new HttpClient(handler);
        using var runtime = Runtime(http, handler, temporaryStore.Create());

        var links = JsonSerializer.SerializeToElement(await runtime.OpenAsync(default));
        var liveView = new Uri(links.GetProperty("liveViewUrl").GetString()!);
        var takeControl = new Uri(links.GetProperty("takeControlUrl").GetString()!);

        Assert.Matches("^/live/[0-9a-f]{64}$", liveView.AbsolutePath);
        Assert.Matches("^/view/[0-9a-f]{64}$", takeControl.AbsolutePath);
        Assert.Equal(liveView.AbsolutePath["/live".Length..], takeControl.AbsolutePath["/view".Length..]);
        Assert.Empty(liveView.Fragment);
        Assert.Equal("#control", takeControl.Fragment);
        await runtime.CloseAsync(default);
    }

    private static DesktopRuntime Runtime(
        HttpClient http,
        McpHandler handler,
        FileSessionStore store) =>
        new(
            new McpConnection(http, new FakeAgentUserTokenProvider(), TestSettings.Create()),
            store,
            TestSettings.Create(),
            "one",
            NullLogger.Instance);

}
