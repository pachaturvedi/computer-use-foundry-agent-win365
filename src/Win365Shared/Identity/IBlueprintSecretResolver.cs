namespace Win365Agent;

/// <summary>
/// Resolves the <c>client_secret</c> mode blueprint secret without exposing it as an environment
/// variable or other application configuration value.
/// </summary>
public interface IBlueprintSecretResolver
{
    /// <summary>Gets the current blueprint client secret value.</summary>
    /// <param name="cancellationToken">A token that cancels resolution.</param>
    /// <returns>The blueprint client secret.</returns>
    Task<string> GetSecretAsync(CancellationToken cancellationToken);
}
