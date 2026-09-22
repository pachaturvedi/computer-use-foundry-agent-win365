targetScope = 'subscription'

param environmentName string
param location string
@allowed([
  'true'
  'false'
])
param deployState string = 'false'
@maxLength(24)
param resourcePrefix string = ''
param resourceGroupName string = ''
@minLength(36)
@maxLength(36)
param agentPrincipalId string = '00000000-0000-0000-0000-000000000000'
param blueprintCredentialMode string = 'client_secret'

var stateEnabled = toLower(deployState) == 'true'
var resolvedResourcePrefix = !empty(resourcePrefix) ? resourcePrefix : environmentName
var resolvedResourceGroupName = !empty(resourceGroupName) ? resourceGroupName : '${resolvedResourcePrefix}-rg'
var tags = {
  'azd-env-name': environmentName
  component: 'state'
  workload: 'win365-foundry-sample'
  'managed-by': 'azd'
}

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' existing = {
  name: resolvedResourceGroupName
}

module keyVault './keyvault.bicep' = {
  name: 'w365-credential-vault'
  scope: environmentResourceGroup
  params: {
    location: location
    resourcePrefix: resolvedResourcePrefix
    tags: union(tags, { component: 'credentials' })
    agentPrincipalId: agentPrincipalId
    blueprintCredentialMode: blueprintCredentialMode
  }
}

module storage './storage.bicep' = if (stateEnabled) {
  name: 'state-storage'
  scope: environmentResourceGroup
  params: {
    name: resolvedResourcePrefix
    location: location
    tags: tags
    agentPrincipalId: agentPrincipalId
  }
}

output STATE_RESOURCE_GROUP_NAME string = environmentResourceGroup.name
output STATE_STORAGE_ACCOUNT_NAME string = stateEnabled ? storage!.outputs.storageAccountName : ''
output STATE_CONTAINER_NAME string = stateEnabled ? storage!.outputs.containerName : ''
output SESSION_BLOB_URI string = stateEnabled ? storage!.outputs.sessionBlobUri : ''
output W365_KEY_VAULT_NAME string = keyVault.outputs.keyVaultName
// Compatibility alias for azd environments created before the vault moved out of the viewer layer.
output VIEWER_KEY_VAULT_NAME string = keyVault.outputs.keyVaultName
