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
    private readonly Lazy<Task<string>> _secret;

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
        _secret = new Lazy<Task<string>>(FetchAsync, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    /// <inheritdoc/>
    public Task<string> GetSecretAsync(CancellationToken cancellationToken) => _secret.Value;

    private async Task<string> FetchAsync()
    {
        var secret = await _client.GetSecretAsync(SecretName).ConfigureAwait(false);
        return secret.Value.Value;
    }
}
