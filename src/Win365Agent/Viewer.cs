using System.Security.Claims;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;

namespace Win365Agent;

public static class Viewer
{
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
    public static void Map(WebApplication app, Settings settings)
    {
        var sdk = settings.Https("SCREENSHARE_SDK_URL");
        var frames = settings.Required("SCREENSHARE_FRAME_ORIGINS").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (frames.Length == 0 || frames.Any(f => !Uri.TryCreate(f, UriKind.Absolute, out var u) ||
            u.Scheme != "https" || u.GetLeftPart(UriPartial.Authority) != f))
            throw new InvalidOperationException("SCREENSHARE_FRAME_ORIGINS must list exact HTTPS origins from onboarding.");
        app.Use(async (ctx, next) =>
        {
            ctx.Response.Headers.CacheControl = "no-store";
            ctx.Response.Headers["Referrer-Policy"] = "no-referrer";
            ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
            ctx.Response.Headers.ContentSecurityPolicy =
                $"default-src 'none'; script-src 'self' {sdk.GetLeftPart(UriPartial.Authority)}; style-src 'self'; " +
                $"frame-src {string.Join(' ', frames)}; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
            if (settings.Local)
                ctx.User = new ClaimsPrincipal(new ClaimsIdentity([
                    new Claim("tid", settings.Required("OPERATOR_TENANT_ID")),
                    new Claim("oid", settings.Required("OPERATOR_OBJECT_ID"))], "loopback-development"));
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
                return Results.Content("No active desktop task. Start a fresh agent task, then refresh this page.", "text/plain");
            return Results.Redirect($"/view/{state.LinkId}");
        });
        group.MapGet("/view/{id}", async (string id, ISessionStore store, HttpContext ctx) =>
        {
            await using var tx = await store.OpenAsync(ctx.RequestAborted);
            if (!Owns(tx.State, id, ctx.User)) return Results.NotFound();
            return Results.Content(File.ReadAllText(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.html")),
                "text/html");
        });
        group.MapGet("/viewer.js", () => Results.File(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.js"), "text/javascript"));
        group.MapGet("/viewer.css", () => Results.File(Path.Combine(app.Environment.ContentRootPath, "wwwroot", "viewer.css"), "text/css"));
        group.MapGet("/api/{id}", async (string id, ISessionStore store, HttpContext ctx, IAntiforgery csrf) =>
        {
            await using var tx = await store.OpenAsync(ctx.RequestAborted);
            if (!Owns(tx.State, id, ctx.User)) return Results.NotFound();
            return Results.Ok(new { phase = tx.State!.Phase, expiresAt = tx.State.ExpiresAt,
                sdkUrl = sdk.ToString(), csrfToken = csrf.GetAndStoreTokens(ctx).RequestToken });
        });
        group.MapPost("/api/{id}/{operation}", async (string id, string operation, ISessionStore store,
            IAgentUserTokens tokens, HttpContext ctx, IAntiforgery csrf) =>
        {
            try { await csrf.ValidateRequestAsync(ctx); }
            catch (AntiforgeryValidationException) { return Results.BadRequest(new { error = "Invalid anti-forgery token." }); }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(65));
            await using var tx = await store.OpenAsync(timeout.Token);
            if (!Owns(tx.State, id, ctx.User)) return Results.NotFound();
            var state = tx.State!;
            if (state.OperationInFlight || state.Phase is not ("Active" or "Paused"))
                return Results.Conflict(new { error = "Session is not ready, or needs recovery." });
            if (operation == "resume")
            {
                state.Phase = "Active";
                await tx.SaveAsync(timeout.Token);
                return Results.Ok(new { phase = state.Phase });
            }
            if (operation is not ("view" or "control" or "refresh-control"))
                return Results.BadRequest(new { error = "Unknown operation." });
            if (operation == "control")
            {
                state.Phase = "Paused";
                await tx.SaveAsync(timeout.Token); // Same exclusive lock as remote actions: pause BEFORE issuing a control token.
            }
            if (operation == "refresh-control" && state.Phase != "Paused")
                return Results.Conflict(new { error = "Control must be paused before token refresh." });
            if (string.IsNullOrWhiteSpace(state.SessionLink)) return Results.Conflict(new { error = "W365 did not provide a screen-share link." });
            var token = await tokens.GetAsync(operation == "view" ? AgentUserTokens.AriView : AgentUserTokens.Ari, timeout.Token);
            return Results.Ok(new { sessionLink = state.SessionLink, token = token.Token, expiresAt = token.ExpiresOn });
        });
    }
    internal static bool Owns(DesktopSession? state, string id, ClaimsPrincipal user) =>
        state is not null && state.LinkId == id && state.OwnerTenantId == user.FindFirstValue("tid") &&
        state.OwnerObjectId == user.FindFirstValue("oid") && state.ExpiresAt > DateTimeOffset.UtcNow;
}
