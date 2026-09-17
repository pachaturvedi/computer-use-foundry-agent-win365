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

        await middleware.InvokeAsync(context, null!, null!, null!);

        Assert.Equal(StatusCodes.Status403Forbidden, context.Response.StatusCode);
        context.Response.Body.Position = 0;
        using var body = await JsonDocument.ParseAsync(context.Response.Body);
        var error = body.RootElement.GetProperty("error");
        Assert.Equal("operator_binding_required", error.GetProperty("code").GetString());
        Assert.Equal(expected, error.GetProperty("fingerprint").GetString());
        Assert.DoesNotContain(caller, body.RootElement.GetRawText());
    }
}
