using System.Text;
using System.Text.Json;
using Azure.Core;

namespace Win365Agent;

/// <summary>Restricts a pre-acquired recovery token to Azure Storage requests.</summary>
internal sealed class StorageTokenCredential : TokenCredential
{
    internal const string StorageAudience = "https://storage.azure.com";
    private readonly AccessToken _token;

    internal StorageTokenCredential(AccessToken token)
    {
        ValidateAudienceWhenParseable(token.Token);
        _token = token;
    }

    public override AccessToken GetToken(
        TokenRequestContext requestContext,
        CancellationToken cancellationToken)
    {
        ValidateRequest(requestContext);
        return _token;
    }

    public override ValueTask<AccessToken> GetTokenAsync(
        TokenRequestContext requestContext,
        CancellationToken cancellationToken)
    {
        ValidateRequest(requestContext);
        return ValueTask.FromResult(_token);
    }

    private static void ValidateRequest(TokenRequestContext requestContext)
    {
        if (requestContext.Scopes is not [BlueprintTokenProvider.StorageScope])
        {
            throw new InvalidOperationException(
                "The recovery credential can be used only for the Azure Storage scope.");
        }
    }

    private static void ValidateAudienceWhenParseable(string token)
    {
        var segments = token.Split('.');
        if (segments.Length != 3 || !TryDecodeBase64Url(segments[1], out var payload))
        {
            return;
        }

        try
        {
            using var document = JsonDocument.Parse(payload);
            if (!document.RootElement.TryGetProperty("aud", out var audience) ||
                audience.ValueKind != JsonValueKind.String ||
                !string.Equals(audience.GetString(), StorageAudience, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "The recovery token audience is not Azure Storage.");
            }
        }
        catch (JsonException)
        {
            // An opaque or non-JSON token cannot be inspected here; Azure Storage still validates it.
        }
    }

    private static bool TryDecodeBase64Url(string value, out byte[] bytes)
    {
        try
        {
            var padded = value.Replace('-', '+').Replace('_', '/');
            padded += new string('=', (4 - padded.Length % 4) % 4);
            bytes = Convert.FromBase64String(padded);
            return true;
        }
        catch (FormatException)
        {
            bytes = [];
            return false;
        }
    }
}
