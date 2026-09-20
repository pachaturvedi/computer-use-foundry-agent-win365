using Azure.Core;
using Azure.Identity;

namespace Win365Agent;

internal static class Win365ServiceCollectionExtensions
{
    internal static void AddWin365Services(
        this WebApplicationBuilder builder,
        Settings settings,
        bool viewerMode)
    {
        builder.Services.AddSingleton(settings);
        builder.Services.AddSingleton<TokenCredential>(new DefaultAzureCredential());
        builder.Services.AddSingleton(new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5)
        })
        {
            Timeout = TimeSpan.FromMinutes(3)
        });
        if (!viewerMode && settings.BlueprintCredentialMode == "client_secret")
        {
            // Reuses the same runtime identity already granted read access to shared Blob state
            // (see infra/state/keyvault.bicep) so the blueprint secret never needs to be delivered
            // to the hosted agent as an environment variable. The viewer (Container App) keeps
            // receiving W365_CLIENT_SECRET through its own native Key Vault secret reference.
            builder.Services.AddSingleton<IBlueprintSecretResolver>(services =>
                new KeyVaultBlueprintSecretResolver(settings, services.GetRequiredService<TokenCredential>()));
        }
        builder.Services.AddSingleton<IBlueprintTokenProvider>(services =>
            new BlueprintTokenProvider(
                services.GetRequiredService<HttpClient>(),
                settings,
                viewerMode,
                services.GetRequiredService<ILogger<BlueprintTokenProvider>>(),
                services.GetService<IBlueprintSecretResolver>()));
        builder.Services.AddSingleton<IAgentUserTokenProvider, AgentUserTokenProvider>();
        builder.Services.AddSingleton<ISessionStore>(services =>
            new BlobSessionStore(
                settings.Https("SESSION_BLOB_URI"),
                services.GetRequiredService<TokenCredential>()));
        builder.Services.AddHttpContextAccessor();
    }
}
