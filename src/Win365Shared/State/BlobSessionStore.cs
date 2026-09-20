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
public sealed class BlobSessionStore(Uri uri, TokenCredential credential) : ISessionStore
{
    private readonly BlobClient _blob = new(
        uri,
        credential,
        new BlobClientOptions { Retry = { MaxRetries = 0 } });

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
