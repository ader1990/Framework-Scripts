#
#  Copies VHDs that have booted as expected to the test location where they will be prepped
#  for Azure automation
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $sourceSA="smokework",
    [Parameter(Mandatory=$false)] [string] $sourceRG="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceContainer="vhds-under-test",

    [Parameter(Mandatory=$false)] [string] $destSA="smokebvt",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_bvts_resource_group",

    [Parameter(Mandatory=$false)] [string] $location="westus",

    [Parameter(Mandatory=$false)] [string] $templateFile="bvt_template.xml",
    [Parameter(Mandatory=$false)] [string] $removeTag="-BORG",
    [Parameter(Mandatory=$false)] [string] $OverwriteVHDs="False",

    [Parameter(Mandatory=$true)] [string] $distro="Smoke-BVT",
    [Parameter(Mandatory=$true)] [string] $testCycle="BVT"
)

. C:\Framework-Scripts\common_functions.ps1
. C:\Framework-Scripts\secrets.ps1

#
#  This is a required location
$removeTag = $removeTag -replace "_","-"
$destContainer="vhds"
$vmFlavor="no-flavor"

$copyblobs_array=@()
$copyblobs = {$copyblobs_array}.Invoke()
$copyblobs.Clear()

if ($OverwriteVHDs -ne "False") {
    $overwriteVHDs = $true
} else {
    $overwriteVHDs = $false
}

write-host "Overwrite flag is $overwriteVHDs"
get-job | Stop-Job
get-job | Remove-Job

set-location C:\azure-linux-automation
git pull

#
#  The last parameter, the switch, says to recreate the storage
#  container if there's an error or if it's in a different
#  region
login_azure $destRG $destSA $location $true

Write-Host "Stopping all running machines..."  -ForegroundColor green
$runningVMs = Get-AzureRmVm -ResourceGroupName $sourceRG
deallocate_machines_in_group $runningVMs $sourceRG $sourceSA $location

Write-Host "Copying the test VMs packages to BVT resource group"
$destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $destRG -Name $destSA
$destContext=New-AzureStorageContext -StorageAccountName $destSA -StorageAccountKey $destKey[0].Value

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceRG -Name $sourceSA
$sourceContext=New-AzureStorageContext -StorageAccountName $sourceSA -StorageAccountKey $sourceKey[0].Value

$blobFilter = '*.vhd'
if ($removeTag -ne "") {
    $blobFilter = '*' + $removeTag
}
Write-Host "Blob filter is $blobFilter"

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA 
$existingBlobs=get-AzureStorageBlob -Container $destContainer 

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA 
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob $blobFilter

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA
$regionSuffix = ("---" + $location+ "-" + $VMFlavor) -replace " ","-"
$regionSuffix = $regionSuffix -replace "_","-"

$fullSuffix = $regionSuffix + "-Booted-and-Verified.vhd"

foreach ($oneblob in $blobs) {
    $fullName=$oneblob.Name
    $bar=$fullName.Replace("---","{")
    $nameParts = $bar.split("{")

    $targetName = $nameParts[0] + $fullSuffix

    $blobIsInDest = $false
    if ($existingBlobs.Name -contains $targetName) {
        $blobIsInDest = $true
    }

    $start_copy = $true
    if (($blobIsInDest -eq $true) -and ($overwriteVHDs -eq $true)) {
        Write-Host "There is an existing blob in the destination and the overwrite flag has been set.  The existing blob will be deleted."
        Remove-AzureStorageBlob -Blob $targetName -Container $destContainer -Force
    } elseif ($blobIsInDest -eq $false) {
        Write-Host "This is a new blob."
    } else {
        Write-Host "There was an existing blob named $targetName, and the overwrite flag was not set.  Blob will not be copied."
        $start_copy = $false
    }    
    
    if ($start_copy -eq $true) {
        Write-Host "Initiating job to copy VHD from $sourceSA/$sourceContainer/$fullName to $destSA/$destContainer/$targetName..." -ForegroundColor Yellow
        $blob = Start-AzureStorageBlobCopy -SrcBlob $fullName -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext
        if ($? -eq $true) {
            $copyblobs.Add($targetName)
        } else {
            Write-Host "Job to copy VHD $targetName failed to start.  Cannot continue"
            exit 1
        }
    }
}

if ($copyblobs.Count -gt 0) {
    Start-Sleep -Seconds 5
    Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow

    Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA
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
                    Write-Host "        Job $blob has copied $bytesCopied of $bytesTotal bytes ($pctComplete %)." -ForegroundColor green
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
            Start-Sleep -Seconds 10
        } else {
            Write-Host ""
            Write-Host "All copy jobs have completed.  Rock on." -ForegroundColor green
        }
    }
}

# Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA 
# $blobs=get-AzureStorageBlob -Container $destContainer
Set-Location C:\azure-linux-automation
$launched_machines = 0

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA 
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob $blobFilter

$regionSuffix = ("---" + $location + "-" + $VMFlavor) -replace " ","-"
$regionSuffix = $regionSuffix -replace "_","-"

$fullSuffix = $regionSuffix + "-Booted-and-Verified.vhd"

foreach ($oneblob in $blobs) {
    $fullName=$oneblob.Name
    
    if ($fullName -like "*$removeTag") {
        $bar=$fullName.Replace("---","{")
        $nameParts = $bar.split("{")
        $targetName = $nameParts[0] + $fullSuffix
        
        $configFileName="c:\temp\bvt_configs\bvt_exec_" + $targetName + ".xml"
        $jobName=$targetName + "_BVT_Runner"

        (Get-Content .\$templateFile).Replace("SMOKE_MACHINE_NAME_HERE",$targetName) | out-file $configFileName -Force
        (Get-Content $configFileName).Replace("STORAGE_ACCOUNT_NAME_HERE",$destSA) | out-file $configFileName -Force
        (Get-Content $configFileName).Replace("LOCATION_HERE",$location) | out-file $configFileName -Force

        #
        # Launch the automation
        write-host "Args are: $sourceName, $configFileName, $distro, $testCycle"
        Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\run_single_bvt.ps1 -sourceName $args[0] -configFileName $args[1] -distro $args[2] -testCycle $args[3]  } `
                                                -ArgumentList @($fullName),@($configFileName),@($distro),@($testCycle)
        if ($? -ne $true) {
            Write-Host "Error launching job $jobName for source $targetName.  BVT will not be run." -ForegroundColor Red
        } else {
            $launched_machines += 1
            $launchTime=date
            Write-Host "Job $jobName launched machine $targetName as BVT $launched_machines at $launchTime" -ForegroundColor Green
        }
    }
}

#
#  Wait for completion...
$sleep_count=0
while ($completed_machines -lt $launched_machines) {

    $completed_machines = 0
    $failed_machines = 0
    $running_machines = 0
    $other_machines = 0

    $logThisOne=$false
    if ($sleep_count % 6 -eq 0) {
        $updateTime=date
        write-host "Update as of $updateTime.  There were $launched_machines started..."
        $logThisOne=$true
    }
    
    foreach ($oneblob in $blobs) {
        $fullName=$oneblob.Name
        
        if ($fullName -like "*$removeTag") {
            $bar=$fullName.Replace("---","{")
            $nameParts = $bar.split("{")
            $targetName = $nameParts[0] + $fullSuffix
            
            $configFileName="c:\temp\bvt_configs\bvt_exec_" + $targetName + ".xml"
            $jobName=$targetName + "_BVT_Runner"

            
            $jobStatus=get-job -Name $jobName
            if ($? -eq $true) {
                $jobState = $jobStatus.State
                if ($jobState -eq "Failed")
                {
                    $completed_machines += 1
                    $failed_machines += 1
                    Write-Host " >>>> BVT job $jobName exited with FAILED state!" -ForegroundColor red
                }
                elseif ($jobState -eq "Completed")
                {
                    $completed_machines += 1
                    Write-Host "***** BVT job $jobName completed successfully." -ForegroundColor green
                }
                elseif ($jobState -eq "Running")
                {
                    $running_machines += 1
                    if ($logThisOne -eq $true) {
                        Write-Host "      BVT job $jobName is still in progress." -ForegroundColor green                
                    }
                }
                else
                {
                    $other_machines += 1
                    Write-Host "????? BVT job $jobName is in state $jobState." -ForegroundColor Yellow
                }
            }
        }
        
    }

    if ($logThisOne -eq $true) {
       write-host "$launched_machines BVT jobs were launched.  Of those: completed = $completed_machines, Running = $running_machines, Failed = $failed_machines, and unknown = $other_machines" -ForegroundColor green
    }

    $sleep_count += 1
    if ($completed_machines -lt $launched_machines) {
        Start-Sleep -Seconds 10
    } else {
        Write-Host "ALL BVTs have completed.  Checking results..."

        if ($failed_machines -gt 0) {
            Write-Host "There were $failed_machines failures out of $launched_machines attempts.  BVTs have failed." -ForegroundColor Red
            c:\framework-Scripts\clear_smoke_bvt_resource_groups
            exit 1
        } elseif ($completed_machines -eq $launched_machines) {
            Write-Host "All BVTs have passed! " -ForegroundColor Green
            c:\framework-Scripts\clear_smoke_bvt_resource_groups
            exit 0
        } else {
            write-host "$launched_machines BVT jobs were launched.  Of those: completed = $completed_machines, Running = $running_machines, Failed = $failed_machines, and unknown = $other_machines" -ForegroundColor Red
            c:\framework-Scripts\clear_smoke_bvt_resource_groups
            exit 1
        }
    }
}
