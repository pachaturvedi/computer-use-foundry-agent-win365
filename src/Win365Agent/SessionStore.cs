using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;

namespace Win365Agent;

public sealed class DesktopSession
{
    public string LinkId { get; set; } = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    public required string RequestId { get; set; }
    public required string OwnerTenantId { get; set; }
    public required string OwnerObjectId { get; set; }
    public string? SessionId { get; set; }
    public string? SessionLink { get; set; }
    public DateTimeOffset ExpiresAt { get; set; } = DateTimeOffset.UtcNow.AddMinutes(10);
    public string Phase { get; set; } = "Starting";
    public bool OperationInFlight { get; set; }
}

public interface ISessionStore
{
    Task<SessionTransaction> OpenAsync(CancellationToken ct);
}
public abstract class SessionTransaction : IAsyncDisposable
{
    public DesktopSession? State { get; set; }
    public abstract Task SaveAsync(CancellationToken ct);
    public abstract ValueTask DisposeAsync();
}

public sealed class FileSessionStore(string path) : ISessionStore
{
    public async Task<SessionTransaction> OpenAsync(CancellationToken ct)
    {
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        FileStream? handle = null;
        while (handle is null)
        {
            ct.ThrowIfCancellationRequested();
            try { handle = new FileStream(fullPath + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException ex) when ((ex.HResult & 0xFFFF) is 32 or 33 or 11)
            { await Task.Delay(100, ct); }
        }
        try
        {
            var state = File.Exists(fullPath)
                ? JsonSerializer.Deserialize<DesktopSession>(await File.ReadAllTextAsync(fullPath, ct)) : null;
            return new Transaction(fullPath, handle) { State = state };
        }
        catch { handle.Dispose(); throw; }
    }
    private sealed class Transaction(string path, FileStream handle) : SessionTransaction
    {
        public override async Task SaveAsync(CancellationToken ct)
        {
            await File.WriteAllTextAsync(path + ".tmp", JsonSerializer.Serialize(State), ct);
            File.Move(path + ".tmp", path, true);
        }
        public override ValueTask DisposeAsync() => handle.DisposeAsync();
    }
}

public sealed class BlobSessionStore(Uri uri, TokenCredential credential) : ISessionStore
{
    private readonly BlobClient blob = new(uri, credential, new BlobClientOptions { Retry = { MaxRetries = 0 } });
    public async Task<SessionTransaction> OpenAsync(CancellationToken ct)
    {
        try
        {
            await blob.UploadAsync(BinaryData.FromString("null"), new BlobUploadOptions
            { Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All } }, ct);
        }
        catch (RequestFailedException ex) when (ex.ErrorCode is "BlobAlreadyExists" or "ConditionNotMet" or "LeaseIdMissing") { }
        var lease = blob.GetBlobLeaseClient();
        while (true)
        {
            try { await lease.AcquireAsync(TimeSpan.FromSeconds(-1), cancellationToken: ct); break; }
            catch (RequestFailedException ex) when (ex.ErrorCode == "LeaseAlreadyPresent") { await Task.Delay(250, ct); }
        }
        try
        {
            var download = await blob.DownloadContentAsync(new BlobDownloadOptions
            { Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId } }, ct);
            return new Transaction(blob, lease)
            { State = JsonSerializer.Deserialize<DesktopSession>(download.Value.Content.ToString()) };
        }
        catch { await lease.ReleaseAsync(cancellationToken: CancellationToken.None); throw; }
    }
    private sealed class Transaction(BlobClient blob, BlobLeaseClient lease) : SessionTransaction
    {
        public override Task SaveAsync(CancellationToken ct) => blob.UploadAsync(
            BinaryData.FromString(JsonSerializer.Serialize(State)),
            new BlobUploadOptions { Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId } }, ct);
        public override async ValueTask DisposeAsync() => await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
    }
}
