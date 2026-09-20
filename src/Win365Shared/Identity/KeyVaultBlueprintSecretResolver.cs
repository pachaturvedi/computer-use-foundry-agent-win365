using Azure.Core;
using Azure.Security.KeyVault.Secrets;

namespace Win365Agent;

/// <summary>
/// Fetches the blueprint client secret directly from the shared Key Vault using the hosted
/// runtime's own identity (the same principal already granted access to shared Blob state),
/// instead of receiving it through an environment variable. The resolved value is cached in
/// memory for the process lifetime; rotating the secret requires a redeploy so the new version is
/// fetched by a fresh process.
/// </summary>
public sealed class KeyVaultBlueprintSecretResolver : IBlueprintSecretResolver
{
    /// <summary>The canonical secret name shared with the optional viewer's Key Vault reference.</summary>
    public const string SecretName = "w365-blueprint-client-secret";

    private readonly SecretClient _client;
    private Lazy<Task<string>> _secret;

    /// <summary>Initializes a resolver bound to the shared Key Vault named by <c>W365_KEY_VAULT_NAME</c>.</summary>
    /// <param name="settings">The configuration source providing the vault name.</param>
    /// <param name="credential">The hosted runtime's own credential; never an operator or CLI credential.</param>
    public KeyVaultBlueprintSecretResolver(Settings settings, TokenCredential credential)
        : this(new SecretClient(
            new Uri($"https://{settings.Required("W365_KEY_VAULT_NAME")}.vault.azure.net/"),
            credential))
    {
    }

    internal KeyVaultBlueprintSecretResolver(SecretClient client)
    {
        _client = client;
        _secret = CreateLazyFetch(CancellationToken.None);
    }

    /// <inheritdoc/>
    public async Task<string> GetSecretAsync(CancellationToken cancellationToken)
    {
        var attempt = Volatile.Read(ref _secret);
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
            Interlocked.CompareExchange(ref _secret, CreateLazyFetch(cancellationToken), attempt);
            throw;
        }
    }

    private Lazy<Task<string>> CreateLazyFetch(CancellationToken cancellationToken) =>
        new(() => FetchAsync(cancellationToken), LazyThreadSafetyMode.ExecutionAndPublication);

    private async Task<string> FetchAsync(CancellationToken cancellationToken)
    {
        var secret = await _client.GetSecretAsync(SecretName, cancellationToken: cancellationToken).ConfigureAwait(false);
        return secret.Value.Value;
    }
}
