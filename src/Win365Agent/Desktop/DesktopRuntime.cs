using System.Text.Json;
using Microsoft.Extensions.AI;

namespace Win365Agent;

/// <summary>
/// Coordinates exclusive Windows 365 desktop allocation, bounded MCP tool execution, operator handoff,
/// and session release for a single response request.
/// </summary>
public sealed class DesktopRuntime : IDisposable
{
    private static readonly Action<ILogger, string, Exception?> _logDesktopReleased =
        LoggerMessage.Define<string>(
            LogLevel.Information,
            new EventId(1, nameof(_logDesktopReleased)),
            "Desktop released for request {RequestId}");

    /// <summary>Gets the MCP tools permitted by the desktop automation policy.</summary>
    public static IReadOnlySet<string> AllowedTools => DesktopRuntimePolicy.AllowedTools;

    private readonly ILogger _logger;
    private readonly McpConnection _mcp;
    private readonly DesktopRuntimeOptions _options;
    private readonly string _requestId;
    private readonly Settings _settings;
    private readonly ISessionStore _store;
    private readonly SemaphoreSlim _toolGate = new(1);
    private IReadOnlyList<ToolSchema> _catalog = [];
    private int _calls;
    private int _images;
    private bool _connected;
    private bool _ownsSlot;
    private bool _allocationAttempted;

    /// <summary>Initializes a desktop runtime for one response request.</summary>
    /// <param name="mcp">The Windows 365 MCP connection.</param>
    /// <param name="store">The exclusive session state store.</param>
    /// <param name="settings">The application settings.</param>
    /// <param name="requestId">The response request that owns any allocated desktop.</param>
    /// <param name="logger">The runtime logger.</param>
    /// <param name="options">Optional polling and execution limits.</param>
    public DesktopRuntime(
        McpConnection mcp,
        ISessionStore store,
        Settings settings,
        string requestId,
        ILogger logger,
        DesktopRuntimeOptions? options = null)
    {
        _mcp = mcp;
        _store = store;
        _settings = settings;
        _requestId = requestId;
        _logger = logger;
        _options = options ?? DesktopRuntimeOptions.Default;
    }

    /// <summary>Allocates a desktop or reopens the active desktop already owned by this request.</summary>
    /// <param name="ct">A token that cancels the operation.</param>
    /// <returns>Operator live-view and take-control links with the task expiration time.</returns>
    /// <exception cref="InvalidOperationException">The desktop is occupied, unavailable, or requires recovery.</exception>
    /// <exception cref="TimeoutException">The allocated desktop does not become ready within the configured polling budget.</exception>
    public async Task<object> OpenAsync(CancellationToken ct)
    {
        await _toolGate.WaitAsync(ct);
        try
        {
            if (!_connected)
            {
                await _mcp.InitializeAsync(ct);
                _catalog = await _mcp.ListAsync(ct);
                _connected = true;
            }

            await using var tx = await _store.OpenAsync(ct);
            if (tx.State is { } existing)
            {
                if (existing.ExpiresAt <= DateTimeOffset.UtcNow)
                {
                    tx.State = null;
                    await tx.SaveAsync(ct);
                }
                else if (existing.RequestId != _requestId &&
                    existing.Phase == DesktopSessionPhase.Starting &&
                    existing.OperationInFlight &&
                    !string.IsNullOrWhiteSpace(existing.AllocationIdempotencyKey) &&
                    existing.OwnerTenantId == _settings.Required("OPERATOR_TENANT_ID") &&
                    existing.OwnerObjectId == _settings.Required("OPERATOR_OBJECT_ID"))
                {
                    existing.RequestId = _requestId;
                    await tx.SaveAsync(ct);
                    _ownsSlot = true;
                    _allocationAttempted = true;
                    return await CompleteAllocationAsync(tx, existing, ct);
                }
                else
                {
                    if (existing.RequestId != _requestId)
                    {
                        throw new InvalidOperationException("Desktop slot is occupied. End or recover the existing task first.");
                    }

                    _ = Own(tx);
                    if (existing.Phase is not (DesktopSessionPhase.Active or DesktopSessionPhase.Paused))
                    {
                        throw new InvalidOperationException("Desktop needs recovery before it can be reopened.");
                    }

                    return Links(existing);
                }
            }

            if (_allocationAttempted)
            {
                throw new InvalidOperationException("This task already allocated a desktop. Submit a fresh task instead.");
            }

            // Persist intent before the remote allocation so a lost response cannot trigger a second desktop.
            tx.State = new DesktopSession
            {
                RequestId = _requestId,
                OwnerTenantId = _settings.Required("OPERATOR_TENANT_ID"),
                OwnerObjectId = _settings.Required("OPERATOR_OBJECT_ID"),
                AllocationIdempotencyKey = Guid.NewGuid().ToString(),
                OperationInFlight = true
            };
            await tx.SaveAsync(ct);
            _ownsSlot = true;
            _allocationAttempted = true;
            return await CompleteAllocationAsync(tx, tx.State, ct);
        }
        finally
        {
            _toolGate.Release();
        }
    }

    private async Task<object> CompleteAllocationAsync(
        SessionTransaction tx,
        DesktopSession state,
        CancellationToken ct)
    {
        var start = await _mcp.CallAsync(
            Require("StartSession").Name,
            new { idempotencyKey = state.AllocationIdempotencyKey },
            ct);
        state.SessionId = McpConnection.Field(start, "sessionId")
                ?? throw new InvalidOperationException("StartSession omitted sessionId. Operator recovery is required.");
        // Checkpoint the remote ID before parsing readiness fields so failures remain recoverable without reallocation.
        await tx.SaveAsync(ct);
        state.SessionLink = McpConnection.Field(start, "sessionLink") ?? McpConnection.Field(start, "screenShareUrl");
        if (state.SessionLink is not null &&
            (!Uri.TryCreate(state.SessionLink, UriKind.Absolute, out var link) || link.Scheme != "https"))
        {
            throw new InvalidOperationException("W365 returned an invalid screen-share link.");

        }

        for (var attempt = 0; attempt < _options.ReadyPollAttempts; attempt++)
        {
            var details = await _mcp.CallAsync(Require("GetSessionDetails").Name,
                new { sessionId = state.SessionId }, ct);
            if (McpConnection.Field(details, "status")?.Equals("Ready", StringComparison.OrdinalIgnoreCase) == true)
            {
                state.SessionLink ??= McpConnection.Field(details, "sessionLink") ?? McpConnection.Field(details, "screenShareUrl");
                if (state.SessionLink is not null &&
                    (!Uri.TryCreate(state.SessionLink, UriKind.Absolute, out var share) ||
                        share.Scheme != "https" || !string.IsNullOrEmpty(share.UserInfo)))
                {
                    throw new InvalidOperationException("W365 returned an invalid screen-share link.");

                }

                _catalog = await _mcp.ListAsync(ct);
                state.OperationInFlight = false;
                state.Phase = DesktopSessionPhase.Active;
                await tx.SaveAsync(ct);
                return Links(state);
            }

            await Task.Delay(_options.ReadyPollInterval, ct);
        }

        throw new TimeoutException("Cloud PC did not become Ready. No second session was allocated.");
    }

    /// <summary>Gets the currently advertised MCP tools that are permitted by policy.</summary>
    /// <returns>Descriptors for the permitted tools.</returns>
    /// <exception cref="InvalidOperationException">This request has not opened a desktop.</exception>
    public object Tools()
    {
        if (!_ownsSlot)
        {
            throw new InvalidOperationException("Call open_desktop first.");
        }

        return _catalog
            .Where(tool => DesktopRuntimePolicy.IsAllowedTool(tool.Name))
            .Select(tool => new
            {
                name = tool.Name,
                description = tool.Description,
                inputSchema = tool.InputSchema
            })
            .ToArray();
    }

    private object Links(DesktopSession session)
    {
        var viewerUrl = _settings.OptionalViewerUrl;
        return new
        {
            liveViewUrl = viewerUrl is null ? null : new Uri(viewerUrl, $"view/{session.LinkId}").ToString(),
            takeControlUrl = viewerUrl is null ? null : new Uri(viewerUrl, $"view/{session.LinkId}#control").ToString(),
            expiresAt = session.ExpiresAt,
            message = viewerUrl is null
                ? "Viewer handoff is unavailable for this agent-only deployment."
                : "The authorized operator must explicitly resume after taking control."
        };
    }

    private ToolSchema Require(string operation) => _catalog.SingleOrDefault(tool =>
        tool.Name == operation || tool.Name == $"mcp_W365ComputerUse_{operation}")
        ?? throw new InvalidOperationException($"W365 catalog is missing {operation}.");

    /// <summary>Executes an allowlisted MCP tool against the desktop owned by this request.</summary>
    /// <param name="toolName">The exact MCP catalog tool name.</param>
    /// <param name="arguments">The tool argument object. Session identifiers are supplied by the runtime.</param>
    /// <param name="ct">A token that cancels the operation.</param>
    /// <returns>The validated tool observations converted to AI content.</returns>
    /// <exception cref="ArgumentException">The arguments are invalid, oversized, or contain a session identifier.</exception>
    /// <exception cref="InvalidOperationException">The tool, session state, ownership, or task budget disallows execution.</exception>
    public async Task<IList<AIContent>> ExecuteAsync(string toolName, JsonElement arguments, CancellationToken ct)
    {
        await _toolGate.WaitAsync(ct);
        try
        {
            if (++_calls > _options.MaxToolCalls)
            {
                throw new InvalidOperationException($"{_options.MaxToolCalls}-tool task budget exhausted.");
            }

            if (!DesktopRuntimePolicy.IsAllowedTool(toolName))
            {
                throw new InvalidOperationException("Tool is not in the sample allowlist.");
            }

            var tool = _catalog.SingleOrDefault(candidate => candidate.Name == toolName)
                ?? throw new InvalidOperationException("Tool is not in the current W365 catalog.");
            if (arguments.ValueKind != JsonValueKind.Object || arguments.GetRawText().Length > _options.MaxToolArgumentCharacters)
            {
                throw new ArgumentException(
                    $"Tool arguments must be an object of at most {_options.MaxToolArgumentCharacters} characters.",
                    nameof(arguments));
            }

            var args = arguments.EnumerateObject().ToDictionary(p => p.Name, p => (object)p.Value.Clone());
            if (args.Keys.Any(k => k.Contains("session", StringComparison.OrdinalIgnoreCase)))
            {
                throw new ArgumentException("Session identifiers are managed by the harness, not the model.", nameof(arguments));
            }

            // A paused task resumes only through an explicit viewer action; browser disconnects do not change state.
            while (true)
            {
                await using (var tx = await _store.OpenAsync(ct))
                {
                    var state = Own(tx);
                    if (state.Phase == DesktopSessionPhase.Active)
                    {
                        if (tool.InputSchema.TryGetProperty("properties", out var props) && props.TryGetProperty("sessionId", out _))
                        {
                            args["sessionId"] = state.SessionId!;
                        }

                        state.OperationInFlight = true;
                        await tx.SaveAsync(ct);
                        var result = await _mcp.CallAsync(toolName, args, ct);
                        state.OperationInFlight = false;
                        await tx.SaveAsync(ct);
                        return McpObservationConverter.Convert(result, ref _images);
                    }

                    if (state.Phase != DesktopSessionPhase.Paused)
                    {
                        throw new InvalidOperationException("Session is not available for automation.");
                    }
                }

                await Task.Delay(_options.ResumePollInterval, ct);
            }
        }
        finally
        {
            _toolGate.Release();
        }
    }

    /// <summary>Pauses automation and returns links for explicit operator interaction.</summary>
    /// <param name="ct">A token that cancels the operation.</param>
    /// <returns>Operator live-view and take-control links with the task expiration time.</returns>
    public async Task<object> HandoffAsync(CancellationToken ct)
    {
        object links;
        await using (var tx = await _store.OpenAsync(ct))
        {
            var state = Own(tx);
            state.Phase = DesktopSessionPhase.Paused;
            await tx.SaveAsync(ct);
            links = Links(state);
        }

        // Return promptly so the model can show the links. Further actions block until explicit resume.
        return links;
    }

    /// <summary>Waits until the operator explicitly resumes a paused desktop.</summary>
    /// <param name="ct">A token that cancels the wait.</param>
    /// <returns>A status message indicating whether automation resumed or no desktop was open.</returns>
    public async Task<string> WaitForResumeAsync(CancellationToken ct)
    {
        if (!_ownsSlot)
        {
            return "No desktop is open.";
        }

        while (true)
        {
            await using (var tx = await _store.OpenAsync(ct))
            {
                var state = tx.State;
                if (state is null || state.RequestId != _requestId)
                {
                    throw new InvalidOperationException("This request does not own the desktop.");
                }

                if (state.Phase != DesktopSessionPhase.Paused)
                {
                    return "No operator resume is pending.";
                }

                if (state.OperationInFlight)
                {
                    throw new InvalidOperationException("A previous operation has an unknown outcome. Operator recovery required.");
                }
            }

            await Task.Delay(_options.ResumePollInterval, ct);
        }
    }

    private DesktopSession Own(SessionTransaction tx)
    {
        var state = tx.State;
        if (state is null || state.RequestId != _requestId)
        {
            throw new InvalidOperationException("This request does not own the desktop.");
        }

        if (state.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            throw new InvalidOperationException("Desktop task expired.");
        }

        if (state.OperationInFlight)
        {
            throw new InvalidOperationException("A previous operation has an unknown outcome. Operator recovery required.");
        }

        return state;
    }

    /// <summary>Ends the Windows 365 session and clears its persisted state.</summary>
    /// <param name="ct">A token that cancels the operation.</param>
    /// <exception cref="InvalidOperationException">Ownership changed or allocation has an unknown outcome.</exception>
    public async Task CloseAsync(CancellationToken ct)
    {
        if (!_ownsSlot)
        {
            return;
        }

        await _toolGate.WaitAsync(ct);
        try
        {
            await using var tx = await _store.OpenAsync(ct);
            if (tx.State?.RequestId != _requestId)
            {
                throw new InvalidOperationException("Desktop ownership changed unexpectedly.");
            }

            if (tx.State.SessionId is null)
            {
                if (tx.State.Phase != DesktopSessionPhase.Starting ||
                    string.IsNullOrWhiteSpace(tx.State.AllocationIdempotencyKey))
                {
                    tx.State.Phase = DesktopSessionPhase.RecoveryRequired;
                    await tx.SaveAsync(ct);
                    throw new InvalidOperationException("StartSession outcome is unknown. Manual W365 recovery required.");
                }

                throw new InvalidOperationException(
                    "StartSession outcome is unknown. Retry with the persisted idempotency key.");
            }

            tx.State.Phase = DesktopSessionPhase.Ending;
            tx.State.OperationInFlight = true;
            // Save before the remote call so an ambiguous EndSession result blocks unsafe automatic reuse.
            await tx.SaveAsync(ct);
            await _mcp.CallAsync(Require("EndSession").Name, new { sessionId = tx.State.SessionId }, ct);
            tx.State = null;
            await tx.SaveAsync(ct);
            _ownsSlot = false;
            _logDesktopReleased(_logger, _requestId, null);
        }
        finally
        {
            _toolGate.Release();
        }
    }

    /// <inheritdoc/>
    public void Dispose() => _toolGate.Dispose();
}
