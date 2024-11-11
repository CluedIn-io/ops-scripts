@description('Name of the alert')
@minLength(1)
param alertName string

@description('Description of alert')
param alertDescription string

@description('Severity of alert {0,1,2,3,4}')
@allowed([
  0
  1
  2
  3
  4
])
param alertSeverity int = 3

@description('Specifies whether the alert is enabled')
param isEnabled bool = true

@description('Full Resource ID of the kubernetes cluster emitting the metric that will be used for the comparison. For example /subscriptions/00000000-0000-0000-0000-0000-00000000/resourceGroups/ResourceGroupName/providers/Microsoft.ContainerService/managedClusters/cluster-xyz')
param clusterResourceId string = ''

@description('The criteria for the alert trigger')
param criteria object = {
  'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
  allOf: [{}]
}

@description('Period of time used to monitor alert activity based on the threshold. Must be between one minute and one day. ISO 8601 duration format.')
@allowed([
  'PT1M'
  'PT5M'
  'PT15M'
  'PT30M'
  'PT1H'
  'PT6H'
  'PT12H'
  'PT24H'
])
param windowSize string = 'PT5M'

@description('how often the metric alert is evaluated represented in ISO 8601 duration format')
@allowed([
  'PT1M'
  'PT5M'
  'PT15M'
  'PT30M'
  'PT1H'
])
param evaluationFrequency string = 'PT1M'

@description('The ID of the action group that is triggered when the alert is activated or deactivated')
param actionGroupId string = ''

resource alertName_resource 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: alertName
  location: 'global'
  tags: {
  }
  properties: {
    description: alertDescription
    severity: alertSeverity
    enabled: isEnabled
    scopes: [
      clusterResourceId
    ]
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    criteria: criteria
    actions: (empty(actionGroupId) ? null : json('[{"actionGroupId": "${actionGroupId}"}]'))
  }
}
