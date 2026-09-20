using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Win365Agent;

/// <summary>Describes an MCP tool advertised by the Windows 365 server.</summary>
/// <param name="Name">The exact tool name used for invocation.</param>
/// <param name="Description">The human-readable tool description.</param>
/// <param name="InputSchema">The JSON Schema for the tool argument object.</param>
public sealed record ToolSchema(string Name, string Description, JsonElement InputSchema);

/// <summary>
/// Reports an MCP tool-level failure (JSON-RPC <c>isError: true</c>). Carries the raw W365
/// diagnostic text for server-side capacity/transient-error detection; never expose
/// <see cref="RawResult"/> to the model or the caller.
/// </summary>
/// <param name="toolName">The tool that reported the error.</param>
/// <param name="rawResult">The raw, untruncated JSON-RPC result text.</param>
public sealed class McpToolException(string toolName, string rawResult)
    : InvalidOperationException($"W365 tool {toolName} returned an error. Inspect W365 service diagnostics; operation is not replayed.")
{
    /// <summary>Gets the raw JSON-RPC result text for diagnostics. Server-side use only.</summary>
    public string RawResult { get; } = rawResult;

    /// <summary>Gets whether the raw result indicates transient W365 capacity exhaustion (no free sessions).</summary>
    public bool IsCapacityExhausted =>
        RawResult.Contains("No free W365 sessions", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Implements the MCP JSON-RPC transport for Windows 365 tool discovery and invocation.
/// </summary>
/// <param name="http">The HTTP transport.</param>
/// <param name="tokens">The provider for Windows 365 MCP access tokens.</param>
/// <param name="settings">The tenant configuration.</param>
public sealed class McpConnection(
    HttpClient http,
    IAgentUserTokenProvider tokens,
    Settings settings,
    ILogger<McpConnection>? logger = null)
{
    private static readonly Action<ILogger, string, Exception?> _logToolError =
        LoggerMessage.Define<string>(
            LogLevel.Error,
            new EventId(1, nameof(_logToolError)),
            "W365 MCP tool {ToolName} reported an error. Inspect server-side diagnostics for correlation; raw remote payload is not logged.");

    private static readonly Action<ILogger, Exception?> _logRpcError =
        LoggerMessage.Define(
            LogLevel.Error,
            new EventId(2, nameof(_logRpcError)),
            "W365 MCP JSON-RPC call reported an error. Raw remote payload is not logged.");

    private static readonly Action<ILogger, string, Exception?> _logInitializeStart =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(10, nameof(_logInitializeStart)),
            "Initializing W365 MCP connection with requested protocol {ProtocolVersion}.");

    private static readonly Action<ILogger, string, bool, Exception?> _logInitializeSuccess =
        LoggerMessage.Define<string, bool>(
            LogLevel.Information,
            new EventId(11, nameof(_logInitializeSuccess)),
            "Initialized W365 MCP connection with negotiated protocol {ProtocolVersion}; session established {HasSession}.");

    private static readonly Action<ILogger, int, Exception?> _logCatalogLoaded =
        LoggerMessage.Define<int>(
            LogLevel.Information,
            new EventId(12, nameof(_logCatalogLoaded)),
            "Loaded {ToolCount} W365 MCP tools from the advertised catalog.");

    private static readonly Action<ILogger, string, Exception?> _logToolCallStart =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(13, nameof(_logToolCallStart)),
            "Calling W365 MCP tool {ToolName}.");

    private static readonly Action<ILogger, string, Exception?> _logToolCallSuccess =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(14, nameof(_logToolCallSuccess)),
            "W365 MCP tool {ToolName} completed successfully.");

    private static readonly Action<ILogger, string, bool, bool, Exception?> _logRpcSend =
        LoggerMessage.Define<string, bool, bool>(
            LogLevel.Information,
            new EventId(15, nameof(_logRpcSend)),
            "Sending W365 MCP JSON-RPC method {Method}; notification {Notification}; session established {HasSession}.");

    private int _sequence;
    private string _version = "2025-06-18";
    private string? _transportSession;
    /// <summary>Negotiates a supported MCP protocol version and initializes the transport session.</summary>
    /// <param name="ct">A token that cancels initialization.</param>
    /// <exception cref="InvalidOperationException">The server selects an unsupported protocol version.</exception>
    public async Task InitializeAsync(CancellationToken ct)
    {
        if (logger is not null)
        {
            _logInitializeStart(logger, _version, null);
        }

        var result = await SendAsync("initialize", new
        {
            protocolVersion = _version,
            capabilities = new { },
            clientInfo = new { name = "foundry-w365-sample", version = "1.0.0" }
        }, false, ct);
        _version = result.GetProperty("protocolVersion").GetString()!;
        if (_version is not ("2025-06-18" or "2025-03-26"))
        {
            throw new InvalidOperationException("Unsupported MCP protocol version.");
        }

        await SendAsync("notifications/initialized", new { }, true, ct);

        if (logger is not null)
        {
            _logInitializeSuccess(logger, _version, _transportSession is not null, null);
        }
    }

    /// <summary>Gets every page of the MCP tool catalog.</summary>
    /// <param name="ct">A token that cancels catalog retrieval.</param>
    /// <returns>The advertised tool schemas.</returns>
    /// <exception cref="InvalidOperationException">The catalog exceeds 500 tools or repeats a pagination cursor.</exception>
    public async Task<IReadOnlyList<ToolSchema>> ListAsync(CancellationToken ct)
    {
        var tools = new List<ToolSchema>();
        string? cursor = null;
        var seen = new HashSet<string>();
        do
        {
            var page = await SendAsync("tools/list", cursor is null ? new { } : (object)new { cursor }, false, ct);
            tools.AddRange(page.GetProperty("tools").EnumerateArray().Select(x => new ToolSchema(
                x.GetProperty("name").GetString()!, x.TryGetProperty("description", out var d) ? d.GetString() ?? "" : "",
                x.GetProperty("inputSchema").Clone())));
            cursor = page.TryGetProperty("nextCursor", out var next) ? next.GetString() : null;
            if (tools.Count > 500 || (cursor is not null && !seen.Add(cursor)))
            {
                throw new InvalidOperationException("Unbounded MCP catalog.");
            }
        } while (cursor is not null);

        if (logger is not null)
        {
            _logCatalogLoaded(logger, tools.Count, null);
        }

        return tools;
    }
    /// <summary>Invokes an MCP tool without automatically replaying failed operations.</summary>
    /// <param name="name">The exact advertised tool name.</param>
    /// <param name="arguments">The tool argument object.</param>
    /// <param name="ct">A token that cancels the request.</param>
    /// <returns>The cloned JSON-RPC result.</returns>
    /// <exception cref="McpToolException">The tool reports an error.</exception>
    public async Task<JsonElement> CallAsync(string name, object arguments, CancellationToken ct)
    {
        if (logger is not null)
        {
            _logToolCallStart(logger, name, null);
        }

        var result = await SendAsync("tools/call", new { name, arguments }, false, ct);
        if (result.TryGetProperty("isError", out var error) && error.ValueKind == JsonValueKind.True)
        {
            var rawResult = result.GetRawText();
            if (logger is not null)
            {
                _logToolError(logger, name, null);
            }

            throw new McpToolException(name, rawResult);
        }

        if (logger is not null)
        {
            _logToolCallSuccess(logger, name, null);
        }

        return result;
    }
    private async Task<JsonElement> SendAsync(string method, object parameters, bool notification, CancellationToken ct)
    {
        if (logger is not null)
        {
            _logRpcSend(logger, method, notification, _transportSession is not null, null);
        }

        var id = Interlocked.Increment(ref _sequence);
        var payload = new Dictionary<string, object> { ["jsonrpc"] = "2.0", ["method"] = method, ["params"] = parameters };
        if (!notification)
        {
            payload["id"] = id;
        }

        using var request = new HttpRequestMessage(HttpMethod.Post,
            $"https://agent365.svc.cloud.microsoft/agents/tenants/{settings.Tenant}/servers/mcp_W365ComputerUse");
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            (await tokens.GetAsync(AgentUserTokenProvider.Atg, ct)).Token);
        request.Headers.Accept.ParseAdd("application/json, text/event-stream");
        request.Headers.Add("MCP-Protocol-Version", _version);
        if (_transportSession is not null)
        {
            request.Headers.Add("Mcp-Session-Id", _transportSession);
        }

        request.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        // Send each JSON-RPC operation once: replaying a state-changing tool after an ambiguous failure is unsafe.
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"W365 MCP {method}: HTTP {(int)response.StatusCode}. No automatic retry was performed.");
        }

        if (response.Headers.TryGetValues("Mcp-Session-Id", out var sessions))
        {
            _transportSession = sessions.Single();
        }

        if (notification)
        {
            return default; // Initialized is allowed to return an empty 202/204.
        }

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        if (response.Content.Headers.ContentType?.MediaType == "text/event-stream")
        {
            // SSE may split one JSON-RPC response across multiple data lines; blank lines delimit complete events.
            using var reader = new StreamReader(stream);
            var data = new StringBuilder();
            var total = 0;
            while (await reader.ReadLineAsync(ct) is { } line)
            {
                total += line.Length;
                if (total > 4 * 1024 * 1024)
                {
                    throw new InvalidOperationException("MCP response exceeded 4 MiB.");
                }

                if (line.Length == 0)
                {
                    if (data.Length > 0 && Parse(data.ToString(), id, logger) is { } result)
                    {
                        return result;
                    }

                    data.Clear();
                }
                else if (line.StartsWith("data:", StringComparison.Ordinal))
                {
                    data.AppendLine(line[5..].TrimStart(' '));
                }
            }
            if (data.Length > 0 && Parse(data.ToString(), id, logger) is { } final)
            {
                return final;
            }

            throw new InvalidOperationException("MCP SSE ended without the matching response.");
        }
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + count > 4 * 1024 * 1024)
            {
                throw new InvalidOperationException("MCP response exceeded 4 MiB.");
            }

            buffer.Write(chunk, 0, count);
        }
        return Parse(Encoding.UTF8.GetString(buffer.ToArray()), id, logger)
            ?? throw new InvalidOperationException("MCP response ID did not match.");
    }
    internal static JsonElement? Parse(string text, int id, ILogger? logger = null)
    {
        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        if (!root.TryGetProperty("id", out var value) || !value.TryGetInt32(out var actual) || actual != id)
        {
            return null;
        }

        if (root.TryGetProperty("error", out var rpcError))
        {
            if (logger is not null)
            {
                _logRpcError(logger, null);
            }

            throw new InvalidOperationException("MCP returned a JSON-RPC error; operation is not replayed.");
        }

        return root.GetProperty("result").Clone();
    }
    internal static string? Field(JsonElement node, string name)
    {
        if (node.ValueKind == JsonValueKind.Object)
        {
            if (node.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String)
            {
                return value.GetString();
            }

            foreach (var property in node.EnumerateObject())
            {
                if (property.Name == "text" && property.Value.ValueKind == JsonValueKind.String)
                {
                    var text = property.Value.GetString()!;
                    if (text.TrimStart().StartsWith('{'))
                    {
                        try
                        {
                            using var embedded = JsonDocument.Parse(text); if (Field(embedded.RootElement, name) is { } found)
                            {
                                return found;
                            }
                        }
                        catch (JsonException) { /* Ordinary tool text is not necessarily JSON. */ }
                    }
                }
                if (Field(property.Value, name) is { } nested)
                {
                    return nested;
                }
            }
        }
        else if (node.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in node.EnumerateArray())
            {
                if (Field(item, name) is { } found)
                {
                    return found;
                }
            }
        }

        return null;
    }
}
