using Azure.Core;
using Win365Agent;

namespace Win365Agent.Tests;

internal sealed class FakeAgentUserTokenProvider : IAgentUserTokenProvider
{
    public Task<AccessToken> GetAsync(
        string audience,
        CancellationToken cancellationToken) =>
        Task.FromResult(
            new AccessToken("fake-test-token", DateTimeOffset.UtcNow.AddHours(1)));
}
