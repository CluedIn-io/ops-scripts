[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClusterName,
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$State
)

Write-Output "[$(Get-Date -Format HH:mm:ss)] Start of runbook"

Write-Output "Logging in to Azure using the Managed Identity assigned to this automation account ..."
az login --identity | Out-Null

Write-Output "Searching for '$ClusterName'"
$resource = az resource list --name $ClusterName | ConvertFrom-Json
if ($resource.count -ne 1) { throw "Problem finding resource. Output:`n$resource" }

$aksCluster = az aks show --resource-group $resource.resourceGroup --name $resource.name | ConvertFrom-Json

Write-Output "Searching activity log"
$logs = az monitor activity-log list --resource-id $aksCluster.id --offset 1h | ConvertFrom-Json

Write-Output "Current PowerState: $($aksCluster.PowerState.Code)"
if (!($logs.operationName.localizedValue -match "^(?:start|stop) managed cluster$")) {
    switch ($aksCluster.PowerState.Code) {
        'Stopped' {
            if ($State -eq 'Stop') { Write-Warning "Host is already stopped" }
            else {
                Write-Output "Starting Cluster"
                az aks start --name $aksCluster.Name --resource-group $aksCluster.resourceGroup --output 'none'
                Start-Sleep 30 # Above command waits for it to start already
                Write-Output "Scaling up stateful sets..."
                az aks command invoke --resource-group $aksCluster.resourceGroup --name $aksCluster.Name --command "kubectl scale statefulset -n cluedin --replicas=1 --all --timeout 5m"
                Write-Output "Scaling up deployments..."
                az aks command invoke --resource-group $aksCluster.resourceGroup --name $aksCluster.Name --command "kubectl scale deploy -n cluedin --replicas=1 --all --timeout 5m"
                Write-Output "Cluster now started"
            }
        }
        'Running' {
            if ($State -eq 'Start') { Write-Warning "Host is already running" }
            else {
                Write-Output "Scaling down deployments..."
                az aks command invoke --resource-group $aksCluster.resourceGroup --name $aksCluster.Name --command "kubectl scale deploy -n cluedin --replicas=0 --all --timeout 5m"
                Write-Output "Scaling down stateful sets..."
                az aks command invoke --resource-group $aksCluster.resourceGroup --name $aksCluster.Name --command "kubectl scale statefulset -n cluedin --replicas=0 --all --timeout 5m"
                Start-Sleep 30 # Grace period, but above already waits
                Write-Output "Stopping Cluster"
                az aks stop --name $aksCluster.Name --resource-group $aksCluster.resourceGroup --output 'none'
            }
        }
        default { Write-Error "Cluster state could not be determined" }
    }
}
else { Write-Output "Cluster is in cooldown or warm up. Please review resource activity log no action taken" }

Write-Output "[$(Get-Date -Format HH:mm:ss)] End of runbook"