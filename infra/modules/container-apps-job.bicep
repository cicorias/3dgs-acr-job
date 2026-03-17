@description('Name of the Container Apps Job.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

@description('The azd environment name.')
param environmentName string

@description('Resource ID of the Container Apps Environment.')
param containerAppsEnvironmentId string

@description('Login server of the Container Registry.')
param containerRegistryLoginServer string

@description('Resource ID of the User-Assigned Managed Identity.')
param managedIdentityId string

@description('Client ID of the User-Assigned Managed Identity.')
param managedIdentityClientId string

@description('Name of the Storage Account.')
param storageAccountName string

@description('Container image name (set by azd deploy).')
param imageName string = ''

@description('Whether to use a GPU workload profile.')
param useGpu bool = false

@description('GPU workload profile name (from Container Apps Environment).')
param gpuProfileName string = 'NC8as-T4'

@description('Whether to use storage account keys instead of RBAC.')
param useStorageKeys bool = false

@description('Storage account connection string (only used when useStorageKeys is true).')
@secure()
param storageConnectionString string = ''

@description('3DGS processing backend (mock, gsplat, gaussian-splatting).')
param processorBackend string = 'mock'

var effectiveImage = !empty(imageName) ? imageName : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// The container expects filesystem paths — it uses Azure Blob Storage via
// AZURE_STORAGE_CONNECTION_STRING or AZURE_STORAGE_ACCOUNT_NAME + managed identity.
// Paths are the mount points within the container's filesystem.
var baseEnv = [
  { name: 'BACKEND', value: processorBackend }
  { name: 'INPUT_PATH', value: '/data/input' }
  { name: 'OUTPUT_PATH', value: '/data/output' }
  { name: 'PROCESSED_PATH', value: '/data/processed' }
  { name: 'ERROR_PATH', value: '/data/error' }
  { name: 'AZURE_STORAGE_ACCOUNT_NAME', value: storageAccountName }
  { name: 'AZURE_CLIENT_ID', value: managedIdentityClientId }
  { name: 'AZURE_CONTAINER_NAME', value: 'input' }
  { name: 'LOG_LEVEL', value: 'info' }
]

var keyEnv = useStorageKeys
  ? [
      {
        name: 'AZURE_STORAGE_CONNECTION_STRING'
        secretRef: 'storage-connection-string'
      }
    ]
  : []

var secrets = useStorageKeys
  ? [
      {
        name: 'storage-connection-string'
        value: storageConnectionString
      }
    ]
  : []

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, {
    'azd-env-name': environmentName
    'azd-service-name': 'job'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: useGpu ? gpuProfileName : 'Consumption'
    configuration: {
      replicaTimeout: 7200
      replicaRetryLimit: 1
      triggerType: 'Manual'
      secrets: secrets
      registries: [
        {
          server: containerRegistryLoginServer
          identity: managedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          image: effectiveImage
          name: 'main'
          resources: useGpu
            ? {
                cpu: json('4')
                memory: '16Gi'
              }
            : {
                cpu: json('2')
                memory: '4Gi'
              }
          env: concat(baseEnv, keyEnv)
        }
      ]
    }
  }
}

@description('The name of the Container Apps Job.')
output name string = job.name

@description('The resource ID of the Container Apps Job.')
output id string = job.id
