targetScope = 'subscription'

param environmentName string
param location string
@allowed([
  'true'
  'false'
])
param deployViewer string = 'false'
@allowed([
  'true'
  'false'
])
param deployState string = 'false'
@allowed([
  'true'
  'false'
])
param viewerProvisioningActive string = 'false'
@allowed([
  'true'
  'false'
])
param w365Enabled string = 'false'
@maxLength(24)
param resourcePrefix string = ''
param resourceGroupName string = ''
param viewerImageName string = 'win365-sample:v1'
param viewerManagedEnvironmentResourceId string = ''
@allowed([
  'true'
  'false'
])
param viewerLogAnalyticsEnabled string = 'false'
param w365KeyVaultName string = ''
@allowed([
  'true'
  'false'
])
param viewerLiveEnabled string = 'false'
param viewerPublicUrl string = ''
param viewerClientId string = ''
param operatorTenantId string = ''
param operatorObjectId string = ''
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

var expectedSessionBlobUri = 'https://${stateStorageAccountName}.blob.${environment().suffixes.storage}/${stateContainerName}/slot.json'
var stateReady = toLower(deployState) == 'true' && !empty(stateStorageAccountName) && !empty(stateContainerName) && sessionBlobUri == expectedSessionBlobUri
var viewerDeploymentRequested = toLower(deployViewer) == 'true' && (toLower(w365Enabled) == 'true' || toLower(viewerProvisioningActive) == 'true')
var viewerEnabled = viewerDeploymentRequested
  ? (stateReady ? true : fail('DEPLOY_VIEWER=true requires validated shared Blob state outputs.'))
  : false
var liveViewerEnabled = viewerEnabled && toLower(viewerLiveEnabled) == 'true'
var resolvedResourcePrefix = !empty(resourcePrefix) ? resourcePrefix : environmentName
var resolvedResourceGroupName = !empty(resourceGroupName) ? resourceGroupName : '${resolvedResourcePrefix}-rg'
var createManagedEnvironment = empty(viewerManagedEnvironmentResourceId)
var managedEnvironmentIdSegments = split(viewerManagedEnvironmentResourceId, '/')
var tags = {
  'azd-env-name': environmentName
  component: 'viewer'
  workload: 'win365-foundry-sample'
  'managed-by': 'azd'
}

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' existing = {
  name: resolvedResourceGroupName
}

resource existingManagedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (viewerEnabled && !createManagedEnvironment) {
  name: managedEnvironmentIdSegments[8]
  scope: resourceGroup(managedEnvironmentIdSegments[2], managedEnvironmentIdSegments[4])
}

module foundation '../viewer-foundation.bicep' = if (viewerEnabled) {
  name: 'viewer-foundation'
  scope: environmentResourceGroup
  params: {
    location: location
    resourcePrefix: resolvedResourcePrefix
    createManagedEnvironment: createManagedEnvironment
    enableLogAnalytics: toLower(viewerLogAnalyticsEnabled) == 'true'
    tags: tags
  }
}

module viewer '../viewer.bicep' = if (viewerEnabled) {
  name: 'viewer-bootstrap'
  scope: environmentResourceGroup
  params: {
    location: createManagedEnvironment ? location : existingManagedEnvironment!.location
    appName: '${resolvedResourcePrefix}-viewer'
    managedEnvironmentResourceId: createManagedEnvironment
      ? foundation!.outputs.environmentResourceId
      : viewerManagedEnvironmentResourceId
    registryName: foundation!.outputs.registryName
    imageName: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    keyVaultName: w365KeyVaultName
    sessionBlobUri: sessionBlobUri
    w365Enabled: liveViewerEnabled
    viewerLiveEnabled: liveViewerEnabled
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
  scope: environmentResourceGroup
  params: {
    storageAccountName: stateStorageAccountName
    stateContainerName: stateContainerName
    viewerPrincipalId: viewer!.outputs.viewerIdentityPrincipalId
  }
}

output VIEWER_RESOURCE_GROUP_NAME string = environmentResourceGroup.name
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
output VIEWER_IMAGE_NAME string = viewerImageName
