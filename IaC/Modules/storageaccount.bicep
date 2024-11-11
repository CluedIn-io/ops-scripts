param storageAccountName string = ''
param location string = ''
param roleAssignments array = []

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    accessTier: 'Cool'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }

  resource container 'blobServices@2023-01-01' = {
    name: 'default'

    resource backupContainer 'containers@2023-01-01' = {
      name: 'helm-backups'
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in roleAssignments: {
  name: guid(storageAccount.id, i.principalId, i.roleDefinitionResourceId)
  scope: storageAccount
  properties: {
    roleDefinitionId: i.roleDefinitionResourceId
    principalId: i.principalId
    principalType: 'ServicePrincipal'
    delegatedManagedIdentityResourceId: i.crossTenantId
  }
}]
