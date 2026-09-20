using System.Text.Json;
using Microsoft.Extensions.AI;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class DesktopAgentHostingTests
{
    [Fact]
    public void LeaseTimeoutMapsToSafeNonRetryableModelError()
    {
        var error = DesktopAgentHosting.MapLockedState(
            new SessionLeaseUnavailableException());

        Assert.Equal("error", error.Status);
        Assert.Equal("desktop_state_locked", error.Code);
        Assert.Contains("Do not retry automatically", error.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("sessionId", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task DesktopActionContentIsNotJsonSerializedAsync()
    {
        IList<AIContent> content =
        [
            new TextContent("screenshot"),
            new DataContent(new byte[] { 1, 2, 3 }, "image/jpeg")
        ];
        var tool = DesktopAgentHosting.CreateDesktopActionFunction(
            (toolName, arguments, cancellationToken) => Task.FromResult<object>(content));

        var result = await tool.InvokeAsync(new AIFunctionArguments
        {
            ["toolName"] = "take_screenshot",
            ["arguments"] = JsonDocument.Parse("{}").RootElement.Clone()
        });

        Assert.Same(content, result);
        Assert.Null(tool.ReturnJsonSchema);
    }

    [Fact]
    public async Task DesktopActionErrorRemainsStructuredJsonAsync()
    {
        var error = new DesktopAgentHosting.DesktopToolError(
            "error",
            "desktop_state_locked",
            "Operator recovery required.");
        var tool = DesktopAgentHosting.CreateDesktopActionFunction(
            (toolName, arguments, cancellationToken) => Task.FromResult<object>(error));

        var result = await tool.InvokeAsync(new AIFunctionArguments
        {
            ["toolName"] = "take_screenshot",
            ["arguments"] = JsonDocument.Parse("{}").RootElement.Clone()
        });

        var json = Assert.IsType<JsonElement>(result);
        Assert.Equal("desktop_state_locked", json.GetProperty("code").GetString());
    }
}
