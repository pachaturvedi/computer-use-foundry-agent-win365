using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;

namespace Win365Agent;

/// <summary>Persists desktop session state as JSON using an Azure Blob lease for distributed exclusivity.</summary>
/// <param name="uri">The URI of the state blob.</param>
/// <param name="credential">The credential used to access the blob.</param>
public sealed class BlobSessionStore(Uri uri, TokenCredential credential, ILogger<BlobSessionStore>? logger = null) : ISessionStore
{
    private static readonly Action<ILogger, Exception?> _logOpenStart =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3001, nameof(_logOpenStart)),
            "Opening blob-backed desktop session state transaction.");

    private static readonly Action<ILogger, Exception?> _logLeaseAcquired =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3002, nameof(_logLeaseAcquired)),
            "Acquired blob lease for desktop session state.");

    private static readonly Action<ILogger, bool, Exception?> _logStateLoaded =
        LoggerMessage.Define<bool>(
            LogLevel.Information,
            new EventId(3003, nameof(_logStateLoaded)),
            "Loaded blob-backed desktop session state; state present {StatePresent}.");

    private static readonly Action<ILogger, bool, Exception?> _logStateSaved =
        LoggerMessage.Define<bool>(
            LogLevel.Information,
            new EventId(3004, nameof(_logStateSaved)),
            "Saved blob-backed desktop session state; state present {StatePresent}.");

    private static readonly Action<ILogger, Exception?> _logTransactionReleased =
        LoggerMessage.Define(
            LogLevel.Information,
            new EventId(3005, nameof(_logTransactionReleased)),
            "Released blob-backed desktop session state transaction.");

    private readonly BlobClient _blob = new(
        uri,
        credential,
        new BlobClientOptions { Retry = { MaxRetries = 0 } });

    /// <inheritdoc/>
    public async Task<SessionTransaction> OpenAsync(CancellationToken cancellationToken)
    {
        if (logger is not null)
        {
            _logOpenStart(logger, null);
        }

        try
        {
            // Atomically initialize absent state; concurrent creators and an existing lease are benign races.
            await _blob.UploadAsync(
                BinaryData.FromString("null"),
                new BlobUploadOptions
                {
                    Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All }
                },
                cancellationToken);
        }
        catch (RequestFailedException exception) when (
            exception.ErrorCode is "BlobAlreadyExists" or "ConditionNotMet" or "LeaseIdMissing")
        {
        }

        var lease = _blob.GetBlobLeaseClient();
        // The lease serializes state transitions across agent and viewer processes.
        while (true)
        {
            try
            {
                await lease.AcquireAsync(TimeSpan.FromSeconds(-1), cancellationToken: cancellationToken);
                break;
            }
            catch (RequestFailedException exception) when (exception.ErrorCode == "LeaseAlreadyPresent")
            {
                await Task.Delay(250, cancellationToken);
            }
        }

        if (logger is not null)
        {
            _logLeaseAcquired(logger, null);
        }

        try
        {
            var download = await _blob.DownloadContentAsync(
                new BlobDownloadOptions
                {
                    Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId }
                },
                cancellationToken);
            var state = JsonSerializer.Deserialize<DesktopSession>(download.Value.Content.ToString());
            if (logger is not null)
            {
                _logStateLoaded(logger, state is not null, null);
            }

            return new Transaction(_blob, lease, logger)
            {
                State = state
            };
        }
        catch
        {
            await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
            throw;
        }
    }

    private sealed class Transaction(BlobClient blob, BlobLeaseClient lease, ILogger<BlobSessionStore>? logger) : SessionTransaction
    {
        public override async Task SaveAsync(CancellationToken cancellationToken)
        {
            await blob.UploadAsync(
                BinaryData.FromString(JsonSerializer.Serialize(State)),
                new BlobUploadOptions
                {
                    Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId }
                },
                cancellationToken);

            if (logger is not null)
            {
                _logStateSaved(logger, State is not null, null);
            }
        }

        public override async ValueTask DisposeAsync()
        {
            await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
            if (logger is not null)
            {
                _logTransactionReleased(logger, null);
            }
        }
    }
}
