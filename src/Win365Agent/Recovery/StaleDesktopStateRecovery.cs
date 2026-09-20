using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;

namespace Win365Agent;

internal sealed record StaleStateSnapshot(
    DesktopSession? State,
    BinaryData Content,
    ETag ETag,
    LeaseState LeaseState);

internal interface IStaleStateStore
{
    Task<StaleStateSnapshot> InspectAsync(CancellationToken cancellationToken);

    Task<StaleStateReconcileOutcome> ReconcileAsync(
        StaleStateSnapshot expected,
        CancellationToken cancellationToken);
}

internal enum StaleStateReconcileOutcome
{
    StateAlreadyClear,
    Cleared
}

internal sealed class BlobStaleStateStore(Uri uri, TokenCredential credential) : IStaleStateStore
{
    private static readonly TimeSpan _retryDelay = TimeSpan.FromMilliseconds(250);
    private readonly BlobClient _blob = new(
        uri,
        credential,
        new BlobClientOptions { Retry = { MaxRetries = 0 } });

    public async Task<StaleStateSnapshot> InspectAsync(CancellationToken cancellationToken)
    {
        var properties = await _blob.GetPropertiesAsync(cancellationToken: cancellationToken);
        var download = await _blob.DownloadContentAsync(cancellationToken);
        var state = JsonSerializer.Deserialize<DesktopSession>(download.Value.Content);
        var leaseState = properties.Value.LeaseState;
        if (leaseState == LeaseState.Leased &&
            properties.Value.LeaseDuration != LeaseDurationType.Infinite)
        {
            throw new InvalidOperationException(
                "Recovery blocked at inspection: the state Blob does not have the expected infinite lease.");
        }
        if (leaseState is not (
            LeaseState.Available or
            LeaseState.Leased or
            LeaseState.Breaking or
            LeaseState.Broken or
            LeaseState.Expired))
        {
            throw new InvalidOperationException(
                "Recovery blocked at inspection: the state Blob lease condition is unknown.");
        }

        return new StaleStateSnapshot(
            state,
            download.Value.Content,
            download.Value.Details.ETag,
            leaseState);
    }

    public async Task<StaleStateReconcileOutcome> ReconcileAsync(
        StaleStateSnapshot expected,
        CancellationToken cancellationToken)
    {
        var lease = _blob.GetBlobLeaseClient(Guid.NewGuid().ToString());
        Exception? breakFailure = null;
        if (expected.LeaseState == LeaseState.Leased)
        {
            try
            {
                // Break is issued at most once. An ambiguous response is reconciled by read-only
                // probing/acquisition below and is never replayed.
                await lease.BreakAsync(TimeSpan.Zero, cancellationToken: cancellationToken);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                breakFailure = exception;
            }
        }

        await AcquireForRecoveryAsync(lease, breakFailure, cancellationToken);
        var stateCleared = false;
        var outcome = StaleStateReconcileOutcome.Cleared;
        Exception? operationFailure = null;
        try
        {
            var current = await DownloadWithLeaseAsync(lease, cancellationToken);
            if (IsNull(current.Value.Content))
            {
                stateCleared = true;
                outcome = StaleStateReconcileOutcome.StateAlreadyClear;
            }
            else
            {
                if (!IsUnchanged(expected, current.Value.Details.ETag, current.Value.Content))
                {
                    throw new InvalidOperationException(
                        "Recovery blocked at post-lease verification: desktop state changed; no clear was attempted.");
                }

                try
                {
                    // Upload is issued at most once.
                    await _blob.UploadAsync(
                        BinaryData.FromString("null"),
                        new BlobUploadOptions
                        {
                            Conditions = new BlobRequestConditions
                            {
                                LeaseId = lease.LeaseId,
                                IfMatch = expected.ETag
                            }
                        },
                        cancellationToken);
                    stateCleared = true;
                }
                catch (Exception exception)
                {
                    // A lost response can mean the one upload succeeded. Probe once under our lease;
                    // never repeat the destructive write.
                    try
                    {
                        using var probeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                        var afterUpload = await DownloadWithLeaseAsync(lease, probeTimeout.Token);
                        if (IsNull(afterUpload.Value.Content))
                        {
                            stateCleared = true;
                        }
                        else
                        {
                            throw new InvalidOperationException(
                                "Recovery stopped at upload reconciliation: the clear outcome is unknown or unchanged. " +
                                "Do not retry Apply automatically; run read-only inspection.", exception);
                        }
                    }
                    catch (InvalidOperationException)
                    {
                        throw;
                    }
                    catch (Exception probeException)
                    {
                        throw new InvalidOperationException(
                            "Recovery stopped at upload reconciliation: the clear outcome could not be observed. " +
                            "Do not retry Apply automatically; run read-only inspection.", probeException);
                    }
                }
            }
        }
        catch (Exception exception)
        {
            operationFailure = exception;
        }

        try
        {
            // Release is also attempted once. A later run can safely reconcile leased-null.
            await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                stateCleared
                    ? "Recovery stopped at lease release: state is clear but lease release is unconfirmed. " +
                      "Do not retry Apply automatically; run read-only inspection."
                    : "Recovery stopped at lease release: release is unconfirmed and state was not confirmed clear. " +
                      "Do not retry Apply automatically; run read-only inspection.",
                exception);
        }

        if (operationFailure is not null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(operationFailure).Throw();
        }
        return outcome;
    }

    private async Task AcquireForRecoveryAsync(
        BlobLeaseClient lease,
        Exception? breakFailure,
        CancellationToken cancellationToken)
    {
        using var timeout = new CancellationTokenSource(BlobSessionStore.DefaultLeaseAcquireTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeout.Token);
        while (true)
        {
            try
            {
                await lease.AcquireAsync(TimeSpan.FromSeconds(-1), cancellationToken: linked.Token);
                return;
            }
            catch (RequestFailedException exception) when (
                exception.ErrorCode is
                    "LeaseAlreadyPresent" or
                    "LeaseIsBreaking" or
                    "LeaseIsBreakingAndCannotBeAcquired")
            {
                try
                {
                    await Task.Delay(_retryDelay, linked.Token);
                    continue;
                }
                catch (OperationCanceledException) when (
                    timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
                {
                    throw new InvalidOperationException(
                        breakFailure is null
                            ? "Recovery blocked at lease acquisition: contention did not resolve within the bounded wait."
                            : "Recovery stopped after an ambiguous lease break: ownership could not be acquired. " +
                              "Do not retry Apply automatically; run read-only inspection.",
                        breakFailure ?? exception);
                }
            }
            catch (OperationCanceledException) when (
                timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new InvalidOperationException(
                    "Recovery blocked at lease acquisition: the provider did not complete within the bounded wait.");
            }
            catch (OperationCanceledException exception) when (cancellationToken.IsCancellationRequested)
            {
                // Cancellation can race a successful acquire response. Probe once using the
                // proposed lease ID and release once if ownership was obtained.
                try
                {
                    using var probeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    _ = await DownloadWithLeaseAsync(lease, probeTimeout.Token);
                }
                catch (RequestFailedException probeException) when (
                    probeException.ErrorCode is
                        "LeaseIdMismatchWithBlobOperation" or
                        "LeaseNotPresentWithBlobOperation")
                {
                    throw new OperationCanceledException(
                        exception.Message,
                        exception,
                        cancellationToken);
                }
                catch (Exception cleanupException)
                {
                    throw new InvalidOperationException(
                        "Recovery stopped at canceled lease acquisition: ownership is unconfirmed. " +
                        "Do not retry Apply automatically; run read-only inspection.",
                        cleanupException);
                }
                try
                {
                    await lease.ReleaseAsync(cancellationToken: CancellationToken.None);
                }
                catch (Exception releaseException)
                {
                    throw new InvalidOperationException(
                        "Recovery stopped at canceled lease acquisition: release is unconfirmed. " +
                        "Do not retry Apply automatically; run read-only inspection.",
                        releaseException);
                }
                throw new OperationCanceledException(exception.Message, exception, cancellationToken);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // Acquisition uses a caller-selected lease ID. If its response was lost, one
                // conditional read establishes whether this process owns the lease.
                try
                {
                    _ = await DownloadWithLeaseAsync(lease, cancellationToken);
                    return;
                }
                catch (Exception probeException)
                {
                    throw new InvalidOperationException(
                        "Recovery stopped at lease acquisition reconciliation: ownership is unknown. " +
                        "Do not retry Apply automatically; run read-only inspection.",
                        new AggregateException(exception, probeException));
                }
            }
        }
    }

    private Task<Response<BlobDownloadResult>> DownloadWithLeaseAsync(
        BlobLeaseClient lease,
        CancellationToken cancellationToken) =>
        _blob.DownloadContentAsync(
            new BlobDownloadOptions
            {
                Conditions = new BlobRequestConditions { LeaseId = lease.LeaseId }
            },
            cancellationToken);

    internal static bool IsUnchanged(
        StaleStateSnapshot expected,
        ETag currentETag,
        BinaryData currentContent) =>
        currentETag == expected.ETag &&
        currentContent.ToMemory().Span.SequenceEqual(expected.Content.ToMemory().Span);

    private static bool IsNull(BinaryData content)
    {
        try
        {
            return JsonSerializer.Deserialize<JsonElement>(content).ValueKind == JsonValueKind.Null;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}

internal enum StaleStateRecoveryOutcome
{
    NoRecoveryRequired,
    Verified,
    ClearStateLeaseRequiresRecovery,
    Cleared,
    ReconciledClearState
}

internal sealed class StaleDesktopStateRecovery(
    IStaleStateStore store,
    McpConnection mcp,
    string ownerTenantId,
    string ownerObjectId)
{
    internal const string NoSessionCondition =
        "No W365 session found. Call mcp_W365ComputerUse_StartSession first.";

    internal async Task<StaleStateRecoveryOutcome> InspectAsync(
        bool apply,
        CancellationToken cancellationToken)
    {
        var snapshot = await store.InspectAsync(cancellationToken);
        if (snapshot.State is null)
        {
            if (snapshot.LeaseState is not (LeaseState.Leased or LeaseState.Breaking))
            {
                return StaleStateRecoveryOutcome.NoRecoveryRequired;
            }
            if (!apply)
            {
                return StaleStateRecoveryOutcome.ClearStateLeaseRequiresRecovery;
            }

            _ = await store.ReconcileAsync(snapshot, cancellationToken);
            return StaleStateRecoveryOutcome.ReconciledClearState;
        }

        ValidateState(snapshot.State, ownerTenantId, ownerObjectId);
        await AssertRemoteSessionAbsentAsync(snapshot.State, cancellationToken);
        if (!apply)
        {
            return StaleStateRecoveryOutcome.Verified;
        }

        var outcome = await store.ReconcileAsync(snapshot, cancellationToken);
        return outcome == StaleStateReconcileOutcome.Cleared
            ? StaleStateRecoveryOutcome.Cleared
            : StaleStateRecoveryOutcome.ReconciledClearState;
    }

    internal static void ValidateState(
        DesktopSession state,
        string ownerTenantId,
        string ownerObjectId)
    {
        if (!string.Equals(state.OwnerTenantId, ownerTenantId, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(state.OwnerObjectId, ownerObjectId, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "Recovery blocked: persisted owner does not match this environment's configured operator boundary.");
        }
        if (state.ExpiresAt > DateTimeOffset.UtcNow)
        {
            throw new InvalidOperationException("Recovery blocked: persisted desktop state has not expired.");
        }
        if (state.OperationInFlight)
        {
            throw new InvalidOperationException(
                "Recovery blocked: persisted desktop state records an operation in flight.");
        }
        if (string.IsNullOrWhiteSpace(state.SessionId))
        {
            throw new InvalidOperationException(
                "Recovery blocked: persisted desktop state has no remote session identifier.");
        }
    }

    private async Task AssertRemoteSessionAbsentAsync(
        DesktopSession state,
        CancellationToken cancellationToken)
    {
        await mcp.InitializeAsync(cancellationToken);
        var catalog = await mcp.ListAsync(cancellationToken);
        var detailsTool = catalog.SingleOrDefault(tool =>
            DesktopRuntimePolicy.IsAllowedLifecycleTool(tool.Name, "GetSessionDetails"))
            ?? throw new InvalidOperationException(
                "Recovery blocked: the live W365 catalog does not advertise GetSessionDetails.");

        try
        {
            _ = await mcp.CallAsync(
                detailsTool.Name,
                new { sessionId = state.SessionId },
                cancellationToken);
        }
        catch (McpToolException exception) when (IsExactNoSessionEnvelope(exception.RawResult))
        {
            return;
        }
        catch (McpToolException)
        {
            throw new InvalidOperationException(
                "Recovery blocked: W365 did not return the exact no-session error envelope.");
        }

        throw new InvalidOperationException(
            "Recovery blocked: W365 did not return the exact no-session error envelope.");
    }

    internal static bool IsExactNoSessionEnvelope(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                root.EnumerateObject().Count() != 2 ||
                !root.TryGetProperty("isError", out var isError) ||
                isError.ValueKind != JsonValueKind.True ||
                !root.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array ||
                content.GetArrayLength() != 1)
            {
                return false;
            }

            var item = content[0];
            return item.ValueKind == JsonValueKind.Object &&
                item.EnumerateObject().Count() == 2 &&
                item.TryGetProperty("type", out var type) &&
                type.ValueKind == JsonValueKind.String &&
                type.GetString() == "text" &&
                item.TryGetProperty("text", out var text) &&
                text.ValueKind == JsonValueKind.String &&
                text.GetString() == NoSessionCondition;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
