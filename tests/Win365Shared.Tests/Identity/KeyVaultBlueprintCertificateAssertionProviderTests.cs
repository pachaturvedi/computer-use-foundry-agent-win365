using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Win365Agent;

namespace Win365Shared.Tests;

public sealed class KeyVaultBlueprintCertificateAssertionProviderTests
{
    private static readonly byte[] _certificateBytes = [1, 2, 3, 4, 5];
    private static readonly Uri _keyId = new("https://sample-vault.vault.azure.net/keys/w365-blueprint-cert/abc123");

    [Fact]
    public async Task BuildsAWellFormedClientAssertionSignedByKeyVaultAsync()
    {
        var reader = new CountingMetadataReader(_certificateBytes, _keyId);
        var credential = new FakeVaultCredential();
        var handler = new SignHandler();
        using var http = new HttpClient(handler);
        var provider = new KeyVaultBlueprintCertificateAssertionProvider(reader, credential, http, "w365-blueprint-cert");

        var assertion = await provider.GetClientAssertionAsync(
            "blueprint-client-id",
            "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
            default);

        var parts = assertion.Split('.');
        Assert.Equal(3, parts.Length);

        var header = JsonSerializer.Deserialize<Dictionary<string, string>>(Base64UrlDecode(parts[0]))!;
        Assert.Equal("RS256", header["alg"]);
        Assert.Equal("JWT", header["typ"]);
        // SHA-1 is only used to reproduce the expected x5t thumbprint under test, matching the
        // convention asserted in KeyVaultBlueprintCertificateAssertionProvider itself.
#pragma warning disable CA5350
        var expectedThumbprint = System.Security.Cryptography.SHA1.HashData(_certificateBytes);
#pragma warning restore CA5350
        Assert.Equal(
            Convert.ToBase64String(expectedThumbprint).TrimEnd('=').Replace('+', '-').Replace('/', '_'),
            header["x5t"]);

        var payload = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(Base64UrlDecode(parts[1]))!;
        Assert.Equal("blueprint-client-id", payload["iss"].GetString());
        Assert.Equal("blueprint-client-id", payload["sub"].GetString());
        Assert.Equal("https://login.microsoftonline.com/tenant/oauth2/v2.0/token", payload["aud"].GetString());
        Assert.True(payload["exp"].GetInt64() > payload["nbf"].GetInt64());

        // The fake sign handler echoes the request's digest back as the signature so this test
        // proves the exact bytes that were signed, without needing a real RSA private key.
        Assert.Equal(handler.LastDigestSent, Base64UrlDecode(parts[2]));
        Assert.Equal($"{_keyId}/sign?api-version=7.4", handler.LastRequestUri);
        Assert.Equal("vault-token", handler.LastAuthorizationToken);
        Assert.Equal(1, reader.Calls);
    }

    [Fact]
    public async Task CachesCertificateMetadataAcrossMultipleAssertionsAsync()
    {
        var reader = new CountingMetadataReader(_certificateBytes, _keyId);
        using var http = new HttpClient(new SignHandler());
        var provider = new KeyVaultBlueprintCertificateAssertionProvider(reader, new FakeVaultCredential(), http, "w365-blueprint-cert");

        await Task.WhenAll(Enumerable.Range(0, 5).Select(_ =>
            provider.GetClientAssertionAsync("client", "https://login.microsoftonline.com/t/oauth2/v2.0/token", default)));

        Assert.Equal(1, reader.Calls);
    }

    [Fact]
    public async Task RetriesAfterAFailedMetadataFetchInsteadOfCachingTheFailureForeverAsync()
    {
        var reader = new CountingMetadataReader(_certificateBytes, _keyId) { FailuresBeforeSuccess = 2 };
        using var http = new HttpClient(new SignHandler());
        var provider = new KeyVaultBlueprintCertificateAssertionProvider(reader, new FakeVaultCredential(), http, "w365-blueprint-cert");

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetClientAssertionAsync("client", "https://login.microsoftonline.com/t/oauth2/v2.0/token", default));
        await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetClientAssertionAsync("client", "https://login.microsoftonline.com/t/oauth2/v2.0/token", default));
        await provider.GetClientAssertionAsync("client", "https://login.microsoftonline.com/t/oauth2/v2.0/token", default);

        Assert.Equal(3, reader.Calls);
    }

    [Fact]
    public async Task ThrowsWhenTheCertificateHasNoBackingKeyAsync()
    {
        var reader = new CountingMetadataReader(_certificateBytes, keyId: null);
        using var http = new HttpClient(new SignHandler());
        var provider = new KeyVaultBlueprintCertificateAssertionProvider(reader, new FakeVaultCredential(), http, "w365-blueprint-cert");

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => provider.GetClientAssertionAsync("client", "https://login.microsoftonline.com/t/oauth2/v2.0/token", default));
    }

    private static byte[] Base64UrlDecode(string value)
    {
        var padded = value.Replace('-', '+').Replace('_', '/');
        padded += new string('=', (4 - (padded.Length % 4)) % 4);
        return Convert.FromBase64String(padded);
    }

    private sealed class CountingMetadataReader(byte[] cer, Uri? keyId) : ICertificateMetadataReader
    {
        public int Calls;
        public int FailuresBeforeSuccess;

        public async Task<(byte[] Cer, Uri? KeyId)> GetCertificateAsync(string certificateName, CancellationToken cancellationToken)
        {
            var callNumber = Interlocked.Increment(ref Calls);
            await Task.Yield();
            if (callNumber <= FailuresBeforeSuccess)
            {
                throw new InvalidOperationException($"Simulated Key Vault failure #{callNumber}.");
            }

            return (cer, keyId);
        }
    }

    private sealed class FakeVaultCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Assert.Equal(["https://vault.azure.net/.default"], requestContext.Scopes);
            return new AccessToken("vault-token", DateTimeOffset.UtcNow.AddHours(1));
        }

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class SignHandler : HttpMessageHandler
    {
        public byte[]? LastDigestSent { get; private set; }
        public string? LastRequestUri { get; private set; }
        public string? LastAuthorizationToken { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            LastRequestUri = request.RequestUri!.ToString();
            LastAuthorizationToken = request.Headers.Authorization?.Parameter;
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            Assert.Equal("RS256", json.RootElement.GetProperty("alg").GetString());
            LastDigestSent = Base64UrlDecode(json.RootElement.GetProperty("value").GetString()!);

            // Echo the digest back as the "signature" so tests can assert on the exact signed bytes.
            var body = JsonSerializer.Serialize(new { kid = "unused", value = json.RootElement.GetProperty("value").GetString() });
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
        }
    }
}
