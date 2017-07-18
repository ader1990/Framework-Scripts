param (
    [Parameter(Mandatory=$true)] [string] $vmName="Unknown",
    [Parameter(Mandatory=$true)] [string] $resourceGroup="smoke_working_resource_group",
    [Parameter(Mandatory=$true)] [string] $storageAccount="smokeworkingstorageacct",
    [Parameter(Mandatory=$true)] [string] $containerName="vhds-under-test"
)

Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'
Select-AzureRmSubscription -SubscriptionId "2cd20493-fe97-42ef-9ace-ab95b63d82c4"
Set-AzureRmCurrentStorageAccount –ResourceGroupName $resourceGroup –StorageAccountName $storageAccount

# try {
    echo "Making sure the VM is stopped..."  
    Stop-AzureRmVM -Name $vmName -ResourceGroupName $resourceGroup -Force -ErrorAction SilentlyContinue

    echo "Deleting any existing VM"
    Remove-AzureRmVM -Name $vmName -ResourceGroupName $resourceGroup -Force -ErrorAction SilentlyContinue

    echo "Creating a new VM config..."   
    $vm=New-AzureRmVMConfig -vmName $vmName -vmSize 'Standard_D2'

    echo "Assigning resource group $resourceGroup network and subnet config to new machine" 
    $VMVNETObject = Get-AzureRmVirtualNetwork -Name SmokeVNet -ResourceGroupName $resourceGroup
    $VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig -Name SmokeSubnet-1 -VirtualNetwork $VMVNETObject

    echo "Assigning the public IP address"  
    $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $vmName-pip -ErrorAction SilentlyContinue
    if ($? -eq $false) {
        Write-Host "Creating new IP address..."
        New-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Location westus -Name $vmName-pip -AllocationMethod Dynamic -IdleTimeoutInMinutes 4
        $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $vmName-pip
    }

    echo "Assigning the network interface"  
    $VNIC = Get-AzureRmNetworkInterface -Name $vmName-nic -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
    if ($? -eq $false) {
        Write-Host "Creating new network interface"
        New-AzureRmNetworkInterface -Name $vmName-nic -ResourceGroupName $resourceGroup -Location westus -SubnetId $VMSubnetObject.Id -publicipaddressid $pip.Id
        $VNIC = Get-AzureRmNetworkInterface -Name $vmName-nic -ResourceGroupName $resourceGroup
    }

    echo "Adding the network interface"  
    Add-AzureRmVMNetworkInterface -VM $vm -Id $VNIC.Id

    echo "Getting the source disk URI" 
    $c = Get-AzureStorageContainer -Name $containerName
    $blobName=$vmName + ".vhd"
    $blobURIRaw = $c.CloudBlobContainer.Uri.ToString() + "/" + $blobName

    echo "Setting the OS disk to interface $blobURIRaw" 
    Set-AzureRmVMOSDisk -VM $vm -Name $vmName -VhdUri $blobURIRaw -CreateOption "Attach" -linux
<# }
Catch
{
    echo "Caught exception attempting to create the Azure VM.  Aborting..." 
    return 1
} #>

try {
    echo "Starting the VM"  
    $NEWVM = New-AzureRmVM -ResourceGroupName $resourceGroup -Location westus -VM $vm
    if ($NEWVM -eq $null) {
        echo "FAILED TO CREATE VM!!" 
    } else {
        echo "VM $vmName started successfully..."             
    }
}
Catch
{
    echo "Caught exception attempting to start the new VM.  Aborting..." 
    return 1
}