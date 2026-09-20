namespace Win365Agent;

/// <summary>Represents exclusive, mutable access to persisted desktop session state.</summary>
public abstract class SessionTransaction : IAsyncDisposable
{
    /// <summary>Gets or sets the loaded session state, or <see langword="null"/> when no session is allocated.</summary>
    public DesktopSession? State { get; set; }

    /// <summary>Persists the current value of <see cref="State"/> while exclusive access is held.</summary>
    /// <param name="cancellationToken">A token that cancels the save operation.</param>
    public abstract Task SaveAsync(CancellationToken cancellationToken);

    /// <summary>Releases the exclusive lock and transaction resources.</summary>
    public abstract ValueTask DisposeAsync();
}
