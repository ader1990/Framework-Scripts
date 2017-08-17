﻿#
#  Run the Basic Operations and Readiness Gateway in Hyper-V.  This script will:
#      - Cleans up any existing VM based on the VHD names
#      - Copy all VHDs from the BaseVHDsPath to WorkingVHDsPath
#      - Create and start in parallel a VM for each VHD. It is assumed that the VHD has a
#        properly configured RunOnce set up
#      - Wait for the VMs to tell us it's done.  The VMs will use PSRP to do a live
#        update of a log file on this machine, and will write a sentinel file
#        when the install succeeds or fails.
#
#  Author: John W. Fawcett, Principal Software Development Engineer, Microsoft
#  Author: Adrian Vladu, Senior Cloud Engineer, Cloudbase Solutions SRL
#

param (
    [Parameter(Mandatory=$false)]
    [string] $BaseVHDsPath="D:\azure_images\",
    [Parameter(Mandatory=$false)]
    [string] $WorkingVHDsPath="D:\working_images\",
    [Parameter(Mandatory=$false)]
    [string] $BootResultsPath="c:\temp\boot_results\",
    [Parameter(Mandatory=$false)]
    [string] $ProgressLogsPath="c:\temp\progress_logs\",
    [Parameter(Mandatory=$false)]
    [switch] $UseChildrenVHD,
    [Parameter(Mandatory=$false)]
    [switch] $SkipCopy,
    [Parameter(Mandatory=$false)]
    [int] $VHDCopyTimeout=200,
    [Parameter(Mandatory=$false)]
    [int] $VMCleanTimeout=20,
    [Parameter(Mandatory=$false)]
    [int] $VMBootTimeout=20,
    [Parameter(Mandatory=$false)]
    [string] $VMNamesDumpFilePath="vm-names.txt"
)

$ErrorActionPreference = "Stop"

function CreateWait-JobFromScript {
    param(
        [Parameter(Mandatory=$true)]
        [String] $ScriptBlock,
        [Parameter(Mandatory=$true)]
        [int] $Timeout = 100,
        [Parameter(Mandatory=$false)]
        [array] $ArgumentList,
        [Parameter(Mandatory=$false)]
        [string] $JobName="Hyperv-Borg-Job-{0}"
        
    )
    $JobName = $JobName -f @(Get-Random 1000000)
    try {
        $s = [Scriptblock]::Create($ScriptBlock)
        $job = Start-Job -Name $JobName -ScriptBlock $s `
            -ArgumentList $ArgumentList
        $jobResult = Wait-Job $job -Timeout $Timeout -Force
        $output = Receive-Job $JobName
        if ($jobResult.State -ne "Completed") {
            throw "Failed to run $JobName with output: $output"
        } else {
            return $output
        }
    } finally {
        Stop-Job $JobName -ErrorAction SilentlyContinue
        Remove-Job $JobName -ErrorAction SilentlyContinue
    }
}

function Cleanup-Environment {
    Write-Host "Cleaning environment before starting BORG..."
    Write-Host "Cleaning up sentinel files..." -ForegroundColor Green
    $completedBootsPath = "C:\temp\completed_boots"
    if (Test-Path $completedBootsPath) {
        Remove-Item -ErrorAction SilentlyContinue "$completedBootsPath\*"
    }
    if (Test-Path $BootResultsPath) {
        Remove-Item -ErrorAction SilentlyContinue "$BootResultsPath\*"
    }
    if (Test-Path $ProgressLogsPath) {
        Remove-Item -ErrorAction SilentlyContinue "$ProgressLogsPath\*"
    }
    Get-Job | Stop-Job | Out-Null
    Get-Job | Remove-Job | Out-Null
    Write-Host "Environment has been cleaned."
}

function Get-VMNames {
    $vhdsFiles = Get-ChildItem "$BaseVHDsPath\*.vhd*" `
        -ErrorAction SilentlyContinue
    $vmNames = @()
    foreach ($vhdFile in $vhdsFiles) {
         $vmNames += $vhdFile.Name.Split('.')[0]
    }
    return $vmNames
}

Workflow Cleanup-VMS {
    param($VMNames, $VMCleanTimeout)
    Write-Output "Cleaning VMs..."
    $errors = 0
    $suffix = Get-Random 1000000
    $scriptBlock = $null
    foreach -parallel ($vmName in $VMNames) {
        $Workflow:scriptBlock = {
            param($VMName)
            Write-Output "Stopping and cleaning machine $VMName."
            Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue | Out-Null
        }
        try {
            $output = CreateWait-JobFromScript -ScriptBlock $Workflow:scriptBlock `
                -ArgumentList @($vmName) -Timeout $VMCleanTimeout `
                -JobName "DeallocateVM-$vmName-$suffix-{0}"
            Write-Output "Job ended with output >> $output <<"
        } catch {
            Write-Output ("Job failed with error: {0}" -f @($_.Message))
            $Workflow:errors += 1
        }
    }
    if ($Workflow:errors) {
        throw "VMs cleanup failed."
    }
    (InlineScript {Write-Host "VMs have been cleaned." -ForegroundColor Green})
}

function Get-ScriptBlockVHDS {
     $scriptBlock = {
        param($VHDFile,
              $BaseVHDsPath,
              $WorkingVHDsPath,
              $UseChildrenVHD
        )
        $from = Join-Path $BaseVHDsPath $vhdFile
        $to = Join-Path $WorkingVHDsPath $vhdFile
        Remove-Item -Path $to -Force -ErrorAction SilentlyContinue | Out-Null
        if (!$UseChildrenVHD) {
            Write-Output "Starting to copy VHD $VHDFile to working directory..."
            $out = Robocopy.exe $BaseVHDsPath $WorkingVHDsPath $VHDFile
            if (!(Test-Path $to)) {
                throw ("$VHDFile could not be copied. Robocopy output: $out." + `
                       "LASTEXITCODE: $LASTEXITCODE")
            } else {
                Write-Output "Finished copying $VHDFile to working directory."
            }
        } else {
            New-VHD -ParentPath $from -Path $to | Out-Null
            Write-Output "Finished creating child vhd: $VHDFile in the working directory."
        }
    }.ToString()
    return $scriptBlock
}

Workflow Copy-VHDS {
    param($BaseVHDsPath, $WorkingVHDsPath, $UseChildrenVHD, $VHDCopyTimeout)
    Write-Output "Copying VHDs..."
    $errors = 0
    $suffix = Get-Random 1000000
    $vhdsFiles = Get-ChildItem "$BaseVHDsPath\*.vhd*" -ErrorAction SilentlyContinue
    $scriptBlock = $null
    foreach -parallel ($vhdFile in $vhdsFiles) {
        $Workflow:scriptBlock = Get-ScriptBlockVHDS
        $VHDFileName = $vhdFile.Name
        try {
            $output = CreateWait-JobFromScript -ScriptBlock $Workflow:scriptBlock `
                -ArgumentList @($VHDFileName, $BaseVHDsPath, $WorkingVHDsPath, $UseChildrenVHD) `
                -Timeout $VHDCopyTimeout -JobName "CopyVHD-$VHDFileName-$suffix-{0}"
            Write-Output "Job ended with output >> $output <<"
        } catch {
            Write-Output ("Job failed with error: {0}" -f @($_.Message))
            $Workflow:errors += 1
        }
    }
    if ($Workflow:errors) {
        throw "Copying VHDS failed."
    }
    (InlineScript {Write-Host "VHDs have been copied."  -ForegroundColor Green})
}

Workflow Create-VMS {
    param($WorkingVHDsPath, $VMBootTimeout, $VMNamesDumpFilePath)
    Write-Output "Creating VMs..."
    $errors = 0
    $suffix = Get-Random 1000000
    $vhdsFiles = Get-ChildItem "$WorkingVHDsPath\*.vhd*" -ErrorAction SilentlyContinue
    $scriptBlock = $null
    $vmsCreated = @()
    foreach -parallel ($vhdFile in $vhdsFiles) {
        $vmName = $vhdFile.Name.Split('.')[0]
        $Workflow:scriptBlock = {
            param($VMName, $VHDPath)
            New-VM -Name $VMName -MemoryStartupBytes 2048MB -Generation 1 `
                -SwitchName "External" -VHDPath $VHDPath | Out-Null
            Set-VM -ProcessorCount 2 -Name $VMName -DynamicMemory:$false
            Set-VMMemory -DynamicMemoryEnabled $false -VMName $VMName
            Enable-VMIntegrationService -Name "*" -VMName $VMName
            Start-VM -Name $VMName
            Write-Output "VM $VMName has been created and started successfully."
        }
        try {
            $output = CreateWait-JobFromScript -ScriptBlock $Workflow:scriptBlock `
                -ArgumentList @($vmName, $vhdFile.FullName) `
                -Timeout $VMBootTimeout -JobName "CreateVM-$vmName-$suffix-{0}"
            Write-Output "Job ended with output >> $output <<"
            $Workflow:vmsCreated += $vmName
        } catch {
            Write-Output ("Job failed with error: {0}" -f @($_.Message))
            $Workflow:errors += 1
        }
    }
    if ($Workflow:errors) {
        throw "VMs creation failed."
    }
    InlineScript {
        Write-Host ("VMs successfully created: {0}" -f @(($USING:vmsCreated -join ",")))
        Out-File -FilePath (Join-Path $USING:WorkingVHDsPath $USING:VMNamesDumpFilePath) `
                 -Encoding "ASCII" -Force -InputObject ($USING:vmsCreated -join "`r`n")
    }
}

function Check-VMS {
    Write-Host "Checking VMs state..."
    Write-Host "Finished checking VMs state."
}

function Main {
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
    Write-Host "   "
    Write-Host "                                BORG CUBE is initialized"                   -ForegroundColor Yellow
    Write-Host "              Starting the Dedicated Remote Nodes of Execution (DRONES)" -ForegroundColor yellow
    Write-Host "    "

    Cleanup-Environment $BootResultsPath $ProgressLogsPath
    $vmNames = Get-VMNames
    Cleanup-VMS -VMNames $vmNames $VMCleanTimeout

    if (!$SkipCopy) {
        Copy-VHDS $BaseVHDsPath $WorkingVHDsPath $UseChildrenVHD $VHDCopyTimeout
    } else {
        Write-Host "Skipping VHDs copy."
    }

    Create-VMS $WorkingVHDsPath $VMBootTimeout $VMNamesDumpFilePath
    Check-VMS $WorkingVHDsPath
}

Main
