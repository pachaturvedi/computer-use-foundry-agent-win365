using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;

namespace Win365Agent;

public interface IAgentUserTokens
{
    Task<AccessToken> GetAsync(string audience, CancellationToken ct);
}

// Explicit thin-protocol implementation of Entra's documented agent-user FIC flow.
// Replace this boundary with an Agent 365 SDK token provider when adopting its host integration.
public sealed class AgentUserTokens(HttpClient http, Settings settings, TokenCredential credential)
    : IAgentUserTokens, IDisposable
{
    public const string Atg = "da81128c-e5b5-4f9e-8d89-50d906f107c5";
    public const string Ari = "90ecec28-f5a6-42b3-9bde-dae1ca98f8b5";
    public const string AriView = Ari + "/Computer.See";
    private const string Exchange = "api://AzureADTokenExchange/.default";
    private const string AssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";
    private readonly SemaphoreSlim gate = new(1);
    private readonly Dictionary<string, AccessToken> cache = [];

    public async Task<AccessToken> GetAsync(string audience, CancellationToken ct)
    {
        if (audience != Atg && audience != Ari && audience != AriView) throw new ArgumentException("Unsupported token audience.");
        await gate.WaitAsync(ct);
        try
        {
            if (cache.TryGetValue(audience, out var cached) && cached.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
                return cached;
            var blueprint = settings.Required("W365_BLUEPRINT_ID");
            var agent = settings.Required("W365_AGENT_ID");
            using var certificate = await LoadCertificateAsync(ct);
            var endpoint = $"https://login.microsoftonline.com/{settings.Tenant}/oauth2/v2.0/token";
            var t1 = await ExchangeAsync(new()
            {
                ["client_id"] = blueprint, ["grant_type"] = "client_credentials", ["scope"] = Exchange,
                ["fmi_path"] = agent, ["client_assertion_type"] = AssertionType,
                ["client_assertion"] = CreateAssertion(certificate, blueprint, endpoint)
            }, ct);
            var t2 = await ExchangeAsync(new()
            {
                ["client_id"] = agent, ["grant_type"] = "client_credentials", ["scope"] = Exchange,
                ["client_assertion_type"] = AssertionType, ["client_assertion"] = t1.Token
            }, ct);
            var result = await ExchangeAsync(new()
            {
                ["client_id"] = agent, ["grant_type"] = "user_fic",
                ["scope"] = audience == AriView ? AriView :
                    audience == Ari ? $"{Ari}/Computer.See {Ari}/Computer.Control" : $"{Atg}/.default",
                ["client_assertion_type"] = AssertionType, ["client_assertion"] = t1.Token,
                ["user_federated_identity_credential"] = t2.Token,
                ["user_id"] = settings.Required("W365_AGENT_USER_ID")
            }, ct);
            cache[audience] = result;
            return result;
        }
        finally { gate.Release(); }
    }

    private async Task<X509Certificate2> LoadCertificateAsync(CancellationToken ct)
    {
        byte[] data;
        if (settings.Optional("W365_CERTIFICATE_PATH") is { } path)
            data = await File.ReadAllBytesAsync(path, ct);
        else
        {
            var client = new SecretClient(settings.Https("W365_KEY_VAULT_URL"), credential);
            var secret = await client.GetSecretAsync(settings.Required("W365_CERTIFICATE_SECRET_NAME"), cancellationToken: ct);
            data = Convert.FromBase64String(secret.Value.Value);
        }
        try
        {
            return X509CertificateLoader.LoadPkcs12(data, settings.Optional("W365_CERTIFICATE_PASSWORD"),
                X509KeyStorageFlags.EphemeralKeySet);
        }
        finally { CryptographicOperations.ZeroMemory(data); }
    }

    internal static string CreateAssertion(X509Certificate2 cert, string client, string endpoint)
    {
        if (!cert.HasPrivateKey || cert.NotAfter.ToUniversalTime() <= DateTime.UtcNow ||
            cert.NotBefore.ToUniversalTime() > DateTime.UtcNow)
            throw new InvalidOperationException("Blueprint certificate is not currently valid or lacks a private key.");
        using var rsa = cert.GetRSAPrivateKey() ?? throw new InvalidOperationException("An RSA certificate is required.");
        var header = Encode(JsonSerializer.SerializeToUtf8Bytes(new
        {
            alg = "RS256", typ = "JWT", x5t = Encode(cert.GetCertHash())
        }));
        var now = DateTimeOffset.UtcNow;
        var body = Encode(JsonSerializer.SerializeToUtf8Bytes(new
        {
            aud = endpoint, iss = client, sub = client, jti = Guid.NewGuid().ToString(),
            nbf = now.AddSeconds(-30).ToUnixTimeSeconds(), exp = now.AddMinutes(5).ToUnixTimeSeconds()
        }));
        var input = $"{header}.{body}";
        return $"{input}.{Encode(rsa.SignData(Encoding.ASCII.GetBytes(input), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))}";
    }
    private static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private async Task<AccessToken> ExchangeAsync(Dictionary<string, string> form, CancellationToken ct)
    {
        using var response = await http.PostAsync(
            $"https://login.microsoftonline.com/{settings.Tenant}/oauth2/v2.0/token",
            new FormUrlEncodedContent(form), ct);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"Agent-user token exchange failed (HTTP {(int)response.StatusCode}). Check tenant, certificate and consent.");
        using var json = await response.Content.ReadFromJsonAsync<JsonDocument>(ct)
            ?? throw new InvalidOperationException("Empty token response.");
        var expires = json.RootElement.GetProperty("expires_in").GetInt32();
        if (expires <= 0) throw new InvalidOperationException("Token has invalid expiry.");
        return new AccessToken(json.RootElement.GetProperty("access_token").GetString()!, DateTimeOffset.UtcNow.AddSeconds(expires));
    }
    public void Dispose() => gate.Dispose();
}
