namespace Win365Agent;

internal static class DesktopRequestContext
{
    internal const string ItemKey = "desktop";

    internal static DesktopRuntime Current(IHttpContextAccessor accessor) =>
        (DesktopRuntime)(accessor.HttpContext?.Items[ItemKey]
            ?? throw new InvalidOperationException(
                "Desktop tools require an authorized Responses request."));
}
