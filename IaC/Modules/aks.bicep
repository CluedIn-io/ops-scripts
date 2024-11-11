param aksClusterName string
param roleAssignments array

resource aksCluster 'Microsoft.ContainerService/managedClusters@2023-07-02-preview' existing = {
  name: aksClusterName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in roleAssignments: {
  name: guid(aksCluster.id, i.principalId, i.roleDefinitionResourceId)
  scope: aksCluster
  properties: {
    roleDefinitionId: i.roleDefinitionResourceId
    principalId: i.principalId
    principalType: 'ServicePrincipal'
    delegatedManagedIdentityResourceId: i.crossTenantId
  }
}]
