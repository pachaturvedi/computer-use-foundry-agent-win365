namespace Win365Agent;

public sealed class Settings(IConfiguration config)
{
    public string Required(string key) => string.IsNullOrWhiteSpace(config[key])
        ? throw new InvalidOperationException($"Configure {key}.") : config[key]!;
    public string? Optional(string key) => string.IsNullOrWhiteSpace(config[key]) ? null : config[key];
    public bool Local => Optional("SAMPLE_LOCAL_MODE") == "true";
    public bool Enabled => Optional("W365_ENABLED") switch
    {
        null or "false" => false,
        "true" => true,
        _ => throw new InvalidOperationException("W365_ENABLED must be true or false.")
    };
    public int HostedPort => int.TryParse(Optional("PORT") ?? "8088", out var port) && port is > 0 and <= 65535
        ? port : throw new InvalidOperationException("PORT must be a TCP port between 1 and 65535.");
    public string Tenant => Guid.Parse(Required("W365_TENANT_ID")).ToString();
    public Uri Https(string key)
    {
        var uri = new Uri(Required(key));
        if (uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new InvalidOperationException($"{key} must be an HTTPS URL without credentials, query or fragment.");
        return uri;
    }
    public Uri ViewerUrl
    {
        get
        {
            var uri = new Uri(Required("VIEWER_PUBLIC_URL").TrimEnd('/') + "/");
            if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) ||
                !string.IsNullOrEmpty(uri.Fragment) ||
                (uri.Scheme != "https" && !(Local && uri.Scheme == "http" && uri.IsLoopback)))
                throw new InvalidOperationException("VIEWER_PUBLIC_URL requires HTTPS (loopback HTTP only in local mode).");
            return uri;
        }
    }
    public void Validate(bool viewerMode = false)
    {
        foreach (var obsolete in new[] { "W365_CERTIFICATE_PATH", "W365_CERTIFICATE_PASSWORD",
                     "W365_KEY_VAULT_URL", "W365_CERTIFICATE_SECRET_NAME", "W365_CLIENT_SECRET" })
            if (Optional(obsolete) is not null)
                throw new InvalidOperationException($"Remove obsolete {obsolete}. This sample reuses Foundry identity without blueprint certificates or secrets.");
        if (!Enabled) return;
        if (Local) throw new InvalidOperationException("Live W365 requires deployed identity authentication. Use W365_ENABLED=false for local bootstrap/offline development.");
        _ = Tenant;
        foreach (var key in new[] { "W365_BLUEPRINT_ID", "W365_AGENT_ID", "W365_AGENT_USER_ID",
                     "W365_AGENT_OBJECT_ID", "OPERATOR_TENANT_ID", "OPERATOR_OBJECT_ID" })
            _ = Guid.Parse(Required(key));
        _ = ViewerUrl;
        _ = Https("SESSION_BLOB_URI");
        if (viewerMode)
            _ = Guid.Parse(Required("AZURE_CLIENT_ID"));
        else
        {
            _ = Required("HOSTED_ALLOWED_USER_ID");
            if (Guid.Parse(Required("FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID")) != Guid.Parse(Required("W365_BLUEPRINT_ID")))
                throw new InvalidOperationException("Configured W365 blueprint does not match the Foundry-provided blueprint.");
        }
    }
}
