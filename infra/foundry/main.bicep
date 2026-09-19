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
@allowed([
  'managed'
  'existing'
])
param foundryProjectOwnership string = 'managed'
param existingProjectEndpoint string = ''
param existingProjectId string = ''
param existingFoundryResourceGroupId string = ''
param existingFoundryResourceGroupName string = ''
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
var useExistingProject = foundryProjectOwnership == 'existing'
var resolvedProjectEndpoint = !useExistingProject
  ? ''
  : (!empty(existingProjectEndpoint) ? existingProjectEndpoint : fail('Existing-project mode requires FOUNDRY_PROJECT_ENDPOINT.'))
var resolvedProjectId = !useExistingProject
  ? ''
  : (!empty(existingProjectId) ? existingProjectId : fail('Existing-project mode requires AZURE_AI_PROJECT_ID.'))
var resolvedFoundryResourceGroupId = !useExistingProject
  ? ''
  : (!empty(existingFoundryResourceGroupId) ? existingFoundryResourceGroupId : fail('Existing-project mode requires AZD_FOUNDRY_RESOURCE_GROUP_ID.'))
var resolvedFoundryResourceGroupName = !useExistingProject
  ? ''
  : (!empty(existingFoundryResourceGroupName) ? existingFoundryResourceGroupName : fail('Existing-project mode requires AZURE_FOUNDRY_RESOURCE_GROUP.'))

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: foundryResourceGroupName
  location: location
  tags: union(tags, { component: 'environment' })
}

module foundry './resources.bicep' = if (!useExistingProject) {
  name: 'foundry-resources'
  scope: environmentResourceGroup
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

output AZD_FOUNDRY_RESOURCE_GROUP_ID string = useExistingProject ? resolvedFoundryResourceGroupId : environmentResourceGroup.id
output AZURE_FOUNDRY_RESOURCE_GROUP string = useExistingProject ? resolvedFoundryResourceGroupName : environmentResourceGroup.name
output AZURE_RESOURCE_GROUP string = environmentResourceGroup.name
output FOUNDRY_PROJECT_OWNERSHIP string = foundryProjectOwnership
output AZURE_AI_ACCOUNT_NAME string = useExistingProject ? accountName : foundry!.outputs.accountName
output AZURE_AI_PROJECT_NAME string = useExistingProject ? projectName : foundry!.outputs.projectName
output AZURE_AI_PROJECT_ID string = useExistingProject ? resolvedProjectId : foundry!.outputs.projectId
output AZURE_OPENAI_ENDPOINT string = useExistingProject ? 'https://${accountName}.openai.azure.com/' : foundry!.outputs.openAiEndpoint
output FOUNDRY_PROJECT_ENDPOINT string = useExistingProject ? resolvedProjectEndpoint : foundry!.outputs.projectEndpoint
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