param automationAccountName string = ''
param location string = ''

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: true
    disableLocalAuth: false
    sku: {
      name: 'Basic'
    }
    encryption: {
      identity: {}
      keySource: 'Microsoft.Automation'
    }
  }
}

output automationAccountId string = automationAccount.id
output automationAccountPrincipalId string = automationAccount.identity.principalId
