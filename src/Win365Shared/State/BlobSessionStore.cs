using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;

namespace Win365Agent;

/// <summary>Persists desktop session state as JSON using an Azure Blob lease for distributed exclusivity.</summary>
public sealed class BlobSessionStore : ISessionStore
{
    internal static readonly TimeSpan DefaultLeaseAcquireTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan _leaseRetryDelay = TimeSpan.FromMilliseconds(250);
    private readonly BlobClient _blob;
    private readonly TimeSpan _leaseAcquireTimeout;

    /// <summary>Initializes a store backed by the specified state Blob.</summary>
    /// <param name="uri">The URI of the state blob.</param>
    /// <param name="credential">The credential used to access the blob.</param>
    public BlobSessionStore(Uri uri, TokenCredential credential)
        : this(
            new BlobClient(
                uri,
                credential,
                new BlobClientOptions { Retry = { MaxRetries = 0 } }),
            DefaultLeaseAcquireTimeout)
    {
    }

    internal BlobSessionStore(BlobClient blob, TimeSpan leaseAcquireTimeout)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(leaseAcquireTimeout, TimeSpan.Zero);
        _blob = blob;
        _leaseAcquireTimeout = leaseAcquireTimeout;
    }

    /// <inheritdoc/>
    public async Task<SessionTransaction> OpenAsync(CancellationToken cancellationToken)
    {
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
        await AcquireLeaseAsync(
            async token =>
            {
                _ = await lease.AcquireAsync(TimeSpan.FromSeconds(-1), cancellationToken: token);
            },
            _leaseAcquireTimeout,
            _leaseRetryDelay,
            cancellationToken);

        try
        {
            var download = await _blob.DownloadContentAsync(
                new BlobDownloadOptions
                {
                    Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId }
                },
                cancellationToken);
            return new Transaction(_blob, lease)
            {
                State = JsonSerializer.Deserialize<DesktopSession>(download.Value.Content.ToString())
            };
        }

        catch
        {
            await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
            throw;
        }
    }

    internal static async Task AcquireLeaseAsync(
        Func<CancellationToken, Task> acquire,
        TimeSpan timeout,
        TimeSpan retryDelay,
        CancellationToken cancellationToken)
    {
        var leaseAlreadyPresentObserved = false;
        using var timeoutSource = new CancellationTokenSource(timeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeoutSource.Token);

        try
        {
            while (true)
            {
                try
                {
                    await acquire(linkedSource.Token);
                    return;
                }
                catch (RequestFailedException exception) when (
                    exception.ErrorCode == "LeaseAlreadyPresent")
                {
                    leaseAlreadyPresentObserved = true;
                    await Task.Delay(retryDelay, linkedSource.Token);
                }
            }
        }
        catch (OperationCanceledException) when (
            timeoutSource.IsCancellationRequested &&
            !cancellationToken.IsCancellationRequested &&
            leaseAlreadyPresentObserved)
        {
            throw new SessionLeaseUnavailableException();
        }
        catch (OperationCanceledException exception) when (
            timeoutSource.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException(
                "Desktop state provider did not complete lease acquisition within the bounded wait.",
                exception);
        }
    }

    private sealed class Transaction(BlobClient blob, BlobLeaseClient lease) : SessionTransaction
    {
        public override Task SaveAsync(CancellationToken cancellationToken) =>
            blob.UploadAsync(
                BinaryData.FromString(JsonSerializer.Serialize(State)),
                new BlobUploadOptions
                {
                    Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId }
                },
                cancellationToken);

        public override async ValueTask DisposeAsync() =>
            await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
    }
}
