using System.Globalization;

namespace Win365Agent;

/// <summary>
/// Provides typed access to application configuration and validates settings required by each hosting mode.
/// </summary>
/// <param name="config">The configuration source.</param>
public sealed class Settings(IConfiguration config)
{
    private const string _defaultScreenShareAppUrl =
        "https://w365ssviewer7f05ac.z13.web.core.windows.net";

    /// <summary>Gets a non-empty configuration value.</summary>
    /// <param name="key">The configuration key.</param>
    /// <returns>The configured value.</returns>
    /// <exception cref="InvalidOperationException">The value is missing, empty, or whitespace.</exception>
    public string Required(string key) => string.IsNullOrWhiteSpace(config[key])
        ? throw new InvalidOperationException($"Configure {key}.") : config[key]!;

    /// <summary>Gets an optional configuration value.</summary>
    /// <param name="key">The configuration key.</param>
    /// <returns>The configured value, or <see langword="null"/> when it is missing, empty, or whitespace.</returns>
    public string? Optional(string key) => string.IsNullOrWhiteSpace(config[key]) ? null : config[key];

    /// <summary>Gets whether the application is running in local bootstrap mode.</summary>
    public bool Local => Optional("SAMPLE_LOCAL_MODE") == "true";

    /// <summary>Gets whether live Windows 365 integration is enabled.</summary>
    /// <exception cref="InvalidOperationException"><c>W365_ENABLED</c> is not <c>true</c> or <c>false</c>.</exception>
    public bool Enabled => Optional("W365_ENABLED") switch
    {
        null or "false" => false,
        "true" => true,
        _ => throw new InvalidOperationException("W365_ENABLED must be true or false.")
    };

    /// <summary>Gets the explicitly selected blueprint authentication mode.</summary>
    public string BlueprintCredentialMode =>
        Optional("W365_BLUEPRINT_CREDENTIAL_MODE") ?? "managed_identity_federation";

    /// <summary>Gets the hosted HTTP port from <c>PORT</c>, defaulting to 8088.</summary>
    /// <exception cref="InvalidOperationException">The configured value is not a valid TCP port.</exception>
    public int HostedPort => int.TryParse(Optional("PORT") ?? "8088", out var port) && port is > 0 and <= 65535
        ? port : throw new InvalidOperationException("PORT must be a TCP port between 1 and 65535.");

    /// <summary>Gets the local agent HTTP port, defaulting to 8088.</summary>
    public int LocalAgentPort => Port("LOCAL_AGENT_PORT", 8088);

    /// <summary>Gets the local viewer HTTP port, defaulting to 5050.</summary>
    public int LocalViewerPort => Port("LOCAL_VIEWER_PORT", 5050);

    /// <summary>Gets the normalized Windows 365 tenant identifier.</summary>
    /// <exception cref="FormatException"><c>W365_TENANT_ID</c> is not a valid GUID.</exception>
    public string Tenant => Guid.Parse(Required("W365_TENANT_ID")).ToString();

    /// <summary>Gets an absolute HTTPS URI that contains no credentials, query, or fragment.</summary>
    /// <param name="key">The configuration key containing the URI.</param>
    /// <returns>The validated URI.</returns>
    /// <exception cref="InvalidOperationException">The URI does not satisfy the HTTPS restrictions.</exception>
    public Uri Https(string key)
    {
        var uri = new Uri(Required(key));
        if (uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new InvalidOperationException($"{key} must be an HTTPS URL without credentials, query or fragment.");
        }

        return uri;
    }

    /// <summary>
    /// Gets the normalized public viewer URI. Loopback HTTP is accepted only in local mode.
    /// </summary>
    /// <exception cref="InvalidOperationException">The URI contains disallowed components or uses an insecure origin.</exception>
    public Uri ViewerUrl
    {
        get
        {
            return OptionalViewerUrl
                ?? throw new InvalidOperationException("Configure VIEWER_PUBLIC_URL.");
        }
    }

    /// <summary>Gets the optional normalized viewer URI for agent-only deployments.</summary>
    public Uri? OptionalViewerUrl
    {
        get
        {
            var value = Optional("VIEWER_PUBLIC_URL");
            if (value is null)
            {
                return null;
            }

            var uri = new Uri(value.TrimEnd('/') + "/");
            if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) ||
                !string.IsNullOrEmpty(uri.Fragment) ||
                (uri.Scheme != "https" && !(Local && uri.Scheme == "http" && uri.IsLoopback)))
            {
                throw new InvalidOperationException("VIEWER_PUBLIC_URL requires HTTPS (loopback HTTP only in local mode).");
            }

            return uri;
        }
    }

    /// <summary>Gets the W365-hosted view-only application URI.</summary>
    public Uri ScreenShareAppUrl
    {
        get
        {
            var uri = new Uri((Optional("SCREENSHARE_APP_URL") ?? _defaultScreenShareAppUrl).TrimEnd('/') + "/");
            if (uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) ||
                !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            {
                throw new InvalidOperationException(
                    "SCREENSHARE_APP_URL must be an HTTPS URL without credentials, query or fragment.");
            }

            return uri;
        }
    }

    /// <summary>Validates configuration for the active application mode.</summary>
    /// <param name="viewerMode">
    /// <see langword="true"/> to validate viewer identity settings; otherwise, validates hosted-agent settings.
    /// </param>
    /// <exception cref="InvalidOperationException">A required setting is missing, obsolete, incompatible, or invalid.</exception>
    /// <exception cref="FormatException">An identity setting is not a valid GUID.</exception>
    public void Validate(bool viewerMode = false)
    {
        // Reject retired secret-based authentication even when W365 is disabled so stale credentials cannot linger unnoticed.
        foreach (var obsolete in new[] { "W365_CERTIFICATE_PATH", "W365_CERTIFICATE_PASSWORD",
                     "W365_KEY_VAULT_URL", "W365_CERTIFICATE_SECRET_NAME" })
        {
            if (Optional(obsolete) is not null)
            {
                throw new InvalidOperationException($"Remove obsolete {obsolete}. This sample reuses Foundry identity without blueprint certificates or secrets.");
            }
        }

        if (!Enabled)
        {
            return;
        }

        if (Local)
        {
            throw new InvalidOperationException("Live W365 requires deployed identity authentication. Use W365_ENABLED=false for local bootstrap/offline development.");
        }

        _ = Tenant;
        foreach (var key in new[] { "W365_BLUEPRINT_ID", "W365_AGENT_ID", "W365_AGENT_USER_ID",
                     "W365_AGENT_OBJECT_ID", "OPERATOR_TENANT_ID", "OPERATOR_OBJECT_ID" })
        {
            _ = Guid.Parse(Required(key));
        }

        _ = Https("SESSION_BLOB_URI");
        if (BlueprintCredentialMode is not ("managed_identity_federation" or "client_secret"))
        {
            throw new InvalidOperationException(
                "W365_BLUEPRINT_CREDENTIAL_MODE must be managed_identity_federation or client_secret. " +
                "key_vault_certificate is reserved for the next implementation phase and currently fails closed.");
        }
        if (viewerMode)
        {
            _ = ViewerUrl;
            _ = ScreenShareAppUrl;
            _ = Guid.Parse(Required("AZURE_CLIENT_ID"));
        }
        else
        {
            if (BlueprintCredentialMode == "client_secret")
            {
                _ = Required("W365_CLIENT_SECRET");
            }
            _ = OptionalViewerUrl;
            _ = Required("HOSTED_ALLOWED_USER_ID");
            // Foundry must inject the same blueprint that was authorized during W365 setup.
            if (Guid.Parse(Required("FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID")) != Guid.Parse(Required("W365_BLUEPRINT_ID")))
            {
                throw new InvalidOperationException("Configured W365 blueprint does not match the Foundry-provided blueprint.");
            }
        }
    }

    private int Port(string key, int fallback) =>
        int.TryParse(Optional(key) ?? fallback.ToString(CultureInfo.InvariantCulture), out var port) && port is > 0 and <= 65535
            ? port : throw new InvalidOperationException($"{key} must be a TCP port between 1 and 65535.");
}
