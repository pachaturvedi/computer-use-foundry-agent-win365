targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Region for the Container App. Defaults to the deployment region and must match the managed environment when an existing one is reused.')
param containerAppLocation string = location
param appName string
param managedEnvironmentResourceId string
param registryName string
param imageName string
param keyVaultName string
param oidcSecretName string = 'w365-viewer-client-secret'
param blueprintSecretName string = 'w365-blueprint-client-secret'
param w365Enabled bool = false
param viewerLiveEnabled bool = false
@allowed([
  'client_secret'
  'managed_identity_federation'
  'key_vault_certificate'
])
param blueprintCredentialMode string = 'key_vault_certificate'
param certificateProvisioningActive bool = false
param certificateRbacReady bool = false
param sessionBlobUri string
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
param screenShareAppUrl string = ''
param useRegistry bool = true
param tags object = {}

var containerImage = useRegistry
  ? '${registry.properties.loginServer}/${imageName}'
  : imageName
var clientSecretEnabled = w365Enabled && blueprintCredentialMode == 'client_secret'
var certificateConfigurationReady = w365Enabled && blueprintCredentialMode == 'key_vault_certificate' && !(certificateProvisioningActive || certificateRbacReady)
  ? fail('key_vault_certificate viewer provisioning requires the orchestration-owned certificate readiness gate.')
  : true
var certificateEnabled = w365Enabled && blueprintCredentialMode == 'key_vault_certificate' && certificateConfigurationReady
var blueprintCertificateName = 'w365-blueprint-certificate'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: registryName }
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: keyVaultName }
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appName}-identity'
  location: location
  tags: tags
}

resource blueprintCertificate 'Microsoft.KeyVault/vaults/certificates@2023-07-01' existing = {
  parent: vault
  name: blueprintCertificateName
}

resource blueprintCertificateKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' existing = {
  parent: vault
  name: blueprintCertificateName
}

// Certificate mode gives the viewer UAMI only public-certificate read and remote-sign rights
// on the one blueprint certificate/key. It receives no private-key export or vault-wide access.
resource viewerCertificateUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (certificateEnabled) {
  name: guid(vault.id, identity.id, 'viewer-blueprint-certificate-reader')
  scope: blueprintCertificate
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    )
  }
}

resource viewerCryptoUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (certificateEnabled) {
  name: guid(vault.id, identity.id, 'viewer-blueprint-certificate-signer')
  scope: blueprintCertificateKey
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '12338af0-0e69-4776-bea7-57ae8d297424'
    )
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
  location: containerAppLocation
  tags: union(tags, { 'azd-service-name': 'viewer' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentResourceId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8080, allowInsecure: false }
      registries: useRegistry ? [{ server: registry.properties.loginServer, identity: identity.id }] : []
      secrets: concat(
        w365Enabled ? [{
          name: 'oidc-secret'
          keyVaultUrl: '${vault.properties.vaultUri}secrets/${oidcSecretName}'
          identity: identity.id
        }] : [],
        clientSecretEnabled ? [{
          name: 'blueprint-secret'
          keyVaultUrl: '${vault.properties.vaultUri}secrets/${blueprintSecretName}'
          identity: identity.id
        }] : []
      )
    }
    template: {
      scale: { minReplicas: 1, maxReplicas: 1 }
      containers: [{
        name: 'viewer'
        image: containerImage
        command: ['dotnet', 'Win365Viewer.dll']
        resources: { cpu: json('0.5'), memory: '1Gi' }
        env: concat([
          { name: 'ASPNETCORE_URLS', value: 'http://+:8080' }
          { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          { name: 'SAMPLE_LOCAL_MODE', value: 'false' }
          { name: 'W365_ENABLED', value: w365Enabled ? 'true' : 'false' }
          { name: 'VIEWER_LIVE_ENABLED', value: viewerLiveEnabled ? 'true' : 'false' }
          { name: 'W365_TENANT_ID', value: w365TenantId }
          { name: 'W365_BLUEPRINT_ID', value: blueprintId }
          { name: 'W365_AGENT_ID', value: agentId }
          { name: 'W365_AGENT_OBJECT_ID', value: agentObjectId }
          { name: 'W365_AGENT_USER_ID', value: agentUserId }
          { name: 'W365_BLUEPRINT_CREDENTIAL_MODE', value: blueprintCredentialMode }
          { name: 'W365_KEY_VAULT_NAME', value: keyVaultName }
          { name: 'SESSION_BLOB_URI', value: sessionBlobUri }
          { name: 'OPERATOR_TENANT_ID', value: operatorTenantId }
          { name: 'OPERATOR_OBJECT_ID', value: operatorObjectId }
          { name: 'VIEWER_PUBLIC_URL', value: viewerPublicUrl }
          { name: 'VIEWER_CLIENT_ID', value: viewerClientId }
          { name: 'SCREENSHARE_SDK_URL', value: screenShareSdkUrl }
          { name: 'SCREENSHARE_FRAME_ORIGINS', value: screenShareFrameOrigins }
          { name: 'SCREENSHARE_APP_URL', value: screenShareAppUrl }
        ],
        w365Enabled ? [{ name: 'VIEWER_CLIENT_SECRET', secretRef: 'oidc-secret' }] : [],
        clientSecretEnabled ? [{ name: 'W365_CLIENT_SECRET', secretRef: 'blueprint-secret' }] : [])
        probes: [{
          type: 'Liveness'
          httpGet: { path: '/health', port: 8080 }
          initialDelaySeconds: 15
          periodSeconds: 30
        }]
      }]
    }
  }
  dependsOn: [registryRole, viewerCertificateUserRole, viewerCryptoUserRole]
}
output viewerHostname string = viewer.properties.configuration.ingress.fqdn
output viewerName string = viewer.name
output viewerIdentityPrincipalId string = identity.properties.principalId
output viewerIdentityClientId string = identity.properties.clientId
output viewerIdentityResourceId string = identity.id
