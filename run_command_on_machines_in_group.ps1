param (
    [Parameter(Mandatory=$false)] [string[]] $requestedNames,
    
    [Parameter(Mandatory=$false)] [string] $destSA="smokesrc",
    [Parameter(Mandatory=$false)] [string] $destRG="smoke_source_resource_group",

    [Parameter(Mandatory=$false)] [string] $suffix="-Runonce-Primed.vhd",

    [Parameter(Mandatory=$false)] [string] $command="unset",
    [Parameter(Mandatory=$false)] [string] $asRoot="false",

    [Parameter(Mandatory=$false)] [string] $location="westus",

    [Parameter(Mandatory=$false)] [int] $retryCount=2
)
    
$destSA = $destSA.Trim()
$destRG = $destRG.Trim()
$suffix = $suffix.Trim()
$asRoot = $asRoot.Trim()
$location = $location.Trim()

. c:\Framework-Scripts\common_functions.ps1
. c:\Framework-Scripts\secrets.ps1

[System.Collections.ArrayList]$vmNames_array
$vmNameArray = {$vmNames_array}.Invoke()
$vmNameArray.Clear()
write-host "Incoming : " $requestedNames
if ($requestedNames -like "*,*") {
    $vmNameArray = $requestedNames.Split(',')
} else {
    $vmNameArray = $requestedNames.Split(' ')
}
Write-Host "After : " $vmNameArray
$suffix = $suffix -replace "_","-"

$commandString = 
{
    param ( $DestRG,
            $DestSA,
            $location,
            $suffix,
            $command,
            $asRoot,
            $vm_name,
            $retryCount
            )

    . C:\Framework-Scripts\common_functions.ps1
    . C:\Framework-Scripts\secrets.ps1

    Start-Transcript C:\temp\transcripts\run_command_on_machines_in_group_$vm_name.log > $null

    login_azure $DestRG $DestSA $location > $null
    #
    #  Session stuff
    #
    $o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
    $cred = make_cred

    $suffix = $suffix.Replace(".vhd","")

    $password="$TEST_USER_ACCOUNT_PASS"

    if ($asRoot -ne $false) {
        $runCommand = "echo $password | sudo -S bash -c `'$command`'"
    } else {
        $runCommand = $command
    }

    $commandBLock=[scriptblock]::Create($runCommand)

    [int]$timesTried = 0
    [bool]$success = $false
    while ($timesTried -lt $retryCount) {
        Write-Debug "Executing remote command on machine $vm_name, resource group $destRG"
        $timesTried = $timesTried + 1
        
        [System.Management.Automation.Runspaces.PSSession]$session = create_psrp_session $vm_name $destRG $destSA $location $cred $o
        if ($? -eq $true -and $session -ne $null) {
            invoke-command -session $session -ScriptBlock $commandBLock -ArgumentList $command
            $success = $true
            break
        } else {
            if ($timesTried -lt $retryCount) {
                Remove-PSSession -Session $session
                Write-Error "    Try $timesTried of $retryCount -- FAILED to establish PSRP connection to machine $vm_name."
            }
        }
        start-sleep -Seconds 10
    }

    if ($session -ne $null) {
        Remove-PSSession -Session $session
    }
    
    Stop-Transcript > $null
}

$commandBLock = [scriptblock]::Create($commandString)

get-job | Stop-Job
get-job | Remove-Job

foreach ($baseName in $vmNameArray) {
    $vm_name = $baseName
    $vm_name = $vm_name -replace ".vhd", ""
    $job_name = "run_command_" + $vm_name

    write-verbose "Executing command on machine $vm_name, resource group $destRG"

    start-job -Name $job_name -ScriptBlock $commandBLock -ArgumentList $DestRG, $DestSA, $location, $suffix, $command, $asRoot, $vm_name, $retryCount > $null
}

$jobFailed = $false
$jobBlocked = $false

Start-Sleep -Seconds 10

$allDone = $false
while ($allDone -eq $false) {
    $allDone = $true
    $numNeeded = $vmNameArray.Count
    $vmsFinished = 0

    foreach ($baseName in $vmNameArray) {
        $vm_name = $baseName
        $vm_name = $vm_name -replace ".vhd", "" 
        $job_name = "run_command_" + $vm_name

        $job = Get-Job -Name $job_name
        $jobState = $job.State

        # write-host "    Job $job_name is in state $jobState" -ForegroundColor Yellow
        if ($jobState -eq "Running") {
            $allDone = $false
        } elseif ($jobState -eq "Failed") {
            Write-Error "**********************  JOB ON HOST MACHINE $vm_name HAS FAILED."
            $jobFailed = $true
            $vmsFinished = $vmsFinished + 1
            receive-job -name job_name -Keep
        } elseif ($jobState -eq "Blocked") {
            Write-Error "**********************  HOST MACHINE $vm_name IS BLOCKED WAITING INPUT.  COMMAND WILL NEVER COMPLETE!!"
            $jobBlocked = $true
            $vmsFinished = $vmsFinished + 1
            receive-job -name job_name -Keep
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

foreach ($baseName in $vmNameArray) {
    $vm_name = $baseName
    $vm_name = $vm_name -replace ".vhd", "" 
    $job_name = "run_command_" + $vm_name

    Write-Host $vm_name :
    Get-Job $job_name | Receive-Job
}

if ($jobFailed -eq $true -or $jobBlocked -eq $true)
{
    exit 1
}

exit 0