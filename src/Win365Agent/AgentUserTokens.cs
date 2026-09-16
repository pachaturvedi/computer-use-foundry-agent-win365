using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Azure.Identity;

namespace Win365Agent;

public interface IAgentUserTokens
{
    Task<AccessToken> GetAsync(string audience, CancellationToken ct);
}

public interface IBlueprintTokens
{
    Task<AccessToken> GetAsync(CancellationToken ct);
}

// Foundry's identity endpoint supplies T1. ACA instead needs an explicitly trusted UAMI.
public sealed class BlueprintTokens : IBlueprintTokens
{
    private readonly HttpClient http;
    private readonly Settings settings;
    private readonly bool viewerMode;
    private readonly TokenCredential credential;
    public BlueprintTokens(HttpClient http, Settings settings, bool viewerMode)
        : this(http, settings, viewerMode, new ManagedIdentityCredential(
            ManagedIdentityId.FromUserAssignedClientId(settings.Required(viewerMode ? "AZURE_CLIENT_ID" : "W365_BLUEPRINT_ID")))) { }

    internal BlueprintTokens(HttpClient http, Settings settings, bool viewerMode, TokenCredential credential)
    {
        this.http = http; this.settings = settings; this.viewerMode = viewerMode; this.credential = credential;
    }

    public async Task<AccessToken> GetAsync(CancellationToken ct)
    {
        var assertion = await credential.GetTokenAsync(new TokenRequestContext([AgentUserTokens.Exchange]), ct);
        if (!viewerMode) return assertion;
        return await AgentUserTokens.ExchangeAsync(http, settings, new()
        {
            ["client_id"] = settings.Required("W365_BLUEPRINT_ID"), ["grant_type"] = "client_credentials",
            ["scope"] = AgentUserTokens.Exchange, ["fmi_path"] = settings.Required("W365_AGENT_ID"),
            ["client_assertion_type"] = AgentUserTokens.AssertionType, ["client_assertion"] = assertion.Token
        }, ct);
    }
}

// Follows the public Foundry AgentTokenHelper sample; T1 never comes from CLI/user credentials.
public sealed class AgentUserTokens(HttpClient http, Settings settings, IBlueprintTokens blueprintTokens)
    : IAgentUserTokens, IDisposable
{
    public const string Atg = "da81128c-e5b5-4f9e-8d89-50d906f107c5";
    public const string Ari = "90ecec28-f5a6-42b3-9bde-dae1ca98f8b5";
    public const string AriView = Ari + "/Computer.See";
    internal const string Exchange = "api://AzureADTokenExchange/.default";
    internal const string AssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";
    private readonly SemaphoreSlim gate = new(1);
    private readonly Dictionary<string, AccessToken> cache = [];

    public async Task<AccessToken> GetAsync(string audience, CancellationToken ct)
    {
        if (audience != Atg && audience != Ari && audience != AriView) throw new ArgumentException("Unsupported token audience.");
        await gate.WaitAsync(ct);
        try
        {
            if (cache.TryGetValue(audience, out var cached) && cached.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
                return cached;
            var agent = settings.Required("W365_AGENT_ID");
            var t1 = await blueprintTokens.GetAsync(ct);
            var t2 = await ExchangeAsync(http, settings, new()
            {
                ["client_id"] = agent, ["grant_type"] = "client_credentials", ["scope"] = Exchange,
                ["client_assertion_type"] = AssertionType, ["client_assertion"] = t1.Token
            }, ct);
            var result = await ExchangeAsync(http, settings, new()
            {
                ["client_id"] = agent, ["grant_type"] = "user_fic", ["requested_token_use"] = "on_behalf_of",
                ["scope"] = audience == AriView ? AriView :
                    audience == Ari ? $"{Ari}/Computer.See {Ari}/Computer.Control" : $"{Atg}/.default",
                ["client_assertion_type"] = AssertionType, ["client_assertion"] = t1.Token,
                ["user_federated_identity_credential"] = t2.Token,
                ["user_id"] = settings.Required("W365_AGENT_USER_ID")
            }, ct);
            cache[audience] = result;
            return result;
        }
        finally { gate.Release(); }
    }

    internal static async Task<AccessToken> ExchangeAsync(HttpClient http, Settings settings,
        Dictionary<string, string> form, CancellationToken ct)
    {
        using var response = await http.PostAsync(
            $"https://login.microsoftonline.com/{settings.Tenant}/oauth2/v2.0/token",
            new FormUrlEncodedContent(form), ct);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"Agent-user token exchange failed (HTTP {(int)response.StatusCode}). Check Foundry identity support, federation, tenant and consent.");
        using var json = await response.Content.ReadFromJsonAsync<JsonDocument>(ct)
            ?? throw new InvalidOperationException("Empty token response.");
        var expires = json.RootElement.GetProperty("expires_in").GetInt32();
        var token = json.RootElement.GetProperty("access_token").GetString();
        if (expires <= 0 || string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Invalid token response.");
        return new AccessToken(token, DateTimeOffset.UtcNow.AddSeconds(expires));
    }
    public void Dispose() => gate.Dispose();
}
