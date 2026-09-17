using System.Net.Http;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class McpConnectionTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task InitializeSupportsEmptyNotificationAndJsonOrSseAsync(bool sse)
    {
        using var handler = new McpHandler { Sse = sse };
        using var http = new HttpClient(handler);
        var mcp = new McpConnection(
            http,
            new FakeAgentUserTokenProvider(),
            TestSettings.Create());

        await mcp.InitializeAsync(default);

        Assert.NotEmpty(await mcp.ListAsync(default));
        Assert.Equal(["initialize", "notifications/initialized", "tools/list"], handler.Methods);
        Assert.True(handler.SawTransportSession);
        Assert.Equal(3, handler.AuthorizationCount);
    }

    [Fact]
    public void MismatchedResponseCannotBeUsed() =>
        Assert.Null(McpConnection.Parse("""{"id":2,"result":{}}""", 1));

    [Fact]
    public void RpcErrorDoesNotExposeBody() =>
        Assert.DoesNotContain(
            "secret",
            Assert.Throws<InvalidOperationException>(() =>
                McpConnection.Parse("""{"id":1,"error":{"message":"secret"}}""", 1)).Message);

    [Fact]
    public void FieldReadsEmbeddedMcpText() =>
        Assert.Equal(
            "abc",
            McpConnection.Field(
                TestSettings.Json(
                    """{"content":[{"type":"text","text":"{\"sessionId\":\"abc\"}"}]}"""),
                "sessionId"));

    [Fact]
    public void OrdinaryTextDoesNotBecomeASession() =>
        Assert.Null(
            McpConnection.Field(
                TestSettings.Json("""{"content":[{"type":"text","text":"{not json"}]}"""),
                "sessionId"));
}
