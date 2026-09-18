targetScope = 'subscription'

param environmentName string
param location string
@minLength(3)
@maxLength(90)
param foundryResourceGroupName string
@minLength(2)
@maxLength(24)
param accountName string
@minLength(2)
@maxLength(64)
param projectName string
@minLength(2)
@maxLength(64)
param resourcePrefix string
@minLength(2)
@maxLength(64)
param modelDeploymentName string
@minLength(2)
@maxLength(64)
param modelName string
@minLength(1)
@maxLength(128)
param modelVersion string
@minLength(1)
@maxLength(64)
param modelSkuName string
@minValue(1)
param modelSkuCapacity int
param projectDisplayName string = projectName
param projectDescription string = 'Default project created with the resource'
@allowed([
  'true'
  'false'
])
param enableDefenderForAI string = 'true'
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
@allowed([
  'true'
  'false'
])
param storedCompletionsDisabled string = 'false'

var tags = {
  'azd-env-name': environmentName
  component: 'foundry'
  workload: 'win365-foundry-sample'
  'managed-by': 'azd'
  'resource-prefix': resourcePrefix
}

resource foundryResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: foundryResourceGroupName
  location: location
  tags: tags
}

module foundry './resources.bicep' = {
  name: 'foundry-resources'
  scope: foundryResourceGroup
  params: {
    location: location
    accountName: accountName
    projectName: projectName
    projectDisplayName: projectDisplayName
    projectDescription: projectDescription
    modelDeploymentName: modelDeploymentName
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelSkuCapacity: modelSkuCapacity
    enableDefenderForAI: toLower(enableDefenderForAI) == 'true'
    publicNetworkAccess: publicNetworkAccess
    storedCompletionsDisabled: toLower(storedCompletionsDisabled) == 'true'
    tags: tags
  }
}

output AZD_FOUNDRY_RESOURCE_GROUP_ID string = foundryResourceGroup.id
output AZURE_FOUNDRY_RESOURCE_GROUP string = foundryResourceGroup.name
output AZURE_RESOURCE_GROUP string = foundryResourceGroup.name
output AZURE_AI_ACCOUNT_NAME string = foundry.outputs.accountName
output AZURE_AI_PROJECT_NAME string = foundry.outputs.projectName
output AZURE_AI_PROJECT_ID string = foundry.outputs.projectId
output AZURE_OPENAI_ENDPOINT string = foundry.outputs.openAiEndpoint
output FOUNDRY_PROJECT_ENDPOINT string = foundry.outputs.projectEndpoint
output AI_PROJECT_DEPLOYMENTS string = string([
  {
    name: modelDeploymentName
    model: {
      name: modelName
      format: 'OpenAI'
      version: modelVersion
    }
    sku: {
      name: modelSkuName
      capacity: modelSkuCapacity
    }
  }
])