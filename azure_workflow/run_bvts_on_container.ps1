#
#  Copies VHDs that have booted as expected to the test location where they will be prepped
#  for Azure automation
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $sourceSA="smokeworkingresourcegroup",
    [Parameter(Mandatory=$false)] [string] $sourceRG="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceContainer="vhds_under_test",

    [Parameter(Mandatory=$false)] [string] $destSA="smokebvtstorageaccount",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_bvts_resource_group",

    [Parameter(Mandatory=$false)] [string] $location="westus",

    [Parameter(Mandatory=$false)] [string] $removeTag="-BORG",
    [Parameter(Mandatory=$false)] [switch] $overwriteVHDs=$true,
    [Parameter(Mandatory=$false)] [switch] $deprovisionBeforeRunning=$true
)



#
#  This is a required location
$destContainer="vhds"

$copyblobs_array=@()
$copyblobs = {$copyblobs_array}.Invoke()

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx' > $null

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4" > $null
Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA > $null

Write-Host "Stopping all running machines..."  -ForegroundColor green
Get-AzureRmVm -ResourceGroupName $sourceRG | Stop-AzureRmVM -Force > $null

Write-Host "Copying the test VMs packages to BVT resource group"
$destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $destRG -Name $destSA
$destContext=New-AzureStorageContext -StorageAccountName $destSA -StorageAccountKey $destKey[0].Value

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceRG -Name $sourceSA
$sourceContext=New-AzureStorageContext -StorageAccountName $sourceSA -StorageAccountKey $sourceKey[0].Value

$blobFilter = '*.vhd'
if (removeTag -ne "") {
    $blobFilter = '*' + $removeTag + '*.vhd'
}

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA > $null
$existingBlobs=get-AzureStorageBlob -Container $destContainer -Blob $blobFilter 

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA > $null
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob $blobFilter

foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name

    $targetName = $sourceName
    if ($removeTag -ne "") {
        $targetName = $sourceName | % { $_ -replace $blobFilter, ".vhd" }
    }

    $start_copy = $true
    if (($existingBlobs.Name -contains $targetName) -and ($overwriteVHDs -eq $true)) {
        Write-Host "There is an existing blob in the destination and the overwrite flag has been set.  The existing blob will be deleted."
        Remove-AzureStorageBlob -Blob $targetName -Container $destContainer
        $need_provisioning = $true
    } else if (($existingBlobs.Name -contains $targetName) -eq $true) {
        Write-Host "This is a new blob."
        $need_provisioning = $true
    } else {
        Write-Host "There was an existing blob named $targetName, and the overwrite flag was not set.  Blob will not be copied."
        $start_copy = $false
    }    
    
    if ($start_copy -eq $true) {
        Write-Host "Initiating job to copy VHD $targetName from LKG to BVT directory..." -ForegroundColor Yellow
        $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext
        if ($? -eq $true) {
            $copyblobs.Add($targetName)
        } else {
            Write-Host "Job to copy VHD $targetName failed to start.  Cannot continue"
            exit 1
        }
    }
}

[array]::copy($copyblobs, $safe_copyblobs)

if ($copyblobs.Count -gt 0) {
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
}

#
#  Session stuff
#
$o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$pw = convertto-securestring -AsPlainText -force -string 'P@ssW0rd-'
$cred = new-object -typename system.management.automation.pscredential -argumentlist "mstest",$global:pw

$blobs=get-AzureStorageBlob -Container $destContainer -Blob $blobFilter
foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name

    #
    #  If we need to deprovision the machine, use PSRP and do so...
    if ($deprovisionBeforeRunning -eq $true) {

        c:\Framework-Scripts\launch_single_azure_vm.ps1 -vmName $sourceName -resourceGroup $destRG -storageAccount $destSA -containerName vhds

        $ip=Get-AzureRmPublicIpAddress -ResourceGroupName $destRG -Name $sourceName

        $session = $null
        while ($session -eq $null) {
            $session=new-PSSession -computername $ip.IpAddress -credential $cred -authentication Basic -UseSSL -Port 443 -SessionOption $o -ErrorAction SilentlyContinue
            if ($? -eq $false) {
                sleep 10
                $session = $null
            } else {
                break
            }
        }

        invoke-command -session $localSession -ScriptBlock {waagent --deprovision -y; shutdown }
    }

    #
    #  Launch the automation
    .\AzureAutomationManager.ps1 -xmlConfigFile .\Azure_ICA_ALL_jwf.xml -runtests -email –Distro JWF -cycleName BVT -UseAzureResourceManager -EconomyMode
}       

#
#  Run through the list again and launch the Jenkins jobs
