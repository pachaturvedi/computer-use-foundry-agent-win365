using System.Collections.Frozen;
using System.Text.Json;

namespace Win365Agent;

/// <summary>Defines the MCP tools that the desktop automation runtime may expose and invoke.</summary>
public static class DesktopRuntimePolicy
{
    private static readonly IReadOnlyList<ToolSchema> _implicitInteractionTools =
    [
        Tool(
            "take_screenshot",
            "Capture the current Windows desktop as an image.",
            """{"type":"object","properties":{},"additionalProperties":false}"""),
        Tool(
            "click",
            "Click a desktop coordinate.",
            """{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string","enum":["Left","Right","Middle","Backward","Forward"]},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["x","y","button","clickCount"],"additionalProperties":false}"""),
        Tool(
            "move_mouse",
            "Move the mouse pointer to a desktop coordinate.",
            """{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"],"additionalProperties":false}"""),
        Tool(
            "drag_mouse",
            "Drag the mouse between two desktop coordinates.",
            """{"type":"object","properties":{"startX":{"type":"integer"},"startY":{"type":"integer"},"endX":{"type":"integer"},"endY":{"type":"integer"},"button":{"type":"string","enum":["Left","Right","Middle","Backward","Forward"]}},"required":["startX","startY","endX","endY","button"],"additionalProperties":false}"""),
        Tool(
            "scroll",
            "Scroll at a desktop coordinate using bounded horizontal and vertical notches.",
            """{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"scrollX":{"type":"integer","minimum":-20,"maximum":20},"scrollY":{"type":"integer","minimum":-20,"maximum":20}},"required":["x","y","scrollX","scrollY"],"additionalProperties":false}"""),
        Tool(
            "type_text",
            "Type text into the focused desktop control.",
            """{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"""),
        Tool(
            "press_keys",
            "Press a key or key combination on the desktop.",
            """{"type":"object","properties":{"keys":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":8}},"required":["keys"],"additionalProperties":false}""")
    ];

    /// <summary>Gets the case-sensitive allowlist of desktop and browser tools.</summary>
    public static IReadOnlySet<string> AllowedTools { get; } = new[]
    {
        "take_screenshot", "get_screen_size", "click", "double_click", "move_mouse", "drag_mouse",
        "scroll", "type_text", "press_keys", "get_accessibility_tree", "get_focused_element",
        "find_element", "invoke_element", "set_value", "get_text", "browser_get_tabs",
        "browser_get_page_content", "browser_get_interactive_elements", "browser_click",
        "browser_type", "browser_scroll", "browser_navigate", "browser_get_current_url"
    }.ToFrozenSet(StringComparer.Ordinal);

    /// <summary>Determines whether a tool is permitted by the desktop automation policy.</summary>
    /// <param name="toolName">The MCP tool name.</param>
    /// <returns><see langword="true"/> when the tool is allowlisted; otherwise, <see langword="false"/>.</returns>
    public static bool IsAllowedTool(string toolName) => AllowedTools.Contains(toolName);

    /// <summary>
    /// Adds the documented W365 interaction tools that are callable after allocation but omitted from
    /// the server's <c>tools/list</c> response. This is a live-validated compatibility requirement, not
    /// a fallback; change it only after the service advertises equivalent schemas and live acceptance passes.
    /// </summary>
    public static IReadOnlyList<ToolSchema> AddImplicitInteractionTools(
        IReadOnlyList<ToolSchema> advertisedTools)
    {
        var tools = advertisedTools.ToList();
        var names = tools.Select(tool => tool.Name).ToHashSet(StringComparer.Ordinal);
        tools.AddRange(_implicitInteractionTools.Where(tool => !names.Contains(tool.Name)));
        return tools;
    }

    private static ToolSchema Tool(string name, string description, string schema)
    {
        using var document = JsonDocument.Parse(schema);
        return new ToolSchema(name, description, document.RootElement.Clone());
    }
}
