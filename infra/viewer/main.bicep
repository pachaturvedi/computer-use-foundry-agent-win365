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
param viewerManagedEnvironmentResourceId string = ''
@allowed([
  'true'
  'false'
])
param viewerLiveEnabled string = 'false'
param viewerPublicUrl string = ''
param viewerClientId string = ''
param operatorTenantId string = ''
param operatorObjectId string = ''
param stateResourceGroupName string = ''
param stateStorageAccountName string = ''
param stateContainerName string = ''
param sessionBlobUri string = ''
param w365TenantId string = ''
param blueprintId string = ''
param agentId string = ''
param agentObjectId string = ''
param agentUserId string = ''
param blueprintCredentialMode string = 'client_secret'
param screenShareSdkUrl string = ''
param screenShareFrameOrigins string = ''
param screenShareAppUrl string = ''

var viewerEnabled = toLower(deployViewer) == 'true'
var liveViewerEnabled = viewerEnabled && toLower(viewerLiveEnabled) == 'true'
var createManagedEnvironment = empty(viewerManagedEnvironmentResourceId)
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
    createManagedEnvironment: createManagedEnvironment
    tags: tags
  }
}

module viewer '../viewer.bicep' = if (viewerEnabled) {
  name: 'viewer-bootstrap'
  scope: viewerResourceGroup
  params: {
    appName: '${resourcePrefix}-viewer'
    managedEnvironmentResourceId: createManagedEnvironment
      ? foundation!.outputs.environmentResourceId
      : viewerManagedEnvironmentResourceId
    registryName: foundation!.outputs.registryName
    imageName: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    keyVaultName: foundation!.outputs.keyVaultName
    sessionBlobUri: sessionBlobUri
    w365Enabled: liveViewerEnabled
    viewerPublicUrl: viewerPublicUrl
    viewerClientId: viewerClientId
    operatorTenantId: operatorTenantId
    operatorObjectId: operatorObjectId
    w365TenantId: w365TenantId
    blueprintId: blueprintId
    agentId: agentId
    agentObjectId: agentObjectId
    agentUserId: agentUserId
    blueprintCredentialMode: blueprintCredentialMode
    screenShareSdkUrl: screenShareSdkUrl
    screenShareFrameOrigins: screenShareFrameOrigins
    screenShareAppUrl: screenShareAppUrl
    useRegistry: false
    tags: tags
  }
}

module viewerStateAccess '../viewer-state-access.bicep' = if (viewerEnabled) {
  name: 'viewer-state-access'
  scope: resourceGroup(stateResourceGroupName)
  params: {
    storageAccountName: stateStorageAccountName
    stateContainerName: stateContainerName
    viewerPrincipalId: viewer!.outputs.viewerIdentityPrincipalId
  }
}

output VIEWER_RESOURCE_GROUP_NAME string = viewerEnabled ? viewerResourceGroup.name : ''
output VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID string = viewerEnabled
  ? (createManagedEnvironment ? foundation!.outputs.environmentResourceId : viewerManagedEnvironmentResourceId)
  : ''
output VIEWER_APP_NAME string = viewerEnabled ? viewer!.outputs.viewerName : ''
output VIEWER_APP_HOSTNAME string = viewerEnabled ? viewer!.outputs.viewerHostname : ''
output VIEWER_IDENTITY_CLIENT_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityClientId : ''
output VIEWER_IDENTITY_PRINCIPAL_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityPrincipalId : ''
output VIEWER_IDENTITY_RESOURCE_ID string = viewerEnabled ? viewer!.outputs.viewerIdentityResourceId : ''
output VIEWER_REGISTRY_NAME string = viewerEnabled ? foundation!.outputs.registryName : ''
output VIEWER_REGISTRY_ENDPOINT string = viewerEnabled ? foundation!.outputs.registryLoginServer : ''
output VIEWER_STORAGE_ACCOUNT_NAME string = viewerEnabled ? stateStorageAccountName : ''
output VIEWER_STATE_CONTAINER_NAME string = viewerEnabled ? stateContainerName : ''
output VIEWER_KEY_VAULT_NAME string = viewerEnabled ? foundation!.outputs.keyVaultName : ''
output VIEWER_IMAGE_NAME string = viewerImageName
