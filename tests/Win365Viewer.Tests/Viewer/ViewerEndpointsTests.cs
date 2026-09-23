using System.Security.Claims;
using Azure.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
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

    [Fact]
    public void RemoteViewerTrustsOneForwardedProtocolHop()
    {
        var builder = WebApplication.CreateBuilder();
        var settings = new Settings(
            new ConfigurationBuilder()
                .AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["OPERATOR_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
                    ["OPERATOR_OBJECT_ID"] = "22222222-2222-2222-2222-222222222222",
                    ["VIEWER_CLIENT_ID"] = "33333333-3333-3333-3333-333333333333",
                    ["VIEWER_PUBLIC_URL"] = "https://viewer.example.com"
                })
                .Build());

        ViewerEndpoints.Configure(builder, settings);

        using var provider = builder.Services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<ForwardedHeadersOptions>>().Value;
        Assert.Equal(ForwardedHeaders.XForwardedProto, options.ForwardedHeaders);
        Assert.Equal(1, options.ForwardLimit);
        Assert.Empty(options.KnownIPNetworks);
        Assert.Empty(options.KnownProxies);
    }

    [Fact]
    public async Task OidcClientAssertionUsesTheBoundViewerCredentialAndExactScopeAsync()
    {
        var credential = new RecordingCredential();

        var assertion = await ViewerOidcClientAssertion.GetAsync(
            credential,
            CancellationToken.None);

        Assert.Equal("viewer-assertion", assertion);
        Assert.Equal(["api://AzureADTokenExchange/.default"], credential.Scopes);
    }

    [Fact]
    public async Task OidcClientAssertionPropagatesCancellationAsync()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var credential = new RecordingCredential();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            ViewerOidcClientAssertion.GetAsync(credential, cancellation.Token).AsTask());
    }

    private sealed class RecordingCredential : TokenCredential
    {
        public string[] Scopes { get; private set; } = [];

        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            Scopes = requestContext.Scopes;
            return new AccessToken("viewer-assertion", DateTimeOffset.UtcNow.AddMinutes(5));
        }

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            Scopes = requestContext.Scopes;
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new AccessToken(
                "viewer-assertion",
                DateTimeOffset.UtcNow.AddMinutes(5)));
        }
    }
}
