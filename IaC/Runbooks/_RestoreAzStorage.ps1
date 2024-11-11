[CmdletBinding()]
param (
    [string]$sourceFolderName ,
    [string]$sourceResourceGroupName ,
    [string]$targetResourceGroupName ,
    [string]$targetRegion ,
    [string]$newStorageAccountName  ,
    [string]$sourceStorageAccountName ,
    [string]$sourceContainerName ,
    [string]$restoreResourceGroupName ,
    [bool]$Preview = $false,
    [string]$AKSResourceGroup  ,
    [string]$AKSClusterName 
)

$destinationContainer = "restore-$sourceFolderName"
$aks = Get-AzAKSCluster -ResourceGroupName $AKSResourceGroup -Name $AKSClusterName

# Generate a SAS token for the source container
try {
    $sourceStorageAccount = Get-AzStorageAccount -ResourceGroupName $sourceResourceGroupName -Name $sourceStorageAccountName -ErrorAction Stop
    $sourceContext = $sourceStorageAccount.Context
    $expiryTime = (Get-Date).AddHours(2) # SAS token valid for 2 hours

    $sasToken = New-AzStorageContainerSASToken -Name $sourceContainerName -Context $sourceContext -Permission r -ExpiryTime $expiryTime -FullUri
    Write-Output "Source SAS token generated successfully."
} catch {
    Write-Error "Failed to retrieve source storage account or generate SAS token. Ensure the storage account '$sourceStorageAccountName' exists in resource group '$sourceResourceGroupName'."
    exit
}

# Check if the storage account already exists
$newStorageAccount = Get-AzStorageAccount -ResourceGroupName $targetResourceGroupName -Name $newStorageAccountName -ErrorAction SilentlyContinue

if ($null -eq $newStorageAccount) {
    try {
        New-AzStorageAccount -ResourceGroupName $targetResourceGroupName -Name $newStorageAccountName -Location $targetRegion -SkuName Standard_LRS -ErrorAction Stop

        do {
            $newStorageAccount = Get-AzStorageAccount -ResourceGroupName $targetResourceGroupName -Name $newStorageAccountName
            Start-Sleep -Seconds 10
        } while ($newStorageAccount.ProvisioningState -ne "Succeeded")
    } catch {
        Write-Error "Failed to create or retrieve the new storage account in resource group '$targetResourceGroupName'."
        exit
    }
}

$newStorageContext = $newStorageAccount.Context

try {
    New-AzStorageContainer -Name $destinationContainer -Context $newStorageContext -Permission Off -ErrorAction Stop
} catch {
    Write-Warning "Failed to create container '$destinationContainer'. It may already exist."
}

$blobs = Get-AzStorageBlob -Container $sourceContainerName -Context $sourceContext | Where-Object { $_.Name -like "$sourceFolderName/*" }
if ($blobs.Count -eq 0) {
    Write-Error "No blobs found in the source folder '$sourceFolderName'. Aborting operation."
    exit
}

# Get existing disks in the restore resource group
$existingDisks = Get-AzDisk -ResourceGroupName $restoreResourceGroupName

# Collect preview information
$previewInfo = @()
$diskPreviewInfo = @()
$blobCopyOperations = @()

foreach ($blob in $blobs) {
    $sourceBlobUri = $sourceStorageAccount.PrimaryEndpoints.Blob + "$sourceContainerName/$($blob.Name)" + "?" + $sasToken.Substring($sasToken.IndexOf('?') + 1)
    $destinationBlobName = $blob.Name

    if ($Preview) {
        $previewInfo += [pscustomobject]@{
            SourceBlobName      = $blob.Name
            DestinationBlobName = $destinationBlobName
            DestinationContainer = $destinationContainer
        }
    } else {
        try {
            $blobCopy = Start-AzStorageBlobCopy -SrcUri $sourceBlobUri -DestContainer $destinationContainer -DestBlob $destinationBlobName -DestContext $newStorageContext
            $blobCopyOperations += $blobCopy
            Write-Output "Started copy of $($blob.Name) to $destinationContainer."
        } catch {
            Write-Error "Failed to start blob copy operation for $($blob.Name). Error details: $_"
            exit
        }
    }
}

if (-not $Preview) {
    do {
        $copyStates = $blobCopyOperations | ForEach-Object {
            Get-AzStorageBlobCopyState -Blob $_.Name -Container $destinationContainer -Context $newStorageContext
        }
        $pendingCopies = $copyStates | Where-Object { $_.Status -eq "Pending" }
        Write-Output "Pending Copies: $($pendingCopies.Count)"
        Start-Sleep -Seconds 10
    } while ($pendingCopies.Count -gt 0)

    Write-Output "All blobs have been successfully copied to the target container '$destinationContainer'."

    # Check the status of all copied files
    $copyStatusCheck = $copyStates | ForEach-Object {
        if ($_.Status -ne "Success") {
            Write-Error "Blob copy failed for $_.Name."
            exit
        }
    }

    Write-Output "Scaling down deployments..."
    Invoke-AzAksRunCommand -ResourceGroupName $aks.ResourceGroupName -Name $aks.Name -Command "kubectl scale deploy -n cluedin --replicas=0 --all" -f
    Start-Sleep 60
    Write-Output "Scaling down stateful sets..."
    Invoke-AzAksRunCommand -ResourceGroupName $aks.ResourceGroupName -Name $aks.Name -Command "kubectl scale statefulset -n cluedin --replicas=0 --all" -f
    Start-Sleep 210
}

# Restore each file to an Azure disk or print the restore details
foreach ($blob in $blobs) {
    $blobName = [System.IO.Path]::GetFileNameWithoutExtension($blob.Name)
    $blobNamePrefix = $blobName -split '-full' | Select-Object -First 1
    $matchingDisk = $existingDisks | Where-Object { $_.Tags.'kubernetes.io-created-for-pvc-name' -like "$blobNamePrefix*" }

    if ($null -eq $matchingDisk) {
        Write-Error "No matching disk found for blob $blobNamePrefix based on 'kubernetes.io-created-for-pvc-name' tag."
        continue
    }

    $diskName = $matchingDisk.Tags.'kubernetes.io-created-for-pv-name'
    $blobUri = $newStorageAccount.PrimaryEndpoints.Blob + "$destinationContainer/$($blob.Name)"
    $storageAccountId = $newStorageAccount.Id

    if ($Preview) {
        $diskPreviewInfo += [pscustomobject]@{
            BlobName        = $blobName
            DiskName        = $diskName
            ResourceGroup   = $restoreResourceGroupName
            DiskTags        = $matchingDisk.Tags
        }
    } else {
        # Check if disk exists and delete it, retaining its tags
        try {
            $existingDisk = Get-AzDisk -ResourceGroupName $restoreResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue
            if ($null -ne $existingDisk) {
                $diskTags = $existingDisk.Tags
                Remove-AzDisk -ResourceGroupName $restoreResourceGroupName -DiskName $diskName -Force
                do {
                    $existingDisk = Get-AzDisk -ResourceGroupName $restoreResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 10
                } while ($null -ne $existingDisk)
                Write-Output "Existing disk $diskName has been successfully deleted."
            }
        } catch {
            Write-Error "Failed to delete existing disk $diskName. Error details: $_"
            exit
        }

        # Create new disk with retained tags and new tag
        $diskConfig = New-AzDiskConfig -AccountType Standard_LRS -Location $targetRegion -CreateOption Import -SourceUri $blobUri -StorageAccountId $storageAccountId
        if ($diskTags) {
            $diskTags['cluedin'] = 'restored'
            $diskConfig.Tags = $diskTags
        } else {
            $diskConfig.Tags = @{ 'cluedin' = 'restored' }
        }

        try {
            New-AzDisk -ResourceGroupName $restoreResourceGroupName -DiskName $diskName -Disk $diskConfig
            Write-Output "Disk $diskName has been successfully created in resource group $restoreResourceGroupName."
        } catch {
            Write-Error "Failed to create disk $diskName. Error details: $_"
        }
    }
}

if ($Preview) {
    Write-Output "Blob Copy Preview:"
    $previewInfo | Format-Table -AutoSize
    
    Write-Output "Disk Restoration Preview:"
    $diskPreviewInfo | Format-Table -AutoSize
}

