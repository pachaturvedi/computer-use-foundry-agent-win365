using System.Security.Claims;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;

namespace Win365Agent;

/// <summary>Configures and maps the authenticated operator UI for viewing and controlling desktop sessions.</summary>
public static class ViewerEndpoints
{
    /// <summary>
    /// Registers antiforgery, authorization, and non-local OpenID Connect authentication services for the viewer.
    /// </summary>
    /// <param name="builder">The web application builder.</param>
    /// <param name="settings">The viewer and operator identity configuration.</param>
    public static void Configure(WebApplicationBuilder builder, Settings settings)
    {
        builder.Services.AddAntiforgery(o =>
        {
            o.HeaderName = "X-CSRF-TOKEN";
            o.Cookie.SecurePolicy = settings.Local ? CookieSecurePolicy.SameAsRequest : CookieSecurePolicy.Always;
        });
        if (!settings.Local)
        {
            builder.Services.AddAuthentication(o =>
            { o.DefaultScheme = "cookie"; o.DefaultChallengeScheme = "oidc"; })
                .AddCookie("cookie", o =>
                {
                    o.Cookie.Name = "__Host-w365-viewer";
                    o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
                    o.Cookie.HttpOnly = true;
                    o.ExpireTimeSpan = TimeSpan.FromMinutes(30);
                    o.SlidingExpiration = false;
                })
                .AddOpenIdConnect("oidc", o =>
                {
                    o.Authority = $"https://login.microsoftonline.com/{Guid.Parse(settings.Required("OPERATOR_TENANT_ID"))}/v2.0";
                    o.ClientId = settings.Required("VIEWER_CLIENT_ID");
                    o.ClientSecret = settings.Required("VIEWER_CLIENT_SECRET");
                    o.ResponseType = "code";
                    o.UsePkce = true;
                    o.SaveTokens = false;
                    o.MapInboundClaims = false;
                    o.Scope.Clear(); o.Scope.Add("openid"); o.Scope.Add("profile");
                    o.Events.OnRedirectToIdentityProvider = ctx =>
                    {
                        ctx.ProtocolMessage.RedirectUri = new Uri(settings.ViewerUrl, "signin-oidc").ToString();
                        return Task.CompletedTask;
                    };
                    o.Events.OnAuthorizationCodeReceived = ctx =>
                    {
                        ctx.TokenEndpointRequest!.RedirectUri = new Uri(settings.ViewerUrl, "signin-oidc").ToString();
                        return Task.CompletedTask;
                    };
                });
        }
        builder.Services.AddAuthorization(o => o.AddPolicy("operator", policy =>
        {
            policy.RequireAuthenticatedUser();
            policy.RequireClaim("tid", settings.Required("OPERATOR_TENANT_ID"));
            policy.RequireClaim("oid", settings.Required("OPERATOR_OBJECT_ID"));
        }));
    }
    /// <summary>
    /// Adds viewer security headers and maps health, static asset, session display, and operator action endpoints.
    /// </summary>
    /// <param name="app">The configured web application.</param>
    /// <param name="settings">The screen-sharing, viewer, and operator configuration.</param>
    /// <exception cref="InvalidOperationException">The configured screen-sharing frame origins are invalid.</exception>
    public static void Map(WebApplication app, Settings settings)
    {
        var sdk = settings.Https("SCREENSHARE_SDK_URL");
        var frames = settings.Required("SCREENSHARE_FRAME_ORIGINS").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // Require exact origins before interpolating them into CSP; paths or malformed values could weaken the policy.
        if (frames.Length == 0 || frames.Any(f => !Uri.TryCreate(f, UriKind.Absolute, out var u) ||
            u.Scheme != "https" || u.GetLeftPart(UriPartial.Authority) != f))
        {
            throw new InvalidOperationException("SCREENSHARE_FRAME_ORIGINS must list exact HTTPS origins from onboarding.");
        }

        app.Use(async (ctx, next) =>
        {
            ctx.Response.Headers.CacheControl = "no-store";
            ctx.Response.Headers["Referrer-Policy"] = "no-referrer";
            ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
            ctx.Response.Headers.ContentSecurityPolicy =
                $"default-src 'none'; script-src 'self' {sdk.GetLeftPart(UriPartial.Authority)}; style-src 'self'; " +
                $"frame-src {string.Join(' ', frames)}; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
            if (settings.Local)
            {
                // ApplicationHosting confines local mode to loopback, so synthetic claims cannot authorize remote clients.
                ctx.User = new ClaimsPrincipal(new ClaimsIdentity([
                    new Claim("tid", settings.Required("OPERATOR_TENANT_ID")),
                    new Claim("oid", settings.Required("OPERATOR_OBJECT_ID"))], "loopback-development"));
            }

            await next(ctx);
        });
        if (!settings.Local) { app.UseHsts(); app.UseAuthentication(); }
        app.UseAuthorization();
        app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));
        var group = app.MapGroup("").RequireAuthorization("operator");
        group.MapGet("/", async (ISessionStore store, HttpContext ctx) =>
        {
            await using var tx = await store.OpenAsync(ctx.RequestAborted);
            if (tx.State is not { } state || !Owns(state, state.LinkId, ctx.User))
            {
                return Results.Content("No active desktop task. Start a fresh agent task, then refresh this page.", "text/plain");
            }

            return Results.Redirect($"/view/{state.LinkId}");
        });
        group.MapGet("/view/{id}", async (string id, ISessionStore store, HttpContext ctx) =>
        {
            await using var tx = await store.OpenAsync(ctx.RequestAborted);
            if (!Owns(tx.State, id, ctx.User))
            {
                return Results.NotFound();
            }

            return Results.Content(File.ReadAllText(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.html")),
                "text/html");
        });
        group.MapGet("/live/{id}", async (string id, ISessionStore store,
            IAgentUserTokenProvider tokens, HttpContext ctx) =>
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(65));
            string sessionLink;
            await using (var tx = await store.OpenAsync(timeout.Token))
            {
                if (!Owns(tx.State, id, ctx.User))
                {
                    return Results.NotFound();
                }

                if (tx.State!.Phase is not (DesktopSessionPhase.Active or DesktopSessionPhase.Paused) ||
                    string.IsNullOrWhiteSpace(tx.State.SessionLink) ||
                    !ValidComputerUrl(tx.State.SessionLink))
                {
                    return Results.Content(
                        "The live view is not ready. Return to the agent task and retry after the desktop is active.",
                        "text/plain",
                        statusCode: StatusCodes.Status409Conflict);
                }

                sessionLink = tx.State.SessionLink;
            }

            var token = await tokens.GetAsync(AgentUserTokenProvider.AriView, timeout.Token);
            return Results.Redirect(BuildLiveViewUrl(
                settings.ScreenShareAppUrl,
                sessionLink,
                token.Token));
        });
        group.MapGet("/viewer.js", () => Results.File(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.js"), "text/javascript"));
        group.MapGet("/viewer.css", () => Results.File(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.css"), "text/css"));
        group.MapGet("/api/{id}", async (string id, ISessionStore store, HttpContext ctx, IAntiforgery csrf) =>
        {
            await using var tx = await store.OpenAsync(ctx.RequestAborted);
            if (!Owns(tx.State, id, ctx.User))
            {
                return Results.NotFound();
            }

            return Results.Ok(new
            {
                phase = tx.State!.Phase,
                expiresAt = tx.State.ExpiresAt,
                sdkUrl = sdk.ToString(),
                csrfToken = csrf.GetAndStoreTokens(ctx).RequestToken
            });
        });
        group.MapPost("/api/{id}/{operation}", async (string id, string operation, ISessionStore store,
            IAgentUserTokenProvider tokens, HttpContext ctx, IAntiforgery csrf) =>
        {
            try { await csrf.ValidateRequestAsync(ctx); }
            catch (AntiforgeryValidationException) { return Results.BadRequest(new { error = "Invalid anti-forgery token." }); }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(65));
            await using var tx = await store.OpenAsync(timeout.Token);
            if (!Owns(tx.State, id, ctx.User))
            {
                return Results.NotFound();
            }

            var state = tx.State!;
            if (state.OperationInFlight || state.Phase is not (DesktopSessionPhase.Active or DesktopSessionPhase.Paused))
            {
                return Results.Conflict(new { error = "Session is not ready, or needs recovery." });
            }

            if (operation == "resume")
            {
                state.Phase = DesktopSessionPhase.Active;
                await tx.SaveAsync(timeout.Token);
                return Results.Ok(new { phase = state.Phase });
            }
            if (operation is not ("view" or "control" or "refresh-control"))
            {
                return Results.BadRequest(new { error = "Unknown operation." });
            }

            if (operation == "control")
            {
                state.Phase = DesktopSessionPhase.Paused;
                await tx.SaveAsync(timeout.Token); // Same exclusive lock as remote actions: pause BEFORE issuing a control token.
            }
            if (operation == "refresh-control" && state.Phase != DesktopSessionPhase.Paused)
            {
                return Results.Conflict(new { error = "Control must be paused before token refresh." });
            }

            if (string.IsNullOrWhiteSpace(state.SessionLink))
            {
                return Results.Conflict(new { error = "W365 did not provide a screen-share link." });
            }

            // Viewing receives a read-only scope; control and refresh require the broader desktop scope.
            var audience = operation == "view" ? AgentUserTokenProvider.AriView : AgentUserTokenProvider.Ari;
            var token = await tokens.GetAsync(audience, timeout.Token);
            return Results.Ok(new { sessionLink = state.SessionLink, token = token.Token, expiresAt = token.ExpiresOn });
        });
    }

    internal static string BuildLiveViewUrl(Uri appUrl, string computerUrl, string token)
    {
        if (!ValidComputerUrl(computerUrl))
        {
            throw new InvalidOperationException("The Windows 365 session has no valid screen-share computer URL.");
        }
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("The Windows 365 view token is empty.");
        }

        var computer = NormalizeComputerUrl(new Uri(computerUrl));
        var fragment =
            $"mode=viewOnly&computerUrl={Uri.EscapeDataString(computer.ToString())}" +
            $"&token={Uri.EscapeDataString(token)}";
        return $"{appUrl.ToString().TrimEnd('/')}/#{fragment}";
    }

    private static Uri NormalizeComputerUrl(Uri computer)
    {
        const string screenSharePath = "/screenshare";
        if (!computer.AbsolutePath.EndsWith(screenSharePath, StringComparison.OrdinalIgnoreCase))
        {
            return computer;
        }

        var builder = new UriBuilder(computer)
        {
            Path = computer.AbsolutePath[..^screenSharePath.Length]
        };
        return builder.Uri;
    }

    private static bool ValidComputerUrl(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var computer) &&
        computer.Scheme == "https" &&
        string.IsNullOrEmpty(computer.UserInfo);

    internal static bool Owns(DesktopSession? state, string id, ClaimsPrincipal user) =>
        state is not null && state.LinkId == id && state.OwnerTenantId == user.FindFirstValue("tid") &&
        state.OwnerObjectId == user.FindFirstValue("oid") && state.ExpiresAt > DateTimeOffset.UtcNow;
}
