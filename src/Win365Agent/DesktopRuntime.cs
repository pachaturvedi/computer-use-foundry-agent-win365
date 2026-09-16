using System.Text.Json;
using Microsoft.Extensions.AI;

namespace Win365Agent;

public sealed class DesktopRuntime(
    McpConnection mcp, ISessionStore store, Settings settings, string requestId, ILogger logger)
{
    public static readonly HashSet<string> AllowedTools = new(StringComparer.Ordinal)
    {
        "take_screenshot", "get_screen_size", "click", "double_click", "move_mouse", "drag_mouse",
        "scroll", "type_text", "press_keys", "get_accessibility_tree", "get_focused_element",
        "find_element", "invoke_element", "set_value", "get_text", "browser_get_tabs",
        "browser_get_page_content", "browser_get_interactive_elements", "browser_click",
        "browser_type", "browser_scroll", "browser_navigate", "browser_get_current_url"
    };
    private IReadOnlyList<ToolSchema> catalog = [];
    private readonly SemaphoreSlim toolGate = new(1);
    private int calls;
    private int images;
    private bool connected;
    private bool ownsSlot;
    private bool allocationAttempted;

    public async Task<object> OpenAsync(CancellationToken ct)
    {
        await toolGate.WaitAsync(ct);
        try
        {
            if (!connected) { await mcp.InitializeAsync(ct); catalog = await mcp.ListAsync(ct); connected = true; }
            await using var tx = await store.OpenAsync(ct);
            if (tx.State is { } existing)
            {
                if (existing.RequestId != requestId) throw new InvalidOperationException("Desktop slot is occupied. End or recover the existing task first.");
                _ = Own(tx);
                if (existing.Phase is not ("Active" or "Paused")) throw new InvalidOperationException("Desktop needs recovery before it can be reopened.");
                return Links(existing);
            }
            if (allocationAttempted) throw new InvalidOperationException("This task already allocated a desktop. Submit a fresh task instead.");
            tx.State = new DesktopSession
            {
                RequestId = requestId, OwnerTenantId = settings.Required("OPERATOR_TENANT_ID"),
                OwnerObjectId = settings.Required("OPERATOR_OBJECT_ID"), OperationInFlight = true
            };
            await tx.SaveAsync(ct);
            ownsSlot = true;
            allocationAttempted = true;
            var startTool = Require("StartSession");
            var startArgs = new Dictionary<string, object>();
            if (startTool.InputSchema.TryGetProperty("properties", out var properties) && properties.TryGetProperty("idempotencyKey", out _))
                startArgs["idempotencyKey"] = Guid.NewGuid().ToString();
            var start = await mcp.CallAsync(startTool.Name, startArgs, ct);
            tx.State.SessionId = McpConnection.Field(start, "sessionId")
                ?? throw new InvalidOperationException("StartSession omitted sessionId. Operator recovery is required.");
            await tx.SaveAsync(ct); // Record allocation before parsing readiness or session-link fields.
            tx.State.SessionLink = McpConnection.Field(start, "sessionLink") ?? McpConnection.Field(start, "screenShareUrl");
            if (tx.State.SessionLink is not null &&
                (!Uri.TryCreate(tx.State.SessionLink, UriKind.Absolute, out var link) || link.Scheme != "https"))
                throw new InvalidOperationException("W365 returned an invalid screen-share link.");
            for (var attempt = 0; attempt < 15; attempt++)
            {
                var details = await mcp.CallAsync(Require("GetSessionDetails").Name,
                    new { sessionId = tx.State.SessionId }, ct);
                if (McpConnection.Field(details, "status")?.Equals("Ready", StringComparison.OrdinalIgnoreCase) == true)
                {
                    tx.State.SessionLink ??= McpConnection.Field(details, "sessionLink") ?? McpConnection.Field(details, "screenShareUrl");
                    if (tx.State.SessionLink is not null &&
                        (!Uri.TryCreate(tx.State.SessionLink, UriKind.Absolute, out var share) ||
                            share.Scheme != "https" || !string.IsNullOrEmpty(share.UserInfo)))
                        throw new InvalidOperationException("W365 returned an invalid screen-share link.");
                    catalog = await mcp.ListAsync(ct);
                    tx.State.OperationInFlight = false;
                    tx.State.Phase = "Active";
                    await tx.SaveAsync(ct);
                    return Links(tx.State);
                }
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
            }
            throw new TimeoutException("Cloud PC did not become Ready. No second session was allocated.");
        }
        finally { toolGate.Release(); }
    }
    public object Tools()
    {
        if (!ownsSlot) throw new InvalidOperationException("Call open_desktop first.");
        return catalog.Where(t => AllowedTools.Contains(t.Name)).Select(t => new
        { name = t.Name, description = t.Description, inputSchema = t.InputSchema }).ToArray();
    }
    private object Links(DesktopSession s) => new
    {
        liveViewUrl = new Uri(settings.ViewerUrl, $"view/{s.LinkId}").ToString(),
        takeControlUrl = new Uri(settings.ViewerUrl, $"view/{s.LinkId}#control").ToString(),
        expiresAt = s.ExpiresAt, message = "The authorized operator must explicitly resume after taking control."
    };
    private ToolSchema Require(string operation) => catalog.SingleOrDefault(t => t.Name == operation ||
        t.Name == $"mcp_W365ComputerUse_{operation}")
        ?? throw new InvalidOperationException($"W365 catalog is missing {operation}.");

    public async Task<IList<AIContent>> ExecuteAsync(string toolName, JsonElement arguments, CancellationToken ct)
    {
        await toolGate.WaitAsync(ct);
        try
        {
            if (++calls > 40) throw new InvalidOperationException("40-tool task budget exhausted.");
            if (!AllowedTools.Contains(toolName)) throw new InvalidOperationException("Tool is not in the sample allowlist.");
            var tool = catalog.SingleOrDefault(t => t.Name == toolName)
                ?? throw new InvalidOperationException("Tool is not in the current W365 catalog.");
            if (arguments.ValueKind != JsonValueKind.Object || arguments.GetRawText().Length > 16_000)
                throw new ArgumentException("Tool arguments must be an object of at most 16000 characters.");
            var args = arguments.EnumerateObject().ToDictionary(p => p.Name, p => (object)p.Value.Clone());
            if (args.Keys.Any(k => k.Contains("session", StringComparison.OrdinalIgnoreCase)))
                throw new ArgumentException("Session identifiers are managed by the harness, not the model.");
            while (true)
            {
                await using (var tx = await store.OpenAsync(ct))
                {
                    var state = Own(tx);
                    if (state.Phase == "Active")
                    {
                        if (tool.InputSchema.TryGetProperty("properties", out var props) && props.TryGetProperty("sessionId", out _))
                            args["sessionId"] = state.SessionId!;
                        state.OperationInFlight = true;
                        await tx.SaveAsync(ct);
                        var result = await mcp.CallAsync(toolName, args, ct);
                        state.OperationInFlight = false;
                        await tx.SaveAsync(ct);
                        return Observations.Convert(result, ref images);
                    }
                    if (state.Phase != "Paused") throw new InvalidOperationException("Session is not available for automation.");
                }
                await Task.Delay(500, ct);
            }
        }
        finally { toolGate.Release(); }
    }
    public async Task<object> HandoffAsync(CancellationToken ct)
    {
        object links;
        await using (var tx = await store.OpenAsync(ct))
        {
            var state = Own(tx);
            state.Phase = "Paused";
            await tx.SaveAsync(ct);
            links = Links(state);
        }
        // Return promptly so the model can show the links. Further actions block until explicit resume.
        return links;
    }
    public async Task<string> WaitForResumeAsync(CancellationToken ct)
    {
        if (!ownsSlot) return "No desktop is open.";
        while (true)
        {
            await using (var tx = await store.OpenAsync(ct))
            {
                var state = Own(tx);
                if (state.Phase == "Active") return "The operator resumed automation.";
                if (state.Phase != "Paused") throw new InvalidOperationException("Desktop is not waiting for human input.");
            }
            await Task.Delay(500, ct);
        }
    }
    private DesktopSession Own(SessionTransaction tx)
    {
        var state = tx.State;
        if (state is null || state.RequestId != requestId) throw new InvalidOperationException("This request does not own the desktop.");
        if (state.ExpiresAt <= DateTimeOffset.UtcNow) throw new InvalidOperationException("Desktop task expired.");
        if (state.OperationInFlight) throw new InvalidOperationException("A previous operation has an unknown outcome. Operator recovery required.");
        return state;
    }
    public async Task CloseAsync(CancellationToken ct)
    {
        if (!ownsSlot) return;
        await toolGate.WaitAsync(ct);
        try
        {
            await using var tx = await store.OpenAsync(ct);
            if (tx.State?.RequestId != requestId) throw new InvalidOperationException("Desktop ownership changed unexpectedly.");
            if (tx.State.SessionId is null)
            {
                tx.State.Phase = "RecoveryRequired";
                await tx.SaveAsync(ct);
                throw new InvalidOperationException("StartSession outcome is unknown. Manual W365 recovery required.");
            }
            tx.State.Phase = "Ending";
            tx.State.OperationInFlight = true;
            await tx.SaveAsync(ct);
            await mcp.CallAsync(Require("EndSession").Name, new { sessionId = tx.State.SessionId }, ct);
            tx.State = null;
            await tx.SaveAsync(ct);
            ownsSlot = false;
            logger.LogInformation("Desktop released for request {RequestId}", requestId);
        }
        finally { toolGate.Release(); }
    }
}
