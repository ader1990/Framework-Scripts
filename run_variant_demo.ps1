param (
    [Parameter(Mandatory=$false)] [switch] $startMachines,
    [Parameter(Mandatory=$false)] [switch] $stopMachines
)

set-location c:\Framework-Scripts
. c:\Framework-Scripts\common_functions.ps1
. c:\Framework-Scripts\secrets.ps1

#
#  First start the machines
$flavors = "Standard_D1_v2,Standard_D3_v2,Standard_D4_v2"
$requestedNames = "OpenLogic-CentOS-73-LAT,Ubuntu1604-LTS-LATEST"
$sourceSA="smokebvtstorageaccount"
$sourceRG="smoke_bvts_resource_group"
$sourceContainer="vhds"

$destSA="variants5"
$destRG="variants_test_5"
$destContainer="running_variants"

$currentSuffix="-generalized.vhd"
$newSuffix = "-Variant.vhd"

$network="SmokeVNet"
$NSG="SmokeNSG"
$subnet="SmokeSubnet-1"
$location="westus"

if ($startMachines -eq $true) {
    #
    #  Step 1:  Instantiate the variants
    .\start_variants.ps1 -sourceSA "smokebvtstorageaccount" -sourceRG $sourceRG -sourceContainer $sourceContainer -sourceSA $sourceSA -destSA $destSA `
                                                            -destRG $destRG -destContainer $destContainer -Flavors $flavors `
                                                            -requestedNames $requestedNames -currentSuffix currentSuffix -newSuffix $newSuffix `
                                                            -network $network -subnet $subnet -NSG $NSG -location $location -Verbose
}

#
#  Now get a list of the running VMs
$variantNames = .\create_variant_name_list.ps1 -Flavors $flavors -requestedNames $requestedNames -location $location -suffix $newSuffix -Verbose

#
#  Run a command across the group
.\run_command_on_machines_in_group.ps1 -requestedNames $variantNames -destSA $destSA -destRG $destRG -suffix "" -command "lscpu" -location $location

#
#  If desired, shut down the topology
if ($stopMachines -eq $true) {
    deallocate_machines_in_list $requestedNames $destRG $destSA $location
}

write-host "Thanks for playing!" -foregroundcolor green