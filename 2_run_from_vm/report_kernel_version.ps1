#!/usr/bin/powershell
#
#  Afterreboot, this script will be executed by runonce.  It checks the booted kernel version against
#  the expected, and returns the result.  If called directly from copy_kernel.ps1, it will be an
#  artificial failure (something happened during install), with the failure point in the argument.
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
param (
    [Parameter(Mandatory=$false)] [string] $failure_point=""
)

function callItIn($c, $m) {
    $output_path="c:\temp\$c"
    
    $m | out-file -Append $output_path
    return
}

function phoneHome($m) {

    invoke-command -session $s -ScriptBlock ${function:callItIn} -ArgumentList $c,$m
}

#
#  Set up the PSRP session
#
$o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$pw=convertto-securestring -AsPlainText -force -string 'P@ssW0rd-'
$cred=new-object -typename system.management.automation.pscredential -argumentlist "mstest",$pw
$s=new-PSSession -computername lis-f1637.redmond.corp.microsoft.com -credential $cred -authentication Basic -SessionOption $o

#
#  What machine are we on?  This will be our log file name on the host
#
$ourHost=hostname
$c="progress_logs/" + $ourHost

$linuxOs = $linuxInfo.ID
phoneHome "Checking for successful kernel installation"

if ($failure_point -eq "") {
    $kernel_name=uname -r
} else {
    $kernel_name = $failure_point
}
 
if (Get-Item -ErrorAction SilentlyContinue -Path /root/expected_version ) {
    $expected=Get-Content /root/expected_version
} 

if (($kernel_name.CompareTo($expected)) -ne 0) {
    phoneHome "Azure insertion cancelled because OS version did not match expected..."
    phoneHome "Installed version is $kernel_name"
    phoneHome "Expected version is $expected"
}

if (($kernel_name.CompareTo($expected)) -ne 0) {

    #
    #  Switch from the log file to the boot results file and log failure, with both expected and found versions
    #
    $c="boot_results/" + $ourHost
    phoneHome "Failed $kernel_name $expected"

    remove-pssession $s

    exit 1
} else {
    phoneHome "Passed.  Let's go to Azure!!"

    #
    #  Switch from the log file to the boot results file and log success, with version
    #
    $c="boot_results/" + $ourHost
    phoneHome "Success $kernel_name"

    remove-pssession $s

    exit 0
}

