// An individual module to allow for some limitations of bicep.
// Ideally assignments would be in an appropriate module that lives and dies with the resource
// but sometimes not possible, so this targets the scope of the RG being used at the top level bicep file.

param roleAssignments array

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in roleAssignments: {
  name: guid(resourceGroup().id, i.principalId, i.roleDefinitionResourceId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: i.roleDefinitionResourceId
    principalId: i.principalId
    principalType: 'ServicePrincipal'
    delegatedManagedIdentityResourceId: i.crossTenantId
  }
}]
