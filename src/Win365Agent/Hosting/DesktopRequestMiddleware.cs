using System.Security.Cryptography;
using System.Text;

namespace Win365Agent;

internal sealed class DesktopRequestMiddleware(
    RequestDelegate next,
    Settings settings,
    ILogger<DesktopRequestMiddleware> logger)
{
    private static readonly Action<ILogger, string, string, Exception?> _logAccessDenied =
        LoggerMessage.Define<string, string>(
            LogLevel.Warning,
            new EventId(1, nameof(_logAccessDenied)),
            "Operator access denied. Partition fingerprint {Fingerprint}; request {TraceId}.");

    private static readonly Action<ILogger, string, Exception?> _logCleanupFailure =
        LoggerMessage.Define<string>(
            LogLevel.Critical,
            new EventId(2, nameof(_logCleanupFailure)),
            "Desktop cleanup failed ({ErrorType}); session slot remains blocked for operator recovery.");

    public async Task InvokeAsync(
        HttpContext context,
        HttpClient http,
        IAgentUserTokenProvider tokenProvider,
        ISessionStore sessionStore)
    {
        if (!ResponseRequestValidator.IsCreate(context.Request))
        {
            await next(context);
            return;
        }

        if (!settings.Local && !IsAuthorized(context, out var fingerprint))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            await context.Response.WriteAsJsonAsync(new
            {
                error = new
                {
                    code = "operator_binding_required",
                    message = "Bind this Foundry caller fingerprint before enabling desktop access.",
                    fingerprint,
                    traceId = context.TraceIdentifier
                }
            }, context.RequestAborted);
            return;
        }

        if (!await ResponseRequestValidator.ValidateAsync(context))
        {
            return;
        }

        // Bound the complete model task, including time spent waiting for operator handoff.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            context.RequestAborted);
        deadline.CancelAfter(TimeSpan.FromMinutes(10));
        context.RequestAborted = deadline.Token;
        using var desktop = new DesktopRuntime(
            new McpConnection(http, tokenProvider, settings),
            sessionStore,
            settings,
            Guid.NewGuid().ToString(),
            logger);
        context.Items[DesktopRequestContext.ItemKey] = desktop;

        try
        {
            await next(context);
            await desktop.WaitForResumeAsync(deadline.Token);
        }
        finally
        {
            // Cleanup gets its own deadline because the request token may already be canceled.
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(75));
            try
            {
                await desktop.CloseAsync(cleanup.Token);
            }
            catch (Exception exception)
            {
                _logCleanupFailure(logger, exception.GetType().Name, exception);
            }

            context.Items.Remove(DesktopRequestContext.ItemKey);
        }
    }

    private bool IsAuthorized(HttpContext context, out string fingerprint)
    {
        var values = context.Request.Headers["x-agent-user-id"];
        // Hash before logging and allow deployments to store either the legacy raw ID or its fingerprint.
        fingerprint = values.Count == 1 && values[0]?.Length is > 0 and < 1024
            ? "sha256:" + Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(values[0]!))).ToLowerInvariant()
            : "missing";
        if (fingerprint != "missing" &&
            (values.ToString() == settings.Required("HOSTED_ALLOWED_USER_ID") ||
                fingerprint == settings.Required("HOSTED_ALLOWED_USER_ID")))
        {
            return true;
        }

        _logAccessDenied(logger, fingerprint, context.TraceIdentifier, null);
        return false;
    }
}
