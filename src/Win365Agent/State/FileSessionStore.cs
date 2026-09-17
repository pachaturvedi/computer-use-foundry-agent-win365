using System.Text.Json;

namespace Win365Agent;

/// <summary>Persists desktop session state as JSON using a lock file for process-level exclusivity.</summary>
/// <param name="path">The session state file path.</param>
public sealed class FileSessionStore(string path) : ISessionStore
{
    /// <inheritdoc/>
    public async Task<SessionTransaction> OpenAsync(CancellationToken cancellationToken)
    {
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        FileStream? handle = null;
        // FileShare.None turns the sidecar file into a process-wide mutex; retry only lock-contention errors.
        while (handle is null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                handle = new FileStream(
                    fullPath + ".lock",
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None);
            }
            catch (IOException exception) when ((exception.HResult & 0xFFFF) is 32 or 33 or 11)
            {
                await Task.Delay(100, cancellationToken);
            }
        }

        try
        {
            var state = File.Exists(fullPath)
                ? JsonSerializer.Deserialize<DesktopSession>(
                    await File.ReadAllTextAsync(fullPath, cancellationToken))
                : null;
            return new Transaction(fullPath, handle) { State = state };
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private sealed class Transaction(string path, FileStream handle) : SessionTransaction
    {
        public override async Task SaveAsync(CancellationToken cancellationToken)
        {
            // Replace only after a complete write so readers never observe partially serialized JSON.
            await File.WriteAllTextAsync(
                path + ".tmp",
                JsonSerializer.Serialize(State),
                cancellationToken);
            File.Move(path + ".tmp", path, true);
        }

        public override ValueTask DisposeAsync() => handle.DisposeAsync();
    }
}
