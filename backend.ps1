##### Install PowerShell 5 using https://github.com/DarwinJS/ChocoPackages/blob/master/PowerShell/v5.1/tools/ChocolateyInstall.ps1#L107-L173
##### For 2008 R2, run the .ps1 from: https://download.microsoft.com/download/6/F/5/6F5FF66C-6775-42B0-86C4-47D41F2DA187/Win7AndW2K8R2-KB3191566-x64.zip
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptPath\common_functions.ps1"

function Import-ScriptViaDotNotation {
    param($FilePath)
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        throw "File $FilePath does not exist."
    }
}

class Instance {
    [Backend] $Backend
    [String] $Name
    [String] $LogPath = ("$env:SystemDrive\temp\transcripts" + `
                         "\launch_single_azure_vm_{0}.log")
    [String] $DefaultUsername
    [String] $DefaultPassword

    Instance ($Backend, $Name) {
        $transcriptPath = $this.LogPath -f @($Name)
        Start-Transcript -Path $transcriptPath -Force -Append
        $this.Backend = $Backend
        $this.Name = $Name
        Write-Host ("Initialized instance wrapper" + $this.Name) `
            -ForegroundColor Blue
    }

    [void] Cleanup () {
        $this.Backend.CleanupInstance($this.Name)
    }

    [void] CreateFromSpecialized () {
        $this.Backend.CreateInstanceFromSpecialized($this.Name)
    }

    [void] CreateFromURN () {
        $this.Backend.CreateInstanceFromURN($this.Name)
    }

    [void] CreateFromGeneralized () {
        $this.Backend.CreateInstanceFromGeneralized($this.Name)
    }

    [void] StopInstance () {
        $this.Backend.StopInstance($this.Name)
    }

    [void] RemoveInstance () {
        $this.Backend.removeInstance($this.Name)
    }

    [String] GetPublicIP () {
        return $this.Backend.GetPublicIP($this.Name)
    }

    [object] GetVM () {
        return $this.Backend.GetVM($this.Name)
    }

    [String] SetupAzureRG() {
        return $this.Backend.SetupAzureRG()
    }

    [string] WaitForAzureRG() {
        return $this.Backend.WaitForAzureRG( )
    }
}

class AzureInstance : Instance {
    AzureInstance ($Backend, $Name) : base ($Backend, $Name) {}
}

class HypervInstance : Instance {
    HypervInstance ($Params) : base ($Params) {}
}


class Backend {
    [String] $Name="BaseBackend"

    Backend ($Params) {
        Write-Host ("Initialized backend " + $this.Name) -ForegroundColor Blue
    }

    [Instance] GetInstanceWrapper ($InstanceName) {
        Write-Host ("Initializing instance on backend " + $this.Name) `
            -ForegroundColor Green
        return $null
    }

    [void] CreateInstanceFromSpecialized ($InstanceName) {
    }

    [void] CreateInstanceFromURN ($InstanceName) {
    }

    [void] CreateInstanceFromGeneralized ($InstanceName) {
    }

    [void] CleanupInstance ($InstanceName) {
        Write-Host ("Cleaning instance and associated resources on backend {0}" `
                    -f @($this.Name)) -ForegroundColor Red
    }

    [void] RebootInstance ($InstanceName) {
        Write-Host ("Rebooting instance on backend " + $this.Name) `
            -ForegroundColor Green
    }

    [String] GetPublicIP ($InstanceName) {
        Write-Host ("Getting instance public IP a on backend " + $this.Name) `
            -ForegroundColor Green
        return $null
    }

    [object] GetVM($instanceName) {
       Write-Host ("Getting instance VM on backend " + $this.Name) `
           -ForegroundColor Green
       return $null       
    }

    [void] StopInstance($instanceName) {
       Write-Host ("StopInstance VM on backend " + $this.Name) `
           -ForegroundColor Green
    }

    [void] RemoveInstance($instanceName) {
       Write-Host ("RemoveInstance VM on backend " + $this.Name) `
           -ForegroundColor Green
    }

    [Object] GetPSSession($InstanceName) {
        Write-Host ("Getting new Powershell Session on backend " + $this.Name) `
            -ForegroundColor Green
        return $null
    }

    [string] SetupAzureRG() {
        Write-Host ("Setting up Azure Resource Groups " + $this.Name) `
            -ForegroundColor Green
        return $null
    }

    [string] WaitForAzureRG() {
        Write-Host ("Waiting for Azure resource group setup " + $this.Name) `
            -ForegroundColor Green
        return $null
    }
}

class AzureBackend : Backend {
    [String] $Name = "AzureBackend"
    [String] $SecretsPath = "$env:SystemDrive\Framework-Scripts\secrets.ps1"
    [String] $ProfilePath = "$env:SystemDrive\Azure\ProfileContext.ctx"
    [String] $ResourceGroupName = "smoke_working_resource_group"
    [String] $StorageAccountName = "smokework"
    [String] $ContainerName = "vhds-under-test"
    [String] $Location = "westus"
    [String] $VMFlavor = "Standard_D2_V2"
    [String] $NetworkName = "SmokeVNet"
    [String] $SubnetName = "SmokeSubnet"
    [String] $NetworkSecGroupName = "SmokeNSG"
    [String] $addressPrefix = "172.19.0.0/16"
    [String] $subnetPrefix = "172.19.0.0/24"
    [String] $blobURN = $null
    [String] $suffix = "-Smoke-1"

    AzureBackend ($Params) : base ($Params) {
        if (Test-Path $this.SecretsPath) {
            Import-ScriptViaDotNotation $this.SecretsPath
        } else {
            throw "Secrets file $($this.SecretsPath) does not exist."
        }
    }

    [Instance] GetInstanceWrapper ($InstanceName) {
        if (Test-Path $this.SecretsPath) {
            # dot sourcing cannot be mocked, so we need a method here.
            Import-ScriptViaDotNotation $this.SecretsPath
        } else {
            throw "Secrets file does not exist."
        }

        $this.suffix = $this.suffix -replace "_","-"
        login_azure $this.ResourceGroupName $this.StorageAccountName $this.Location
        # TODO(avladu) clean this code
        $regionSuffix = ("-" + $this.Location) -replace " ","-"
        $imageName = $InstanceName + "-" + $this.VMFlavor + $regionSuffix.ToLower()
        $imageName = $imageName -replace "_","-"
        $imageName = $imageName + $this.suffix
        $imageName = $imageName  -replace ".vhd", ""

        $instance = [AzureInstance]::new($this, $imageName)
        return $instance
    }

    [string] SetupAzureRG() {
        #
        #  Avoid potential race conditions
        Write-Host "Getting the NSG"
        $sg = $this.getNSG()

        Write-Host "Getting the network"
        $VMVNETObject = $this.getNetwork($sg)

        Write-Host "Getting the subnet"
        $this.getSubnet($sg, $VMVNETObject)

        return "Success"
    }

    [string] WaitForAzureRG() {
        $azureIsReady = $false
        # add finite number of retries
        while (!$azureIsReady) {
            $sg = Get-AzureRmNetworkSecurityGroup -Name $this.NetworkSecGroupName `
                      -ResourceGroupName $this.ResourceGroupName
            if (!$sg) {
                Start-Sleep -Seconds 10
            } else {
                $VMVNETObject = Get-AzureRmVirtualNetwork -Name $this.NetworkName `
                                    -ResourceGroupName $this.ResourceGroupName
                if (!$VMVNETObject) {
                    Start-Sleep -Seconds 10
                } else {
                    $VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig `
                        -Name $this.SubnetName -VirtualNetwork $VMVNETObject
                    if (!$VMSubnetObject) {
                        Start-Sleep -Seconds 10
                    } else {
                        $azureIsReady = $true
                    }
                }
            }
        }

        return "Success"
    }

    [void] StopInstance ($InstanceName) {
        Write-Host "Stopping machine $InstanceName"
        Stop-AzureRmVM -Name $InstanceName `
                       -ResourceGroupName $this.ResourceGroupName -Force
    }

    [void] RemoveInstance ($InstanceName) { 
        Write-Host "Removing machine $InstanceName"
        Remove-AzureRmVM -Name $InstanceName `
            -ResourceGroupName $this.ResourceGroupName -Force `
            -ErrorAction SilentlyContinue
    }

    [void] CleanupInstance ($InstanceName) {
        $this.RemoveInstance($InstanceName)

        Write-Host "Cleaning machine $InstanceName. Deleting NIC..."
        $VNIC = Get-AzureRmNetworkInterface -Name $InstanceName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if ($VNIC) {
            Remove-AzureRmNetworkInterface -Name $InstanceName `
                -ResourceGroupName $this.ResourceGroupName -Force
        }

        Write-Host "Cleaning machine $InstanceName. Deleting PIP..."
        $pip = Get-AzureRmPublicIpAddress -Name $InstanceName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if ($pip) {
            Remove-AzureRmPublicIpAddress -Name $InstanceName -Force `
                 -ResourceGroupName $this.ResourceGroupName
        }
    }

    [object] GetNSG() {
        $sg = Get-AzureRmNetworkSecurityGroup -Name $this.NetworkSecGroupName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if (!$sg) {
            Write-Host "NSG does not exist. Creating NSG..." `
                -ForegroundColor Yellow
            $rule1 = New-AzureRmNetworkSecurityRuleConfig -Name "ssl-rule"
                -Description "Allow SSL over HTTPS" -Access "Allow" `
                -Protocol "Tcp" -Direction "Inbound" -Priority "100" `
                -SourceAddressPrefix "Internet" -SourcePortRange "*" `
                -DestinationAddressPrefix "*" -DestinationPortRange "443"
            $rule2 = New-AzureRmNetworkSecurityRuleConfig -Name "ssh-rule" `
               -Description "Allow SSH" -Access "Allow" -Protocol "Tcp" `
               -Direction "Inbound" -Priority "101" `
               -SourceAddressPrefix "Internet" -SourcePortRange "*" `
               -DestinationAddressPrefix "*" -DestinationPortRange "22"

            New-AzureRmNetworkSecurityGroup -Name $this.NetworkSecGroupName `
                -Location $this.Location -SecurityRules @($rule1,$rule2) `
                -ResourceGroupName $this.ResourceGroupName

            $sg = Get-AzureRmNetworkSecurityGroup -Name $this.NetworkSecGroupName `
                -ResourceGroupName $this.ResourceGroupName
            Write-Host "NSG created successfully."
        }

        return $sg
    }

    [object] GetNetwork($sg) {
        $VMVNETObject = Get-AzureRmVirtualNetwork -Name $this.NetworkName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if (!$VMVNETObject) {
            Write-Host "Network does not exist for this region. Creating now..." `
                -ForegroundColor Yellow
            $VMSubnetObject = New-AzureRmVirtualNetworkSubnetConfig `
                -Name $this.SubnetName  -AddressPrefix $this.subnetPrefix `
                -NetworkSecurityGroup $sg
            New-AzureRmVirtualNetwork   -Name $this.NetworkName `
                -ResourceGroupName $this.ResourceGroupName `
                -Location $this.Location -AddressPrefix $this.addressPrefix `
                -Subnet $VMSubnetObject
            $VMVNETObject = Get-AzureRmVirtualNetwork -Name $this.NetworkName `
                -ResourceGroupName $this.ResourceGroupName
        }

        return $VMVNETObject
    }

    [object] GetSubnet($sg,$VMVNETObject) {
        $VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig `
            -Name $this.SubnetName -VirtualNetwork $VMVNETObject `
            -ErrorAction SilentlyContinue
        if (!$VMSubnetObject) {
            Write-Host "Subnet does not exist for this region. Creating now..." `
                -ForegroundColor Yellow
            Add-AzureRmVirtualNetworkSubnetConfig -Name $this.SubnetName `
                -VirtualNetwork $VMVNETObject -AddressPrefix $this.subnetPrefix `
                -NetworkSecurityGroup $sg
            Set-AzureRmVirtualNetwork -VirtualNetwork $VMVNETObject 
            $VMVNETObject = Get-AzureRmVirtualNetwork -Name $this.NetworkName `
                -ResourceGroupName $this.ResourceGroupName
            $VMSubnetObject = Get-AzureRmVirtualNetworkSubnetConfig `
                -Name $this.SubnetName -VirtualNetwork $VMVNETObject
        }

        return $VMSubnetObject
    }

    [object] GetPIP($pipName) {
        $pip = Get-AzureRmPublicIpAddress -Name $pipName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue
        if (!$pip) {
            Write-Host "Public IP does not exist for this region. Creating now..." `
                -ForegroundColor Yellow
            New-AzureRmPublicIpAddress -Name $pipName -Location $this.Location `
                -AllocationMethod Dynamic -IdleTimeoutInMinutes 4 `
                -ResourceGroupName $this.ResourceGroupName
            $pip = Get-AzureRmPublicIpAddress -Name $pipName `
                -ResourceGroupName $this.ResourceGroupName
        }

        return $pip
    }

    [object] GetNIC([string] $nicName,
                    [object] $VMSubnetObject, 
                    [object] $pip) {
        $VNIC = Get-AzureRmNetworkInterface -Name $nicName `
            -ResourceGroupName $this.ResourceGroupName `
            -ErrorAction SilentlyContinue

        if (!$VNIC) {
            Write-Host "Creating new network interface" -ForegroundColor Yellow
            New-AzureRmNetworkInterface -Name $nicName `
                -Location $this.Location -SubnetId $VMSubnetObject.Id `
                -PublicIPAddressId $pip.Id `
                -ResourceGroupName $this.ResourceGroupName
            $VNIC = Get-AzureRmNetworkInterface -Name $nicName `
                -ResourceGroupName $this.ResourceGroupName
        }

        return $VNIC
    }

    [void] BaseCreateInstance($InstanceName, $SpecializationScript) {
        Write-Host "Creating a new VM config..." -ForegroundColor Yellow

        $sg = $this.getNSG()
        $VMVNETObject = $this.getNetwork($sg)
        $VMSubnetObject = $this.getSubnet($sg, $VMVNETObject)

        $vm = New-AzureRmVMConfig -VMName $InstanceName -VMSize $this.VMFlavor
        Write-Host ("Assigning network $($this.NetworkName) and subnet config " + `
            " $($this.SubnetName) with NSG $($this.NetworkSecGroupName) to new machine") `
            -ForegroundColor Yellow

        Write-Host "Assigning the public IP address" -ForegroundColor Yellow
        $ipName = $InstanceName
        $pip = $this.getPIP($ipName)

        Write-Host "Assigning the network interface" -ForegroundColor Yellow
        $nicName = $InstanceName
        $VNIC = $this.getNIC($nicName, $VMSubnetObject, $pip)
        $VNIC.NetworkSecurityGroup = $sg
        
        Set-AzureRmNetworkInterface -NetworkInterface $VNIC

        Write-Host "Adding the network interface" -ForegroundColor Yellow
        Add-AzureRmVMNetworkInterface -VM $vm -Id $VNIC.Id
        #
        #  Code specific to a specialized blob
        $blobURIRaw = ("https://{0}.blob.core.windows.net/{1}/{2}.vhd" -f `
                       @($this.StorageAccountName, $this.ContainerName, $InstanceName))
        $vm = Invoke-Command -ScriptBlock $SpecializationScript.GetNewClosure()
        $trying = $true
        $tries = 0
        while ($trying -eq $true) {
            $trying = $false
            try {
                Write-Host "Starting the VM" -ForegroundColor Yellow
                $NEWVM = New-AzureRmVM -ResourceGroupName $this.ResourceGroupName `
                    -Location $this.Location -VM $vm
                if (!$NEWVM) {
                    throw
                } else {
                    Write-Host "VM $InstanceName started successfully..." `
                        -ForegroundColor Green
                }
            } catch {
                Write-Host "Failed to create VM" -ForegroundColor Red
                Start-Sleep -Seconds 30
                $trying = $true
                $tries = $tries + 1
                if ($tries -gt 5) {
                    Stop-Transcript
                    break
                }
            }
        }
    }

    [void] CreateInstanceFromSpecialized ($InstanceName) {
        $this.BaseCreateInstance($instanceName, {
            $vm = Set-AzureRmVMOSDisk -VM $vm -Name $InstanceName `
                -VhdUri $blobURIRaw -CreateOption Attach -Linux
            return $vm
        })
    }

    [void] CreateInstanceFromGeneralized ($InstanceName) {
        $this.BaseCreateInstance($instanceName, {
            $imageConfig = New-AzureRmImageConfig -Location $this.Location
            $imageConfig = Set-AzureRmImageOsDisk -Image $imageConfig `
                -OsType Windows -OsState Generalized -BlobUri $blobURIRaw
            $image = New-AzureRmImage -ImageName $InstanceName `
                -ResourceGroupName $this.ResourceGroupName -Image $imageConfig

            $cred = make_cred_initial
            $vm = Set-AzureRmVMSourceImage -VM $vm -Id $image.Id
            $vm = Set-AzureRmVMOSDisk -VM $vm -DiskSizeInGB 20 `
                -Name $InstanceName -CreateOption fromImage -Caching ReadWrite
            $vm = Set-AzureRmVMOperatingSystem -VM $vm `
                -Windows -ComputerName $InstanceName `
                -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
            return $vm
        })
    }

    [void] CreateInstanceFromURN ($InstanceName) {
        $this.BaseCreateInstance($instanceName, {
            Write-Host "Parsing the blob string " $this.blobURN
            if (!$this.blobURN) {
                throw "Blob URN is not set."
            }
            $blobParts = $this.blobURN.split(":")
            $blobSA = $this.StorageAccountName
            $blobContainer = $this.ContainerName
            $osDiskVhdUri = "https://$blobSA.blob.core.windows.net/$blobContainer/" `
                + $InstanceName + ".vhd"
            $cred = make_cred_initial
            $vm = Set-AzureRmVMOperatingSystem -VM $vm -Linux `
                -ComputerName $InstanceName -Credential $cred
            $vm = Set-AzureRmVMSourceImage -VM $vm `
                 -PublisherName $blobParts[0] -Offer $blobParts[1] `
                 -Skus $blobParts[2] -Version $blobParts[3]
            $vm = Set-AzureRmVMOSDisk -VM $vm -VhdUri $osDiskVhdUri `
                -Name $InstanceName -CreateOption fromImage -Caching ReadWrite
            return $vm
        })
    }

    [String] GetPublicIP ($InstanceName) {
        ([Backend]$this).GetPublicIP($InstanceName)

        $ip = Get-AzureRmPublicIpAddress -Name $InstanceName `
                  -ResourceGroupName $this.ResourceGroupName
        if ($ip) {
            return $ip.IPAddress
        } else {
            return $null
        }
    }

    [Object] GetPSSession ($InstanceName) {
        return ([Backend]$this).GetPSSession()
    }

    [Object] GetVM($instanceName) {
        Write-Host "Getting $InstanceName"
        return (Get-AzureRmVM -Name $InstanceName `
             -ResourceGroupName $this.ResourceGroupName)
    }
}

class HypervBackend : Backend {
    [String] $Name="HypervBackend"

    HypervBackend ($Params) : base ($Params) {}
}


class BackendFactory {
    [Backend] GetBackend([String] $Type, $Params) {
        return (New-Object -TypeName $Type -ArgumentList $Params)
    }
}
