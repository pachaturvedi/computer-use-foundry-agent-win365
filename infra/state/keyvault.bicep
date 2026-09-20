targetScope = 'resourceGroup'

param location string = resourceGroup().location
@minLength(2)
@maxLength(24)
param resourcePrefix string
param tags object = {}
@minLength(36)
@maxLength(36)
param agentPrincipalId string = '00000000-0000-0000-0000-000000000000'
// Not @allowed-restricted: this may be unset/empty in phase 1, before W365 setup selects a
// credential mode. Only an exact 'client_secret' match enables the role assignment below.
param blueprintCredentialMode string = 'client_secret'

// Only client_secret mode reads the blueprint secret from this vault at agent runtime; other
// modes must not receive standing read access to it.
var agentRoleAssignmentEnabled = agentPrincipalId != '00000000-0000-0000-0000-000000000000' && blueprintCredentialMode == 'client_secret'

// Only key_vault_certificate mode signs blueprint assertions against this vault's certificate at
// agent runtime; other modes must not receive standing access to the certificate or its key.
var agentCertificateRoleAssignmentEnabled = agentPrincipalId != '00000000-0000-0000-0000-000000000000' && blueprintCredentialMode == 'key_vault_certificate'

var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, resourcePrefix), 6)
var keyVaultName = take('${resourcePrefix}-kv-${resourceSuffix}', 24)
// Must match the certificate name created by scripts/Initialize-W365BlueprintCertificate.ps1 so
// the certificate/key-scoped role assignments below apply to that object only, not the whole
// shared vault (which also holds unrelated viewer/blueprint secrets).
var blueprintCertificateName = 'w365-blueprint-certificate'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 90
    tenantId: tenant().tenantId
  }
}

// Grants the hosted agent's own runtime identity read-only access to the blueprint client secret
// (client_secret mode) so the secret never needs to be injected as an environment variable or
// azd-managed configuration value. Least-privilege: Key Vault Secrets User (read-only), scoped to
// this vault only.
resource agentSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (agentRoleAssignmentEnabled) {
  name: guid(vault.id, agentPrincipalId, 'blueprint-secret-reader')
  scope: vault
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

// Grants the hosted agent's own runtime identity read-only access to the blueprint certificate's
// public metadata (key_vault_certificate mode) so it can build the x5t thumbprint and resolve the
// certificate's backing key ID. Least-privilege: Key Vault Certificate User, scoped to only the
// blueprint certificate object (not the whole shared vault, which also holds unrelated secrets).
resource blueprintCertificate 'Microsoft.KeyVault/vaults/certificates@2023-07-01' existing = {
  parent: vault
  name: blueprintCertificateName
}

resource agentCertificateUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (agentCertificateRoleAssignmentEnabled) {
  name: guid(vault.id, agentPrincipalId, 'blueprint-certificate-reader')
  scope: blueprintCertificate
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    )
  }
}

// Grants the hosted agent's own runtime identity sign-only access to the blueprint certificate's
// backing key (key_vault_certificate mode) so it can build a signed client assertion remotely.
// Least-privilege: Key Vault Crypto User, scoped to only the backing key object (a Key Vault
// certificate always creates and manages a same-named key). The private key material never
// leaves Key Vault; this role permits only cryptographic operations, not key export, and does not
// grant access to any other key, secret, or certificate in the shared vault.
resource blueprintCertificateKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' existing = {
  parent: vault
  name: blueprintCertificateName
}

resource agentCryptoUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (agentCertificateRoleAssignmentEnabled) {
  name: guid(vault.id, agentPrincipalId, 'blueprint-certificate-signer')
  scope: blueprintCertificateKey
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '12338af0-0e69-4776-bea7-57ae8d297424'
    )
  }
}

output keyVaultName string = vault.name
