namespace Win365Agent;

/// <summary>Configures desktop session polling and per-task execution limits.</summary>
public sealed class DesktopRuntimeOptions
{
    /// <summary>Gets the default runtime options.</summary>
    public static DesktopRuntimeOptions Default { get; } = new();

    /// <summary>Gets the maximum number of desktop tool calls allowed per task.</summary>
    public int MaxToolCalls { get; init; } = 40;

    /// <summary>Gets the maximum serialized size of a tool argument object, in characters.</summary>
    public int MaxToolArgumentCharacters { get; init; } = 16_000;

    /// <summary>Gets the maximum number of attempts to poll a new session for readiness.</summary>
    public int ReadyPollAttempts { get; init; } = 15;

    /// <summary>Gets the delay between session-readiness polls.</summary>
    public TimeSpan ReadyPollInterval { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>Gets the delay between checks for an operator-requested resume.</summary>
    public TimeSpan ResumePollInterval { get; init; } = TimeSpan.FromMilliseconds(500);
}
