#
#  Copies user VHDs it finds for VMs in the reference resource group into the 'clean-vhds' 
#  storage container.  The target blobs will have the name of the VM, as a .vhd
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $sourceSA="smokevhds",
    [Parameter(Mandatory=$false)] [string] $sourceRG="smoke_source_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceContainer="vhds",

    [Parameter(Mandatory=$false)] [string] $destSA="smokesourcestorageacct",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_source_resource_group",

    [Parameter(Mandatory=$false)] [string] $destContainer="clean-vhds",
    [Parameter(Mandatory=$false)] [string] $location="westus"
)

$copyblobs_array=@()
$copyblobs = {$copyblobs_array}.Invoke()

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA

Write-Host "Stopping all running machines..."  -ForegroundColor green
Get-AzureRmVm -ResourceGroupName $sourceRG | Stop-AzureRmVM -Force

Write-Host "Launching jobs to copy individual machines..." -ForegroundColor Yellow

$destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $destRG -Name $destSA
$destContext=New-AzureStorageContext -StorageAccountName $destSA -StorageAccountKey $destKey[0].Value

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceRG -Name $sourceSA
$sourceContext=New-AzureStorageContext -StorageAccountName $sourceSA -StorageAccountKey $sourceKey[0].Value

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob "*-Smoke-1*.vhd"
foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name
    $targetName = $sourceName | % { $_ -replace "Smoke-1.*.vhd", "Smoke-1.vhd" }

    Write-Host "Initiating job to copy VHD $targetName from cache to working directory..." -ForegroundColor Yellow
    $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext
    if ($? -eq $true) {
        $copyblobs.Add($targetName)
    } else {
        Write-Host "Job to copy VHD $targetName failed to start.  Cannot continue"
        exit 1
    }
}

sleep 5
Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA
$stillCopying = $true
while ($stillCopying -eq $true) {
    $stillCopying = $false
    $reset_copyblobs = $true

    write-host "Checking blob copy status..." -ForegroundColor yellow
    while ($reset_copyblobs -eq $true) {
        $reset_copyblobs = $false
        foreach ($blob in $copyblobs) {
            $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $destContainer -ErrorAction SilentlyContinue
            if ($? -eq $false) {
                Write-Host "  ***** Could not get copy state for job $blob.  Job may not have started." -ForegroundColor red
                $copyblobs.Remove($blob)
                $reset_copyblobs = $true
                break
            } elseif ($status.Status -eq "Pending") {
                $bytesCopied = $status.BytesCopied
                $bytesTotal = $status.TotalBytes
                $pctComplete = ($bytesCopied / $bytesTotal) * 100
                Write-Host "   --- Job $blob has copied $bytesCopied of $bytesTotal bytes ($pctComplete % complete)." -ForegroundColor yellow
                $stillCopying = $true
            } else {
                $exitStatus = $status.Status
                if ($exitStatus -eq "Success") {
                    Write-Host "   ***** Job $blob has completed with state $exitStatus." -ForegroundColor green
                } else {
                    Write-Host "   ***** Job $blob has failed with state $exitStatus." -ForegroundColor Red
                }
                $copyblobs.Remove($blob)
                $reset_copyblobs = $true
                break
            }
        }
    }

    if ($stillCopying -eq $true) {
        sleep(10)
    } else {
        Write-Host "All copy jobs have completed.  Rock on." -ForegroundColor Green
    }
}

exit 0
