@description('Unique name (within the Resource Group) for the Action group.')
param actionGroupName string = 'cluedin-actiongroup'

@maxLength(12)
@description('Short name (maximum 12 characters) for the Action group.')
param actionGroupShortName string = 'cluedin-ag'

@description('support mail address to route alerts')
param emailAddress string = ''


resource emailActionGroup 'Microsoft.Insights/actionGroups@2021-09-01' = {
  location: 'Global'
  name: actionGroupName
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      {
        name: 'supportEmail'
        emailAddress: emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

output emailActionGroup string = emailActionGroup.id
