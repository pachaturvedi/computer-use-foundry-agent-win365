using System.Security.Claims;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class ViewerEndpointsTests
{
    [Theory]
    [InlineData("owner", "tenant", true)]
    [InlineData("other", "tenant", false)]
    [InlineData("owner", "other", false)]
    public void OpaqueLinkAloneDoesNotAuthorizeViewer(
        string owner,
        string tenant,
        bool allowed)
    {
        var state = TestSettings.Session();
        var user = new ClaimsPrincipal(
            new ClaimsIdentity(
                [new Claim("oid", owner), new Claim("tid", tenant)]));

        Assert.Equal(allowed, ViewerEndpoints.Owns(state, state.LinkId, user));
        Assert.False(ViewerEndpoints.Owns(state, "wrong-link", user));
        state.ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1);
        Assert.False(ViewerEndpoints.Owns(state, state.LinkId, user));
    }
}
