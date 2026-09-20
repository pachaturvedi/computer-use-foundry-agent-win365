targetScope = 'resourceGroup'

param location string = resourceGroup().location
@minLength(2)
@maxLength(24)
param resourcePrefix string
param tags object = {}
@minLength(36)
@maxLength(36)
param agentPrincipalId string = '00000000-0000-0000-0000-000000000000'

var agentRoleAssignmentEnabled = agentPrincipalId != '00000000-0000-0000-0000-000000000000'

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
