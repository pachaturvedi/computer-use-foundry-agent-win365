namespace Win365Agent;

internal static class BootstrapEndpoints
{
    internal static void Map(WebApplication app)
    {
        // Keep the phase-one deployment probeable, but reject task traffic until W365 identity setup is complete.
        app.MapGet("/health", () => Results.Ok(new { status = "healthy", w365Enabled = false }));
        app.MapGet("/readiness", () => Results.Ok(new { status = "ready", w365Enabled = false }));
        app.MapGet("/liveness", () => Results.Ok(new { status = "alive" }));
        app.MapFallback(() => Results.Json(new
        {
            error = "w365_not_configured",
            message =
                "Phase 1 is ready. Complete Setup-W365.ps1 for the Foundry identity, " +
                "then deploy the same agent with W365_ENABLED=true."
        }, statusCode: StatusCodes.Status503ServiceUnavailable));
    }
}
