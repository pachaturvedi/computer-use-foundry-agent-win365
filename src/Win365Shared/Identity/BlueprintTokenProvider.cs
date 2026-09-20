using Azure.Core;
using Azure.Identity;

namespace Win365Agent;

// The runtime identity supplies a federated assertion; the blueprint exchange supplies T1.
/// <summary>
/// Acquires a runtime managed-identity assertion and exchanges it for an agent-scoped blueprint assertion.
/// </summary>
public sealed class BlueprintTokenProvider : IBlueprintTokenProvider
{
    private static readonly Action<ILogger, string, Exception?> _logBlueprintTokenStart =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(2001, nameof(_logBlueprintTokenStart)),
            "Starting blueprint token acquisition using credential mode {CredentialMode}.");

    private static readonly Action<ILogger, Exception?> _logManagedIdentityAssertionStart =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(2002, nameof(_logManagedIdentityAssertionStart)),
            "Requesting managed-identity assertion for blueprint exchange.");

    private static readonly Action<ILogger, DateTimeOffset, Exception?> _logBlueprintTokenSuccess =
        LoggerMessage.Define<DateTimeOffset>(
            LogLevel.Information,
            new EventId(2003, nameof(_logBlueprintTokenSuccess)),
            "Blueprint token acquisition succeeded; token expires at {ExpiresOnUtc}.");

    private readonly TokenCredential _credential;
    private readonly HttpClient _http;
    private readonly ILogger<BlueprintTokenProvider>? _logger;
    private readonly IBlueprintSecretResolver? _secretResolver;
    private readonly Settings _settings;

    /// <summary>Initializes a blueprint token provider.</summary>
    /// <param name="http">The client used for blueprint token exchange requests.</param>
    /// <param name="settings">The managed identity, tenant, and agent configuration.</param>
    /// <param name="viewerMode">
    /// <see langword="true"/> to use the viewer managed identity; otherwise, use the hosted instance identity.
    /// </param>
    /// <param name="logger">The diagnostic logger.</param>
    /// <param name="secretResolver">
    /// Resolves the <c>client_secret</c> mode blueprint secret from Key Vault using the runtime's
    /// own identity. Required only when <c>W365_BLUEPRINT_CREDENTIAL_MODE</c> is <c>client_secret</c>.
    /// </param>
    public BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        ILogger<BlueprintTokenProvider> logger,
        IBlueprintSecretResolver? secretResolver = null)
        : this(
            http,
            settings,
            viewerMode,
            new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(
                    settings.Required(viewerMode ? "AZURE_CLIENT_ID" : "W365_AGENT_ID"))),
            logger,
            secretResolver)
    {
    }

    internal BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        TokenCredential credential,
        ILogger<BlueprintTokenProvider>? logger = null,
        IBlueprintSecretResolver? secretResolver = null)
    {
        _http = http;
        _settings = settings;
        _credential = credential;
        _logger = logger;
        _secretResolver = secretResolver;
    }

    /// <inheritdoc/>
    public async Task<AccessToken> GetAsync(CancellationToken cancellationToken)
    {
        if (_logger is not null)
        {
            _logBlueprintTokenStart(_logger, _settings.BlueprintCredentialMode, null);
        }

        if (_settings.BlueprintCredentialMode == "client_secret")
        {
            var secret = _secretResolver is not null
                ? await _secretResolver.GetSecretAsync(cancellationToken)
                : _settings.Required("W365_CLIENT_SECRET");

            var token = await AgentUserTokenProvider.ExchangeAsync(
                _http,
                _settings,
                new Dictionary<string, string>
                {
                    ["client_id"] = _settings.Required("W365_BLUEPRINT_ID"),
                    ["client_secret"] = secret,
                    ["grant_type"] = "client_credentials",
                    ["scope"] = AgentUserTokenProvider.Exchange,
                    ["fmi_path"] = _settings.Required("W365_AGENT_ID")
                },
                cancellationToken,
                "blueprint",
                _logger);

            if (_logger is not null)
            {
                _logBlueprintTokenSuccess(_logger, token.ExpiresOn, null);
            }

            return token;
        }

        if (_logger is not null)
        {
            _logManagedIdentityAssertionStart(_logger, null);
        }

        var assertion = await _credential.GetTokenAsync(
            new TokenRequestContext([AgentUserTokenProvider.Exchange]),
            cancellationToken);

        var result = await AgentUserTokenProvider.ExchangeAsync(
            _http,
            _settings,
            new Dictionary<string, string>
            {
                ["client_id"] = _settings.Required("W365_BLUEPRINT_ID"),
                ["grant_type"] = "client_credentials",
                ["scope"] = AgentUserTokenProvider.Exchange,
                ["fmi_path"] = _settings.Required("W365_AGENT_ID"),
                ["client_assertion_type"] = AgentUserTokenProvider.AssertionType,
                ["client_assertion"] = assertion.Token
            },
            cancellationToken,
            "blueprint",
            _logger);

        if (_logger is not null)
        {
            _logBlueprintTokenSuccess(_logger, result.ExpiresOn, null);
        }

        return result;
    }
}
