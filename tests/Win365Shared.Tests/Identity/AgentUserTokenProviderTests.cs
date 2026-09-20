using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using Win365Agent;

namespace Win365Shared.Tests;

public sealed class AgentUserTokenProviderTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FoundryAndFederatedViewerUseTheSameAgentUserWithoutStoredCredentialsAsync(bool viewer)
    {
        var settings = new Settings(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
            ["W365_BLUEPRINT_ID"] = "blueprint",
            ["W365_AGENT_ID"] = "agent",
            ["W365_AGENT_USER_ID"] = "agent-user"
        }).Build());
        using var handler = new TokenHandler();
        using var http = new HttpClient(handler);
        var credential = new FakeCredential();
        var blueprint = new BlueprintTokenProvider(http, settings, viewer, credential);
        using var provider = new AgentUserTokenProvider(http, settings, blueprint);
        var results = await Task.WhenAll(
            Enumerable.Range(0, 5).Select(_ => provider.GetAsync(AgentUserTokenProvider.Atg, default)));
        const int count = 3;
        const int first = 1;
        const string t1 = "token-1";
        Assert.All(results, token => Assert.Equal($"token-{count}", token.Token));
        Assert.Equal(count, handler.Forms.Count);
        Assert.Equal(1, credential.Calls);
        Assert.Equal("blueprint", handler.Forms[0]["client_id"]);
        Assert.Equal("agent", handler.Forms[0]["fmi_path"]);
        Assert.Equal("identity-endpoint-token", handler.Forms[0]["client_assertion"]);
        Assert.Equal("agent", handler.Forms[first]["client_id"]);
        Assert.Equal(t1, handler.Forms[first]["client_assertion"]);
        Assert.Equal(t1, handler.Forms[first + 1]["client_assertion"]);
        Assert.Equal($"token-{first + 1}", handler.Forms[first + 1]["user_federated_identity_credential"]);
        Assert.Equal("user_fic", handler.Forms[first + 1]["grant_type"]);
        Assert.Equal("agent-user", handler.Forms[first + 1]["user_id"]);
        Assert.Equal("on_behalf_of", handler.Forms[first + 1]["requested_token_use"]);
        Assert.Equal($"{AgentUserTokenProvider.Atg}/.default", handler.Forms[first + 1]["scope"]);
        await provider.GetAsync(AgentUserTokenProvider.AriView, default);
        Assert.Equal(count * 2, handler.Forms.Count);
        Assert.Equal(AgentUserTokenProvider.AriView, handler.Forms[^1]["scope"]);
        Assert.DoesNotContain("Computer.Control", handler.Forms[^1]["scope"]);
        await provider.GetAsync(AgentUserTokenProvider.Ari, default);
        Assert.Equal(
            $"{AgentUserTokenProvider.Ari}/Computer.See " +
            $"{AgentUserTokenProvider.Ari}/Computer.Control " +
            $"{AgentUserTokenProvider.Ari}/Computer.Do " +
            $"{AgentUserTokenProvider.Ari}/Computer.Get",
            handler.Forms[^1]["scope"]);
        Assert.All(handler.Forms, f => Assert.False(f.ContainsKey("client_secret")));
        await Assert.ThrowsAsync<ArgumentException>(() => provider.GetAsync("https://untrusted.example", default));
    }

    [Fact]
    public async Task MissingHostedIdentityHasNoFallbackAsync()
    {
        var settings = new Settings(new ConfigurationBuilder().Build());
        using var handler = new TokenHandler();
        using var http = new HttpClient(handler);
        var blueprint = new BlueprintTokenProvider(
            http,
            settings,
            false,
            new FakeCredential { Fail = true });
        await Assert.ThrowsAsync<InvalidOperationException>(() => blueprint.GetAsync(default));
        Assert.Empty(handler.Forms);
    }

    [Fact]
    public async Task ExplicitClientSecretModeSkipsManagedIdentityAsync()
    {
        var settings = new Settings(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
            ["W365_BLUEPRINT_ID"] = "blueprint",
            ["W365_AGENT_ID"] = "agent",
            ["W365_AGENT_USER_ID"] = "agent-user",
            ["W365_BLUEPRINT_CREDENTIAL_MODE"] = "client_secret",
            ["W365_CLIENT_SECRET"] = "temporary-secret"
        }).Build());
        using var handler = new TokenHandler();
        using var http = new HttpClient(handler);
        var credential = new FakeCredential { Fail = true };
        var blueprint = new BlueprintTokenProvider(http, settings, false, credential);
        using var provider = new AgentUserTokenProvider(http, settings, blueprint);

        var token = await provider.GetAsync(AgentUserTokenProvider.Atg, default);

        Assert.Equal("token-3", token.Token);
        Assert.Equal(0, credential.Calls);
        Assert.Equal("temporary-secret", handler.Forms[0]["client_secret"]);
        Assert.Equal("agent", handler.Forms[0]["fmi_path"]);
        Assert.Equal("token-1", handler.Forms[1]["client_assertion"]);
        Assert.Equal("token-2", handler.Forms[2]["user_federated_identity_credential"]);
    }

    private sealed class FakeCredential : TokenCredential
    {
        public int Calls;
        public bool Fail;
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Assert.Equal(["api://AzureADTokenExchange/.default"], requestContext.Scopes);
            Calls++;
            if (Fail)
            {
                throw new InvalidOperationException("No hosted identity.");
            }

            return new AccessToken("identity-endpoint-token", DateTimeOffset.UtcNow.AddHours(1));
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
    private sealed class TokenHandler : HttpMessageHandler
    {
        public List<Dictionary<string, string>> Forms { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Assert.Equal("login.microsoftonline.com", request.RequestUri!.Host);
            var form = (await request.Content!.ReadAsStringAsync(ct)).Split('&').Select(item => item.Split('=', 2))
                .ToDictionary(parts => WebUtility.UrlDecode(parts[0]), parts => WebUtility.UrlDecode(parts[1]));
            Forms.Add(form);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new { access_token = $"token-{Forms.Count}", expires_in = 3600 }), Encoding.UTF8, "application/json")
            };
        }
    }
}
