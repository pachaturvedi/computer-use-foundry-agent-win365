namespace Win365Agent;

/// <summary>
/// Builds a self-signed JWT client assertion for the <c>key_vault_certificate</c> blueprint
/// credential mode without ever exposing the certificate's private key to application code.
/// </summary>
public interface IBlueprintCertificateAssertionProvider
{
    /// <summary>Builds a fresh, short-lived client assertion for a blueprint token request.</summary>
    /// <param name="clientId">The blueprint app/client ID used as the assertion's issuer and subject.</param>
    /// <param name="tokenEndpoint">The Microsoft Entra token endpoint used as the assertion's audience.</param>
    /// <param name="cancellationToken">A token that cancels the request.</param>
    /// <returns>A compact JWT signed by the certificate's Key Vault-managed key.</returns>
    Task<string> GetClientAssertionAsync(string clientId, string tokenEndpoint, CancellationToken cancellationToken);
}
