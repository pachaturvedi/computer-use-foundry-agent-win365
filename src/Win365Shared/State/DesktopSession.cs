using System.Text.Json.Serialization;

namespace Win365Agent;

/// <summary>Represents the persisted ownership and lifecycle state of a Windows 365 desktop task.</summary>
public sealed class DesktopSession
{
    /// <summary>Gets or sets the opaque identifier used in operator viewer links.</summary>
    public string LinkId { get; set; } = Convert.ToHexString(
        System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    /// <summary>Gets or sets the response request that exclusively owns the desktop.</summary>
    public required string RequestId { get; set; }

    /// <summary>Gets or sets the Microsoft Entra tenant ID of the authorized operator.</summary>
    public required string OwnerTenantId { get; set; }

    /// <summary>Gets or sets the Microsoft Entra object ID of the authorized operator.</summary>
    public required string OwnerObjectId { get; set; }

    /// <summary>Gets or sets the Windows 365 session ID, or <see langword="null"/> before allocation is confirmed.</summary>
    public string? SessionId { get; set; }

    /// <summary>Gets or sets the stable key used to recover an ambiguous StartSession result.</summary>
    public string? AllocationIdempotencyKey { get; set; }

    /// <summary>Gets or sets the HTTPS screen-sharing link supplied by Windows 365.</summary>
    public string? SessionLink { get; set; }

    /// <summary>Gets or sets the time after which the task can no longer use the desktop.</summary>
    public DateTimeOffset ExpiresAt { get; set; } = DateTimeOffset.UtcNow.AddMinutes(15);

    /// <summary>Gets or sets the current desktop lifecycle phase.</summary>
    public DesktopSessionPhase Phase { get; set; } = DesktopSessionPhase.Starting;

    /// <summary>
    /// Gets or sets whether an external operation has started but its outcome has not yet been persisted.
    /// </summary>
    public bool OperationInFlight { get; set; }
}

[JsonConverter(typeof(JsonStringEnumConverter<DesktopSessionPhase>))]
/// <summary>Identifies the lifecycle phase of a persisted desktop session.</summary>
public enum DesktopSessionPhase
{
    /// <summary>The desktop is being allocated and prepared.</summary>
    Starting,

    /// <summary>The desktop is available for automated tool calls.</summary>
    Active,

    /// <summary>Automation is suspended while the operator interacts with the desktop.</summary>
    Paused,

    /// <summary>An operation has an unknown outcome and requires manual operator recovery.</summary>
    RecoveryRequired,

    /// <summary>The desktop session is being released.</summary>
    Ending
}
