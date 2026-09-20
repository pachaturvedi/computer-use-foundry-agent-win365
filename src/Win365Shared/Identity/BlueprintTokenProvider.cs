using Azure.Core;
using Azure.Identity;

namespace Win365Agent;

// The runtime identity supplies a federated assertion; the blueprint exchange supplies T1.
/// <summary>
/// Acquires a runtime managed-identity assertion and exchanges it for an agent-scoped blueprint assertion.
/// </summary>
public sealed class BlueprintTokenProvider : IBlueprintTokenProvider
{
    private readonly TokenCredential _credential;
    private readonly HttpClient _http;
    private readonly ILogger<BlueprintTokenProvider>? _logger;
    private readonly Settings _settings;

    /// <summary>Initializes a blueprint token provider.</summary>
    /// <param name="http">The client used for blueprint token exchange requests.</param>
    /// <param name="settings">The managed identity, tenant, and agent configuration.</param>
    /// <param name="viewerMode">
    /// <see langword="true"/> to use the viewer managed identity; otherwise, use the hosted instance identity.
    /// </param>
    public BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        ILogger<BlueprintTokenProvider> logger)
        : this(
            http,
            settings,
            viewerMode,
            new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(
                    settings.Required(viewerMode ? "AZURE_CLIENT_ID" : "W365_AGENT_ID"))),
            logger)
    {
    }

    internal BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        TokenCredential credential,
        ILogger<BlueprintTokenProvider>? logger = null)
    {
        _http = http;
        _settings = settings;
        _credential = credential;
        _logger = logger;
    }

    /// <inheritdoc/>
    public async Task<AccessToken> GetAsync(CancellationToken cancellationToken)
    {
        if (_settings.BlueprintCredentialMode == "client_secret")
        {
            return await AgentUserTokenProvider.ExchangeAsync(
                _http,
                _settings,
                new Dictionary<string, string>
                {
                    ["client_id"] = _settings.Required("W365_BLUEPRINT_ID"),
                    ["client_secret"] = _settings.Required("W365_CLIENT_SECRET"),
                    ["grant_type"] = "client_credentials",
                    ["scope"] = AgentUserTokenProvider.Exchange,
                    ["fmi_path"] = _settings.Required("W365_AGENT_ID")
                },
                cancellationToken,
                "blueprint",
                _logger);
        }

        var assertion = await _credential.GetTokenAsync(
            new TokenRequestContext([AgentUserTokenProvider.Exchange]),
            cancellationToken);

        return await AgentUserTokenProvider.ExchangeAsync(
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
    }
}
