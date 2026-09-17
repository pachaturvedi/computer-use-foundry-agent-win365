targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}
param agentPrincipalId string

var compactName = toLower(replace(name, '-', ''))
var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, name), 6)
var storageAccountName = take('${compactName}st${resourceSuffix}', 24)
var containerName = 'desktop-state'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateContainer.id, agentPrincipalId, 'state')
  scope: stateContainer
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

output storageAccountName string = storage.name
output containerName string = stateContainer.name
output sessionBlobUri string = '${storage.properties.primaryEndpoints.blob}${stateContainer.name}/slot.json'
