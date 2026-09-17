using Azure.Core;

namespace Win365Agent;

/// <summary>Acquires the managed-identity assertion used by agent-user token exchanges.</summary>
public interface IBlueprintTokenProvider
{
    /// <summary>Gets a blueprint identity access token.</summary>
    /// <param name="cancellationToken">A token that cancels token acquisition.</param>
    /// <returns>The blueprint identity token.</returns>
    Task<AccessToken> GetAsync(CancellationToken cancellationToken);
}
