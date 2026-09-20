namespace Win365Agent;

internal static class ApplicationHosting
{
    internal static void Configure(
        WebApplicationBuilder builder,
        Settings settings,
        bool viewerMode)
    {
        if (settings.Local)
        {
            // Local mode deliberately stays on loopback because it bypasses deployed hosting and viewer authentication.
            var localPort = viewerMode ? settings.LocalViewerPort : settings.LocalAgentPort;
            builder.WebHost.UseUrls($"http://localhost:{localPort}");
            builder.Configuration["AllowedHosts"] = "localhost;127.0.0.1;[::1]";
        }

        builder.Logging.SetMinimumLevel(LogLevel.Information);
        builder.Logging.AddFilter("Azure", LogLevel.Warning);
        builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.Warning);
        builder.Logging.AddFilter("Microsoft.Agents", LogLevel.Warning);

        if (!viewerMode &&
            !settings.Local &&
            string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FOUNDRY_HOSTING_ENVIRONMENT")))
        {
            // The hosted agent relies on Foundry's request envelope and identity; direct production hosting is unsupported.
            throw new InvalidOperationException(
                "Agent mode must run behind Foundry hosting. " +
                "Use explicit loopback local mode for development.");
        }

        if (!settings.Enabled && !viewerMode && !settings.Local)
        {
            // The bootstrap container must listen on every interface so the platform health probes can reach it.
            builder.WebHost.UseUrls($"http://0.0.0.0:{settings.HostedPort}");
        }
    }
}
