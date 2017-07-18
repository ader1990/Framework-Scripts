##############################################################
#
#  Microsoft Linux Kernel Build and Validation Pipeline
#
#  Script Name:  download_azure_distro_templates
#
#  Script Summary:  This script will create a VHD in Azure
#         assigned to the azuresmokeresourcegroup so it can be
#         discovered by the download monitoring job.
#
##############################################################
param (
    [Parameter(Mandatory=$false)] [switch] $getAll,
    [Parameter(Mandatory=$false)] [switch] $replaceVHD,
    [Parameter(Mandatory=$false)] [string[]] $requestedVMs
)

$rg="azuresmokeresourcegroup"
$nm="azuresmokestorageaccount"

write-host "Importing the context...." -ForegroundColor green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

$requestedVMs

write-host "Selecting the Azure subscription..." -ForegroundColor green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $rg –StorageAccountName $nm

Write-Host "Getting the list of machines and disks..."
$smoke_machines=Get-AzureRmVm -ResourceGroupName $rg
$smoke_disks=Get-AzureRmDisk -ResourceGroupName $rg
$neededVms_array=@()
$neededVms = {$neededVms_array}.Invoke()

write-host "Clearing the old VHD download directory" -ForegroundColor green
if ($getAll -eq $true -and $replaceVHD -eq $true) {
    Write-Host "GetAll and replaceVHD were both specified.  Clearning the download directory..." -ForegroundColor green
    remove-item "D:\azure_images\*" -recurse -force
} elseif ($requestedVMs.Length -eq 0) {
    foreach ($machine in $smoke_machines) {
        $machineName=$machine.Name+".vhd"
        $vmName=$machine.Name
        if ((Test-Path D:\azure_images\$machineName) -eq $true -and $replaceVHD -eq $true) {
            Write-Host "Machine $vmName is being deleted from the disk and will be downloaded again..." -ForegroundColor green
            remove-item "D:\azure_images\$machineName" -recurse -force
            stop-vm -Name $vmName
            remove-vm -Name $vmName -Force
            $neededVms.Add($vmName)
        } elseIf (Test-Path D:\azure_images\$machineName) {
            Write-Host "Machine $vmName was already on the disk and the replaceVHD flag was not given.  Machine will not be updated." -ForegroundColor red            
        } else {
            Write-Host "Machine $vmName does not yet exist on the disk.  Machine will be downloaded..." -ForegroundColor green
            stop-vm -Name $vmName
            remove-vm -Name $vmName -Force
            $neededVms.Add($vmName)
        }
    }
} else {
    foreach ($machine in $requestedVMs) {
        Write-Host "Downloading per user-defined list"
        $machineName=$machine.Name +".vhd"
        $vmName=$machine.Name
        write-host "Looking for machine $vmName"
        if ((Test-Path D:/azure_images/$machineName) -eq $true -and $replaceVHD -eq $true) {
            Write-Host "Machine $vmName is being deleted from the disk and will be downloaded again..." -ForegroundColor green
            remove-item "D:/azure_images/$machineName" -recurse -force
            stop-vm -Name $vmName
            remove-vm -Name $vmName -Force
            $neededVms.Add($vmName)
        } elseIf (Test-Path D:\azure_images\$machineName) {
            Write-Host "Machine $vmName was already on the disk and the replaceVHD flag was not given.  Machine will not be updated." -ForegroundColor red            
        } else {
            Write-Host "Machine $vmName does not yet exist on the disk.  Machine will be downloaded..." -ForegroundColor green
            stop-vm -Name $vmName
            remove-vm -Name $vmName -Force
            $neededVms.Add($vmName)
        }
    }
}
        
if ($getAll -eq $true) {
    Write-Host "Downloading all machines.  This may take some time..." -ForegroundColor green
    foreach ($machine in $smoke_machines) {
        $vhd_name=$machine.Name + ".vhd"
        $machine_name = "D:/azure_images/" + $machine.Name

        $vmName=$machine.Name

        $neededVMs.Add($vmName)

        $jobName = $vmName + "_SaveVhd"
        $uri=$machine.StorageProfile.OsDisk.Vhd.Uri

        Write-Host "Starting job $jobName to download machine $vhd_name from uri $uri to directory $machine_name" -ForegroundColor green

        Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\download_single_vm.ps1 -g $args[0] -u $args[1] -n $args[2] -j $args[3] } -ArgumentList @($rg, $uri, $machine_name, $jobName)
    }
} else {
    foreach ($neededMachine in $neededVms) {
       
        foreach ($machine in $smoke_machines) {
            $vmName=$machine.Name
            if ($vmName -eq $neededMachine) {
                break;
            }
        }
        $vhd_name=$machine.Name + ".vhd"
        $machine_name = "D:/azure_images/" + $machine.Name + ".vhd"
        $vmName=$machine.Name

        $jobName = $vmName + "_SaveVhd"
        $uri=$machine.StorageProfile.OsDisk.Vhd.Uri
        Write-Host "Starting job $jobName to download machine $vhd_name from uri $uri to directory $machine_name" -ForegroundColor green

        Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\download_single_vm.ps1 -g $args[0] -u $args[1] -n $args[2] -j $args[3] } -ArgumentList @($rg, $uri, $machine_name, $jobName)
    }
}

$sleepCount = 0
$stop_checking = $false

while ($stop_checking -eq $false) {
    foreach ($machine in $neededVms) {
        $waitIntervals = 0
    
        $jobName = $machine + "_SaveVhd"

        if (($sleepCount % 6) -eq 0) {
            Write-Host "Checking download progress of machine $machine, job $jobName"  -ForegroundColor green
        }

        $jobState=Get-Job -Name $jobName
        $failed=$true

        if ($jobState.State -eq "Running") {
            if (($sleepCount % 6) -eq 0) {
                $dlLog="c:\temp\"+ $jobName+ "_download.log"
                Write-Host "Download still in progress.  Last line from log file is:" -ForegroundColor green
                get-content $dlLog | Select-Object -Last 1 | write-host  -ForegroundColor cyan
                $failed=$false
            }
        } elseif ($jobState.State -eq "Completed") {
            Write-Host "Download has completed" -ForegroundColor green
            $stop_checking = $true
            $failed=$false
        } elseif ($jobState.State -eq "Failed") {
            Write-Host "Download has FAILED" -ForegroundColor red
            $stop_checking = $true
        } elseif ($jobState.State -eq "Stopped") {
            Write-Host "Download has Stopped"  -ForegroundColor red   
            $stop_checking = $true
        } elseif ($jobState.State -eq "Blocked") {
            Write-Host "Download has Blocked" -ForegroundColor red
            $stop_checking = $true
         } elseif ($jobState.State -eq "Suspended") {
            Write-Host "Download has Suspended" -ForegroundColor red
        } elseif ($jobState.State -eq "Disconnected") {
            Write-Host "Download has Disconnected" -ForegroundColor red
            $stop_checking = $true
        } elseif ($jobState.State -eq "Suspending") {
            Write-Host "Download is being suspended" -ForegroundColor red
        } elseif ($jobState.State -eq "Stopping") {
            Write-Host "Download is being Stopped" -ForegroundColor red
        }

        if ($stop_checking -eq $true)
        {
            if ($failed) {
                Write-Host "DOWNLOAD FAILED!!" -Foregroundcolor Red
            } else {
                Write-Host "Machine $machine has been downloaded successfully." -ForegroundColor green
            }
            $neededVms.Remove($machine)

            if ($neededVms.Length -le 0) {
                Write-Host "All downloads have completed or failed.  Terminating loop." -ForegroundColor Green
                break;
            }
            else
            {
                $stop_checking = $false
            }
        }
    }
    $SleepCount++
    Start-Sleep 10
}