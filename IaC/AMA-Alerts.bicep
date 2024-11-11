@description('Unique name (within the Resource Group) for the Action group.')
param actionGroupName string = 'cluedin-actiongroup'

@maxLength(12)
@description('Short name (maximum 12 characters) for the Action group.')
param actionGroupShortName string = 'cluedin-ag'

@description('Support mail address to route alerts')
param emailAddress string = ''

@description('The AKS Cluster name that will be gathered at runtime')
param AKSClusterName string = ''

@description('ClientId of the omsAgent')
param omsAgentId string = ''

resource aksCluster 'Microsoft.ContainerService/managedClusters@2023-07-02-preview' existing = {
  name: AKSClusterName
}

module actiongroup 'Modules/actiongroup.bicep' = {
  name: 'cluedin-action-group-creation'
  params: {
    actionGroupName: actionGroupName
    actionGroupShortName: actionGroupShortName
    emailAddress: emailAddress
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aksCluster
  name: guid(resourceGroup().id, 'cluster-role-assignment')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb') // Monitoring Metrics Publisher
    principalId: omsAgentId
    principalType: 'ServicePrincipal'
  }
}

module container_cpu_alert 'Modules/aksalerts.bicep' = {
  name: 'container-cpu-alert-rule'
  params: {
    alertName: 'Container CPU usage is above 95'
    alertDescription: 'This alert monitors Container CPU usage and triggers when any container usage peaks above 95%'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'cpuThresholdViolated'
          metricNamespace: 'Insights.Container/containers'
          dimensions: [
            {
              name: 'kubernetes namespace'
              operator: 'Include'
              values: [
                'cluedin'
              ]
            }
            {
              name: 'controllerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'containerName'
              operator: 'Exclude'
              values: [
                  'cluedin-processing'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 95
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module container_memory_alert 'Modules/aksalerts.bicep' = {
  name: 'container-memory-alert-rule'
  params: {
    alertName: 'Container memory usage is above 95'
    alertDescription: 'Calculates average working set memory used per container. It triggers When average working set memory usage per container is greater than 95%.'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'memoryWorkingSetThresholdViolated'
          metricNamespace: 'Insights.Container/containers'
          dimensions: [
            {
              name: 'kubernetes namespace'
              operator: 'Include'
              values: [
                'cluedin'
              ]
            }
            {
              name: 'controllerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 95
          timeAggregation: 'average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module node_cpu_alert 'Modules/aksalerts.bicep' = {
  name: 'node-cpu-alert-rule'
  params: {
    alertName: 'Average node CPU utilization is greater than 80'
    alertDescription: 'Calculates average CPU used per node. It triggers alert when average node CPU utilization is greater than 80%'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'cpuUsagePercentage'
          metricNamespace: 'Insights.Container/nodes'
          dimensions: [
            {
              name: 'host'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module node_disk_alert 'Modules/aksalerts.bicep' = {
  name: 'node-disk-usage-alert-rule'
  params: {
    alertName: 'Node disk usage is above 80'
    alertDescription: 'Calculates average disk usage for a node'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'DiskUsedPercentage'
          metricNamespace: 'Insights.Container/nodes'
          dimensions: [
            {
              name: 'host'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'device'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module node_not_ready_alert 'Modules/aksalerts.bicep' = {
  name: 'node-not-ready-alert-rule'
  params: {
    alertName: 'Number of nodes in Notready state'
    alertDescription: 'Calculates if any node is in NotReady state.'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'nodesCount'
          metricNamespace: 'Insights.Container/nodes'
          dimensions: [
            {
              name: 'status'
              operator: 'Include'
              values: [
                'NotReady'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module node_memory_alert 'Modules/aksalerts.bicep' = {
  name: 'node-memory-usage-alert-rule'
  params: {
    alertName: 'Node memory is greater than 80'
    alertDescription: 'Calculates average Working set memory for a node.'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'memoryWorkingSetPercentage'
          metricNamespace: 'Insights.Container/nodes'
          dimensions: [
            {
              name: 'host'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module oom_alert 'Modules/aksalerts.bicep' = {
  name: 'oom-alert-rule'
  params: {
    alertName: 'Pod killed or evicted by OOM'
    alertDescription: 'Calculates number of OOM killed containers'
    clusterResourceId: aksCluster.id
    actionGroupId: actiongroup.outputs.emailActionGroup
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'oomKilledContainerCount'
          metricNamespace: 'Insights.Container/pods'
          dimensions: [
            {
              name: 'kubernetes namespace'
              operator: 'Include'
              values: [
                'cluedin'
              ]
            }
            {
              name: 'controllerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module pod_failed_alert 'Modules/aksalerts.bicep' = {
  name: 'pod-failed-alert-rule'
  params: {
    alertName: 'Pod is in failed state'
    alertDescription: 'This alert monitors pod status and triggers when any of the pod status is in failed/pending'
    actionGroupId: actiongroup.outputs.emailActionGroup
    clusterResourceId: aksCluster.id
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'podCount'
          metricNamespace: 'Insights.Container/pods'
          dimensions: [
            {
              name: 'kubernetes namespace'
              operator: 'Include'
              values: [
                'cluedin'
              ]
            }
            {
              name: 'phase'
              operator: 'Include'
              values: [
                'Failed'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

module pv_usage_alert 'Modules/aksalerts.bicep' = {
  name: 'pv-usage-alert-rule'
  params: {
    alertName: 'Persistent volume usage above 80'
    alertDescription: 'Calculate persistent volume in a cluster'
    actionGroupId: actiongroup.outputs.emailActionGroup
    clusterResourceId: aksCluster.id
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: '1st criterion'
          metricName: 'pvUsageExceededPercentage'
          metricNamespace: 'Insights.Container/persistentvolumes'
          dimensions: [
            {
              name: 'kubernetesNamespace'
              operator: 'Include'
              values: [
                'cluedin'
              ]
            }
            {
              name: 'podName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          skipMetricValidation: true
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}
