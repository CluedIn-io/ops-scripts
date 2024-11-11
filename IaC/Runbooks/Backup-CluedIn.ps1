[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClusterName,
    [ValidateSet('Incremental', 'Full')][string]$SnapshotType = 'Incremental',
    [string]$BackupResourceGroup,
    [string]$RetentionCount = 7
)

$isIncremental = $SnapshotType -eq 'Incremental'

Write-Output "[$(Get-Date -Format HH:mm:ss)] Start of runbook"

Write-Output "Logging in to Azure using the Managed Identity assigned to this automation account ..."
az login --identity | Out-Null

Write-Output "Searching for '$ClusterName'"
$resource = az resource list --name $ClusterName | ConvertFrom-Json
if ($resource.count -ne 1) { throw "Problem finding resource. Output:`n$resource" }

$aksCluster = az aks show --resource-group $resource.resourceGroup --name $resource.name | ConvertFrom-Json

$isPoweredDown = $aksCluster.PowerState.Code -eq 'Stopped'

$aksParams = @(
    '--resource-group', $aksCluster.resourceGroup
    '--name', $aksCluster.Name
    '--output', 'none'
)

if (!$isPoweredDown) {
    Write-Output "Scaling down stateful sets..."
    az aks command invoke --command "kubectl scale statefulset --namespace cluedin --replicas=0 --all --timeout 5m" @aksParams
    if (!$?) { Write-Error "Potential issue with scale down of stateful sets"; $errored = $true }

    Write-Output "Scaling down deployments..."
    az aks command invoke --command "kubectl scale deploy --namespace cluedin --replicas=0 --all --timeout 5m" @aksParams
    if (!$?) { Write-Error "Potential issue with scale down of deployments"; $errored = $true }
}

Write-Output "Getting AKS disks from AKS cluster"
$disks = az disk list --resource-group $aksCluster.nodeResourceGroup | ConvertFrom-Json
if (!$disks) { throw "Issue obtaining disks" }

# coalescence doesn't work here for automation runbooks as it's not passing a absolute null
$BackupResourceGroup = (!($BackupResourceGroup)) ? $aksCluster.resourceGroup : $BackupResourceGroup

Write-Output "Ensuring '$BackupResourceGroup' exists"
az group show --name $BackupResourceGroup --output none 2>$null
if (!$?) { throw "Issue with backup location" }

# Do we need to check if there's a region difference in resource groups????
# YES - we do

Write-Output "Processing $($disks.count) disks"
$diskTag = 'kubernetes.io-created-for-pvc-name'
foreach ($disk in $disks) {
    $pvcTag = $disk.tags.$diskTag ?? 'unknown'

    $tagNames = ($disk.tags | Get-Member -MemberType NoteProperty).name
    $tags = foreach ($tag in $tagNames) { '{0}={1}' -f $tag, $disk.tags.$tag }

    Write-Output "Processing disk '$pvcTag ($($disk.name))'"
    $snapshotName = '{0}-{1}-snapshot-{2}' -f $pvcTag, $SnapshotType.ToLower(), $(Get-Date -Format 'ddMyyHHmm')

    $params = @(
        '--resource-group', $BackupResourceGroup
        '--name', $snapshotName
        '--source', $disk.id
        '--tags', $tags
        '--output', 'none'
    )
    if ($isIncremental) { $params += '--incremental' }

    az snapshot create @params
    if (!$?) { Write-Error "Issue taking snapshot of '$snapshotName'"; $errored = $true }
}

if ($isIncremental) {
    Write-Output "Checking snapshot retentions"
    foreach ($disk in $disks) {
        $pvcTag = $disk.tags.$diskTag ?? 'unknown'

        $params = @(
            '--resource-group', $BackupResourceGroup
            '--query', "[?starts_with(name, '$pvcTag') && incremental]"
        )
        $incrementalSnapshotDisks = (az snapshot list @params | ConvertFrom-Json) | Sort-Object -Property TimeCreated -Descending

        <#
            The way incremental snapshots work is by merging into the next available one when being cleaned up.
            This means that during a cleanup period, the restoring of the disk is still possible!

            ref: https://learn.microsoft.com/en-us/azure/virtual-machines/faq-for-disks?tabs=azure-portal#what-happens-if-i-have-multiple-incremental-snapshots-and-delete-one-of-them-
        #>
        if ($incrementalSnapshotDisks.Count -gt $retentionCount) {
            $snapshotsToDelete = $incrementalSnapshotDisks[$retentionCount..($incrementalSnapshotDisks.Count - 1)]
            foreach ($snapshot in $snapshotsToDelete) {
                Write-Output "Deleting incremental snapshot '$($snapshot.Name)'"
                az snapshot delete --ids $snapshot.id --output 'none'
                if (!$?) { Write-Error "Issue deleting snapshot '$($snapshot.Name)'"; $errored = $true }
            }
        }
    }
}

if (!$isPoweredDown) {
    Write-Output "Scaling up stateful sets..."
    az aks command invoke --command "kubectl scale statefulset --namespace cluedin --replicas=1 --all --timeout 5m" @aksParams
    if (!$?) { Write-Error "Potential issue with scale down of stateful sets"; $errored = $true }

    Write-Output "Scaling up deployments..."
    az aks command invoke --command "kubectl scale deploy --namespace cluedin --replicas=1 --all --timeout 5m" @aksParams
    if (!$?) { Write-Error "Potential issue with scale down of deployments"; $errored = $true }
}

Write-Output "[$(Get-Date -Format HH:mm:ss)] End of runbook"
if ($errored) { $LASTEXITCODE = 1 }