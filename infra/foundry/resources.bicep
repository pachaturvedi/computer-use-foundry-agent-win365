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

var deployerPrincipalId = deployer().objectId

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

resource deployerProjectManagerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, deployerPrincipalId, 'foundry-project-manager')
  scope: account
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'eadc314b-1a2d-4efa-be10-5d325db5065e'
    )
  }
}

resource deployerFoundryUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, deployerPrincipalId, 'foundry-user')
  scope: account
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '53ca6127-db72-4b80-b1b0-d745d6d5456d'
    )
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-15-preview' = {
  parent: account
  name: projectName
  location: location
  dependsOn: [
    defender
  ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: projectDescription
    displayName: projectDisplayName
  }
}

resource projectFoundryUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, project.id, 'project-foundry-user')
  scope: account
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '53ca6127-db72-4b80-b1b0-d745d6d5456d'
    )
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2026-05-15-preview' = {
  parent: account
  name: modelDeploymentName
  dependsOn: [
    project
    deployerProjectManagerRole
  ]
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

output accountName string = account.name
output projectName string = projectName
output projectId string = project.id
output openAiEndpoint string = 'https://${account.name}.openai.azure.com/'
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${projectName}'