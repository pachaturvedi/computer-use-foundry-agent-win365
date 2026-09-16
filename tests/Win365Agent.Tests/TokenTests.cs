using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class TokenTests
{
    [Fact]
    public async Task ThreeStageFlowCachesByScopeAndNeverUsesABlueprintSecret()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".pfx");
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=offline", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
        await File.WriteAllBytesAsync(path, cert.Export(X509ContentType.Pfx, "offline-only-password"));
        try
        {
            var settings = new Settings(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
                ["W365_BLUEPRINT_ID"] = "blueprint", ["W365_AGENT_ID"] = "agent", ["W365_AGENT_USER_ID"] = "agent-user",
                ["W365_CERTIFICATE_PATH"] = path, ["W365_CERTIFICATE_PASSWORD"] = "offline-only-password"
            }).Build());
            using var handler = new TokenHandler();
            using var http = new HttpClient(handler);
            using var provider = new AgentUserTokens(http, settings, new UnusedCredential());
            var results = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => provider.GetAsync(AgentUserTokens.Atg, default)));
            Assert.All(results, token => Assert.Equal("token-3", token.Token));
            Assert.Equal(3, handler.Forms.Count);
            Assert.Equal("blueprint", handler.Forms[0]["client_id"]);
            Assert.Equal("agent", handler.Forms[0]["fmi_path"]);
            Assert.Equal("token-1", handler.Forms[1]["client_assertion"]);
            Assert.Equal("token-1", handler.Forms[2]["client_assertion"]);
            Assert.Equal("token-2", handler.Forms[2]["user_federated_identity_credential"]);
            Assert.Equal("user_fic", handler.Forms[2]["grant_type"]);
            Assert.Equal("agent-user", handler.Forms[2]["user_id"]);
            Assert.Equal($"{AgentUserTokens.Atg}/.default", handler.Forms[2]["scope"]);
            await provider.GetAsync(AgentUserTokens.AriView, default);
            Assert.Equal(6, handler.Forms.Count);
            Assert.Equal(AgentUserTokens.AriView, handler.Forms[5]["scope"]);
            Assert.DoesNotContain("Computer.Control", handler.Forms[5]["scope"]);
            await provider.GetAsync(AgentUserTokens.Ari, default);
            Assert.Contains("Computer.Control", handler.Forms[8]["scope"]);
            Assert.All(handler.Forms, f => Assert.False(f.ContainsKey("client_secret")));
            await Assert.ThrowsAsync<ArgumentException>(() => provider.GetAsync("https://untrusted.example", default));
        }
        finally { File.Delete(path); }
    }
    private sealed class UnusedCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Test must not use Azure credentials.");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Test must not use Azure credentials.");
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
