metadata description = 'Updates runbooks for customers'

param location string = resourceGroup().location
param aksClusterName string
param automationAccountName string

var roleContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // MSFT: Contributor
var roleReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // MSFT: Reader

// We need the crossTenant check due to the way role assignments work in customer environments.
var cluedinTenantId = 'f5ae2861-b3fc-449d-a9e7-49c14d011ac0'
var crossTenant = subscription().tenantId != cluedinTenantId

module automationAccount 'Modules/automationaccount.bicep' = {
  name: 'automation-account'
  params: {
    automationAccountName: automationAccountName
    location: location
  }
}

module aksCluster 'Modules/aks.bicep' = {
  name: 'aks-cluster'
  params: {
    aksClusterName: aksClusterName
    roleAssignments: [
      {
        roleDefinitionResourceId: roleContributor
        principalId: automationAccount.outputs.automationAccountPrincipalId
        crossTenantId: crossTenant ? automationAccount.outputs.automationAccountId : null
      }
    ]
  }
}

resource roleAssignmentMRGReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, roleReader)
  properties: {
    roleDefinitionId: roleReader
    principalId: automationAccount.outputs.automationAccountPrincipalId
    principalType: 'ServicePrincipal'
    delegatedManagedIdentityResourceId: crossTenant ? automationAccount.outputs.automationAccountId : null
  }
  dependsOn: [
    automationAccount
  ]
}
