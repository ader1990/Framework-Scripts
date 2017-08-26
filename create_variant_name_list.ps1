#
#  Create a set of macines based on variants.  Variants are different machine types (standard_d2_v2), so a set of variant
#  machines all share the same base VHD image, but are (potentially) using different hardware configurations.#
#  Copies VHDs that have booted as expected to the test location where they will be prepped
#  for Azure automation
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string[]] $Flavors="",
    [Parameter(Mandatory=$false)] [string[]] $requestedNames = "",
    [Parameter(Mandatory=$false)] [string] $location = "",
    [Parameter(Mandatory=$false)] [string] $suffix = ""
)

[System.Collections.ArrayList]$vmNames_array
$vmNameArray = {$vmNames_array}.Invoke()
$vmNameArray.Clear()
if ($requestedNames -like "*,*") {
    $vmNameArray = $requestedNames.Split(',')
} else {
    $vmNameArray = $requestedNames
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

if ($flavorsArray.Count -eq 1 -and $flavorsArray[0] -eq "" ) {
Write-Host "Must specify at least one VM Flavor to build..  Unable to process this request."
exit 1
}

. "C:\Framework-Scripts\common_functions.ps1"
. "C:\Framework-Scripts\secrets.ps1"

foreach ($vmName in $vmNameArray) {
    foreach ($oneFlavor in $flavorsArray) {
        $regionSuffix = ("---" + $location + "-" + $oneFlavor.ToLower()) -replace " ","-"
        $regionSuffix = $regionSuffix -replace "_","-"

        $imageName = $vmName + $regionSuffix
        $imageName = $imageName + $suffix
        $imageName = $imageName  -replace ".vhd", ""

        $all_vmNameArray += $imageName
    }
}

return $all_vmNameArray