@description('Name of the Container Apps Environment.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Whether to create a GPU-enabled dedicated workload profile.')
param useGpu bool = false

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: reference(logAnalyticsWorkspaceId, '2023-09-01').customerId
        sharedKey: listKeys(logAnalyticsWorkspaceId, '2023-09-01').primarySharedKey
      }
    }
    workloadProfiles: concat(
      [
        {
          name: 'Consumption'
          workloadProfileType: 'Consumption'
        }
      ],
      useGpu
        ? [
            {
              name: 'gpu'
              workloadProfileType: 'NC24-A100'
              minimumCount: 0
              maximumCount: 1
            }
          ]
        : []
    )
  }
}

@description('The resource ID of the Container Apps Environment.')
output id string = containerAppsEnvironment.id

@description('The name of the Container Apps Environment.')
output name string = containerAppsEnvironment.name

@description('The default domain of the Container Apps Environment.')
output defaultDomain string = containerAppsEnvironment.properties.defaultDomain
