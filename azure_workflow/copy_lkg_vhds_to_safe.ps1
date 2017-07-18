#
#  Copies VHDs that have booted as expected to the LKG drop location
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $sourceSA="smokeworkingstorageacct",
    [Parameter(Mandatory=$false)] [string] $sourceRG="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceContainer="vhds-under-test",
    [Parameter(Mandatory=$false)] [string] $sourcePkgContainer="last-build-packages",

    [Parameter(Mandatory=$false)] [string] $destSA="smoketestoutstorageacct",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_output_resource_group",
    [Parameter(Mandatory=$false)] [string] $destContainer="last-known-good-vhds",
    [Parameter(Mandatory=$false)] [string] $destPkgContainer="last-known-good-packages",

    [Parameter(Mandatory=$false)] [string] $location="westus",
    [Parameter(Mandatory=$false)] [switch] $excludePackages=$false,
    [Parameter(Mandatory=$false)] [switch] $excludeVHDs=$false
)

$copyblobs_array=@()
$copyblobs = {$copyblobs_array}.Invoke()

Write-Host "Switch excludePackages is $excludePackages and switch excludeVHDs is $excludeVHDs"

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx' > $null

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4" > $null
Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA > $null

Write-Host "Stopping all running machines..."  -ForegroundColor green
# Get-AzureRmVm -ResourceGroupName $sourceRG | Stop-AzureRmVM -Force > $null


$destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $destRG -Name $destSA
$destContext=New-AzureStorageContext -StorageAccountName $destSA -StorageAccountKey $destKey[0].Value

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceRG -Name $sourceSA
$sourceContext=New-AzureStorageContext -StorageAccountName $sourceSA -StorageAccountKey $sourceKey[0].Value

#
#  Clear the working containers
#
Write-Host "Clearing any existing VHDs"
if ($excludeVHDs -eq $false) {
    Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA > $null
    Get-AzureStorageBlob -Container $destContainer -blob * | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $destContainer}
    if ($? -eq $false) {
        $failure_point="ClearingContainers"
        ErrOut($failure_point)
    }
}


if ($excludePackages -eq $false) {
    Write-Host "Copying the build packages to LKG"
    Get-AzureStorageBlob -Container $destPkgContainer -blob * | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $destPkgContainer}
    if ($? -eq $false) {
        $failure_point="ClearingContainers"
        ErrOut($failure_point)
    }

    #
    #  Now copy the packages
    Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA > $null

    Write-Host "Copying the VHDs to LKG"
    $blobs=get-AzureStorageBlob -Container $sourcePkgContainer -Blob *
    foreach ($oneblob in $blobs) {
        $sourceName=$oneblob.Name
        $targetName = $sourceName

        Write-Host "Initiating job to copy package $targetName from cache to working directory..." -ForegroundColor Yellow
        $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $destPkgContainer -SrcContainer $sourcePkgContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext
        if ($? -eq $true) {
            $copyblobs.Add($targetName)
        } else {
            Write-Host "Job to copy package $targetName failed to start.  Cannot continue"
            exit 1
        }
    }

    sleep 5
    Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow

    $stillCopying = $true
    while ($stillCopying -eq $true) {
        $stillCopying = $false
        $reset_copyblobs = $true

        Write-Host ""
        Write-Host "Checking copy status..."
        while ($reset_copyblobs -eq $true) {
            $reset_copyblobs = $false
            foreach ($blob in $copyblobs) {
                $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $destContainer -ErrorAction SilentlyContinue
                if ($? -eq $false) {
                    Write-Host "        Could not get copy state for job $blob.  Job may not have started." -ForegroundColor Yellow
                    $copyblobs.Remove($blob)
                    $reset_copyblobs = $true
                    break
                } elseif ($status.Status -eq "Pending") {
                    $bytesCopied = $status.BytesCopied
                    $bytesTotal = $status.TotalBytes
                    $pctComplete = ($bytesCopied / $bytesTotal) * 100
                    Write-Host "        Job $blob has copied $bytesCopied of $bytesTotal bytes (%$pctComplete)." -ForegroundColor green
                    $stillCopying = $true
                } else {
                    $exitStatus = $status.Status
                    if ($exitStatus -eq "Completed") {
                        Write-Host "   **** Job $blob has failed with state $exitStatus." -ForegroundColor Red
                    } else {
                        Write-Host "   **** Job $blob has completed successfully." -ForegroundColor Green
                    }
                    $copyblobs.Remove($blob)
                    $reset_copyblobs = $true
                    break
                }
            }
        }

        if ($stillCopying -eq $true) {
            Write-Host ""
            sleep(10)
        } else {
            Write-Host ""
            Write-Host "All copy jobs have completed.  Rock on." -ForegroundColor green
        }
    }

}

if ($excludeVHDs -eq $true) {
    exit 0
}

Write-Host "Launching jobs to copy individual machines..." -ForegroundColor green

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA > $null
$sourceContainer

get-AzureStorageBlob -Container $sourceContainer -Blob "*-BORG.vhd"
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob "*-BORG.vhd"
foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name
    $targetName = $sourceName | % { $_ -replace "-BORG.vhd", "-Booted-and-Verified.vhd" }

    Write-Host "Initiating job to copy VHD $targetName from final build to output cache directory..." -ForegroundColor green
    $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext -Force > $null
    if ($? -eq $true) {
        $copyblobs.Add($targetName)
    } else {
        Write-Host "Job to copy VHD $targetName failed to start.  Cannot continue" -ForegroundColor Red
        exit 1
    }
}

sleep 5
Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA  > $null
$stillCopying = $true
while ($stillCopying -eq $true) {
    $stillCopying = $false
    $reset_copyblobs = $true

    Write-Host ""
    Write-Host "Checking copy status..."
    while ($reset_copyblobs -eq $true) {
        $reset_copyblobs = $false
        foreach ($blob in $copyblobs) {
            $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $destContainer -ErrorAction SilentlyContinue
            if ($? -eq $false) {
                Write-Host "        Could not get copy state for job $blob.  Job may not have started." -ForegroundColor Yellow
                $copyblobs.Remove($blob)
                $reset_copyblobs = $true
                break
            } elseif ($status.Status -eq "Pending") {
                $bytesCopied = $status.BytesCopied
                $bytesTotal = $status.TotalBytes
                $pctComplete = ($bytesCopied / $bytesTotal) * 100
                Write-Host "        Job $blob has copied $bytesCopied of $bytesTotal bytes (%$pctComplete)." -ForegroundColor green
                $stillCopying = $true
            } else {
                $exitStatus = $status.Status
                if ($exitStatus -eq "Completed") {
                    Write-Host "   **** Job $blob has failed with state $exitStatus." -ForegroundColor Red
                } else {
                    Write-Host "   **** Job $blob has completed successfully." -ForegroundColor Green
                }
                $copyblobs.Remove($blob)
                $reset_copyblobs = $true
                break
            }
        }
    }

    if ($stillCopying -eq $true) {
        Write-Host ""
        sleep(10)
    } else {
        Write-Host ""
        Write-Host "All copy jobs have completed.  Rock on." -ForegroundColor green
    }
}

write-host "All done!"
exit 0
