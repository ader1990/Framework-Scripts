
param (
    [Parameter(Mandatory=$true)] [string] $g,
    [Parameter(Mandatory=$true)] [string] $u,
    [Parameter(Mandatory=$true)] [string] $n,
    [Parameter(Mandatory=$true)] [string] $j
)

$logFileName="c:/temp/"+$j +"_download.log"
$localFileName=$n

remove-item -path $logFileName -Force
Write-Host "DownloadSingleVM called for RG $g, URI $u, path $n" | out-file $logFileName 

$nm="azuresmokestoragesccount"

Write-Host "Importing the context...." | out-file $logFileName
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx' | out-file -append $logFileName

Write-Host "Selecting the Azure subscription..." | out-file -append $logFileName
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4" | out-file -Append $logFileName
Set-AzureRmCurrentStorageAccount –ResourceGroupName $g –StorageAccountName $nm | out-file -Append $logFileName

Write-Host "Attempting to save the VM..." | out-file -append $logFileName
Save-AzureRmVhd -Verbose -ResourceGroupName $g -SourceUri $u -LocalFilePath $localFileName -overwrite -NumberOfThreads 10
Write-Host "Attempt complete..." | out-file -append $logFileName
       