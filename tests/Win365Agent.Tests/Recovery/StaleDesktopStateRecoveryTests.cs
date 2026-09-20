using System.Net;
using System.Text;
using System.Text.Json;
using Azure;
using Microsoft.Extensions.Logging.Abstractions;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class StaleDesktopStateRecoveryTests
{
    [Theory]
    [InlineData("""[{"status":"STOPPED"}]""", true)]
    [InlineData("""{"sessions":[{"status":" idle "}]}""", true)]
    [InlineData("""{"items":[{"status":"Deleted"}]}""", true)]
    [InlineData("""{"value":[{"status":"expired"}]}""", true)]
    [InlineData("""{"data":[{"status":"stopped"}]}""", true)]
    [InlineData("""{"data":{"sessions":[]}}""", true)]
    [InlineData("""{"sessions":[{"status":""}]}""", false)]
    [InlineData("""{"sessions":[{"status":"unknown"}]}""", false)]
    [InlineData("""{"sessions":[],"items":[]}""", false)]
    [InlineData("""{"sessions":[],"nextLink":"next"}""", false)]
    [InlineData("""{"data":{"items":[],"pagination":{"nextToken":"next"}}}""", false)]
    public void HostedSessionGuardAcceptsOnlyKnownUnpagedSchemas(string json, bool expected)
    {
        Assert.Equal(expected, HostedSessionRecoveryGuard.HasOnlyStoppedSessions(json));
    }

    [Fact]
    public void ChangedStateOrEtagCannotPassThePostLeaseCheck()
    {
        var snapshot = new StaleStateSnapshot(
            Session(),
            BinaryData.FromString("""{"state":"old"}"""),
            new ETag("\"old\""),
            Azure.Storage.Blobs.Models.LeaseState.Leased);

        Assert.False(BlobStaleStateStore.IsUnchanged(
            snapshot,
            new ETag("\"new\""),
            snapshot.Content));
        Assert.False(BlobStaleStateStore.IsUnchanged(
            snapshot,
            snapshot.ETag,
            BinaryData.FromString("""{"state":"changed"}""")));
        Assert.True(BlobStaleStateStore.IsUnchanged(
            snapshot,
            snapshot.ETag,
            snapshot.Content));
    }

    [Fact]
    public async Task InspectionAcceptsOnlyExactNoSessionConditionAndDoesNotMutateAsync()
    {
        var store = new FakeStaleStateStore(Session());
        using var handler = new RecoveryMcpHandler(
            StaleDesktopStateRecovery.NoSessionCondition);
        using var http = new HttpClient(handler);
        var recovery = Recovery(store, http);

        var outcome = await recovery.InspectAsync(apply: false, default);

        Assert.Equal(StaleStateRecoveryOutcome.Verified, outcome);
        Assert.False(store.Cleared);
        Assert.Equal(["initialize", "notifications/initialized", "tools/list", "tools/call"], handler.Methods);
    }

    [Fact]
    public async Task ApplyClearsOnlyAfterExactNoSessionConditionAsync()
    {
        var store = new FakeStaleStateStore(Session());
        using var handler = new RecoveryMcpHandler(
            StaleDesktopStateRecovery.NoSessionCondition);
        using var http = new HttpClient(handler);

        var outcome = await Recovery(store, http).InspectAsync(apply: true, default);

        Assert.Equal(StaleStateRecoveryOutcome.Cleared, outcome);
        Assert.True(store.Cleared);
    }

    [Fact]
    public async Task CleanStateIsAnIdempotentNoOpAsync()
    {
        var store = new FakeStaleStateStore(
            null,
            Azure.Storage.Blobs.Models.LeaseState.Available);
        using var handler = new RecoveryMcpHandler(
            StaleDesktopStateRecovery.NoSessionCondition);
        using var http = new HttpClient(handler);

        var outcome = await Recovery(store, http).InspectAsync(apply: true, default);

        Assert.Equal(StaleStateRecoveryOutcome.NoRecoveryRequired, outcome);
        Assert.Empty(handler.Methods);
        Assert.False(store.Cleared);
    }

    [Theory]
    [InlineData("No W365 session found.")]
    [InlineData("No W365 session found for supplied identifier")]
    [InlineData("PrefixNo W365 session found. Call mcp_W365ComputerUse_StartSession first.")]
    [InlineData("Error: No W365 session found. Call mcp_W365ComputerUse_StartSession first.")]
    [InlineData("Session is active")]
    public async Task AmbiguousOrActiveRemoteConditionBlocksMutationAsync(string message)
    {
        var store = new FakeStaleStateStore(Session());
        using var handler = new RecoveryMcpHandler(message);
        using var http = new HttpClient(handler);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => Recovery(store, http).InspectAsync(apply: true, default));

        Assert.StartsWith("Recovery blocked:", exception.Message, StringComparison.Ordinal);
        Assert.False(store.Cleared);
    }

    [Theory]
    [InlineData("""{"isError":true,"content":[{"type":"text","text":"No W365 session found. Call mcp_W365ComputerUse_StartSession first."},{"type":"text","text":"other"}]}""")]
    [InlineData("""{"isError":true,"content":[{"type":"image","text":"No W365 session found. Call mcp_W365ComputerUse_StartSession first."}]}""")]
    [InlineData("""{"isError":false,"content":[{"type":"text","text":"No W365 session found. Call mcp_W365ComputerUse_StartSession first."}]}""")]
    [InlineData("""{"isError":true,"content":[{"type":"text","text":"unrelated"}],"structuredContent":{"message":"No W365 session found. Call mcp_W365ComputerUse_StartSession first."}}""")]
    [InlineData("""{"isError":true,"content":[{"type":"text","text":"No W365 session found. Call mcp_W365ComputerUse_StartSession first."}],"structuredContent":{"status":"contradictory"}}""")]
    public void ContradictoryMultipleOrUnrelatedErrorEnvelopesAreRejected(string json)
    {
        Assert.False(StaleDesktopStateRecovery.IsExactNoSessionEnvelope(json));
    }

    [Fact]
    public async Task PersistedOwnerMustMatchConfiguredBoundaryBeforeW365OrMutationAsync()
    {
        var state = Session();
        state.OwnerObjectId = "different-owner";
        var store = new FakeStaleStateStore(state);
        using var handler = new RecoveryMcpHandler(StaleDesktopStateRecovery.NoSessionCondition);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => Recovery(store, new HttpClient(handler)).InspectAsync(apply: true, default));

        Assert.Contains("configured operator boundary", exception.Message, StringComparison.Ordinal);
        Assert.Empty(handler.Methods);
        Assert.False(store.Cleared);
    }

    [Fact]
    public async Task LeasedNullIsReadOnlyUntilApplyThenReconciledAsync()
    {
        var store = new FakeStaleStateStore(
            null,
            Azure.Storage.Blobs.Models.LeaseState.Leased);
        using var handler = new RecoveryMcpHandler(StaleDesktopStateRecovery.NoSessionCondition);
        var recovery = Recovery(store, new HttpClient(handler));

        Assert.Equal(
            StaleStateRecoveryOutcome.ClearStateLeaseRequiresRecovery,
            await recovery.InspectAsync(apply: false, default));
        Assert.False(store.Cleared);
        Assert.Equal(
            StaleStateRecoveryOutcome.ReconciledClearState,
            await recovery.InspectAsync(apply: true, default));
        Assert.True(store.Cleared);
        Assert.Empty(handler.Methods);
    }

    [Theory]
    [InlineData(Azure.Storage.Blobs.Models.LeaseState.Available)]
    [InlineData(Azure.Storage.Blobs.Models.LeaseState.Breaking)]
    public async Task InterruptedBreakOrAcquireStateIsReconciledOnceAsync(
        Azure.Storage.Blobs.Models.LeaseState leaseState)
    {
        var store = new FakeStaleStateStore(Session(), leaseState);
        using var handler = new RecoveryMcpHandler(StaleDesktopStateRecovery.NoSessionCondition);

        var outcome = await Recovery(store, new HttpClient(handler))
            .InspectAsync(apply: true, default);

        Assert.Equal(StaleStateRecoveryOutcome.Cleared, outcome);
        Assert.Equal(1, store.ReconcileCalls);
    }

    [Fact]
    public async Task LegacySelfAssertedHostedVerificationFlagIsRejectedAsync()
    {
        var exitCode = await StaleStateRecoveryCommand.RunAsync(
            ["--environment", "demo-dev", "--apply", "--hosted-sessions-verified"]);

        Assert.Equal(2, exitCode);
    }

    [Theory]
    [InlineData("client_secret", true)]
    [InlineData("key_vault_certificate", true)]
    [InlineData("managed_identity_federation", false)]
    public void RecoveryLoadsKeyVaultBindingForKeyVaultBackedModes(
        string credentialMode,
        bool expected)
    {
        Assert.Equal(
            expected,
            StaleStateRecoveryCommand.RequiresKeyVault(credentialMode));
    }

    [Theory]
    [InlineData("lease acquisition")]
    [InlineData("upload reconciliation")]
    [InlineData("lease release")]
    public async Task AmbiguousMutationStagesAreNeverAutomaticallyRetriedAsync(string stage)
    {
        var store = new FaultingStaleStateStore(
            Session(),
            new InvalidOperationException(
                $"Recovery stopped at {stage}: outcome is ambiguous. Do not retry Apply automatically."));
        using var handler = new RecoveryMcpHandler(StaleDesktopStateRecovery.NoSessionCondition);

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => Recovery(store, new HttpClient(handler)).InspectAsync(apply: true, default));

        Assert.Contains(stage, exception.Message, StringComparison.Ordinal);
        Assert.Contains("Do not retry Apply automatically", exception.Message, StringComparison.Ordinal);
        Assert.Equal(1, store.ReconcileCalls);
    }

    [Fact]
    public async Task UnsafePersistedStateBlocksBeforeW365Async()
    {
        var state = Session();
        state.OperationInFlight = true;
        var store = new FakeStaleStateStore(state);
        using var handler = new RecoveryMcpHandler(
            StaleDesktopStateRecovery.NoSessionCondition);
        using var http = new HttpClient(handler);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => Recovery(store, http).InspectAsync(apply: true, default));

        Assert.Empty(handler.Methods);
        Assert.False(store.Cleared);
    }

    private static StaleDesktopStateRecovery Recovery(
        IStaleStateStore store,
        HttpClient http) =>
        new(
            store,
            new McpConnection(
                http,
                new FakeAgentUserTokenProvider(),
                TestSettings.Create(),
                NullLogger<McpConnection>.Instance),
            "tenant",
            "owner");

    private static DesktopSession Session() => new()
    {
        RequestId = "request",
        OwnerTenantId = "tenant",
        OwnerObjectId = "owner",
        SessionId = "remote",
        ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        Phase = DesktopSessionPhase.Paused,
        OperationInFlight = false
    };

    private sealed class FakeStaleStateStore(
        DesktopSession? state,
        Azure.Storage.Blobs.Models.LeaseState leaseState =
            Azure.Storage.Blobs.Models.LeaseState.Leased) : IStaleStateStore
    {
        public bool Cleared { get; private set; }
        public int ReconcileCalls { get; private set; }

        public Task<StaleStateSnapshot> InspectAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new StaleStateSnapshot(
                state,
                state is null
                    ? BinaryData.FromString("null")
                    : BinaryData.FromString(JsonSerializer.Serialize(state)),
                default,
                leaseState));

        public Task<StaleStateReconcileOutcome> ReconcileAsync(
            StaleStateSnapshot expected,
            CancellationToken cancellationToken)
        {
            ReconcileCalls++;
            Cleared = true;
            return Task.FromResult(
                expected.State is null
                    ? StaleStateReconcileOutcome.StateAlreadyClear
                    : StaleStateReconcileOutcome.Cleared);
        }
    }

    private sealed class FaultingStaleStateStore(
        DesktopSession state,
        Exception failure) : IStaleStateStore
    {
        public int ReconcileCalls { get; private set; }

        public Task<StaleStateSnapshot> InspectAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new StaleStateSnapshot(
                state,
                BinaryData.FromString(JsonSerializer.Serialize(state)),
                default,
                Azure.Storage.Blobs.Models.LeaseState.Leased));

        public Task<StaleStateReconcileOutcome> ReconcileAsync(
            StaleStateSnapshot expected,
            CancellationToken cancellationToken)
        {
            ReconcileCalls++;
            return Task.FromException<StaleStateReconcileOutcome>(failure);
        }
    }

    private sealed class RecoveryMcpHandler(string condition) : HttpMessageHandler
    {
        public List<string> Methods { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            using var body = JsonDocument.Parse(
                await request.Content!.ReadAsStringAsync(cancellationToken));
            var method = body.RootElement.GetProperty("method").GetString()!;
            Methods.Add(method);
            if (method == "notifications/initialized")
            {
                return new HttpResponseMessage(HttpStatusCode.Accepted);
            }

            var id = body.RootElement.GetProperty("id").GetInt32();
            object result = method switch
            {
                "initialize" => new { protocolVersion = "2025-06-18" },
                "tools/list" => new
                {
                    tools = new[]
                    {
                        new
                        {
                            name = "GetSessionDetails",
                            description = "read-only details",
                            inputSchema = new { type = "object" }
                        }
                    }
                },
                "tools/call" => new
                {
                    isError = true,
                    content = new[] { new { type = "text", text = condition } }
                },
                _ => throw new InvalidOperationException(method)
            };
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result }),
                    Encoding.UTF8,
                    "application/json")
            };
            response.Headers.Add("Mcp-Session-Id", "transport");
            return response;
        }
    }
}
