namespace Win365Agent;

public sealed class Settings(IConfiguration config)
{
    public string Required(string key) => string.IsNullOrWhiteSpace(config[key])
        ? throw new InvalidOperationException($"Configure {key}.") : config[key]!;
    public string? Optional(string key) => string.IsNullOrWhiteSpace(config[key]) ? null : config[key];
    public bool Local => Optional("SAMPLE_LOCAL_MODE") == "true";
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
    public void Validate()
    {
        _ = Tenant;
        foreach (var key in new[] { "W365_BLUEPRINT_ID", "W365_AGENT_ID", "W365_AGENT_USER_ID",
                     "OPERATOR_TENANT_ID", "OPERATOR_OBJECT_ID" })
            _ = Guid.Parse(Required(key));
        _ = ViewerUrl;
        if (Optional("W365_CERTIFICATE_PATH") is null)
        {
            _ = Https("W365_KEY_VAULT_URL");
            _ = Required("W365_CERTIFICATE_SECRET_NAME");
        }
        else if (!Local)
            throw new InvalidOperationException("Hosted mode requires Key Vault certificate storage.");
        if (!Local)
        {
            _ = Https("SESSION_BLOB_URI");
            _ = Required("HOSTED_ALLOWED_USER_ID");
        }
        else
            _ = Required("SESSION_FILE");
    }
}
