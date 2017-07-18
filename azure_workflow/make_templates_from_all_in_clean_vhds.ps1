#
#  Copies user VHDs it finds for VMs in the reference resource group into the 'clean-vhds' 
#  storage container.  The target blobs will have the name of the VM, as a .vhd
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $sourceSA="smokesourcestorageacct",
    [Parameter(Mandatory=$false)] [string] $sourceRG="smoke_source_resource_group",
    [Parameter(Mandatory=$false)] [string] $sourceContainer="clean-vhds"
)

Write-Host "Importing the context...." -ForegroundColor Green
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

Write-Host "Selecting the Azure subscription..." -ForegroundColor Green
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"

Set-AzureRmCurrentStorageAccount –ResourceGroupName $sourceRG –StorageAccountName $sourceSA
$blobs=get-AzureStorageBlob -Container $sourceContainer -Blob "*-Smoke-1*.vhd"

foreach ($oneblob in $blobs) {
    $sourceName=$oneblob.Name

    $sourceName = $sourceName.Replace("-Smoke-1.vhd","")

    write-Host "Starting job to copy VHD $sourceName to working directory..." -ForegroundColor green
    $jobName=$sourceName + "_copy_job"

    $existingJob = get-job $jobName -ErrorAction SilentlyContinue > $null
    if ($? -eq $true) {
        stop-job $jobName -ErrorAction SilentlyContinue > $null
        remove-job $jobName -ErrorAction SilentlyContinue > $null
    }
 
    Start-Job -Name $jobName -ScriptBlock { C:\Framework-Scripts\make_template_from_clean.ps1 $args[0] } -ArgumentList @($sourceName) > $null
}

$copy_in_progress = $true
while ($copy_in_progress -eq $true) {
    $copy_in_progress = $false

    write-Host "Checking copy progress..." -ForegroundColor green

    foreach ($oneblob in $blobs) {
        $sourceName=$oneblob.Name

        $sourceName = $sourceName.Replace("-Smoke-1.vhd","")

        $jobName=$sourceName + "_copy_job"

        $jobStatus=get-job -Name $jobName -ErrorAction SilentlyContinue
        if ($? -eq $true) {
            $jobState = $jobStatus.State
        } else {
            $jobStatus = "Completed"
        }
        
        if (($jobState -ne "Completed") -and 
            ($jobState -ne "Failed")) {
            Write-Host "      Current state of job $jobName is $jobState" -ForegroundColor yellow
            $copy_in_progress = $true
        }
        elseif ($jobState -eq "Failed")
        {
            $failed = $true
            Write-Host "----> Copy job $jobName exited with FAILED state!" -ForegroundColor red
            Receive-Job -Name $jobName
        }
        else
        {
            Write-Host "***** Copy job $jobName completed successfully." -ForegroundColor green
        }
    }
    sleep 15
}

write-host "All done!"
exit 0