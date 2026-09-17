targetScope = 'resourceGroup'

param location string = resourceGroup().location
param accountName string
param projectName string
param projectDisplayName string
param projectDescription string
param modelDeploymentName string
param modelName string
param modelVersion string
param modelSkuName string
param modelSkuCapacity int
param enableDefenderForAI bool = true
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
param storedCompletionsDisabled bool = false
param tags object = {}

resource account 'Microsoft.CognitiveServices/accounts@2026-05-15-preview' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    apiProperties: {}
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
    allowProjectManagement: true
    defaultProject: projectName
    associatedProjects: [
      projectName
    ]
    publicNetworkAccess: publicNetworkAccess
    storedCompletionsDisabled: storedCompletionsDisabled
  }
}

resource defender 'Microsoft.CognitiveServices/accounts/defenderForAISettings@2026-05-15-preview' = if (enableDefenderForAI) {
  parent: account
  name: 'Default'
  properties: {
    state: 'Enabled'
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2026-05-15-preview' = {
  parent: account
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelSkuCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    currentCapacity: modelSkuCapacity
    raiPolicyName: 'Microsoft.DefaultV2'
    deploymentState: 'Running'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-15-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: projectDescription
    displayName: projectDisplayName
  }
}

output accountName string = account.name
output projectName string = projectName
output projectId string = project.id
output openAiEndpoint string = 'https://${account.name}.openai.azure.com/'
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${projectName}'