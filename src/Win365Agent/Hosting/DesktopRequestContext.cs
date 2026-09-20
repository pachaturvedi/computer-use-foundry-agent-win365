namespace Win365Agent;

internal static class DesktopRequestContext
{
    internal const string ItemKey = "desktop";
    internal const string DeadlineItemKey = "desktop-deadline";

    internal static DesktopRuntime Current(IHttpContextAccessor accessor) =>
        (DesktopRuntime)(accessor.HttpContext?.Items[ItemKey]
            ?? throw new InvalidOperationException(
                "Desktop tools require an authorized Responses request."));

    /// <summary>
    /// Gets a cancellation token combining the caller-supplied token with the request's bounded
    /// per-task deadline, so desktop/W365 operations still respect the 15-minute budget even though
    /// <see cref="HttpContext.RequestAborted"/> is no longer overwritten with it.
    /// </summary>
    internal static CancellationTokenSource LinkDeadline(IHttpContextAccessor accessor, CancellationToken callerToken)
    {
        var deadline = accessor.HttpContext?.Items[DeadlineItemKey] as CancellationToken?;
        return deadline is { } token
            ? CancellationTokenSource.CreateLinkedTokenSource(callerToken, token)
            : CancellationTokenSource.CreateLinkedTokenSource(callerToken);
    }
}
