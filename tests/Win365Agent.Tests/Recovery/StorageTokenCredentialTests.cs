using System.Text;
using System.Text.Json;
using Azure.Core;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class StorageTokenCredentialTests
{
    [Fact]
    public void CredentialAcceptsOnlyExactStorageScope()
    {
        var credential = new StorageTokenCredential(
            new AccessToken("opaque", DateTimeOffset.UtcNow.AddMinutes(5)));

        _ = credential.GetToken(
            new TokenRequestContext(["https://storage.azure.com/.default"]),
            default);
        Assert.Throws<InvalidOperationException>(() => credential.GetToken(
            new TokenRequestContext(["https://management.azure.com/.default"]),
            default));
        Assert.Throws<InvalidOperationException>(() => credential.GetToken(
            new TokenRequestContext(
                ["https://storage.azure.com/.default", "https://management.azure.com/.default"]),
            default));
    }

    [Fact]
    public void ParseableJwtMustHaveExactStorageAudience()
    {
        _ = new StorageTokenCredential(Token(StorageTokenCredential.StorageAudience));
        Assert.Throws<InvalidOperationException>(
            () => new StorageTokenCredential(Token("https://management.azure.com")));
    }

    private static AccessToken Token(string audience)
    {
        static string Encode(object value)
        {
            var text = Convert.ToBase64String(
                Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value)));
            return text.TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        return new AccessToken(
            $"{Encode(new { alg = "none" })}.{Encode(new { aud = audience })}.x",
            DateTimeOffset.UtcNow.AddMinutes(5));
    }
}
