param (
    [Parameter(Mandatory=$true)] [string] $sourceName="Unknown",
    [Parameter(Mandatory=$true)] [string] $configFileName="Unknown",
    [Parameter(Mandatory=$true)] [string] $distro="Smoke-BVT",
    [Parameter(Mandatory=$true)] [string] $testCycle="BVT"
)


$logFileName = "c:\temp\transcripts\" + $sourceName + "_transcript.log"
Start-Transcript $logFileName -Force

. "C:\Framework-Scripts\secrets.ps1"

#
#  Launch the automation
Write-Output "Starting execution of test $testCycle on machine $sourceName" 

Import-AzureRmContext -Path 'C:\Azure\ProfileContext.ctx'
Select-AzureRmSubscription -SubscriptionId "$AZURE_SUBSCRIPTION_ID" 

$tests_failed = $false
Set-Location C:\azure-linux-automation
C:\azure-linux-automation\AzureAutomationManager.ps1 -xmlConfigFile $configFileName -runtests -email –Distro $distro -cycleName $testCycle -UseAzureResourceManager -EconomyMode
if ($? -ne $true) {
    $tests_failed = $true
}

Stop-Transcript

if ($tests_failed -eq $true) {
    exit 1
} else {
    exit 0
}