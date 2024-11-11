[CmdletBinding()]
param(
[string]$snapshotResourceGroupName ,
[string]$storageResourceGroupName ,
[string]$storageAccountName ,
[string]$containerName ,
[Int16]$expiryInHours = 1, # Set the expiry time for the SAS token
[Int16]$maxRetries = 5,
[Int16]$retryDelaySeconds = 15,
[bool]$deleteAfterCopy = $true # Set this flag to $true to delete the snapshot after a successful copy
)
$currentDateFolder = (Get-Date).ToString("yyyy-MM-dd"),
# Ensure the container exists in the storage account resource group
$storageAccount = Get-AzStorageAccount -ResourceGroupName $storageResourceGroupName -Name $storageAccountName
$ctx = $storageAccount.Context
$container = Get-AzStorageContainer -Name $containerName -Context $ctx
if (-not $container) {
    New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off
}

# Function to update network access policy for the snapshot
function Update-NetworkAccessPolicyForSnapshot {
    param (
        [string]$snapshotName
    )

    $snapshot = Get-AzSnapshot -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName
    $originalNetworkAccessPolicy = $snapshot.NetworkAccessPolicy
    $originalPublicNetworkAccess = $snapshot.PublicNetworkAccess

    $snapshot.NetworkAccessPolicy = "AllowAll"
    $snapshot.PublicNetworkAccess = "Enabled"
    $snapshot = Update-AzSnapshot -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshot
    
    return @{ NetworkAccessPolicy = $originalNetworkAccessPolicy; PublicNetworkAccess = $originalPublicNetworkAccess }
}

# Function to reset network access policy for the snapshot
function Reset-NetworkAccessPolicyForSnapshot {
    param (
        [string]$snapshotName,
        [hashtable]$originalPolicy
    )

    $snapshot = Get-AzSnapshot -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName
    $snapshot.NetworkAccessPolicy = $originalPolicy.NetworkAccessPolicy
    $snapshot.PublicNetworkAccess = $originalPolicy.PublicNetworkAccess
    $snapshot = Update-AzSnapshot -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshot
}

# Function to verify the blob copy operation using Get-AzStorageBlobCopyState
function Verify-BlobCopy {
    param (
        [string]$blobName,
        [string]$containerName,
        [object]$ctx,
        [int]$retryDelay
    )

    while ($true) {
        try {
            $copyStatus = Get-AzStorageBlobCopyState -Container $containerName -Blob $blobName -Context $ctx

            if ($copyStatus.Status -eq "Success") {
                Write-Output "Blob copy completed successfully for $blobName."
                return $true
            } elseif ($copyStatus.Status -eq "Failed") {
                throw "Blob copy failed for $blobName."
            }
            
            Write-Host "Copy status for $blobName : $copyStatus.Status. Checking again in $retryDelay seconds."
            Start-Sleep -Seconds $retryDelay
        }
        catch {
            Write-Host "Failed to verify blob copy for $blobName. Retrying in $retryDelay seconds."
            Start-Sleep -Seconds $retryDelay
        }
    }
}

# Loop through all snapshots and handle backup process
$snapshots = Get-AzSnapshot -ResourceGroupName $snapshotResourceGroupName | Where-Object { $_.Name -like "*-full-snapshot-*" }

foreach ($snapshot in $snapshots) {
    $snapshotName = $snapshot.Name
    $success = $false
    $attempts = 0

    while (-not $success -and $attempts -lt $maxRetries) {
        try {
            # Update network access policy for the snapshot
            $originalPolicy = Update-NetworkAccessPolicyForSnapshot -snapshotName $snapshotName

            # Generate a SAS token for the snapshot
            $expiryDate = (Get-Date).AddHours($expiryInHours)
            $sasToken = Grant-AzSnapshotAccess -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName -DurationInSecond ($expiryInHours * 3600) -Access Read
            $snapshotSasUri = [Uri]::EscapeUriString($sasToken.AccessSAS)
            Write-Host "SAS Token: $($sasToken.AccessSAS)"

            # Construct the snapshot URL using the proper URI format
            $snapshotUrl = $sasToken.AccessSAS

            # Copy the snapshot to the storage account with current date folder
            $destBlobName = "$currentDateFolder/$snapshotName.vhd"
            Start-AzStorageBlobCopy -AbsoluteUri $snapshotUrl -DestContainer $containerName -DestBlob $destBlobName -DestContext $ctx

            # Verify the blob copy operation
            $copySuccess = Verify-BlobCopy -blobName $destBlobName -containerName $containerName -ctx $ctx -retryDelay $retryDelaySeconds
            if ($copySuccess) {
                Write-Output "Backup for snapshot $snapshotName completed successfully!"
                
                # Revoke the SAS token
                Revoke-AzSnapshotAccess -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName

                # Reset network access policy for the snapshot
                Reset-NetworkAccessPolicyForSnapshot -snapshotName $snapshotName -originalPolicy $originalPolicy
                
                # Delete the snapshot if the flag is set
                if ($deleteAfterCopy) {
                    Remove-AzSnapshot -ResourceGroupName $snapshotResourceGroupName -SnapshotName $snapshotName -Force
                    Write-Output "Snapshot $snapshotName has been deleted."
                }

                $success = $true
            } else {
                throw "Blob copy verification failed for $snapshotName."
            }
        }
        catch {
            Write-Host "Error occurred while processing snapshot $snapshotName : $_"
            $attempts++
            if ($attempts -lt $maxRetries) {
                Write-Host "Retrying in $retryDelaySeconds seconds..."
                Start-Sleep -Seconds $retryDelaySeconds
            } else {
                Write-Host "Max retry attempts reached for snapshot $snapshotName. Skipping to the next snapshot."
            }
        }
    }
}

Write-Output "All snapshot restoration and backup operations have been completed successfully."
