#
#  Run the Basic Operations and Readiness Gateway on Azure.  This script will:
#      - Copy a VHD from the templates container to a working one
#      - Create a VM around the VHD and launch it.  It is assumed that the VHD has a
#        properly configured RunOnce set up
#      - Periodically poll the VM and check for status.  Report same to console unitl
#        either SUCCESS or FAILURE is perceived.
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
#  Azure information

param (
    #
    #  Azure RG for all accounts and containers
    [Parameter(Mandatory=$false)] [string] $sourceResourceGroupName="smoke_source_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceStorageAccountName="smokesourcestorageacct",
    [Parameter(Mandatory=$false)] [string] $sourceContainerName="safe-templates",

    [Parameter(Mandatory=$false)] [string] $workingResourceGroupName="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $workingStorageAccountName="smokeworkingstorageacct",
    [Parameter(Mandatory=$false)] [string] $workingContainerName="vhds-under-test",

    [Parameter(Mandatory=$false)] [string] $sourceURI="Unset",

    # 
    #  A place with the contents of Last Known Good.  This is similar to Latest for packagee
    [Parameter(Mandatory=$false)] [string] $testOutputResourceGroup="smoke_output_resoruce_group",
    [Parameter(Mandatory=$false)] [string] $testOutputStorageAccountName="smoketestoutstorageacct",    
    [Parameter(Mandatory=$false)] [string] $testOutputContainerName="last-known-good-vhds",

    #
    #  Our location
    [Parameter(Mandatory=$false)] [string] $location="westus"
)
Set-StrictMode -Version 2.0

$global:sourceResourceGroupName=$sourceResourceGroupName
$global:sourceStorageAccountName=$sourceStorageAccountName
$global:sourceContainerName=$sourceContainerName

$global:workingResourceGroupName=$workingResourceGroupName
$global:workingStorageAccountName=$workingStorageAccountName
$global:workingContainerName=$workingContainerName

$global:sourceURI=$sourceURI

$global:testOutputResourceGroup=$testOutputResourceGroup
$global:testOutputContainerName=$testOutputContainerName
$global:workingContainerName=$workingContainerName

$global:useSourceURI=[string]::IsNullOrEmpty($global:sourceURI)

#
#  The machines we're working with
$global:neededVms_array=@()
$global:neededVms = {$neededVms_array}.Invoke()
$global:copyblobs_array=@()
$global:copyblobs = {$copyblobs_array}.Invoke()


$global:completed=0
$global:elapsed=0
#
#  Timer interval in msec.
$global:interval=500
$global:boot_timeout_minutes=20
$global:boot_timeout_intervals_per_minute=(60*(1000/$global:interval))
$global:boot_timeout_intervals= ($global:interval * $global:boot_timeout_intervals_per_minute) * $global:boot_timeout_minutes

#
#  Machine counts and status
$global:num_expected=0
$global:num_remaining=0
$global:failed=0
$global:booted_version="Unknown"
$global:timer_is_running = 0

#
#  Session stuff
#
$global:o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$global:pw = convertto-securestring -AsPlainText -force -string 'P@ssW0rd-'
$global:cred = new-object -typename system.management.automation.pscredential -argumentlist "mstest",$global:pw


class MonitoredMachine {
    [string] $name="unknown"
    [string] $status="Unitialized"
    [string] $ipAddress="Unitialized"
    $session=$null
}
[System.Collections.ArrayList]$global:monitoredMachines = @()

$timer=New-Object System.Timers.Timer

class MachineLogs {
    [string] $name="unknown"
    [string] $job_log
    [string] $job_name
}
[System.Collections.ArrayList]$global:machineLogs = @()

function copy_azure_machines {
    if ($global:useSourceURI -eq $false)
    {
        #
        #  In the source group, stop any machines, then get the keys.
        Set-AzureRmCurrentStorageAccount –ResourceGroupName $global:sourceResourceGroupName –StorageAccountName $global:sourceStorageAccountName > $null

        Write-Host "Stopping any currently running machines in the source resource group..."  -ForegroundColor green
        Get-AzureRmVm -ResourceGroupName $global:sourceResourceGroupName -status |  where-object -Property PowerState -eq -value "VM Running" | Stop-AzureRmVM -Force > $null       

        $sourceKey=Get-AzureRmStorageAccountKey -ResourceGroupName $global:sourceResourceGroupName -Name $global:sourceStorageAccountName
        $sourceContext=New-AzureStorageContext -StorageAccountName $global:sourceStorageAccountName -StorageAccountKey $sourceKey[0].Value

        $blobs = Get-AzureStorageBlob -Container $global:sourceContainerName

        #
        #  Switch to the target resource group
        Set-AzureRmCurrentStorageAccount –ResourceGroupName $global:workingResourceGroupName –StorageAccountName $global:workingStorageAccountName > $null

        Write-Host "Stopping and deleting any currently running machines in the target resource group..."  -ForegroundColor green
        Get-AzureRmVm -ResourceGroupName $global:workingResourceGroupName | Remove-AzureRmVM -Force > $null

        Write-Host "Clearing VHDs in the working storage container $global:workingContainerName..."  -ForegroundColor green
        Get-AzureStorageBlob -Container $global:workingContainerName -blob * | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $global:workingContainerName } > $null

        $destKey=Get-AzureRmStorageAccountKey -ResourceGroupName $global:workingResourceGroupName -Name $global:workingStorageAccountName
        $destContext=New-AzureStorageContext -StorageAccountName $global:workingStorageAccountName -StorageAccountKey $destKey[0].Value

        Write-Host "Preparing the individual machines..." -ForegroundColor green
        foreach ($oneblob in $blobs) {
            $sourceName=$oneblob.Name
            $targetName = $sourceName | % { $_ -replace "RunOnce-Primed.vhd", "BORG.vhd" }

            $vmName = $targetName.Replace(".vhd","")
            $global:neededVMs.Add($vmName)
   
            Write-Host "    ---- Initiating job to copy VHD $vmName from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $global:workingContainerName -SrcContainer $global:sourceContainerName -DestBlob $targetName -Context $sourceContext -DestContext $destContext

            $global:copyblobs.Add($targetName)
        }
    } else {
        Write-Host "Clearing the destination container..."  -ForegroundColor green
        Get-AzureStorageBlob -Container $global:workingContainerName -blob * | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $global:workingContainerName}  > $null

        foreach ($singleURI in $global:URI) {
            Write-Host "Preparing to copy disk by URI.  Source URI is $singleURI"  -ForegroundColor green

            $splitUri=$singleURI.split("/")
            $lastPart=$splitUri[$splitUri.Length - 1]

            $sourceName = $lastPart
            $targetName = $sourceName | % { $_ -replace ".vhd", "-BORG.vhd" }

            $vmName = $targetName.Replace(".vhd","")

            $global:neededVMs.Add($vmName)

            Write-Host "Initiating job to copy VHD $vhd_name from cache to working directory..." -ForegroundColor Yellow
            $blob = Start-AzureStorageBlobCopy -SrcBlob $sourceName -DestContainer $global:workingContainerName -SrcContainer $global:sourceContainerName -DestBlob $targetName -Context $sourceContext -DestContext $destContext

            $global:copyblobs.Add($targetName)
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
            foreach ($blob in $global:copyblobs) {
                $status = Get-AzureStorageBlobCopyState -Blob $blob -Container $global:workingContainerName -ErrorAction SilentlyContinue
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
            Write-Host "All copy jobs have completed.  Rock on."
        }
    }
}


function launch_azure_vms {
    get-job | Stop-Job  > $null
    get-job | remove-job  > $null
    foreach ($vmName in $global:neededVms) {
        $machine = new-Object MonitoredMachine
        $machine.name = $vmName
        $machine.status = "Booting" # $status
        $global:monitoredMachines.Add($machine)

        $global:num_remaining++
        $jobname=$vmName + "-VMStart"
        # launch_single_vm($vmName)

        $machine_log = New-Object MachineLogs
        $machine_log.name = $vmName
        $machine_log.job_name = $jobname
        $global:machineLogs.Add($machine_log)        

        $resourceGroup="smoke_working_resource_group"
        $storageAccount="smokeworkingstorageacct"
        $containerName="vhds-under-test"

        Start-Job -Name $jobname -ScriptBlock { c:\Framework-Scripts\launch_single_azure_vm.ps1 -resourceGroup $args[0] -storageAccount $args[1] -containerName $args[2] -vmName $args[3]} -ArgumentList @($resourceGroup),@($storageAccount),@($containerName),@($vmName)
    }

    foreach ($machineLog in $global:machineLogs) {
            [MachineLogs]$singleLog=$machineLog
    
        $jobname=$singleLog.job_name
        $jobStatus=get-job -Name $jobName
        $jobState = $jobStatus.State
        
        if ($jobState -eq "Failed") {
            Write-Host "----> Azure boot Job $jobName failed to lanch.  Error information is $jobStatus.Error" -ForegroundColor yellow
            $global:failed = 1
            $global:num_remaining--
            if ($global:num_remaining -eq 0) {
                $global:completed = 1
            }                        
        }
        elseif ($jobState -eq "Completed")
        {
            Write-Host "----> Azure boot job $jobName completed while we were waiting.  We will check results later." -ForegroundColor green
            $global:num_remaining--
            if ($global:num_remaining -eq 0) {
                $global:completed = 1
            }
        }
        else
        {
            Write-Host "      Azure boot job $jobName launched successfully." -ForegroundColor green
        }    
    }
}

$action={
    function checkMachine ([MonitoredMachine]$machine) {
        $machineName=$machine.name
        $machineStatus=$machine.status
        $machineIP=$machine.ipAddress

        if ($machineStatus -eq "Completed" -or $global:num_remaining -eq 0) {
            Write-Host "    **** Machine $machineName is in state $machineStatus, which is complete, or there are no remaining machines" -ForegroundColor green
            return 0
        }

        if ($machineStatus -ne "Booting") {
            Write-Host "    **** ??? Machine $machineName was not in state Booting.  Cannot process" -ForegroundColor red
            return 1
        }        

        $failed=0

        #
        #  Attempt to create the PowerShell PSRP session
        #
        $machineIsUp = $false
        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine

            if ($localMachine.Name -eq $machineName) {
                $haveAddress = $false
                while ($haveAddress -eq $false) {
                    $ip=Get-AzureRmPublicIpAddress -ResourceGroupName $global:workingResourceGroupName -Name $localMachine.Name
                    if ($? -eq $false) {
                        sleep 10
                        Write-Host "Waiting for machine $machineName to accept connections..."
                    } else {
                        $haveAddress = $true
                    }
                }
                $ipAddress=$ip.IpAddress
                $localMachine.ipAddress = $ipAddress

                # Write-Host "Creating PowerShell Remoting session to machine at IP $ipAddress"  -ForegroundColor green
                if ($localMachine.session -eq $null) {
                    $localMachine.session=new-PSSession -computername $localMachine.ipAddress -credential $global:cred -authentication Basic -UseSSL -Port 443 -SessionOption $global:o -ErrorAction SilentlyContinue
                
                    if ($? -eq $true) {
                        $machineIsUp = $true
                    } else {
                        return 0
                    }
                }
                break
            }
        }

        $localSession = $localMachine.session
        try {            
            $installed_vers=invoke-command -session $localSession -ScriptBlock {/bin/uname -r}
            # Write-Host "$machineName installed version retrieved as $installed_vers" -ForegroundColor Cyan
        }
        Catch
        {
            # Write-Host "Caught exception attempting to verify Azure installed kernel version.  Aborting..." -ForegroundColor red
            $installed_vers="Unknown"
            Remove-PSSession -Session $localSession > $null
            $localMachine.session = $null
        }

        #
        #  Now, check for success
        #
        $expected_verDeb=Get-Content C:\temp\expected_version_deb -ErrorAction SilentlyContinue
        $expected_verCent=Get-Content C:\temp\expected_version_centos -ErrorAction SilentlyContinue

        $global:booted_version = $expected_verDeb
        if ($expected_verDeb -eq "") {
            if ($expected_verCent -eq "") {
                $global:booted_version = "Unknown"
            } else {
                $global:booted_version = $expected_verCent
            }
        } else {
            $global:booted_version = $expected_verDeb
        }

        # Write-Host "Looking for version $expected_verDeb or $expected_verCent"

        if (($expected_verDeb.CompareTo($installed_vers) -ne 0) -and ($expected_verCent.CompareTo($installed_vers) -ne 0)) {
            if (($global:elapsed % $global:boot_timeout_intervals_per_minute) -eq 0) {
                Write-Host "     Machine $machineName is up, but the kernel version is $installed_vers when we expected" -ForegroundColor Cyan
                Write-Host "             something like $expected_verCent or $expected_verDeb.  Waiting to see if it reboots." -ForegroundColor Cyan
                Write-Host ""
            }
            # Write-Host "(let's see if there is anything running with the name Kernel on the remote machine)"
            # invoke-command -session $localMachine.session -ScriptBlock {ps -efa | grep -i linux}
        } else {
            Write-Host "    *** Machine $machineName came back up as expected.  kernel version is $installed_vers" -ForegroundColor green
            $localMachine.Status = "Completed"
            $global:num_remaining--
        }
    }

    if ($global:timer_is_running -eq 0) {
        return
    }

    $global:elapsed=$global:elapsed+$global:interval
    # Write-Host "Checking elapsed = $global:elapsed against interval limit of $global:boot_timeout_intervals" -ForegroundColor Yellow

    if ($global:elapsed -ge $global:boot_timeout_intervals) {
        Write-Host "Elapsed is $global:elapsed"
        Write-Host "Intervals is $global:boot_timeout_intervals"
        Write-Host "Timer has timed out." -ForegroundColor red
        $global:completed=1
    }

    #
    #  Check for Hyper-V completion
    #
    foreach ($localMachine in $global:monitoredMachines) {
        [MonitoredMachine]$monitoredMachine=$localMachine
        $monitoredMachineName=$monitoredMachine.name
        $monitoredMachineStatus=$monitoredMachine.status

        foreach ($localLog in $global:machineLogs) {
            [MachineLogs]$singleLog=$localLog

            #
            #  Don't even try if the new-vm hasn't completed...
            #
            $jobStatus=$null
            if ($singleLog.name -eq $monitoredMachineName) {
                $jobStatus = get-job $singleLog.job_name
                if ($? -eq $true) {
                    $jobStatus = $jobStatus.State
                } else {
                    $jobStatus = "Unknown"
                }
               
                if ($jobStatus -ne $null -and ($jobStatus -eq "Completed" -or $jobStatus -eq "Failed")) {
                    if ($jobStatus -eq "Completed") {
                        if ($monitoredMachineStatus -ne "Completed") {
                            checkMachine $monitoredMachine
                        }
                    } elseif ($jobStatus -eq "Failed") {
                        Write-Host "Job to start VM $monitoredMachineName failed.  Any log information provided follows:"
                        receive-job $jobname
                    }
                } elseif ($jobStatus -eq $null -and $monitoredMachineStatus -ne "Completed") {
                    checkMachine $monitoredMachine
                }
            }
        }
    }

    if ($global:num_remaining -eq 0) {
        $global:completed=1
    }

    if (($global:elapsed % 10000) -eq 0) {
        if ($global:num_remaining -eq 0) {
            Write-Host "***** All machines have reported in."  -ForegroundColor magenta
            if ($global:failed -eq $true) {
                Write-Host "One or more machines have failed to boot.  This job has failed." -ForegroundColor Red
            }
            Write-Host "Stopping the timer" -ForegroundColor green
            $global:completed=1
        }

        Write-Host ""
        Write-Host "Waiting for remote machines to complete all testing.  There are $global:num_remaining machines left.." -ForegroundColor green

        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine

            $monitoredMachineName=$monitoredMachine.name
            $monitoredMachineStatus=$monitoredMachine.status

            $calledIt = $false
            foreach ($localLog in $global:machineLogs) {
                [MachineLogs]$singleLog=$localLog

                $singleLogName = $singleLog.name
                $singleLogJobName = $singleLog.job_name

                if ($singleLogName -eq $monitoredMachineName) {
                    if ($monitoredMachine.status -ne "Completed") {
                        $jobStatusObj = get-job $singleLogJobName -ErrorAction SilentlyContinue
                        if ($? -eq $true) {
                            $jobStatus = $jobStatusObj.State
                        } else {
                            $jobStatus = "Unknown"
                        }
                    } else {
                        $jobStatus = "Completed"
                    }
               
                    if ($jobStatus -eq "Completed" -or $jobStatus -eq "Failed") {
                        if ($jobStatus -eq "Completed") {
                           if ($monitoredMachineStatus -eq "Completed") {
                                Write-Host "    *** Machine $monitoredMachineName has completed..." -ForegroundColor green
                                $calledIt = $true
                            } else {
                                Write-Host "    --- Testing of machine $monitoredMachineName is in progress..." -ForegroundColor Yellow
                                if ($monitoredMachine.session -eq $null) {
                                    $monitoredMachine.session=new-PSSession -computername $monitoredMachine.ipAddress -credential $global:cred -authentication Basic -UseSSL -Port 443 -SessionOption $global:o -ErrorAction SilentlyContinue
                
                                    if ($? -eq $true) {
                                        $machineIsUp = $true
                                    } else {
                                        $monitoredMachine.session = $null
                                    }
                                }

                                if ($monitoredMachine.session -ne $null) {
                                    $localSession = $localMachine.session
                                    Write-Host "          Last three lines of the log file for machine $monitoredMachineName ..." -ForegroundColor Magenta   
                                    try {             
                                        $last_lines=invoke-command -session $localSession -ScriptBlock { get-content /opt/microsoft/borg_progress.log  | Select-Object -last 3 }
                                        if ($? -eq $true) {
                                            $last_lines | write-host -ForegroundColor Magenta
                                        } else {
                                            Write-Host "      +++ Error when attempting to retrieve the log file from the remote host.  It may be rebooting..." -ForegroundColor Yellow
                                        }
                                    }
                                    catch
                                    {
                                        Write-Host "    +++ Error when attempting to retrieve the log file from the remote host.  It may be rebooting..." -ForegroundColor Yellow
                                    }
                                }
                                $calledIt = $true
                            }                          
                        } elseif ($jobStatus -eq "Failed") {
                            Write-Host "    *** Job $singleLogName failed to start." -ForegroundColor Red
                            Write-Host "        Log information, if any, follows:" -ForegroundColor Red
                            receive-job $singleLogJobName 
                            $calledIt = $true
                        }                      
                    } elseif ($jobStatusObj -ne $null) {
                        $message="    --- The job starting VM $monitoredMachineName has not completed yet.  The current state is " + $jobStatus
                        Write-Host $message -ForegroundColor Yellow
                        $calledIt = $true
                    }
                    
                    break
                }
            }

            if ($calledIt -eq $false -and $monitoredMachineStatus -ne "Completed") {
                Write-Host "--- Machine $monitoredMachineName has not completed yet" -ForegroundColor yellow
            }                                  
        }
    }
    [Console]::Out.Flush() 
}

unregister-event AzureBORGTimer -ErrorAction SilentlyContinue

Write-Host "    " -ForegroundColor green
Write-Host "                 **********************************************" -ForegroundColor yellow
Write-Host "                 *                                            *" -ForegroundColor yellow
Write-Host "                 *            Microsoft Linux Kernel          *" -ForegroundColor yellow
Write-Host "                 *     Basic Operational Readiness Gateway    *" -ForegroundColor yellow
Write-Host "                 * Host Infrastructure Validation Environment *" -ForegroundColor yellow
Write-Host "                 *                                            *" -ForegroundColor yellow
Write-Host "                 *           Welcome to the BORG HIVE         *" -ForegroundColor yellow
Write-Host "                 **********************************************" -ForegroundColor yellow
Write-Host "    "
Write-Host "          Initializing the CUBE (Customizable Universal Base of Execution)" -ForegroundColor yellow
Write-Host "    "

#
#  Clean up the sentinel files
#
Write-Host "   "
Write-Host "                                BORG CUBE is initialized"                   -ForegroundColor Yellow
Write-Host "              Starting the Dedicated Remote Nodes of Execution (DRONES)" -ForegroundColor yellow
Write-Host "    "

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx' > $null

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4" > $null
Set-AzureRmCurrentStorageAccount –ResourceGroupName $global:sourceResourceGroupName –StorageAccountName $global:sourceStorageAccountName > $null

#
#  Copy the virtual machines to the staging container
#                
copy_azure_machines

#
#  Launch the virtual machines
#                
launch_azure_vms
write-host "$global:num_remaining machines have been launched.  Waiting for completion..."

#
#  Wait for the machines to report back
#    
unregister-event AzureBORGTimer -ErrorAction SilentlyContinue     > $null       
Write-Host "                          Initiating temporal evaluation loop (Starting the timer)" -ForegroundColor yellow
Register-ObjectEvent -InputObject $timer -EventName elapsed –SourceIdentifier AzureBORGTimer -Action $action > $null
$global:timer_is_running=1
$timer.Interval = 1000
$timer.Enabled = $true
$timer.start()

Write-Host "Finished launching the VMs.  Completed is $global:completed" -ForegroundColor Yellow
while ($global:completed -eq 0) {
    start-sleep -s 1
}

Write-Host ""
Write-Host "                         Exiting Temporal Evaluation Loop (Unregistering the timer)" -ForegroundColor yellow
Write-Host ""
$global:timer_is_running=0
$timer.stop()
unregister-event AzureBORGTimer > $null

if ($global:num_remaining -eq 0) {
    Write-Host "                          All machines have come back up.  Checking results." -ForegroundColor green
    Write-Host ""
    
    if ($global:failed -eq $true) {
        Write-Host "     Failures were detected in reboot and/or reporting of kernel version.  See log above for details." -ForegroundColor red
        Write-Host "                                             BORG TESTS HAVE FAILED!!" -ForegroundColor red
    } else {
        Write-Host "     All machines rebooted successfully to some derivitive of kernel version $global:booted_version" -ForegroundColor green
        Write-Host "                                  BORG has been passed successfully!" -ForegroundColor green
    }
} else {
        Write-Host "                              Not all machines booted in the allocated time!" -ForegroundColor red
        Write-Host ""
        Write-Host " Machines states are:" -ForegroundColor red
        foreach ($localMachine in $global:monitoredMachines) {
            [MonitoredMachine]$monitoredMachine=$localMachine
            $monitoredMachineName=$monitoredMachine.name
            $monitoredMachineState=$monitoredMachine.status
            if ($monitoredMachineState -ne "Completed") {
                
                if ($monitoredMachine.session -ne $null) {
                    Write-Host "  --- Machine $monitoredMachineName is in state $monitoredMachineState.  This is the log, if any:" -ForegroundColor red 
                    $log_lines=invoke-command -session $monitoredMachine.session -ScriptBlock { get-content /opt/microsoft/borg_progress.log } -ErrorAction SilentlyContinue
                    if ($? -eq $true) {
                        $log_lines | write-host -ForegroundColor Magenta
                    }
                } else {
                    Write-Host "     --- No remote log available.  Either the machine is off-line or the log was not created." -ForegroundColor Red
                }
            } else {
                Write-Host Machine "  --- Machine $monitoredMachineName is in state $monitoredMachineState" -ForegroundColor green
            }
            $global:failed = 1
        }
    }

Write-Host ""

if ($global:failed -eq 0) {    
    Write-Host "                                    BORG is Exiting with success.  Thanks for Playing" -ForegroundColor green
    exit 0
} else {
    Write-Host "                                    BORG is Exiting with failure.  Thanks for Playing" -ForegroundColor red
    exit 1
}
