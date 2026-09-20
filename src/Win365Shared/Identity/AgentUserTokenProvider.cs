using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;

namespace Win365Agent;

// Follows the public Foundry AgentTokenHelper sample; T1 never comes from CLI/user credentials.
/// <summary>
/// Exchanges a Foundry blueprint assertion for scoped agent-user access tokens and caches usable tokens.
/// </summary>
/// <param name="http">The client used for Microsoft Entra token exchange requests.</param>
/// <param name="settings">The identity and tenant configuration.</param>
/// <param name="blueprintTokenProvider">The source of managed-identity blueprint assertions.</param>
public sealed class AgentUserTokenProvider(
    HttpClient http,
    Settings settings,
    IBlueprintTokenProvider blueprintTokenProvider,
    ILogger<AgentUserTokenProvider>? logger = null)
    : IAgentUserTokenProvider, IDisposable
{
    private static readonly Action<ILogger, string, Exception?> _logTokenRequestStart =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(1101, nameof(_logTokenRequestStart)),
            "Requesting agent-user token for audience {Audience}.");

    private static readonly Action<ILogger, string, DateTimeOffset, Exception?> _logTokenCacheHit =
        LoggerMessage.Define<string, DateTimeOffset>(
            LogLevel.Information,
            new EventId(1102, nameof(_logTokenCacheHit)),
            "Reusing cached agent-user token for audience {Audience}; token expires at {ExpiresOnUtc}.");

    private static readonly Action<ILogger, string, DateTimeOffset, Exception?> _logTokenRequestSuccess =
        LoggerMessage.Define<string, DateTimeOffset>(
            LogLevel.Information,
            new EventId(1103, nameof(_logTokenRequestSuccess)),
            "Acquired agent-user token for audience {Audience}; token expires at {ExpiresOnUtc}.");

    private static readonly Action<ILogger, string, string, Exception?> _logExchangeStart =
        LoggerMessage.Define<string, string>(
            LogLevel.Information,
            new EventId(1104, nameof(_logExchangeStart)),
            "Starting Entra token exchange stage {Stage} for scope {Scope}.");

    private static readonly Action<ILogger, string, DateTimeOffset, Exception?> _logExchangeSuccess =
        LoggerMessage.Define<string, DateTimeOffset>(
            LogLevel.Information,
            new EventId(1105, nameof(_logExchangeSuccess)),
            "Completed Entra token exchange stage {Stage}; token expires at {ExpiresOnUtc}.");

    /// <summary>Identifies the audience used for Windows 365 MCP requests.</summary>
    public const string Atg = "da81128c-e5b5-4f9e-8d89-50d906f107c5";

    /// <summary>Identifies the audience used for desktop viewing and control.</summary>
    public const string Ari = "90ecec28-f5a6-42b3-9bde-dae1ca98f8b5";

    /// <summary>Identifies the delegated scope used for read-only desktop viewing.</summary>
    public const string AriView = Ari + "/Computer.See";
    internal const string Exchange = "api://AzureADTokenExchange/.default";
    internal const string AssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";

    private static readonly Action<ILogger, string, int, string, string, string, string, Exception?>
        _logTokenExchangeFailure = LoggerMessage.Define<string, int, string, string, string, string>(
            LogLevel.Error,
            new EventId(1001, nameof(_logTokenExchangeFailure)),
            "Agent token exchange failed at {Stage}. HTTP {Status}; Entra error {Error}; code {ErrorCode}; " +
            "correlation {CorrelationId}; description: {Description}");

    private readonly Dictionary<string, AccessToken> _cache = [];
    private readonly SemaphoreSlim _gate = new(1);

    /// <inheritdoc/>
    /// <remarks>Cached tokens are refreshed when fewer than five minutes remain before expiration.</remarks>
    public async Task<AccessToken> GetAsync(string audience, CancellationToken cancellationToken)
    {
        if (audience != Atg && audience != Ari && audience != AriView)
        {
            throw new ArgumentException("Unsupported token audience.", nameof(audience));
        }

        if (logger is not null)
        {
            _logTokenRequestStart(logger, audience, null);
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_cache.TryGetValue(audience, out var cached) &&
                cached.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
            {
                if (logger is not null)
                {
                    _logTokenCacheHit(logger, audience, cached.ExpiresOn, null);
                }

                return cached;
            }

            var agent = settings.Required("W365_AGENT_ID");
            // Exchange the blueprint assertion for the user's federated credential, then combine both for the scoped token.
            var t1 = await blueprintTokenProvider.GetAsync(cancellationToken);
            var t2 = await ExchangeAsync(
                http,
                settings,
                new Dictionary<string, string>
                {
                    ["client_id"] = agent,
                    ["grant_type"] = "client_credentials",
                    ["scope"] = Exchange,
                    ["client_assertion_type"] = AssertionType,
                    ["client_assertion"] = t1.Token
                },
                cancellationToken,
                "agent-identity",
                logger);
            var result = await ExchangeAsync(
                http,
                settings,
                new Dictionary<string, string>
                {
                    ["client_id"] = agent,
                    ["grant_type"] = "user_fic",
                    ["requested_token_use"] = "on_behalf_of",
                    ["scope"] = audience == AriView
                        ? AriView
                        : audience == Ari
                            ? $"{Ari}/Computer.See {Ari}/Computer.Control {Ari}/Computer.Do {Ari}/Computer.Get"
                            : $"{Atg}/.default",
                    ["client_assertion_type"] = AssertionType,
                    ["client_assertion"] = t1.Token,
                    ["user_federated_identity_credential"] = t2.Token,
                    ["user_id"] = settings.Required("W365_AGENT_USER_ID")
                },
                cancellationToken,
                "agent-user",
                logger);
            _cache[audience] = result;
            if (logger is not null)
            {
                _logTokenRequestSuccess(logger, audience, result.ExpiresOn, null);
            }

            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal static async Task<AccessToken> ExchangeAsync(
        HttpClient http,
        Settings settings,
        Dictionary<string, string> form,
        CancellationToken cancellationToken,
        string stage = "token",
        ILogger? logger = null)
    {
        if (logger is not null)
        {
            _logExchangeStart(logger, stage, form["scope"], null);
        }

        using var response = await http.PostAsync(
            $"https://login.microsoftonline.com/{settings.Tenant}/oauth2/v2.0/token",
            new FormUrlEncodedContent(form),
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var error = "unknown";
            var errorCode = "unknown";
            var correlationId = "unknown";
            var description = "Unavailable.";
            try
            {
                using var failure = await response.Content.ReadFromJsonAsync<JsonDocument>(cancellationToken);
                if (failure is not null)
                {
                    var root = failure.RootElement;
                    if (root.TryGetProperty("error", out var errorValue))
                    {
                        error = errorValue.GetString() ?? error;
                    }
                    if (root.TryGetProperty("error_codes", out var codes) &&
                        codes.ValueKind == JsonValueKind.Array &&
                        codes.GetArrayLength() > 0)
                    {
                        errorCode = codes[0].GetInt32().ToString(System.Globalization.CultureInfo.InvariantCulture);
                    }
                    if (root.TryGetProperty("correlation_id", out var correlation))
                    {
                        correlationId = correlation.GetString() ?? correlationId;
                    }
                    if (root.TryGetProperty("error_description", out var errorDescription))
                    {
                        description = errorDescription.GetString() ?? description;
                    }
                }
            }
            catch (JsonException)
            {
                description = "The identity provider returned a non-JSON error body.";
            }
            if (logger is not null)
            {
                _logTokenExchangeFailure(
                    logger,
                    stage,
                    (int)response.StatusCode,
                    error,
                    errorCode,
                    correlationId,
                    description,
                    null);
            }
            throw new HttpRequestException(
                $"Agent token exchange failed at {stage} (HTTP {(int)response.StatusCode}, " +
                $"error {error}, code {errorCode}, correlation {correlationId}).");
        }

        using var json = await response.Content.ReadFromJsonAsync<JsonDocument>(cancellationToken)
            ?? throw new InvalidOperationException("Empty token response.");
        var expires = json.RootElement.GetProperty("expires_in").GetInt32();
        var token = json.RootElement.GetProperty("access_token").GetString();
        if (expires <= 0 || string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("Invalid token response.");
        }

        var accessToken = new AccessToken(token, DateTimeOffset.UtcNow.AddSeconds(expires));
        if (logger is not null)
        {
            _logExchangeSuccess(logger, stage, accessToken.ExpiresOn, null);
        }

        return accessToken;
    }

    /// <inheritdoc/>
    public void Dispose() => _gate.Dispose();
}
