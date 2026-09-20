namespace Win365Agent;

/// <summary>Reports that exclusive desktop state could not be acquired within its bounded wait.</summary>
public sealed class SessionLeaseUnavailableException : TimeoutException
{
    /// <summary>The stable error code returned to the desktop model.</summary>
    public const string ErrorCode = "desktop_state_locked";

    /// <summary>The safe operator-facing message. It contains no state or session identifiers.</summary>
    public const string SafeMessage =
        "Desktop state is locked by another process. Do not retry automatically. " +
        "An operator must run the guarded stale-state recovery workflow.";

    /// <summary>Initializes the exception with the stable safe message.</summary>
    public SessionLeaseUnavailableException()
        : base(SafeMessage)
    {
    }
}
