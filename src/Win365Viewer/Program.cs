using Azure.Core;
using Azure.Identity;
using Win365Agent;

var builder = WebApplication.CreateBuilder(args);
var settings = new Settings(builder.Configuration);

if (settings.Local)
{
    builder.WebHost.UseUrls($"http://localhost:{settings.LocalViewerPort}");
    builder.Configuration["AllowedHosts"] = "localhost;127.0.0.1;[::1]";
}

builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Logging.AddFilter("Azure", LogLevel.Warning);
builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.Warning);

settings.Validate(viewerMode: true);
if (!settings.Enabled)
{
    var bootstrap = builder.Build();
    bootstrap.MapGet("/health", () => Results.Ok(new
    {
        status = "healthy",
        viewerLiveEnabled = false
    }));
    bootstrap.MapFallback(() => Results.Json(
        new
        {
            error = "viewer_not_configured",
            message = "The companion viewer is deployed but not live. Configure the approved screen-share SDK and frame origins, then activate the viewer."
        },
        statusCode: StatusCodes.Status503ServiceUnavailable));
    bootstrap.Run();
    return;
}

builder.Services.AddSingleton(settings);
var viewerManagedIdentityClientId = settings.Required("AZURE_CLIENT_ID");
builder.Services.AddSingleton<TokenCredential>(new ManagedIdentityCredential(
    ManagedIdentityId.FromUserAssignedClientId(viewerManagedIdentityClientId)));
builder.Services.AddSingleton(new HttpClient(new SocketsHttpHandler
{
    AllowAutoRedirect = false,
    PooledConnectionLifetime = TimeSpan.FromMinutes(5)
})
{
    Timeout = TimeSpan.FromMinutes(3)
});
if (settings.BlueprintCredentialMode == "key_vault_certificate")
{
    builder.Services.AddSingleton<IBlueprintCertificateAssertionProvider>(services =>
        new KeyVaultBlueprintCertificateAssertionProvider(
            settings,
            services.GetRequiredService<TokenCredential>(),
            services.GetRequiredService<HttpClient>()));
}
builder.Services.AddSingleton<IBlueprintTokenProvider>(services =>
    new BlueprintTokenProvider(
        services.GetRequiredService<HttpClient>(),
        settings,
        viewerMode: true,
        services.GetRequiredService<ILogger<BlueprintTokenProvider>>(),
        certificateAssertionProvider: services.GetService<IBlueprintCertificateAssertionProvider>()));
builder.Services.AddSingleton<IAgentUserTokenProvider, AgentUserTokenProvider>();
builder.Services.AddSingleton<ISessionStore>(services =>
    new BlobSessionStore(
        settings.Https("SESSION_BLOB_URI"),
        services.GetRequiredService<TokenCredential>()));
builder.Services.AddHttpContextAccessor();

ViewerEndpoints.Configure(builder, settings);
var app = builder.Build();
ViewerEndpoints.Map(app, settings);
app.Run();

public partial class Program;
