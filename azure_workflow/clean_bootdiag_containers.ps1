
param (
    [Parameter(Mandatory=$false)] [string] $resourceGroup="smoke_working_resource_group",
    [Parameter(Mandatory=$false)] [string] $storageAccount="smokeworkingstorageacct"
)

Write-Host "Cleaning boot diag blobs from storage account $storageAccount, resource group $resourceGroup"

Write-Host "Importing the context...." 
Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'

Write-Host "Selecting the Azure subscription..." 
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4" 
Set-AzureRmCurrentStorageAccount –ResourceGroupName $resourceGroup –StorageAccountName $storageAccount 

$containers=get-azurestoragecontainer
foreach ($container in $containers) {
    if ($container.Name -like "bootdiag*") { 
        Remove-AzureStorageContainer -Force -Name $container.Name  
    }
 }       