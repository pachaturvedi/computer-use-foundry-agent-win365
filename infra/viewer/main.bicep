targetScope = 'subscription'

param environmentName string
param location string
@allowed([
  'true'
  'false'
])
param deployViewer string = 'false'
@minLength(2)
@maxLength(24)
param resourcePrefix string
param viewerResourceGroupName string = '${resourcePrefix}-viewer-rg'
param viewerImageName string = 'win365-sample:v1'

var viewerEnabled = toLower(deployViewer) == 'true'
var tags = {
  'azd-env-name': environmentName
  component: 'viewer'
  workload: 'win365-foundry-sample'
  'managed-by': 'azd'
}

resource viewerResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = if (viewerEnabled) {
  name: viewerResourceGroupName
  location: location
  tags: tags
}

module foundation '../viewer-foundation.bicep' = if (viewerEnabled) {
  name: 'viewer-foundation'
  scope: viewerResourceGroup
  params: {
    location: location
    resourcePrefix: resourcePrefix
    tags: tags
  }
}

module viewer '../viewer.bicep' = if (viewerEnabled) {
  name: 'viewer-bootstrap'
  scope: viewerResourceGroup
  params: {
    appName: '${resourcePrefix}-viewer'
    environmentName: foundation!.outputs.environmentName
    registryName: foundation!.outputs.registryName
    imageName: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    keyVaultName: foundation!.outputs.keyVaultName
    storageAccountName: foundation!.outputs.storageAccountName
    stateContainerName: foundation!.outputs.stateContainerName
    w365Enabled: false
    useRegistry: false
    tags: tags
  }
}

output VIEWER_RESOURCE_GROUP_NAME string = viewerEnabled ? viewerResourceGroup.name : ''
output VIEWER_APP_NAME string = viewerEnabled ? viewer!.outputs.viewerName : ''
output VIEWER_APP_HOSTNAME string = viewerEnabled ? viewer!.outputs.viewerHostname : ''
output VIEWER_IDENTITY_CLIENT_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityClientId : ''
output VIEWER_IDENTITY_PRINCIPAL_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityPrincipalId : ''
output VIEWER_IDENTITY_RESOURCE_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityResourceId : ''
output VIEWER_REGISTRY_NAME string = viewerEnabled ? foundation!.outputs.registryName : ''
output VIEWER_REGISTRY_ENDPOINT string = viewerEnabled ? foundation!.outputs.registryLoginServer : ''
output VIEWER_STORAGE_ACCOUNT_NAME string = viewerEnabled ? foundation!.outputs.storageAccountName : ''
output VIEWER_STATE_CONTAINER_NAME string = viewerEnabled ? foundation!.outputs.stateContainerName : ''
output VIEWER_KEY_VAULT_NAME string = viewerEnabled ? foundation!.outputs.keyVaultName : ''
output VIEWER_IMAGE_NAME string = viewerImageName
