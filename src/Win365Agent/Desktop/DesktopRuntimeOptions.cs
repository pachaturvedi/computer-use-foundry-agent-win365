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
    public int ReadyPollAttempts { get; init; } = 180;

    /// <summary>Gets the delay between session-readiness polls.</summary>
    public TimeSpan ReadyPollInterval { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>Gets the delay between checks for an operator-requested resume.</summary>
    public TimeSpan ResumePollInterval { get; init; } = TimeSpan.FromMilliseconds(500);

    /// <summary>Gets the maximum number of StartSession attempts when W365 reports no free capacity.</summary>
    public int StartSessionCapacityRetryAttempts { get; init; } = 8;

    /// <summary>Gets the base delay between StartSession retries after a capacity-exhausted error.</summary>
    /// <remarks>
    /// Actual delay grows exponentially per attempt (base * 2^(attempt-1)), capped at
    /// <see cref="StartSessionCapacityRetryMaxInterval"/>, with up to 20% random jitter added to
    /// avoid synchronized retry storms across concurrent requests.
    /// </remarks>
    public TimeSpan StartSessionCapacityRetryBaseInterval { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>Gets the maximum delay between StartSession capacity retries, regardless of backoff growth.</summary>
    public TimeSpan StartSessionCapacityRetryMaxInterval { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>
    /// Gets the hard policy limit on total elapsed time spent retrying StartSession for capacity
    /// exhaustion. Retries stop once this budget is exceeded even if attempts remain, so a request
    /// cannot be held open indefinitely by a persistently unavailable pool.
    /// </summary>
    public TimeSpan StartSessionCapacityRetryMaxTotalWait { get; init; } = TimeSpan.FromMinutes(6);
}
