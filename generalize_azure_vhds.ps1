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

    [Parameter(Mandatory=$false)] [string] $requestedNames,
    [Parameter(Mandatory=$false)] [string] $generalizeAll,

    [Parameter(Mandatory=$false)] [string] $location,

    [Parameter(Mandatory=$false)] [string] $suffix="-Runonce-Primed.vhd"
)

$suffix = $suffix -replace "_","-"

. C:\Framework-Scripts\common_functions.ps1
. C:\Framework-Scripts\secrets.ps1

[System.Collections.ArrayList]$vmNames_array
$vmNameArray = {$vmNames_array}.Invoke()
$vmNameArray.Clear()
if ($requestedNames -ne "Unset" -and $requestedNames -like "*,*") {
    $vmNameArray = $requestedNames.Split(',')
} else {
    $vmNameArray += $requestedNames
}

[System.Collections.ArrayList]$base_names_array
$machineBaseNames = {$base_names_array}.Invoke()
$machineBaseNames.Clear()

[System.Collections.ArrayList]$full_names_array
$machineFullNames = {$full_names_array}.Invoke()
$machineFullNames.Clear()

login_azure $sourceRG $sourceSA $location

$vmName = $vmNameArray[0]
if ($generalizeAll -eq $false -and ($vmNameArray.Count -eq 1  -and $vmNameArray[0] -eq "Unset")) {
    Write-Host "Must specify either a list of VMs in RequestedNames, or use MakeDronesFromAll.  Unable to process this request."
    Stop-Transcript
    exit 1
} else {
    $requestedNames = ""
    $runningVMs = Get-AzureRmVm -ResourceGroupName $sourceRG

    if ($generalizeAll -eq $true) {
        foreach ($vm in $runningVMs) {
            $vm_name=$vm.Name
            $requestedNames = $requestedNames + $vm_name + ","
            $machineBaseNames += $vm_name
            $machineFullNames += $vm_name
        }
    } else {
        foreach ($vm in $runningVMs) {
            $vm_name=$vm.Name
            foreach ($name in $requestedNames) {
                if ($vm_name.contains($name)) {
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
                        -VHDNamePrefix $vhdPrefix -Path c:\test\vhd_templates\$machine_name

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
$bar=$vm_name.Replace("---","{")
$vhdPrefix = $bar.split("{")[0]
if ($vhdPrefix.Length -gt 22) {
    $vhdPrefix = $vhdPrefix.substring(0,23)
}

$blobFilter = '*.json'
if ($removeTag -ne "") {
    $blobFilter = '*' + $removeTag
}
Write-Host "Blob filter is $blobFilter"

$generalized_container = "system/Microsoft.Compute/Images/" + $sourceContainer + "/"
$blobs=get-AzureStorageBlob -Container $generalized_container -Blob $blobFilter

[int]$nameIndex = 0
foreach ($vm_name in $machineBaseNames) {
    $machine_name = $machineFullNames[$nameIndex]

    
    $jsonURI = "https://" + $sourceRG + ".blob.core.windows.net/system/Microsoft.Compute/Images/" + $sourceContainer + "/" + OpenLogic-CentOS-73-LAT-vmTemplate.1b544b03-16b2-46bd-a00e-607dc4f02f45.json
exit 0
