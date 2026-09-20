using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class DesktopRequestMiddlewareTests
{
    [Fact]
    public async Task DeniedCallerReturnsSafeBindingFingerprintAsync()
    {
        const string caller = "opaque-platform-user";
        var expected = "sha256:" + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(caller))).ToLowerInvariant();
        var settings = new Settings(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?>
            {
                ["HOSTED_ALLOWED_USER_ID"] = "pending"
            }).Build());
        var middleware = new DesktopRequestMiddleware(
            _ => throw new InvalidOperationException("Unauthorized requests must not continue."),
            settings,
            NullLogger<DesktopRequestMiddleware>.Instance);
        var context = new DefaultHttpContext();
        context.Request.Method = HttpMethods.Post;
        context.Request.Path = "/responses";
        context.Request.ContentType = "application/json";
        context.Request.Headers["x-agent-user-id"] = caller;
        context.Response.Body = new MemoryStream();

        await middleware.InvokeAsync(context, null!, null!, null!, NullLogger<McpConnection>.Instance);

        Assert.Equal(StatusCodes.Status403Forbidden, context.Response.StatusCode);
        context.Response.Body.Position = 0;
        using var body = await JsonDocument.ParseAsync(context.Response.Body);
        var error = body.RootElement.GetProperty("error");
        Assert.Equal("operator_binding_required", error.GetProperty("code").GetString());
        Assert.Equal(expected, error.GetProperty("fingerprint").GetString());
        Assert.DoesNotContain(caller, body.RootElement.GetRawText());
    }

    [Fact]
    public async Task InternalDeadlineDoesNotSilentlyAbortTheResponseAsync()
    {
        // Regression test: DesktopRequestMiddleware must not overwrite context.RequestAborted with its
        // internal per-task deadline. Simulate the deadline elapsing (an OperationCanceledException from
        // downstream) while the real client connection is still open, and confirm a graceful JSON
        // response is written instead of the request dying with no body.
        var settings = new Settings(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?>
            {
                ["SAMPLE_LOCAL_MODE"] = "true"
            }).Build());
        var middleware = new DesktopRequestMiddleware(
            _ => throw new OperationCanceledException("Simulated internal deadline."),
            settings,
            NullLogger<DesktopRequestMiddleware>.Instance);
        var context = new DefaultHttpContext();
        context.Request.Method = HttpMethods.Post;
        context.Request.Path = "/responses";
        context.Request.ContentType = "application/json";
        context.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes("{}"));
        context.Response.Body = new MemoryStream();

        await middleware.InvokeAsync(
            context,
            new HttpClient(),
            null!,
            null!,
            NullLogger<McpConnection>.Instance);

        Assert.False(context.RequestAborted.IsCancellationRequested);
        Assert.Equal(StatusCodes.Status504GatewayTimeout, context.Response.StatusCode);
        context.Response.Body.Position = 0;
        using var body = await JsonDocument.ParseAsync(context.Response.Body);
        Assert.Equal(
            "task_deadline_exceeded",
            body.RootElement.GetProperty("error").GetProperty("code").GetString());
    }
}
