using Win365Agent;

namespace Win365Viewer.Tests;

internal static class TestSettings
{
    internal static DesktopSession Session() => new()
    {
        RequestId = "task",
        OwnerObjectId = "owner",
        OwnerTenantId = "tenant",
        Phase = DesktopSessionPhase.Active,
        SessionId = "desktop"
    };
}
