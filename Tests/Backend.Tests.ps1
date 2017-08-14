$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$parentPath = Split-Path -Parent $here
. "$parentPath\Backend.ps1"

Describe "Test Azure Backend instance" {
    Mock Test-Path { return $true }
    Mock Import-ScriptViaDotNotation { return $true }
    Mock login_azure { return $true }
    Mock Start-Transcript { return $true }
    Mock Write-Host { return $true }

    $backendFactory = [BackendFactory]::new()
    $azureBackend = $backendFactory.GetBackend("AzureBackend", @(1))
    It "Should create a valid instance wrapper" {
        $azureInstance = $azureBackend.GetInstanceWrapper($vmName)
        $azureInstance | Should Not Be $null
    }

    It "should run all mocked commands" {
        Assert-VerifiableMocks
    }
}