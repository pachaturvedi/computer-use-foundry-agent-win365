using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Security.KeyVault.Certificates;

namespace Win365Agent;

/// <summary>
/// Reads a certificate's public bytes and backing Key Vault key ID. Abstracted from
/// <see cref="CertificateClient"/> so tests can supply canned metadata without needing to
/// construct Azure SDK response models, which have no public constructor for this purpose.
/// </summary>
internal interface ICertificateMetadataReader
{
    /// <summary>Reads the current public certificate bytes and backing key ID.</summary>
    /// <param name="certificateName">The Key Vault certificate name.</param>
    /// <param name="cancellationToken">A token that cancels the request.</param>
    Task<(byte[] Cer, Uri? KeyId)> GetCertificateAsync(string certificateName, CancellationToken cancellationToken);
}

internal sealed class CertificateClientMetadataReader(CertificateClient client) : ICertificateMetadataReader
{
    public async Task<(byte[] Cer, Uri? KeyId)> GetCertificateAsync(string certificateName, CancellationToken cancellationToken)
    {
        var certificate = await client.GetCertificateAsync(certificateName, cancellationToken).ConfigureAwait(false);
        return (certificate.Value.Cer, certificate.Value.KeyId);
    }
}

/// <summary>
/// Builds a self-signed JWT client assertion for the <c>key_vault_certificate</c> blueprint
/// credential mode. The certificate's public bytes are read from Key Vault to compute the
/// standard <c>x5t</c> thumbprint, and the assertion is signed remotely by calling Key Vault's
/// own <c>sign</c> REST operation against the certificate's backing key. The private key is
/// never exported, downloaded, or held in process memory; Key Vault performs the signing
/// operation and returns only the signature.
/// </summary>
public sealed class KeyVaultBlueprintCertificateAssertionProvider : IBlueprintCertificateAssertionProvider
{
    /// <summary>The canonical certificate name, mirroring <see cref="KeyVaultBlueprintSecretResolver.SecretName"/>.</summary>
    public const string CertificateName = "w365-blueprint-certificate";

    private const string _keyVaultScope = "https://vault.azure.net/.default";
    private const string _keyVaultApiVersion = "7.4";

    private readonly ICertificateMetadataReader _metadataReader;
    private readonly TokenCredential _credential;
    private readonly HttpClient _http;
    private readonly string _certificateName;
    private Lazy<Task<(byte[] Thumbprint, Uri KeyId)>> _metadata;

    /// <summary>
    /// Initializes a provider bound to the shared Key Vault named by <c>W365_KEY_VAULT_NAME</c>
    /// and the canonical certificate named by <see cref="CertificateName"/>.
    /// </summary>
    /// <param name="settings">The configuration source providing the vault name.</param>
    /// <param name="credential">The hosted runtime's own credential; never an operator or CLI credential.</param>
    /// <param name="http">The client used for the Key Vault <c>sign</c> REST operation.</param>
    public KeyVaultBlueprintCertificateAssertionProvider(Settings settings, TokenCredential credential, HttpClient http)
        : this(
            new CertificateClientMetadataReader(new CertificateClient(
                new Uri($"https://{settings.Required("W365_KEY_VAULT_NAME")}.vault.azure.net/"),
                credential)),
            credential,
            http,
            CertificateName)
    {
    }

    internal KeyVaultBlueprintCertificateAssertionProvider(
        ICertificateMetadataReader metadataReader,
        TokenCredential credential,
        HttpClient http,
        string certificateName)
    {
        _metadataReader = metadataReader;
        _credential = credential;
        _http = http;
        _certificateName = certificateName;
        _metadata = CreateLazyMetadataFetch(CancellationToken.None);
    }

    /// <inheritdoc/>
    public async Task<string> GetClientAssertionAsync(string clientId, string tokenEndpoint, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(clientId);
        ArgumentException.ThrowIfNullOrWhiteSpace(tokenEndpoint);

        var (thumbprint, keyId) = await GetMetadataAsync(cancellationToken).ConfigureAwait(false);

        var now = DateTimeOffset.UtcNow;
        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string>
        {
            ["alg"] = "RS256",
            ["typ"] = "JWT",
            ["x5t"] = Base64UrlEncode(thumbprint)
        });
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["aud"] = tokenEndpoint,
            ["iss"] = clientId,
            ["sub"] = clientId,
            ["jti"] = Guid.NewGuid().ToString(),
            ["nbf"] = now.ToUnixTimeSeconds(),
            ["exp"] = now.AddMinutes(5).ToUnixTimeSeconds()
        });
        var signingInput = $"{Base64UrlEncode(headerBytes)}.{Base64UrlEncode(payloadBytes)}";
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(signingInput));

        var signature = await SignAsync(keyId, digest, cancellationToken).ConfigureAwait(false);
        return $"{signingInput}.{Base64UrlEncode(signature)}";
    }

    private async Task<byte[]> SignAsync(Uri keyId, byte[] digest, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(
            new TokenRequestContext([_keyVaultScope]),
            cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{keyId}/sign?api-version={_keyVaultApiVersion}")
        {
            Headers = { Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token.Token) },
            Content = JsonContent.Create(new { alg = "RS256", value = Base64UrlEncode(digest) })
        };
        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new InvalidOperationException(
                $"Key Vault sign operation failed (HTTP {(int)response.StatusCode}): {body}");
        }

        using var json = await response.Content.ReadFromJsonAsync<JsonDocument>(cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidOperationException("Empty Key Vault sign response.");
        var value = json.RootElement.GetProperty("value").GetString();
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException("Key Vault sign response did not contain a signature value.");
        }

        return Base64UrlDecode(value);
    }

    private async Task<(byte[] Thumbprint, Uri KeyId)> GetMetadataAsync(CancellationToken cancellationToken)
    {
        var attempt = Volatile.Read(ref _metadata);
        try
        {
            return await attempt.Value.ConfigureAwait(false);
        }
        catch
        {
            // Only a successful fetch is cached for the process lifetime. A failed attempt (for
            // example, RBAC not yet propagated or a transient Key Vault error) must not be cached
            // forever; swap in a fresh attempt so the next call retries instead of replaying the
            // same failure indefinitely.
            Interlocked.CompareExchange(ref _metadata, CreateLazyMetadataFetch(cancellationToken), attempt);
            throw;
        }
    }

    private Lazy<Task<(byte[] Thumbprint, Uri KeyId)>> CreateLazyMetadataFetch(CancellationToken cancellationToken) =>
        new(() => FetchMetadataAsync(cancellationToken), LazyThreadSafetyMode.ExecutionAndPublication);

    private async Task<(byte[] Thumbprint, Uri KeyId)> FetchMetadataAsync(CancellationToken cancellationToken)
    {
        var (cer, keyId) = await _metadataReader
            .GetCertificateAsync(_certificateName, cancellationToken)
            .ConfigureAwait(false);
        if (keyId is null)
        {
            throw new InvalidOperationException(
                $"Certificate '{_certificateName}' has no backing Key Vault key and cannot be used for remote signing.");
        }

        // SHA-1 is required here only to compute the standard x5t JWT header thumbprint (RFC 7517
        // / Entra client-assertion convention); it is not used for any signing or verification
        // security decision, so this is not a cryptographic weakness.
#pragma warning disable CA5350
        var thumbprint = SHA1.HashData(cer);
#pragma warning restore CA5350

        return (thumbprint, keyId);
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        var padded = value.Replace('-', '+').Replace('_', '/');
        padded += new string('=', (4 - (padded.Length % 4)) % 4);
        return Convert.FromBase64String(padded);
    }
}
