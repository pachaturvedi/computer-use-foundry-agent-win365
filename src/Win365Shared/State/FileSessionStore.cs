using System.Text.Json;

namespace Win365Agent;

/// <summary>Persists desktop session state as JSON using a lock file for process-level exclusivity.</summary>
/// <param name="path">The session state file path.</param>
public sealed class FileSessionStore(string path, ILogger<FileSessionStore>? logger = null) : ISessionStore
{
    private static readonly Action<ILogger, Exception?> _logOpenStart =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3101, nameof(_logOpenStart)),
            "Opening file-backed desktop session state transaction.");

    private static readonly Action<ILogger, Exception?> _logLockAcquired =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3102, nameof(_logLockAcquired)),
            "Acquired file lock for desktop session state.");

    private static readonly Action<ILogger, bool, Exception?> _logStateLoaded =
        LoggerMessage.Define<bool>(
            LogLevel.Information,
            new EventId(3103, nameof(_logStateLoaded)),
            "Loaded file-backed desktop session state; state present {StatePresent}.");

    private static readonly Action<ILogger, bool, Exception?> _logStateSaved =
        LoggerMessage.Define<bool>(
            LogLevel.Information,
            new EventId(3104, nameof(_logStateSaved)),
            "Saved file-backed desktop session state; state present {StatePresent}.");

    private static readonly Action<ILogger, Exception?> _logTransactionReleased =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3105, nameof(_logTransactionReleased)),
            "Released file-backed desktop session state transaction.");

    /// <inheritdoc/>
    public async Task<SessionTransaction> OpenAsync(CancellationToken cancellationToken)
    {
        if (logger is not null)
        {
            _logOpenStart(logger, null);
        }

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

        if (logger is not null)
        {
            _logLockAcquired(logger, null);
        }

        try
        {
            var state = File.Exists(fullPath)
                ? JsonSerializer.Deserialize<DesktopSession>(
                    await File.ReadAllTextAsync(fullPath, cancellationToken))
                : null;
            if (logger is not null)
            {
                _logStateLoaded(logger, state is not null, null);
            }

            return new Transaction(fullPath, handle, logger) { State = state };
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private sealed class Transaction(string path, FileStream handle, ILogger<FileSessionStore>? logger) : SessionTransaction
    {
        public override async Task SaveAsync(CancellationToken cancellationToken)
        {
            // Replace only after a complete write so readers never observe partially serialized JSON.
            await File.WriteAllTextAsync(
                path + ".tmp",
                JsonSerializer.Serialize(State),
                cancellationToken);
            File.Move(path + ".tmp", path, true);

            if (logger is not null)
            {
                _logStateSaved(logger, State is not null, null);
            }
        }

        public override async ValueTask DisposeAsync()
        {
            await handle.DisposeAsync();
            if (logger is not null)
            {
                _logTransactionReleased(logger, null);
            }
        }
    }
}
