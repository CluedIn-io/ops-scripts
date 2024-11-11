[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClusterName
)

Write-Output "[$(Get-Date -Format HH:mm:ss)] Start of runbook"

Write-Output "Logging in to Azure using the Managed Identity assigned to this automation account ..."
az login --identity | Out-Null

Write-Output "Searching for '$ClusterName'"
$resource = az resource list --name $ClusterName | ConvertFrom-Json
if ($resource.count -ne 1) { throw "Problem finding resource. Output:`n$resource" }

$aksCluster = az aks show --resource-group $resource.resourceGroup --name $resource.name | ConvertFrom-Json

switch ($aksCluster.PowerState.Code) {
    'Stopped' {
        Write-Warning "Cluster is in a stopped state. Helm Values cannot be backed up."
        exit 1
    }
    'Running' {
        Write-Output "Getting helm values"
        $command = "helm get values cluedin-platform --namespace cluedin --output yaml"

        $params = @(
            '--resource-group', $aksCluster.resourceGroup
            '--name', $aksCluster.name
            '--command', $command
            '--output', 'json'
        )
        $result = az aks command invoke @params | ConvertFrom-Json
        $values = New-TemporaryFile
        $result.logs | Out-File -FilePath $values.FullName

        Write-Output "Getting storage account connection details"
        $storageAccountName = $ClusterName.replace('aks-', 'storage')
        $saIdParams = @(
            '--name', $storageAccountName
            '--resource-group', $resource.resourceGroup
            '--query', 'id'
            '--output', 'tsv'
        )
        $saId = az storage account show @saIdParams

        $saConnectStringParams = @(
            '--ids', $saId
            '--query', 'connectionString'
            '--output', 'tsv'
        )
        $saConnectionString = az storage account show-connection-string @saConnectStringParams

        Write-Output "Uploading values.yaml to storage account"
        $params = @(
            '--file', $values.FullName
            '--container', 'helm-backups'
            '--name', ('cluedin-values_{0}.yaml' -f (Get-Date -Format yyyyMMdd-HHmmss))
            '--connection-string', $saConnectionString
            '--no-progress'
            '--output', 'none'
        )
        az storage blob upload @params
        if (!$?) { throw "Isuse with uploading values as blob" }
        Write-Output "Upload successful"
    }
    default { Write-Error "Issue determining cluster state '$($aksCluster.PowerState.Code)'" }
}

Write-Output "[$(Get-Date -Format HH:mm:ss)] End of runbook"