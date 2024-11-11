metadata description = 'Deploys the backup solution to a customers environment'

param location string = resourceGroup().location
param aksClusterName string
param automationAccountName string
param storageAccountName string
param aksClusterNodeRG string

var cluedinTenantId = 'f5ae2861-b3fc-449d-a9e7-49c14d011ac0'
var crossTenant = subscription().tenantId != cluedinTenantId

var roleStorageBlobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // MSFT: Storage Blob Data Contributor
var roleStorageKeyOperator =  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '81a9662b-bebf-436f-a333-f67b29880f12') // MSFT: Storage Account Key Operator Service Role
var roleContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // MSFT: Contributor
var roleReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // MSFT: Reader
var roleDiskSnapshotContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7efff54f-a5b4-42b5-a1c5-5411624893ce') // MSFT: Disk Snapshot Contributor

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' existing = {
  name: automationAccountName
}

module storageAccount 'Modules/storageaccount.bicep' = {
  name: 'storage-account'
  params: {
    storageAccountName: storageAccountName
    location: location
    roleAssignments: [
      {
        roleDefinitionResourceId: roleStorageBlobContributor
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
      {
        roleDefinitionResourceId: roleStorageKeyOperator
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
    ]
  }
}

// AKS is deployed via the AMA package, so no module actually exists for this.

// Contributor role is required to perform AKS actions.
module aksCluster 'Modules/aks.bicep' = {
  name: 'aks-cluster'
  params: {
    aksClusterName: aksClusterName
    roleAssignments: [
      {
        roleDefinitionResourceId: roleContributor
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
    ]
  }
}

module roleAssignmentRG 'Modules/roleassignments-rg.bicep' = {
  scope: resourceGroup()
  name: 'rg-roleassignments'
  params: {
    roleAssignments: [
      {
        roleDefinitionResourceId: roleDiskSnapshotContributor
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
    ]
  }
}

module roleAssignmentAksNodeRG 'Modules/roleassignments-rg.bicep' = {
  scope: resourceGroup(aksClusterNodeRG)
  name: 'node-roleassignments'
  params: {
    roleAssignments: [
      {
        roleDefinitionResourceId: roleReader
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
      {
        roleDefinitionResourceId: roleDiskSnapshotContributor
        principalId: automationAccount.identity.principalId
        crossTenantId: crossTenant ? automationAccount.id : null
      }
    ]
  }
}
