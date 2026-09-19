targetScope = 'resourceGroup'

param location string = resourceGroup().location
@minLength(2)
@maxLength(24)
param resourcePrefix string
param createManagedEnvironment bool = true
param tags object = {}

var compactPrefix = toLower(replace(resourcePrefix, '-', ''))
var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, resourcePrefix), 6)
var environmentName = '${resourcePrefix}-cae'
var registryName = take('${compactPrefix}cr${resourceSuffix}', 50)
var logAnalyticsName = '${resourcePrefix}-viewer-logs'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (createManagedEnvironment) {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = if (createManagedEnvironment) {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics!.properties.customerId
        sharedKey: logAnalytics!.listKeys().primarySharedKey
      }
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

output environmentResourceId string = createManagedEnvironment ? environment!.id : ''
output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output logAnalyticsName string = logAnalytics.name
