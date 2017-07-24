﻿##############################################################
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
    [Parameter(Mandatory=$false)] [string] $getAll=$false,
    [Parameter(Mandatory=$false)] [string] $replaceVHD=$false,
    [Parameter(Mandatory=$false)] [string[]] $requestedVMs
)

. "C:\Framework-Scripts\secrets.ps1"

$rg="smoke_source_resource_group"
$nm="smokesourcestorageacct"
$srcContainer="clean-vhds"

write-host "Importing the context...." -ForegroundColor green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

$requestedVMs

write-host "Selecting the Azure subscription..." -ForegroundColor green
Select-AzureRmSubscription -SubscriptionId "$AZURE_SUBSCRIPTION_ID"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $rg –StorageAccountName $nm

$sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $rg -Name $nm
$sourceContext=New-AzureStorageContext -StorageAccountName $nm -StorageAccountKey $sourceKey[0].Value

$uri_front="https://"
$uri_middle="smokesourcestorageacct.blob.core.windows.net/"

$neededVms_array=@()
$neededVms = {$neededVms_array}.Invoke()

Write-Host "Getting the list of disks..."
$blobs=get-AzureStorageBlob -Container $srcContainer -Blob "*-Smoke-1*.vhd"
foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name
    $targetName = $sourceName | % { $_ -replace "Smoke-1.*.vhd", "Smoke-1.vhd" }

    if ((Test-Path D:\azure_images\$targetName) -eq $true -and $replaceVHD -eq $true) {
            Write-Host "Machine $targetName is being deleted from the disk and will be downloaded again..." -ForegroundColor green
            remove-item "D:\azure_images\$targetName" -recurse -force
            stop-vm -Name $targetName -ErrorAction SilentlyContinue
            remove-vm -Name $targetName -Force -ErrorAction SilentlyContinue
            $neededVms.Add($targetName)
        } elseIf (Test-Path D:\azure_images\$targetName) {
            Write-Host "Machine $targetName was already on the disk and the replaceVHD flag was not given.  Machine will not be updated." -ForegroundColor red            
        } else {
            Write-Host "Machine $targetName does not yet exist on the disk.  Machine will be downloaded..." -ForegroundColor green
            stop-vm -Name $targetName -ErrorAction SilentlyContinue
            remove-vm -Name $targetName -Force -ErrorAction SilentlyContinue
            $neededVms.Add($targetName)
        }
}

if ($getAll -eq $true) {
    Write-Host "Downloading all machines.  This may take some time..." -ForegroundColor green
    foreach ($machine in $neededVms) {
        $machine_name = "D:/azure_images/" + $machine

        $uri=$uri_front + $nm + ".blob.core.windows.net/" + $srcContainer + "/" + $machine
        $jobName=$machine + "-download"

        Write-Host "Starting job $jobName to download machine $machine from uri $uri to directory $machine_name" -ForegroundColor green
        Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\download_single_vm.ps1 -g $args[0] -u $args[1] -n $args[2] -j $args[3] } -ArgumentList @($rg, $uri, $machine_name, $jobName)
    }
} else {
    foreach ($neededMachine in $requestedVMs) {
        $vmName=$neededMachine

        $foundIt = $false
        foreach ($machine in $neededVms) {            
            if ($vmName -eq $machine) {
                $foundIt = $true
                break;
            }
        }

        if ($foundIt -eq $false) {
            Write-Host "Requested VM $machine was not found on host.  Machine cannot be downloaded."
        } else {
            $vhd_name=$machine
            $machine_name = "D:/azure_images/" + $machine
            $vmName=$machine

            $jobName = $vmName + "-download"
            $uri=$uri_front + $nm + ".blob.core.windows.net/" + $srcContainer + "/" + $machine
            Write-Host "Starting job $jobName to download machine $vhd_name from uri $uri to directory $machine_name" -ForegroundColor green

            Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\download_single_vm.ps1 -g $args[0] -u $args[1] -n $args[2] -j $args[3] } -ArgumentList @($rg, $uri, $machine_name, $jobName)
        }
    }
}

$sleepCount = 1
$stop_checking = $false

while ($stop_checking -eq $false) {
    foreach ($machine in $neededVms) {
        $waitIntervals = 0
    
        $jobName = $machine + "-download"

        if (($sleepCount % 6) -eq 0) {
            Write-Host "Checking download progress of machine $machine, job $jobName"  -ForegroundColor green
        }

        $jobState=Get-Job -Name $jobName
        $failed=$true

        if ($jobState.State -eq "Running") {
            if (($sleepCount % 6) -eq 0) {
                $dlLog="c:\temp\"+ $jobName+ "_download.log"
                Write-Host "Download still in progress.  Last line from log file is:" -ForegroundColor green
                get-content $dlLog | Select-Object -Last 1 | write-host  -ForegroundColor cyan -ErrorAction SilentlyContinue
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
    $SleepCount+=1
    Start-Sleep 10
}