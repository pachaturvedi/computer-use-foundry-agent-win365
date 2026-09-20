using System.Security.Claims;
using Win365Agent;

namespace Win365Viewer.Tests;

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

    [Fact]
    public void LiveViewLinkUsesViewOnlyModeAndEscapesSessionValues()
    {
        var link = ViewerEndpoints.BuildLiveViewUrl(
            new Uri("https://screenshare.example.com/"),
            "https://computer.example.com/session/screenshare?id=one two",
            "header.payload/signature");

        Assert.Equal(
            "https://screenshare.example.com/" +
            "#mode=viewOnly&computerUrl=https%3A%2F%2Fcomputer.example.com%2Fsession%3Fid%3Done%20two" +
            "&token=header.payload%2Fsignature",
            link);
    }

    [Fact]
    public void LiveViewLinkPreservesComputerUrlsWithoutScreenShareSuffix()
    {
        var link = ViewerEndpoints.BuildLiveViewUrl(
            new Uri("https://screenshare.example.com/"),
            "https://computer.example.com/session?id=one",
            "token");

        Assert.Contains(
            "computerUrl=https%3A%2F%2Fcomputer.example.com%2Fsession%3Fid%3Done",
            link,
            StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("http://computer.example.com/session", "token")]
    [InlineData("https://user@computer.example.com/session", "token")]
    [InlineData("https://computer.example.com/session", " ")]
    public void LiveViewLinkRejectsUnsafeInputs(string computerUrl, string token) =>
        Assert.Throws<InvalidOperationException>(() => ViewerEndpoints.BuildLiveViewUrl(
            new Uri("https://viewer.example.com/"),
            computerUrl,
            token));
}
