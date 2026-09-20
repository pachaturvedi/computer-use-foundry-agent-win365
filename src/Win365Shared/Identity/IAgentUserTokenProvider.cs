using Azure.Core;

namespace Win365Agent;

/// <summary>Acquires access tokens for supported Windows 365 agent-user audiences.</summary>
public interface IAgentUserTokenProvider
{
    /// <summary>Gets an access token for a supported audience.</summary>
    /// <param name="audience">The audience or delegated scope identifier.</param>
    /// <param name="cancellationToken">A token that cancels token acquisition.</param>
    /// <returns>A valid access token.</returns>
    /// <exception cref="ArgumentException">The audience is not supported.</exception>
    Task<AccessToken> GetAsync(string audience, CancellationToken cancellationToken);
}
