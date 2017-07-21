param (
    [Parameter(Mandatory=$true)] [string] $vmName="Unknown",
    [Parameter(Mandatory=$true)] [string] $resourceGroup="smoke_working_resource_group",
    [Parameter(Mandatory=$true)] [string] $storageAccount="smokeworkingstorageacct",
    [Parameter(Mandatory=$true)] [string] $containerName="vhds-under-test",

    [Parameter(Mandatory=$false)] [string] $network="SmokeVNet",
    [Parameter(Mandatory=$false)] [string] $subnet="SmokeSubnet-1",
    [Parameter(Mandatory=$false)] [string] $Location="westus",

    [Parameter(Mandatory=$false)] [switch] $addAdminUser,
    [Parameter(Mandatory=$false)] [string] $adminUser="mstest",
    [Parameter(Mandatory=$false)] [string] $adminPW="P@ssW0rd-"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$FRAMEWORK_SCRIPTS = $scriptPath
. "${FRAMEWORK_SCRIPTS}\common_functions.ps1"

login_azure $resourceGroup $storageAccount

echo "Making sure the VM is stopped..."  
Get-AzureRmVm -ResourceGroupName $resourceGroup -status | Where-Object -Property Name -Like "$vmName*" | where-object -Property PowerState -eq -value "VM Running" | Stop-AzureRmVM -Force

echo "Deleting any existing VM"
Get-AzureRmVm -ResourceGroupName $resourceGroup -status | Where-Object -Property Name -Like "$vmName*" | Remove-AzureRmVM -Force

echo "Creating a new VM config..."   
$vm=New-AzureRmVMConfig -vmName $vmName -vmSize 'Standard_DS2_v2'

echo "Assigning resource group $resourceGroup network and subnet config to new machine" 
$VMVNETObject = Get-AzureRmVirtualNetwork -Name $network -ResourceGroupName $resourceGroup
$VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig -Name $subnet -VirtualNetwork $VMVNETObject

echo "Assigning the public IP address"  
$pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $vmName-pip -ErrorAction SilentlyContinue
if ($? -eq $false) {
    Write-Host "Creating new IP address..."
    New-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Location $Location -Name $vmName-pip -AllocationMethod Dynamic -IdleTimeoutInMinutes 4
    $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $resourceGroup -Name $vmName-pip
}

echo "Assigning the network interface"  
$VNIC = Get-AzureRmNetworkInterface -Name $vmName-nic -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
if ($? -eq $false) {
    Write-Host "Creating new network interface"
    New-AzureRmNetworkInterface -Name $vmName-nic -ResourceGroupName $resourceGroup -Location $Location -SubnetId $VMSubnetObject.Id -publicipaddressid $pip.Id
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

try {
    echo "Starting the VM"  
    $NEWVM = New-AzureRmVM -ResourceGroupName $resourceGroup -Location $Location -VM $vm
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

# if ($addAdminUser -eq $true) {
#     $pw = convertto-securestring -AsPlainText -force -string $adminPW
#     $cred = new-object -typename system.management.automation.pscredential -argumentlist "mstest",$pw
# 
#     Set-AzureRmVMAccessExtension -UserName $adminUser -Password $adminPW -ResourceGroupName $resourceGroup -VMName $vmName 
# }