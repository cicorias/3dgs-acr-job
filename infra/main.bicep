targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (used for resource naming).')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Whether to use a GPU workload profile for the job.')
param useGpu bool = false

@description('Whether to use storage account keys instead of RBAC for storage access.')
param useStorageKeys bool = false

@description('3DGS processing backend: mock, gsplat, gaussian-splatting.')
param processorBackend string = 'mock'

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${abbrs.resourceGroup}-${environmentName}'
  location: location
  tags: tags
}

module identity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: rg
  params: {
    name: '${abbrs.managedIdentity}-${resourceToken}'
    location: location
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    name: '${abbrs['operationalInsights-workspace']}-${resourceToken}'
    location: location
    tags: tags
  }
}

module acr 'modules/acr.bicep' = {
  name: 'container-registry'
  scope: rg
  params: {
    name: '${abbrs.containerRegistry}${resourceToken}'
    location: location
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: '${abbrs.storageAccount}${resourceToken}'
    location: location
    tags: tags
  }
}

module containerAppsEnv 'modules/container-apps-env.bicep' = {
  name: 'container-apps-env'
  scope: rg
  params: {
    name: '${abbrs['app-containerApps-environment']}-${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.id
    useGpu: useGpu
  }
}

module job 'modules/container-apps-job.bicep' = {
  name: 'container-apps-job'
  scope: rg
  params: {
    name: '${abbrs['app-jobs']}-${resourceToken}'
    location: location
    tags: tags
    environmentName: environmentName
    containerAppsEnvironmentId: containerAppsEnv.outputs.id
    containerRegistryLoginServer: acr.outputs.loginServer
    managedIdentityId: identity.outputs.resourceId
    managedIdentityClientId: identity.outputs.clientId
    storageAccountName: storage.outputs.name
    useGpu: useGpu
    useStorageKeys: useStorageKeys
    storageConnectionString: useStorageKeys ? storage.outputs.connectionString : ''
    processorBackend: processorBackend
  }
}

// ── Outputs (saved to azd env) ──────────────────────────────────────────────
output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_ID string = acr.outputs.id
output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerAppsEnv.outputs.name
output AZURE_STORAGE_ACCOUNT_NAME string = storage.outputs.name
output AZURE_STORAGE_ACCOUNT_ID string = storage.outputs.id
output MANAGED_IDENTITY_NAME string = identity.outputs.name
output MANAGED_IDENTITY_PRINCIPAL_ID string = identity.outputs.principalId
output MANAGED_IDENTITY_CLIENT_ID string = identity.outputs.clientId
output MANAGED_IDENTITY_RESOURCE_ID string = identity.outputs.resourceId
output JOB_NAME string = job.outputs.name
output AZURE_RESOURCE_GROUP string = rg.name
