using System.Collections.Frozen;

namespace Win365Agent;

/// <summary>Defines the MCP tools that the desktop automation runtime may expose and invoke.</summary>
public static class DesktopRuntimePolicy
{
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
}
