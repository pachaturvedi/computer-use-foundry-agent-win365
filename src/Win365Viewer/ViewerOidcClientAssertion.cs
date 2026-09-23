using Azure.Core;

namespace Win365Agent;

internal static class ViewerOidcClientAssertion
{
    private const string _exchangeScope = "api://AzureADTokenExchange/.default";

    public static async ValueTask<string> GetAsync(
        TokenCredential credential,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(credential);
        var token = await credential.GetTokenAsync(
            new TokenRequestContext([_exchangeScope]),
            cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(token.Token))
        {
            throw new InvalidOperationException("The viewer managed identity did not return a client assertion.");
        }

        return token.Token;
    }
}
