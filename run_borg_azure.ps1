#
#  Run the Basic Operations and Readiness Gateway on Azure.  This script will:
#      - Copy a VHD from the templates container to a working one
#      - Create a VM around the VHD and launch it. It is assumed that the VHD has a
#        properly configured RunOnce set up
#      - Periodically poll the VM and check for status. Report same to console until
#        either SUCCESS or FAILURE is perceived.
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
#  Azure information
param (
    [Parameter(Mandatory=$false)] [string] $sourceResourceGroupName="smoke_source_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceStorageAccountName="smokesourcestorageacct",
    [Parameter(Mandatory=$false)] [string] $sourceContainerName="safe-templates",
    [Parameter(Mandatory=$false)] [string] $workingResourceGroupName="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $workingStorageAccountName="smokeworkingstorageacct",
    [Parameter(Mandatory=$false)] [string] $workingContainerName="vhds-under-test",
    [Parameter(Mandatory=$false)] [string] $sourceURI,
    [Parameter(Mandatory=$false)] [string] $testOutputResourceGroup="smoke_output_resoruce_group",
    [Parameter(Mandatory=$false)] [string] $testOutputStorageAccountName="smoketestoutstorageacct",    
    [Parameter(Mandatory=$false)] [string] $testOutputContainerName="last-known-good-vhds",
    [Parameter(Mandatory=$false)] [string] $location="westus",
    [Parameter(Mandatory=$true)] [string] $SubscriptionId
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$FRAMEWORK_SCRIPTS = $scriptPath

#
#  The machines we're working with
$Global:neededVMs_array=@()
$Global:neededVMs = {$neededVMs_array}.Invoke()
$Global:copyblobs_array=@()
$Global:copyblobs = {$copyblobs_array}.Invoke()


#  Session stuff
#
$sessionOptions = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$securePassword = convertto-securestring -AsPlainText -force -string 'P@ssW0rd-'
$credentials = new-object -typename system.management.automation.pscredential -argumentlist "mstest",$securePassword


class MonitoredMachine {
    [string] $name = $null
    [string] $status = $null
    [string] $ipAddress = $null
    $session = $null
}

[System.Collections.ArrayList]$Global:MonitoredMachines = @()
$timer = New-Object System.Timers.Timer


function Copy-AzureVMDisks {
    if ($useSourceURI -eq $false) {
        #
        #  In the source group, stop any machines, then get the keys.
        Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceResourceGroupName –StorageAccountName $sourceStorageAccountName | Out-Null

        Write-Host "Stopping any currently running machines in the source resource group..."  -ForegroundColor green
        Get-AzureRmVm -ResourceGroupName $sourceResourceGroupName -status |  where-object -Property PowerState -eq -value "VM Running" | Stop-AzureRmVM -Force | Out-Null
        $sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $sourceResourceGroupName -Name $sourceStorageAccountName
        $sourceContext=New-AzureStorageContext -StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceKey[0].Value

        $blobs = Get-AzureStorageBlob -Container $sourceContainerName

        #
        #  Switch to the target resource group
        Set-AzureRmCurrentStorageAccount –ResourceGroupName $workingResourceGroupName –StorageAccountName $workingStorageAccountName | Out-Null

        Write-Host "Stopping and deleting any currently running machines in the target resource group..."  -ForegroundColor green
        Get-AzureRmVm -ResourceGroupName $workingResourceGroupName | Remove-AzureRmVM -Force | Out-Null

        Write-Host "Clearing VHDs in the working storage container $workingContainerName..."  -ForegroundColor green
        Get-AzureStorageBlob -Container $workingContainerName -blob * | ForEach-Object { Remove-AzureStorageBlob -Blob $_.Name -Container $workingContainerName } | Out-Null

        $destKey = Get-AzureRmStorageAccountKey -ResourceGroupName $workingResourceGroupName -Name $workingStorageAccountName
        $destContext = New-AzureStorageContext -StorageAccountName $workingStorageAccountName -StorageAccountKey $destKey[0].Value

        Write-Host "Preparing the individual machines..." -ForegroundColor green
        foreach ($oneblob in $blobs) {
            $sourceName=$oneblob.Name
            $targetName = $sourceName | % { $_ -replace "RunOnce-Primed.vhd", "BORG.vhd" }

            $vmName = $targetName.Replace(".vhd","")
            $Global:neededVMs.Add($vmName)
   
            Write-Host "    ---- Initiating job to copy VHD $vmName from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $workingContainerName -SrcContainer $sourceContainerName -DestBlob $targetName -Context $sourceContext -DestContext $destContext

            $Global:copyblobs.Add($targetName)
        }
    } else {
        Write-Host "Clearing the destination container..."  -ForegroundColor green
        Get-AzureStorageBlob -Container $workingContainerName -blob * | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $workingContainerName}  | Out-Null

        foreach ($singleURI in $URI) {
            Write-Host "Preparing to copy disk by URI.  Source URI is $singleURI"  -ForegroundColor green

            $splitUri=$singleURI.split("/")
            $lastPart=$splitUri[$splitUri.Length - 1]

            $sourceName = $lastPart
            $targetName = $sourceName | % { $_ -replace ".vhd", "-BORG.vhd" }

            $vmName = $targetName.Replace(".vhd","")

            $Global:neededVMs.Add($vmName)

            Write-Host "Initiating job to copy VHD $vhd_name from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $workingContainerName -SrcContainer $sourceContainerName -DestBlob $targetName -Context $sourceContext -DestContext $destContext

            $Global:copyblobs.Add($targetName)
        }
    }

    Write-Host "All copy jobs have been launched.  Waiting for completion..." -ForegroundColor green
    Write-Host ""
    $stillCopying = $true
    while ($stillCopying -eq $true) {
        $stillCopying = $false
        $reset_copyblobs = $true

        Write-Host "Checking copy status..." -ForegroundColor Green
        while ($reset_copyblobs -eq $true) {
            $reset_copyblobs = $false
            foreach ($blob in $Global:copyblobs) {
                $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $workingContainerName -ErrorAction SilentlyContinue
                if ($? -eq $false) {
                    Write-Host "     **** Could not get copy state for job $blob.  Job may not have started." -ForegroundColor Red
                    # $copyblobs.Remove($blob)
                    # $reset_copyblobs = $true
                    break
                } elseif ($status.Status -eq "Pending") {
                    $bytesCopied = $status.BytesCopied
                    $bytesTotal = $status.TotalBytes
                    $pctComplete = ($bytesCopied / $bytesTotal) * 100
                    Write-Host "    ---- Job $blob has copied $bytesCopied of $bytesTotal bytes ($pctComplete %)." -ForegroundColor Yellow
                    $stillCopying = $true
                } else {
                    $exitStatus = $status.Status
                    if ($exitStatus -eq "Success") {
                        Write-Host "     **** Job $blob has completed successfully." -ForegroundColor Green
                    } else {
                        Write-Host "     **** Job $blob has failed with state $exitStatus." -ForegroundColor Red
                    }
                    # $copyblobs.Remove($blob)
                    # $reset_copyblobs = $true
                    # break
                }
            }
        }

        if ($stillCopying -eq $true) {
            sleep(15)
        } else {
            Write-Host "All copy jobs have completed. Rock on." -ForegroundColor Green
        }
    }
}


function Start-AzureVMs {
    Get-Job | Stop-Job | Out-Null
    Get-Job | Remove-Job | Out-Null
    $jobs = @()

    foreach ($vmName in $Global:neededVMs) {
        $machine = New-Object MonitoredMachine
        $machine.name = $vmName
        $machine.status = "Booting"
        $Global:MonitoredMachines.Add($machine) | Out-Null
        $jobname = $vmName + "-VMStart"

        $machine_log = New-Object MachineLogs
        $machine_log.name = $vmName
        $machine_log.job_name = $jobname
        $Global:machineLogs.Add($machine_log) | Out-Null

        ($jobs += Start-Job -Name $jobname -ScriptBlock {
                $ErrorActionPreference = "Stop"
                Set-StrictMode -Version 2.0;
                $FRAMEWORK_SCRIPTS= $args[4];
                & "$FRAMEWORK_SCRIPTS\launch_single_azure_vm.ps1" -resourceGroup $args[0] -storageAccount $args[1] -containerName $args[2] -vmName $args[3]
            } -ArgumentList @($workingResourceGroupName,$workingStorageAccountName,$workingContainerName,$vmName,$FRAMEWORK_SCRIPTS)) | Out-Null
    }
    Write-Host "Waiting for Azure VM start jobs" -ForegroundColor Cyan
    Wait-Job $jobs -Timeout 60 | Out-Null
    foreach ($job in $jobs) {
        Write-Host "Job Name: $($job.Name)" -ForegroundColor Cyan
        $Global:completed = 1
        switch ($job.State) {
            "Completed" {
                Write-Host "----> Azure boot job $($job.Name) completed while we were waiting. We will check results later." -ForegroundColor Green
            }
            "Failed" {
                Write-Host "----> Azure boot $($job.Name) failed to lanch. Error information is $($job.Error)" -ForegroundColor Yellow
                $Global:completed = 0
            }
            "Running" {
                Write-Host "----> Azure boot $($job.Name) launched successfully." -ForegroundColor Green
                $Global:completed = 0
            }
        }
    }
}

function Get-MachineKernelStatus {
    $wrongKernelMachines = $Global:MonitoredMachines.Count
    foreach ($localMachine in $Global:MonitoredMachines) {
        $maxRetries =  10
        $retries =  0
        while (!$localMachine.IPAddress -and ($retries -lt $maxRetries)) {
            Write-Host ("Getting {0} IP address" -f @($localMachine.Name)) -ForegroundColor Cyan
            $ip = Get-AzureRmPublicIpAddress -ResourceGroupName $Global:workingResourceGroupName -Name ("{0}-pip" -f @($localMachine.Name))
            if ($ip) {
                $localMachine.IPAddress = $ip.IPAddress
            } else {
                $retries++
            }
        }
        if (!$localMachine.IPAddress) {
            continue
        }

        Write-Host ("Creating PowerShell Remoting session to machine at IP " + $localMachine.IPAddress) -ForegroundColor Green
        if ($localMachine.Session -eq $null) {
            $localMachine.Session = New-PSSession -Computername $localMachine.IPAddress -Credential $credentials -Authentication Basic `
                                                  -UseSSL -Port 443 -SessionOption $sessionOptions -ErrorAction SilentlyContinue
        }
        if (!$localMachine.Session) {
            continue
        }
        $kernelVersion = Invoke-Command -Session $localMachine.Session -ScriptBlock { /bin/uname -r } -ErrorAction SilentlyContinue
        if (!$kernelVersion) {
            continue
        }
        Write-Host "$localMachine installed version retrieved as $kernelVersion" -ForegroundColor Cyan
        Remove-PSSession -Session $localMachine.Session | Out-Null
        $localMachine.Session = $null

        $expectedVersionDebKernel = Get-Content C:\temp\expected_version_deb
        $expectedVersionRpmKernel = Get-Content C:\temp\expected_version_centos
        if (@($expectedVersionDebKernel, $expectedVersionRpmKernel) -contains $kernelVersion) {
            Write-Host ("    *** Machine " + $localMachine.Name + " came back up as expected. Kernel version is $kernelVersion") -ForegroundColor Green
            $localMachine.Status = "Completed"
            $wrongKernelMachines--
        } else {
            Write-Host ("*** Machine " + $localMachine.Name + " is up, but the kernel version is $kernelVersion when we expected") -ForegroundColor Cyan
            Write-Host  "something like $expectedVersionDebKernel or $expectedVersionRpmKernel.  Waiting to see if it reboots.***" -ForegroundColor Cyan
            Write-Host ""
        }
    }
    return $wrongKernelMachines
}

function Run-Borg {
    #####################MAIN#########################
    Write-Host "    " -ForegroundColor green
    Write-Host "                 **********************************************" -ForegroundColor Yellow
    Write-Host "                 *                                            *" -ForegroundColor Yellow
    Write-Host "                 *            Microsoft Linux Kernel          *" -ForegroundColor Yellow
    Write-Host "                 *     Basic Operational Readiness Gateway    *" -ForegroundColor Yellow
    Write-Host "                 * Host Infrastructure Validation Environment *" -ForegroundColor Yellow
    Write-Host "                 *                                            *" -ForegroundColor Yellow
    Write-Host "                 *           Welcome to the BORG HIVE         *" -ForegroundColor Yellow
    Write-Host "                 **********************************************" -ForegroundColor Yellow
    Write-Host "    "
    Write-Host "          Initializing the CUBE (Customizable Universal Base of Execution)" -ForegroundColor Yellow
    Write-Host "    "
    Write-Host "   "
    Write-Host "                                BORG CUBE is initialized"                   -ForegroundColor Yellow
    Write-Host "              Starting the Dedicated Remote Nodes of Execution (DRONES)" -ForegroundColor Yellow
    Write-Host "    "

    Write-Host "Connecting to Azure and setting the proper resource group and storage account" -ForegroundColor Green
    Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx' | Out-Null
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId | Out-Null
    Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceResourceGroupName –StorageAccountName $sourceStorageAccountName | Out-Null

    #  Copy the virtual machines disks to the staging container
    Copy-AzureVMDisks

    #  Launch the virtual machines
    Start-AzureVMs
    Write-Host "Finished launching the VMs. Completed is $Global:completed" -ForegroundColor Yellow
    $maxRetries =  10
    $retries =  0
    $wrongKernelMachines = 0
    while ($retries -lt $maxRetries) {
        $wrongKernelMachines = Get-MachineKernelStatus
        if ($wrongKernelMachines -eq 0) {
            Write-Host "All machines have the correct kernel"
            break
        } else {
            Start-Sleep 10
            $retries++
        }
    }

    if ($wrongKernelMachines -ne 0) {
        Write-Host "     Failures were detected in reboot and/or reporting of kernel version.  See log above for details." -ForegroundColor Red
        Write-Host "                                             BORG TESTS HAVE FAILED!!" -ForegroundColor Red
        Write-Host "                                    BORG is Exiting with failure.  Thanks for Playing" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "     All machines rebooted successfully to some derivitive of kernel version $Global:booted_version" -ForegroundColor green
        Write-Host "                                  BORG has been passed successfully!" -ForegroundColor green
        Write-Host "                                    BORG is Exiting with success.  Thanks for Playing" -ForegroundColor green
        exit 0
    }
}

Run-Borg
