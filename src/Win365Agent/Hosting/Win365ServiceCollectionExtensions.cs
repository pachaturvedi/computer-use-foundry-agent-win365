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
        builder.Services.AddSingleton<IBlueprintTokenProvider>(services =>
            new BlueprintTokenProvider(
                services.GetRequiredService<HttpClient>(),
                settings,
                viewerMode,
                services.GetRequiredService<ILogger<BlueprintTokenProvider>>()));
        builder.Services.AddSingleton<IAgentUserTokenProvider, AgentUserTokenProvider>();
        builder.Services.AddSingleton<ISessionStore>(services =>
            new BlobSessionStore(
                settings.Https("SESSION_BLOB_URI"),
                services.GetRequiredService<TokenCredential>()));
        builder.Services.AddHttpContextAccessor();
    }
}
