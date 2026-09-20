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
}
