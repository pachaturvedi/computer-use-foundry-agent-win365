targetScope = 'resourceGroup'

param location string = resourceGroup().location
param appName string
param environmentName string
param registryName string
param imageName string
param keyVaultName string
param oidcSecretName string = 'w365-viewer-client-secret'
param w365Enabled bool = false
param storageAccountName string
param stateContainerName string = 'desktop-state'
param viewerPublicUrl string = ''
param viewerClientId string = ''
param operatorTenantId string = ''
param operatorObjectId string = ''
param w365TenantId string = ''
param blueprintId string = ''
param agentId string = ''
param agentObjectId string = ''
param agentUserId string = ''
param screenShareSdkUrl string = ''
param screenShareFrameOrigins string = ''
#disable-next-line no-hardcoded-env-urls
param screenShareAppUrl string = 'https://w365ssviewer7f05ac.z13.web.core.windows.net'
param useRegistry bool = true
param tags object = {}

var containerImage = useRegistry
  ? '${registry.properties.loginServer}/${imageName}'
  : imageName

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' existing = { name: environmentName }
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: registryName }
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: keyVaultName }
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageAccountName }
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}
resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobs
  name: stateContainerName
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appName}-identity'
  location: location
  tags: tags
}
resource vaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identity.id, 'secrets')
  scope: vault
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}
resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateContainer.id, identity.id, 'state')
  scope: stateContainer
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource registryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, 'pull')
  scope: registry
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

resource viewer 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, { 'azd-service-name': 'viewer' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8080, allowInsecure: false }
      registries: useRegistry ? [{ server: registry.properties.loginServer, identity: identity.id }] : []
      secrets: w365Enabled ? [{
        name: 'oidc-secret'
        keyVaultUrl: '${vault.properties.vaultUri}secrets/${oidcSecretName}'
        identity: identity.id
      }] : []
    }
    template: {
      scale: { minReplicas: 1, maxReplicas: 1 }
      containers: [{
        name: 'viewer'
        image: containerImage
        command: ['dotnet', 'Win365Agent.dll']
        args: ['--viewer']
        resources: { cpu: json('0.5'), memory: '1Gi' }
        env: concat([
          { name: 'ASPNETCORE_URLS', value: 'http://+:8080' }
          { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          { name: 'SAMPLE_LOCAL_MODE', value: 'false' }
          { name: 'W365_ENABLED', value: string(w365Enabled) }
          { name: 'W365_TENANT_ID', value: w365TenantId }
          { name: 'W365_BLUEPRINT_ID', value: blueprintId }
          { name: 'W365_AGENT_ID', value: agentId }
          { name: 'W365_AGENT_OBJECT_ID', value: agentObjectId }
          { name: 'W365_AGENT_USER_ID', value: agentUserId }
          { name: 'SESSION_BLOB_URI', value: '${storage.properties.primaryEndpoints.blob}${stateContainerName}/slot.json' }
          { name: 'OPERATOR_TENANT_ID', value: operatorTenantId }
          { name: 'OPERATOR_OBJECT_ID', value: operatorObjectId }
          { name: 'VIEWER_PUBLIC_URL', value: viewerPublicUrl }
          { name: 'VIEWER_CLIENT_ID', value: viewerClientId }
          { name: 'SCREENSHARE_SDK_URL', value: screenShareSdkUrl }
          { name: 'SCREENSHARE_FRAME_ORIGINS', value: screenShareFrameOrigins }
          { name: 'SCREENSHARE_APP_URL', value: screenShareAppUrl }
        ], w365Enabled ? [{ name: 'VIEWER_CLIENT_SECRET', secretRef: 'oidc-secret' }] : [])
        probes: [{
          type: 'Liveness'
          httpGet: { path: '/health', port: 8080 }
          initialDelaySeconds: 15
          periodSeconds: 30
        }]
      }]
    }
  }
  dependsOn: [vaultRole, blobRole, registryRole]
}
output viewerHostname string = viewer.properties.configuration.ingress.fqdn
output viewerName string = viewer.name
output viewerIdentityPrincipalId string = identity.properties.principalId
output viewerIdentityClientId string = identity.properties.clientId
output viewerIdentityResourceId string = identity.id
