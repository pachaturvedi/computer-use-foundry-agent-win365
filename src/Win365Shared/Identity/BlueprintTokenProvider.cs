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
    private readonly IBlueprintCertificateAssertionProvider? _certificateAssertionProvider;
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
    /// <param name="certificateAssertionProvider">
    /// Builds the <c>key_vault_certificate</c> mode client assertion using the runtime's own
    /// identity. Required only when <c>W365_BLUEPRINT_CREDENTIAL_MODE</c> is <c>key_vault_certificate</c>.
    /// </param>
    public BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        ILogger<BlueprintTokenProvider> logger,
        IBlueprintSecretResolver? secretResolver = null,
        IBlueprintCertificateAssertionProvider? certificateAssertionProvider = null)
        : this(
            http,
            settings,
            viewerMode,
            new ManagedIdentityCredential(
                ManagedIdentityId.FromUserAssignedClientId(
                    settings.Required(viewerMode ? "AZURE_CLIENT_ID" : "W365_AGENT_ID"))),
            logger,
            secretResolver,
            certificateAssertionProvider)
    {
    }

    internal BlueprintTokenProvider(
        HttpClient http,
        Settings settings,
        bool viewerMode,
        TokenCredential credential,
        ILogger<BlueprintTokenProvider>? logger = null,
        IBlueprintSecretResolver? secretResolver = null,
        IBlueprintCertificateAssertionProvider? certificateAssertionProvider = null)
    {
        _http = http;
        _settings = settings;
        _credential = credential;
        _logger = logger;
        _secretResolver = secretResolver;
        _certificateAssertionProvider = certificateAssertionProvider;
    }

    /// <inheritdoc/>
    public async Task<AccessToken> GetAsync(CancellationToken cancellationToken)
    {
        if (_settings.BlueprintCredentialMode == "client_secret")
        {
            var secret = _secretResolver is not null
                ? await _secretResolver.GetSecretAsync(cancellationToken)
                : _settings.Required("W365_CLIENT_SECRET");

            return await AgentUserTokenProvider.ExchangeAsync(
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
        }

        if (_settings.BlueprintCredentialMode == "key_vault_certificate")
        {
            if (_certificateAssertionProvider is null)
            {
                throw new InvalidOperationException(
                    "key_vault_certificate mode requires a certificate assertion provider.");
            }

            var clientId = _settings.Required("W365_BLUEPRINT_ID");
            var tokenEndpoint = $"https://login.microsoftonline.com/{_settings.Tenant}/oauth2/v2.0/token";
            var clientAssertion = await _certificateAssertionProvider.GetClientAssertionAsync(
                clientId,
                tokenEndpoint,
                cancellationToken);

            return await AgentUserTokenProvider.ExchangeAsync(
                _http,
                _settings,
                new Dictionary<string, string>
                {
                    ["client_id"] = clientId,
                    ["grant_type"] = "client_credentials",
                    ["scope"] = AgentUserTokenProvider.Exchange,
                    ["fmi_path"] = _settings.Required("W365_AGENT_ID"),
                    ["client_assertion_type"] = AgentUserTokenProvider.AssertionType,
                    ["client_assertion"] = clientAssertion
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

    internal const string StorageScope = "https://storage.azure.com/.default";

    /// <summary>
    /// Gets a Storage token for the configured agent identity for the guarded recovery path.
    /// </summary>
    /// <param name="cancellationToken">A token that cancels token acquisition.</param>
    /// <returns>An access token whose subject is the configured agent identity.</returns>
    internal async Task<AccessToken> GetAgentIdentityStorageTokenAsync(
        CancellationToken cancellationToken)
    {
        var blueprintToken = await GetAsync(cancellationToken);
        return await AgentUserTokenProvider.ExchangeAsync(
            _http,
            _settings,
            new Dictionary<string, string>
            {
                ["client_id"] = _settings.Required("W365_AGENT_ID"),
                ["grant_type"] = "client_credentials",
                ["scope"] = StorageScope,
                ["client_assertion_type"] = AgentUserTokenProvider.AssertionType,
                ["client_assertion"] = blueprintToken.Token
            },
            cancellationToken,
            "agent-identity-resource",
            _logger);
    }
}
