#
#  Copy a VHD from the clean-vhds storage container to the safe-templates container, where
#  they have a VM created for them.  The VM should then be booted and make_drone.sh used
#  to turn the thing into a machine we can use.  Make_drone.sh will set up the runonce, with
#  update_and_copy.sh set to be executed as soon as the system boots and cron executes
#  the runonce reboot task.
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$true)] [string] $name
)

$vmName = $name + "-RunOnce-Primed"
$rg="smoke_source_resource_group"

$nm="smokesourcestorageacct"  

$destContainerName = "safe-templates"

Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $rg –StorageAccountName $nm

Write-Host "Attempting to create templeate from $name.  Stopping any running machines..." -ForegroundColor Green
$existingVM=Get-AzureRmVM -name $vmName -ResourceGroupName $rg -ErrorAction SilentlyContinue
if ($?) {
    Write-Host "There was already a VM present and running with the name $vmName.  Stopping and deleting so it can be replaced..." -ForegroundColor Yellow
    Stop-AzureRmVM -Name $vmName -ResourceGroupName $rg -force
    Remove-AzureRmVM -Name $vmName -ResourceGroupName $rg -Force
}

## Global
$location = "westus"

## Storage
$storageType = "Standard_D2"

## Network
$nicname = $name + "-NIC"
$subnet1Name = "SmokeSubnet-1"
$vnetName = "SmokeVNet"
$vnetAddressPrefix = "10.0.0.0/16"
$vnetSubnetAddressPrefix = "10.0.0.0/24"

## Compute

$vmSize = "Standard_A2"

$osDiskName = $vmName + "-osDisk"
$blobURIRaw="https://smokesourcestorageacct.blob.core.windows.net/clean-vhds/" + $name + "-Smoke-1.vhd"
Write-Host "Clearing any old images..." -ForegroundColor Green
Get-AzureStorageBlob -Container $destContainerName -Prefix $name | ForEach-Object {Remove-AzureStorageBlob -Blob $_.Name -Container $destContainerName}
$destUri = $blobURIRaw.Replace("clean-vhds","safe-templates")

Write-Host "Attempting to create virtual machine $vmName.  This may take some time." -ForegroundColor Green
## Setup local VM object
# $cred = Get-Credential
az vm create -n $vmName -g $rg -l $location --os-type linux --image $blobURIRaw --storage-container-name "safe-templates" --use-unmanaged-disk --nsg SmokeNSG `
   --subnet SmokeSubnet-1 --vnet-name SmokeVNet --storage-account $nm --os-disk-name $vmName 