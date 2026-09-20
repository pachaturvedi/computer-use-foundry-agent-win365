using Win365Agent;

namespace Win365Shared.Tests;

public sealed class FileSessionStoreTests
{
    [Fact]
    public async Task StatePersistsAndLockSerializesRequestsAsync()
    {
        using var temporaryStore = new TemporarySessionStore();
        var store = temporaryStore.Create();
        await using (var first = await store.OpenAsync(default))
        {
            first.State = TestSettings.Session();
            await first.SaveAsync(default);
            using var timeout = new CancellationTokenSource(150);
            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => store.OpenAsync(timeout.Token));
        }

        await using var second = await store.OpenAsync(default);
        Assert.Equal("owner", second.State!.OwnerObjectId);
    }
}
