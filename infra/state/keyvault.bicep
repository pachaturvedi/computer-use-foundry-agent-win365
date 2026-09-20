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

var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, resourcePrefix), 6)
var keyVaultName = take('${resourcePrefix}-kv-${resourceSuffix}', 24)

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

output keyVaultName string = vault.name
