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

@description('GPU workload profile type.')
@allowed(['Consumption-GPU-NC8as-T4', 'Consumption-GPU-NC24-A100'])
param gpuProfileType string = 'Consumption-GPU-NC8as-T4'

@description('Whether to use storage account keys instead of RBAC for storage access.')
param useStorageKeys bool = false

@description('3DGS processing backend: mock, gsplat, gaussian-splatting.')
param processorBackend string = 'mock'

@description('Include RBAC role assignments in provisioning. Set to false if the deployer lacks Owner/UAA permissions.')
param includeRbac bool = true

@description('Principal ID of the deployer (signed-in user). Set automatically by preprovision hook.')
param deployerPrincipalId string = ''

@description('Additional tags for the storage account (e.g., SecurityControl:Ignore for key access policy bypass).')
param storageExtraTags object = {}

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
    tags: union(tags, storageExtraTags)
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
    gpuProfileType: gpuProfileType
  }
}

// AcrPull is a provisioning prerequisite — Container Apps validates registry
// credentials during job creation. Without it, provisioning times out.
module acrPullRole 'modules/acr-pull-role.bicep' = if (includeRbac) {
  name: 'acr-pull-role'
  scope: rg
  params: {
    containerRegistryName: acr.outputs.name
    managedIdentityPrincipalId: identity.outputs.principalId
  }
}

// Storage Blob Data Contributor — only needed at job runtime, assigned
// separately via scripts/assign-rbac.sh by a privileged user.
module storageBlobRole 'modules/storage-blob-role.bicep' = if (includeRbac) {
  name: 'storage-blob-role'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    managedIdentityPrincipalId: identity.outputs.principalId
  }
}

// Deployer RBAC — gives the signed-in user AcrPush + Storage Blob Data Contributor
// so azd deploy can push images and the deployer can manage blobs.
module deployerRoles 'modules/deployer-roles.bicep' = if (includeRbac && !empty(deployerPrincipalId)) {
  name: 'deployer-roles'
  scope: rg
  params: {
    containerRegistryName: acr.outputs.name
    storageAccountName: storage.outputs.name
    deployerPrincipalId: deployerPrincipalId
  }
}

module job 'modules/container-apps-job.bicep' = {
  name: 'container-apps-job'
  scope: rg
  dependsOn: [acrPullRole]
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
    gpuProfileName: useGpu ? containerAppsEnv.outputs.gpuProfileName : ''
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
