using Azure;
using Win365Agent;

namespace Win365Shared.Tests;

public sealed class BlobSessionStoreTests
{
    [Fact]
    public async Task LeaseAlreadyPresentFailsWithStableTypedErrorAfterBoundedWaitAsync()
    {
        var attempts = 0;

        var exception = await Assert.ThrowsAsync<SessionLeaseUnavailableException>(() =>
            BlobSessionStore.AcquireLeaseAsync(
                _ =>
                {
                    attempts++;
                    throw new RequestFailedException(
                        409,
                        "conflict",
                        "LeaseAlreadyPresent",
                        null);
                },
                TimeSpan.FromMilliseconds(30),
                TimeSpan.FromMilliseconds(1),
                CancellationToken.None));

        Assert.True(attempts > 1);
        Assert.Equal("desktop_state_locked", SessionLeaseUnavailableException.ErrorCode);
        Assert.Equal(SessionLeaseUnavailableException.SafeMessage, exception.Message);
        Assert.DoesNotContain("LeaseAlreadyPresent", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExternalCancellationPropagatesWithoutLeaseTimeoutMappingAsync()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var exception = await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            BlobSessionStore.AcquireLeaseAsync(
                _ => throw new RequestFailedException(
                    409,
                    "conflict",
                    "LeaseAlreadyPresent",
                    null),
                TimeSpan.FromMinutes(1),
                TimeSpan.FromMilliseconds(1),
                cancellation.Token));

        Assert.IsNotType<SessionLeaseUnavailableException>(exception);
    }

    [Fact]
    public async Task ProviderTimeoutWithoutObservedContentionIsNotMappedToLockedStateAsync()
    {
        var exception = await Assert.ThrowsAsync<TimeoutException>(() =>
            BlobSessionStore.AcquireLeaseAsync(
                async token => await Task.Delay(Timeout.InfiniteTimeSpan, token),
                TimeSpan.FromMilliseconds(20),
                TimeSpan.FromMilliseconds(1),
                CancellationToken.None));

        Assert.IsNotType<SessionLeaseUnavailableException>(exception);
        Assert.Contains("provider", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task NonContentionProviderFailurePropagatesImmediatelyAsync()
    {
        var expected = new RequestFailedException(503, "unavailable", "ServerBusy", null);
        var actual = await Assert.ThrowsAsync<RequestFailedException>(() =>
            BlobSessionStore.AcquireLeaseAsync(
                _ => throw expected,
                TimeSpan.FromSeconds(1),
                TimeSpan.FromMilliseconds(1),
                CancellationToken.None));

        Assert.Same(expected, actual);
    }
}
