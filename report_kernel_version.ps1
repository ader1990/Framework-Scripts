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

. "/root/Framework-Scripts/secrets.ps1"

#
#  Set up the PSRP session
#
$o = New-PSSessionOption -SkipCACheck -SkipRevocationCheck -SkipCNCheck
$pw=convertto-securestring -AsPlainText -force -string "$TEST_USER_ACCOUNT_PASS"
$cred=new-object -typename system.management.automation.pscredential -argumentlist "$TEST_USER_ACCOUNT_NAME",$pw
$s=new-PSSession -computername lis-f1637.redmond.corp.microsoft.com -credential $cred -authentication Basic -SessionOption $o

#
#  What machine are we on?  This will be our log file name on the host
#
$ourHost=hostname
$c="progress_logs/" + $ourHost

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
    write-verbose "Kernel did not boot into the desired version.  Checking to see if this is a newer version.."
    $boot_again = $false
    $failed = $false
    $oldGrub=get-content /etc/default/grub
    if (Test-Path /bin/rpm) {
        #
        #  rpm-based system
        #
        $kernels = rpm -qa | sls "kernel" | sls 'kernel-[0-9].*'

        $kernelArray = @()
        
        foreach ($kernel in $kernels) {
            $KernelParts = $Kernel -split '-'
            $vers = $kernelParts[1]
        
            if ($kernelArray -contains $vers) {
            } else {
                $kernelArray += $vers
            }
        }

        foreach ($grubLine in $oldGrub) {
            if ($grubLine -match "GRUB_DEFAULT") {
                $parts = $grubLine -split("=")
        
                [int]$parts[1] = [int]$parts[1] + 1
                if ($parts[1] -ge $kernelArray.count) {
                    write-host "No more kernels to try"
                    $failed = $true
                    break
                } else {
                    write-verbose "Downgrading one level"
                    $boot_again = $true
                }
        
                $grubLine = "GRUB_DEFAULT=" + $parts[1]
            }
        
            $grubLine | out-file "/tmp/y" -append -force
        }
    } else {
        $kernels = dpkg --list | sls linux-image        
        $kernelArray = @()
        
        foreach ($kernel in $kernels) {
            $KernelParts = $Kernel -split '\s+'
            $vers = $kernelParts[2]
        
            if ($kernelArray -contains $vers) {
            } else {
                $kernelArray += $vers
            }
        }
        
        foreach ($grubLine in $oldGrub) {
            if ($grubLine -match "GRUB_DEFAULT") {
                $parts = $grubLine -split("=")
        
                [int]$parts[1] = [int]$parts[1] + 1
                if ($parts[1] -ge $kernelArray.count) {
                    write-host "No more kernels to try"
                    $failed = $true
                    break
                } else {
                    write-verbose "Downgrading one level"
                    $boot_again = $true
                }
        
                $grubLine = "GRUB_DEFAULT=" + $parts[1]
            }
        
            $grubLine | out-file "/tmp/y" -append -force
        }
    }
        
    if ($boot_again = $true) {
        copy-Item -Path "/tmp/y" -Destination "/root/runonce.d"
        copy-Item -Path "/root/Framework-Scripts/report_kernel_version.ps1" -Destination "/etc/default/grub"
        PhoneHome "Kernel did not come up with the correct version, but the correct version is listed.  "
        reboot
    } elseif ($failed -eq $true) {
        phoneHome "BORG FAILED because no OS version would boot that match expected..."
        phoneHome "Installed version is $kernel_name"
        phoneHome "Expected version is $expected"
        exit 1
    }
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

