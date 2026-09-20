namespace Win365Agent;

/// <summary>Provides exclusive transactional access to persisted desktop session state.</summary>
public interface ISessionStore
{
    /// <summary>Acquires exclusive access and loads the current session state.</summary>
    /// <param name="cancellationToken">A token that cancels lock acquisition or state loading.</param>
    /// <returns>A transaction that must be asynchronously disposed to release exclusive access.</returns>
    Task<SessionTransaction> OpenAsync(CancellationToken cancellationToken);
}
