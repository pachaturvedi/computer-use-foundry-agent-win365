using Azure;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Win365Agent;

namespace Win365Shared.Tests;

public sealed class KeyVaultBlueprintSecretResolverTests
{
    [Fact]
    public async Task ResolvesAndCachesTheSecretWithoutRepeatedKeyVaultCallsAsync()
    {
        var client = new CountingSecretClient("current-secret-value");
        var resolver = new KeyVaultBlueprintSecretResolver(client);

        var results = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => resolver.GetSecretAsync(default)));

        Assert.All(results, value => Assert.Equal("current-secret-value", value));
        Assert.Equal(1, client.Calls);
    }

    [Fact]
    public async Task RequestsTheCanonicalBlueprintSecretNameAsync()
    {
        var client = new CountingSecretClient("value");
        var resolver = new KeyVaultBlueprintSecretResolver(client);

        await resolver.GetSecretAsync(default);

        Assert.Equal("w365-blueprint-client-secret", client.RequestedName);
    }

    private sealed class CountingSecretClient(string value) : SecretClient
    {
        public int Calls;
        public string? RequestedName;

        public override async Task<Response<KeyVaultSecret>> GetSecretAsync(
            string name, string? version = null, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Calls);
            RequestedName = name;
            await Task.Yield();
            var secret = new KeyVaultSecret(name, value);
            return Response.FromValue(secret, new FakeResponse());
        }
    }

    private sealed class FakeResponse : Response
    {
        public override int Status => 200;
        public override string ReasonPhrase => "OK";
        public override Stream? ContentStream { get => null; set => throw new NotSupportedException(); }
        public override string ClientRequestId { get => string.Empty; set => throw new NotSupportedException(); }
        public override void Dispose()
        {
        }
        protected override bool ContainsHeader(string name) => false;
        protected override IEnumerable<HttpHeader> EnumerateHeaders() => [];
        protected override bool TryGetHeader(string name, out string value)
        {
            value = null!;
            return false;
        }
        protected override bool TryGetHeaderValues(string name, out IEnumerable<string> values)
        {
            values = null!;
            return false;
        }
    }
}
