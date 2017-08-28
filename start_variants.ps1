#
#  Create a set of macines based on variants.  Variants are different machine types (standard_d2_v2), so a set of variant
#  machines all share the same base VHD image, but are (potentially) using different hardware configurations.#
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
    [Parameter(Mandatory=$false)] [string] $destContainer="vhds-under-test",

    [Parameter(Mandatory=$false)] [string[]] $Flavors="",
    [Parameter(Mandatory=$false)] [string[]] $requestedNames = "",
    
    [Parameter(Mandatory=$false)] [string] $currentSuffix="-booted-and-verified.vhd",
    [Parameter(Mandatory=$false)] [string] $newSuffix="-variant.vhd",

    [Parameter(Mandatory=$false)] [string] $network="smokeVNet",
    [Parameter(Mandatory=$false)] [string] $subnet="SmokeSubnet-1",
    [Parameter(Mandatory=$false)] [string] $NSG="SmokeNSG",
    [Parameter(Mandatory=$false)] [string] $location="westus"
)

$sourceSA = $sourceSA.Trim()
$sourceRG = $sourceRG.Trim()
$sourceContainer = $sourceContainer.Trim()
$destSA = $destSA.Trim()
$destRG = $destRG.Trim()
$destContainer = $destContainer.Trim()
$Flavors = $Flavors.Trim()
$requestedNames  = $requestedNames.Trim()
$currentSuffix = $currentSuffix.Trim()
$newSuffix = $newSuffix.Trim()
$network = $network.Trim()
$subnet = $subnet.Trim()
$NSG = $NSG.Trim()
$location = $location.Trim()

[System.Collections.ArrayList]$vmNames_array
$vmNameArray = {$vmNames_array}.Invoke()
$vmNameArray.Clear()
if ($requestedNames -like "*,*") {
    $vmNameArray = $requestedNames.Split(',')
} else {
    $vmNameArray += $requestedNames
}

[System.Collections.ArrayList]$all_vmNames_array
$all_vmNameArray = {$vmNames_array}.Invoke()
$all_vmNameArray.Clear()

[System.Collections.ArrayList]$flavors_array
$flavorsArray = {$flavors_array}.Invoke()
$flavorsArray.Clear()
if ($Flavors -like "*,*") {
    $flavorsArray = $Flavors.Split(',')
} else {
    $flavorsArray = $Flavors
}

$vmName = $vmNameArray[0]
if ($makeDronesFromAll -ne $true -and ($vmNameArray.Count -eq 1  -and $vmName -eq "")) {
    Write-Host "Must specify either a list of VMs in RequestedNames, or use MakeDronesFromAll.  Unable to process this request."
    exit 1
}

if ($flavorsArray.Count -eq 1 -and $flavorsArray[0] -eq "" ) {
Write-Host "Must specify at least one VM Flavor to build..  Unable to process this request."
exit 1
}

. "C:\Framework-Scripts\common_functions.ps1"
. "C:\Framework-Scripts\secrets.ps1"

login_azure $sourceRG $sourceSA $location

$timeStarted = Get-Date -Format s

$blobs = Get-AzureStorageBlob -Container $sourceContainer

$failed = $false

$comandScript = {
    param ($vmName,
            $sourceRG,
            $sourceSA,
            $sourceContainer,
            $destRG,
            $destSA,
            $destContainer,
            $location,
            $currentSuffix,
            $newSuffix,
            $NSG,
            $network,
            $subnet,
            $vmFlavor,
            $timeStarted
    )

    $logFileName = "c:\temp\transcripts\start_variants_scriptblock-" + $vmName + "-" + $vmFlavor + "-" + $timeStarted
    Start-Transcript $logFileName -Force

    . "C:\Framework-Scripts\common_functions.ps1"
    . "C:\Framework-Scripts\secrets.ps1"

    login_azure $destRG $destSA $location

    $blobs = Get-AzureStorageBlob -Container $sourceContainer

    $blobName = "Unset"
    foreach ($blob in $blobs) {
        $blobName = $blob.Name
        if ($blobName.contains($vmName)) {
            break
        }
    }

    if ($startMachines -eq $true) {
        Write-verbose "Deallocating machine $vmName, if it is up"
        $runningMachines = Get-AzureRmVm -ResourceGroupName $destRG -status | Where-Object -Property Name -Like "$vmName*"
        deallocate_machines_in_group $runningMachines $destRG $destSA $location

        foreach ($blob in $blobs) {
            $blobName = $blob.Name
            $vmSearch = "^" + $vmName + "*"
            if ($blob.Name -like $vmName) {
                $sourceVhdName = $blobName
            }
        }

        $sourceURI = ("https://{0}.blob.core.windows.net/{1}/{2}" -f @($sourceSA, $sourceContainer, $blobName))

        $vmFlavLow = $vmFlavor.ToLower()
        Write-verbose "Attempting to create virtual machine $newVMName from source URI $sourceURI.  This may take some time."
        C:\Framework-Scripts\launch_single_azure_vm.ps1 -vmName $newVMName -resourceGroup $destRG -storageAccount $destSA -containerName $destContainer `
                                                    -network $network -subnet $subnet -NSG $NSG -Location $location -VMFlavor $vmFlavLow -suffix $newSuffix `
                                                    -imageIsGeneralized -generalizedBlobURI $sourceURI
        if ($? -ne $true) {
            Write-error "Error creating VM $newVMName.  This VM must be manually examined!!"
            Stop-Transcript
            exit 1
        }
    }

    #
    #  Just because it's up doesn't mean it's accepting connections yet.  Wait 2 minutes, then try to connect.  I tried 1 minute,
    #  but kept getting timeouts on the Ubuntu machines.
    $regionSuffix = ("-" + $location + "-" + $vmFlavor.ToLower()) -replace " ","-"
    $regionSuffix = $regionSuffix -replace "_","-"
    $imageName = $newVMName + $regionSuffix
    $imageName = $imageName + $newSuffix
    $imageName = $imageName -replace ".vhd", ""

    $machineIsUp = $false
    [int]$sleepCount = 0
    while ($false -eq $machineIsUp -and $sleepCount -lt 30) {
        $machineIsUp = $true
        $sleepCount = $sleepCount + 1
        $pipName = $imageName
        $ip=(Get-AzureRmPublicIpAddress -ResourceGroupName $destRG -Name $pipName).IpAddress
        if ($ip -eq $null -or $ip.ToLower() -eq "not assigned") {
            $machineIsIP = $false
            start-sleep -Seconds 10
        } else {
            $machineIsUp = $true
            break
        }
    }

    if ($true -ne $machineIsUp) {
        Write-errpr "Error getting IP address for VM $newVMName.  This VM must be manually examined!!"
        Stop-Transcript
        exit 1
    }
}

$scriptBlock = [scriptblock]::Create($comandScript)

[System.Collections.ArrayList]$copyblobs_array
$copyblobs = {$copyblobs_array}.Invoke()
$copyblobs.clear()

foreach ($vmName in $vmNameArray) {
    $blobName = $vmName
    $copyblobs += $blobName

    write-verbose "Starting variants for machine $blobName"
    foreach ($oneFlavor in $flavorsArray) {
        $vmJobName = "start_" + $oneFlavor + $blobName

        write-verbose "Launching job to start machine $blobName in flavor $oneFlavor"
        Start-Job -Name $vmJobName -ScriptBlock $scriptBlock -ArgumentList $blobName, $sourceRG, $sourceSA, $sourceContainer,`
                                                                           $destRG, $destSA, $destContainer, $location,`
                                                                           $currentSuffix, $newSuffix, $NSG, $network, `
                                                                           $subnet, $oneFlavor, $timeStarted
    }
}

Start-Sleep -Seconds 10

$allDone = $false
while ($allDone -eq $false) {
    $allDone = $true
    $numNeeded = $vmNameArray.Count
    $vmsFinished = 0

    foreach ($vmName in $vmNameArray) {
        
        $blobName = $vmName
        
        $blobName = $blobName.replace(".vhd","")

        foreach ($oneFlavor in $flavorsArray) {
            $vmJobName = "start_" + $oneFlavor + $blobName
            $job = Get-Job -Name $vmJobName
            $jobState = $job.State
            
            if ($jobState -eq "Running") {
                write-host "    Job $vmJobName is in state $jobState" -ForegroundColor Yellow
                $allDone = $false
                $logFileName = "c:\temp\transcripts\start_variants_scriptblock-" + $vmName + "-" + $vmFlavor + "-" + $timeStarted
                $logLines = Get-Content -Path $logFile -Tail 5
                if ($? -eq $true) {
                    Write-Host "         Last 5 lines from log file $logFile :" -ForegroundColor Cyan
                    foreach ($line in $logLines) {
                        write-host "        "$line -ForegroundColor Gray
                    }
                }
            } elseif ($jobState -eq "Failed") {
                write-host "    Job $vmJobName is in state $jobState" -ForegroundColor red
                write-host "**********************  JOB ON HOST MACHINE $vmJobName HAS FAILED TO START." -ForegroundColor Red
                # $jobFailed = $true
                $vmsFinished = $vmsFinished + 1
                $Failed = $true
            } elseif ($jobState -eq "Blocked") {
                write-host "    Job $vmJobName is in state $jobState" -ForegroundColor magenta
                write-host "**********************  HOST MACHINE $vmJobName IS BLOCKED WAITING INPUT.  COMMAND WILL NEVER COMPLETE!!" -ForegroundColor Red
                # $jobBlocked = $true
                $vmsFinished = $vmsFinished + 1
                $Failed = $true
            } else {
                $vmsFinished = $vmsFinished + 1
            }
        }
    }

    if ($allDone -eq $false) {
        Start-Sleep -Seconds 10
    } elseif ($vmsFinished -eq $numNeeded) {
        break
    }
}

if ($Failed -eq $true) {
    Write-Host "We expected $numNeeded machies, but only $vmsFinished completed.  Command has failed." -ForegroundColor Red
    exit 1
} 