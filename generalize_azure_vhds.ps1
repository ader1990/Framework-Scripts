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

    [Parameter(Mandatory=$false)] [string] $destSA="smokework",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $destContainer="generalized-images",


    [Parameter(Mandatory=$false)] [string] $requestedNames,
    [Parameter(Mandatory=$false)] [string] $generalizeAll,

    [Parameter(Mandatory=$false)] [string] $location,

    [Parameter(Mandatory=$false)] [string] $suffix="-Runonce-Primed.vhd"
)

$sourceSA = $sourceSA.Trim()
$sourceRG = $sourceRG.Trim()
$sourceContainer = $sourceContainer.Trim()
$destSA = $destSA.Trim()
$destRG = $destRG.Trim()
$destContainer = $destContainer.Trim()
$suffix = $suffix.Trim()

$suffix = $suffix -replace "_","-"

. C:\Framework-Scripts\common_functions.ps1
. C:\Framework-Scripts\secrets.ps1

[System.Collections.ArrayList]$vmNames_array
$vmNameArray = {$vmNames_array}.Invoke()
$vmNameArray.Clear()
if ($requestedNames -ne "Unset" -and $requestedNames -like "*,*") {
    $vmNameArray = $requestedNames.Split(',')
} else {
    $vmNameArray = $requestedNames.Split(' ')
}

[System.Collections.ArrayList]$base_names_array
$machineBaseNames = {$base_names_array}.Invoke()
$machineBaseNames.Clear()

[System.Collections.ArrayList]$full_names_array
$machineFullNames = {$full_names_array}.Invoke()
$machineFullNames.Clear()

login_azure $sourceRG $sourceSA $location

$vmName = $vmNameArray[0]
if ($generalizeAll -eq $false -and ($vmNameArray.Count -eq 1  -and $vmName -eq "Unset")) {
    Write-Host "Must specify either a list of VMs in RequestedNames, or use generalizeAll.  Unable to process this request."
    Stop-Transcript
    exit 1
} else {
    $requestedNames = ""
    $runningVMs = Get-AzureRmVm -ResourceGroupName $sourceRG

    if ($generalizeAll -eq "True") {
        Write-Host "Generalizing all running machines..."
        foreach ($vm in $runningVMs) {
            $vm_name=$vm.Name
            $requestedNames = $requestedNames + $vm_name + ","
            $machineBaseNames += $vm_name
            $machineFullNames += $vm_name
        }
    } else {
        write-host "Generalizing only specific machines"
        foreach ($vm in $runningVMs) {
            $vm_name=$vm.Name
            foreach ($name in $requestedNames) {
                if ($vm_name.contains($name)) {
                    Write-Host "Including VM $vm_name"
                    $requestedNames = $requestedNames + $vm_name + ","
                    $machineBaseNames += $name
                    $machineFullNames += $vm_name
                    break
                }
            }
        }
    }

    $requestedNames = $requestedNames -replace ".$"
    $suffix = ""
}

Write-Host "Making sure we're up to date"
C:\Framework-Scripts\run_command_on_machines_in_group.ps1 -requestedNames $requestedNames -destSA $sourceSA -destRG $sourceRG `
                                                          -suffix $suffix -asRoot "True" -location $location -command "git pull /root/Framework-Scripts"
Write-Host "Replacing cloud-init..."
C:\Framework-Scripts\run_command_on_machines_in_group.ps1 -requestedNames $requestedNames -destSA $sourceSA -destRG $sourceRG `
                                                          -suffix $suffix -asRoot "True" -location $location -command "/bin/mv /usr/bin/cloud-init.DO_NOT_RUN_THIS_POS /usr/bin/cloud-init"

Write-Host "Deprovisioning..."
C:\Framework-Scripts\run_command_on_machines_in_group.ps1 -requestedNames $requestedNames -destSA $sourceSA -destRG $sourceRG `
                                                          -suffix $suffix -asRoot "True" -location $location -command "waagent -deprovision -force"
 if ($? -eq $false) {
    Write-Host "FAILED to deprovision machines" -ForegroundColor Red
    exit 1
}

Write-Host "And stopping..."
C:\Framework-Scripts\run_command_on_machines_in_group.ps1 -requestedNames $requestedNames -destSA $sourceSA -destRG $sourceRG `
                                                          -suffix $suffix -asRoot "True" -location $location -command "bash -c shutdown"
if ($? -eq $false) {
    Write-Host "FAILED to stop machines" -ForegroundColor Red
    exit 1
}

$scriptBlockText = {
    
    param (
        [string] $machine_name,
        [string] $sourceRG,
        [string] $sourceContainer,
        [string] $vm_name
    )

    . C:\Framework-Scripts\common_functions.ps1
    . C:\Framework-Scripts\secrets.ps1

    login_azure
    #
    #  This might not be the best way, but I only have 23 characters here, so we'll go with what the user entered
    $bar=$vm_name.Replace("---","{")
    $vhdPrefix = $bar.split("{")[0]
    if ($vhdPrefix.Length -gt 22) {
        $vhdPrefix = $vhdPrefix.substring(0,23)
    }

    Start-Transcript -Path C:\temp\transcripts\generalize_$machine_name.transcript -Force
    write-host "Stopping machine $machine_name for VHD generalization"
    Stop-AzureRmVM -Name $machine_name -ResourceGroupName $sourceRG -Force

    write-host "Settng machine $machine_name to Generalized"
    Set-AzureRmVM -Name $machine_name -ResourceGroupName $sourceRG -Generalized

    write-host "Saving image for machnine $machine_name to container $sourceContainer in RG $sourceRG"
    Save-AzureRmVMImage -VMName $machine_name -ResourceGroupName $sourceRG -DestinationContainerName $sourceContainer `
                        -VHDNamePrefix $vhdPrefix

    write-host "Deleting machine $machine_name"
    Remove-AzureRmVM -Name $machine_name -ResourceGroupName $sourceRG -Force

    Write-Host "Generalization of machine $vm_name complete."

    Stop-Transcript
}

$scriptBlock = [scriptblock]::Create($scriptBlockText)

[int]$nameIndex = 0
foreach ($vm_name in $machineBaseNames) {
    $machine_name = $machineFullNames[$nameIndex]
    $nameIndex = $nameIndex + 1
    $jobName = "generalize_" + $machine_name

    Start-Job -Name $jobName -ScriptBlock $scriptBlock -ArgumentList $machine_name, $sourceRG, $sourceContainer, $vm_name
}

$allDone = $false
while ($allDone -eq $false) {
    $allDone = $true
    $numNeeded = $vmNameArray.Count
    $vmsFinished = 0

    [int]$nameIndex = 0
    foreach ($vm_name in $machineBaseNames) {
        $machine_name = $machineFullNames[$nameIndex]
        $nameIndex = $nameIndex + 1
        $jobName = "generalize_" + $machine_name
        $job = Get-Job -Name $jobName
        $jobState = $job.State

        # write-host "    Job $job_name is in state $jobState" -ForegroundColor Yellow
        if ($jobState -eq "Running") {
            write-verbose "job $jobName is still running..."
            $allDone = $false
        } elseif ($jobState -eq "Failed") {
            write-host "**********************  JOB ON HOST MACHINE $jobName HAS FAILED TO START." -ForegroundColor Red
            # $jobFailed = $true
            $vmsFinished = $vmsFinished + 1
            get-job -Name $jobName | receive-job
            $Failed = $true
        } elseif ($jobState -eq "Blocked") {
            write-host "**********************  HOST MACHINE $jobName IS BLOCKED WAITING INPUT.  COMMAND WILL NEVER COMPLETE!!" -ForegroundColor Red
            # $jobBlocked = $true
            $vmsFinished = $vmsFinished + 1
            get-job -Name $jobName | receive-job
            $Failed = $true
        } else {
            $vmsFinished = $vmsFinished + 1
        }
    }

    if ($allDone -eq $false) {
        Start-Sleep -Seconds 10
    } elseif ($vmsFinished -eq $numNeeded) {
        break
    }
}

if ($Failed -eq $true) {
    Write-Host "Machine generalization failed.  Please check the logs." -ForegroundColor Red
    exit 1
} 

#
#  The generalization process, if successful, placed the VHDs in a location below the current
#  storage container, with the prefix we gave it but some random junk on the back.  We will copy those
#  VHDs, and their associated JSON files, to the output storage container, renaming them 
# to <user supplied>---no_loc-no_flav-generalized.vhd
Write-Host "Copying generalized VHDs in container $sourceContainer from region $location, with extenstion $sourceExtension."-ForegroundColor Magenta

$destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $destRG -Name $destSA
$destContext=New-AzureStorageContext -StorageAccountName $destSA -StorageAccountKey $destKey[0].Value

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceRG -Name $sourceSA
$sourceContext=New-AzureStorageContext -StorageAccountName $sourceSA -StorageAccountKey $sourceKey[0].Value

$copyBlobs = @()

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA
if ($makeDronesFromAll -eq $true) {
    $blobs=get-AzureStorageBlob -Container $sourceContainer -Blob "*.vhd"
    $blobCount = $blobs.Count
    Write-Host "Copying generalized VHDs in container $sourceContainer from region $location, with extenstion $sourceExtension.  There will be $blobCount VHDs :"-ForegroundColor Magenta
    foreach ($blob in $blobs) {
        $copyblobs += $blob
        $blobName = $blob.Name
        write-host "                       $blobName" -ForegroundColor Magenta
    }
} else {
    $blobs=get-AzureStorageBlob -Container $sourceContainer -Blob "*$sourceExtension"
    foreach ($vmName in $vmNames) {
        $foundIt = $false
        foreach ($blob in $blobs) {
            $matchName = "*" + $vmName + "*"
            if ( $blob.Name -match $matchName)  {
                $foundIt = $true
                break
            }
        }

        if ($foundIt -eq $true) {
            write-host "Added blob $theName (" $blob.Name ")"
            $copyblobs += $blob
        } else {
            Write-Host " ***** ??? Could not find source blob $theName in container $sourceContainer.  This request is skipped" -ForegroundColor Red
        }
    }
}

Set-AzureRmCurrentStorageAccount –ResourceGroupName $destRG –StorageAccountName $destSA
if ($clearDestContainer -eq $true) {
    Write-Host "Clearing destination container of all jobs with extension $destExtension"
    get-AzureStorageBlob -Container $destContainer -Blob "*$destExtension" | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $destContainer }
}

[int] $index = 0
foreach ($blob in $copyblobs) {
    $sourceBlobName = $blob.Name

    Write-Host "Copying source blob $sourceBlobName"

    $bar=$sourceBlobName.Replace("---","{")
    $targetName = $bar.split("{")[0] + "-generalized.vhd"

    Write-Host "Initiating job to copy VHD $sourceName from $sourceRG and $sourceContainer to $targetName in $destRG and $destSA, container $destContainer" -ForegroundColor Yellow
    if ($overwriteVHDs -eq $true) {
        $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceBlob.Name -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext -Force
    } else {
        $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceBlob.Name -DestContainer $destContainer -SrcContainer $sourceContainer -DestBlob $targetName -Context $sourceContext -DestContext $destContext
    }

    if ($? -eq $false) {
        Write-Host "Job to copy VHD $targetName failed to start.  Cannot continue"
        Stop-Transcript
        exit 1
    }
}

Start-Sleep -Seconds 5
Write-Host "All jobs have been launched.  Initial check is:" -ForegroundColor Yellow

$stillCopying = $true
while ($stillCopying -eq $true) {
    $stillCopying = $false

    write-host ""
    write-host "Checking blob copy status..." -ForegroundColor yellow

    foreach ($blob in $copyblobs) {
        $sourceBlobName = $blob.Name
        $bar=$sourceBlobName.Replace("---","{")
        $targetName = $bar.split("{")[0] + "-generalized.vhd"

        $copyStatus = Get-AzureStorageBlobCopyState -Blob $targetName -Container $destContainer -ErrorAction SilentlyContinue
        $status = $copyStatus.Status
        if ($? -eq $false) {
            Write-Host "        Could not get copy state for job $targetName.  Job may not have started." -ForegroundColor Yellow
            break
        } elseif ($status -eq "Pending") {
            $bytesCopied = $copyStatus.BytesCopied
            $bytesTotal = $copyStatus.TotalBytes
            if ($bytesTotal -le 0) {
                Write-Host "        Job $targetName not started copying yet." -ForegroundColor green
            } else {
                $pctComplete = ($bytesCopied / $bytesTotal) * 100
                Write-Host "        Job $targetName has copied $bytesCopied of $bytesTotal bytes ($pctComplete %)." -ForegroundColor green
            }
            $stillCopying = $true
        } else {
            if ($status -eq "Success") {
                Write-Host "   **** Job $targetName has completed successfully." -ForegroundColor Green                    
            } else {
                Write-Host "   **** Job $targetName has failed with state $Status." -ForegroundColor Red
            }
        }
    }

    if ($stillCopying -eq $true) {
        Start-Sleep -Seconds 10
    } else {
        Write-Host "All copy jobs have completed.  Rock on." -ForegroundColor Green
    }
}
# Stop-Transcript

exit 0