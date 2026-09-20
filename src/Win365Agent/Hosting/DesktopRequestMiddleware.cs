using System.Security.Cryptography;
using System.Text;

namespace Win365Agent;

internal sealed class DesktopRequestMiddleware(
    RequestDelegate next,
    Settings settings,
    ILogger<DesktopRequestMiddleware> logger)
{
    private static readonly Action<ILogger, string, Exception?> _logDesktopRequestStart =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(4, nameof(_logDesktopRequestStart)),
            "Accepted bounded desktop request {TraceId}."
        );

    private static readonly Action<ILogger, string, Exception?> _logDesktopRequestComplete =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(5, nameof(_logDesktopRequestComplete)),
            "Completed bounded desktop request {TraceId}."
        );

    private static readonly Action<ILogger, string, Exception?> _logDesktopCleanupComplete =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(6, nameof(_logDesktopCleanupComplete)),
            "Completed desktop cleanup for request {TraceId}."
        );

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

    private static readonly Action<ILogger, string, Exception?> _logTaskDeadlineExceeded =
        LoggerMessage.Define<string>(
            LogLevel.Warning,
            new EventId(3, nameof(_logTaskDeadlineExceeded)),
            "Bounded desktop task exceeded its 15-minute execution budget; request {TraceId}.");

    public async Task InvokeAsync(
        HttpContext context,
        HttpClient http,
        IAgentUserTokenProvider tokenProvider,
        ISessionStore sessionStore,
        ILogger<McpConnection> mcpLogger)
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

        // Bound the complete model task, including time spent waiting for operator handoff. Keep the
        // real client-abort signal separate from this internal budget: overwriting context.RequestAborted
        // ties the entire downstream response pipeline (including the final assistant message) to the
        // 15-minute deadline, so once it fires, no graceful error can ever be written back and the
        // connection is silently torn down with no output. Instead, the deadline cancels only the
        // desktop/W365 work and the wait below; a genuine client disconnect still cancels normally.
        var clientAborted = context.RequestAborted;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(clientAborted);
        deadline.CancelAfter(TimeSpan.FromMinutes(15));
        using var desktop = new DesktopRuntime(
            new McpConnection(http, tokenProvider, settings, mcpLogger),
            sessionStore,
            settings,
            Guid.NewGuid().ToString(),
            logger);
        context.Items[DesktopRequestContext.ItemKey] = desktop;
        context.Items[DesktopRequestContext.DeadlineItemKey] = deadline.Token;
        _logDesktopRequestStart(logger, context.TraceIdentifier, null);

        try
        {
            await next(context);
            await desktop.WaitForResumeAsync(deadline.Token);
            _logDesktopRequestComplete(logger, context.TraceIdentifier, null);
        }
        catch (OperationCanceledException) when (!clientAborted.IsCancellationRequested)
        {
            // The internal per-task deadline fired while the real client connection is still open;
            // report it instead of leaving the caller with a silent, contentless response.
            _logTaskDeadlineExceeded(logger, context.TraceIdentifier, null);
            if (!context.Response.HasStarted)
            {
                context.Response.StatusCode = StatusCodes.Status504GatewayTimeout;
                await context.Response.WriteAsJsonAsync(new
                {
                    error = new
                    {
                        code = "task_deadline_exceeded",
                        message = "The bounded desktop task exceeded its 15-minute execution budget before completing.",
                        traceId = context.TraceIdentifier
                    }
                }, CancellationToken.None);
            }
        }
        finally
        {
            // Cleanup gets its own deadline because the request token may already be canceled.
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(75));
            try
            {
                await desktop.CloseAsync(cleanup.Token);
                _logDesktopCleanupComplete(logger, context.TraceIdentifier, null);
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
