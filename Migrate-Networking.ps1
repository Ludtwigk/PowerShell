$ConfirmPreference = "None"
$ErrorActionPreference = "Continue"

Import-Module -Name VMware.VimAutomation.Core

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCeip:$false -Scope Session | Out-Null

# Global Variables
$sourceVcName = Read-Host "Source vCenter Name: "
$destVcName = Read-Host "Destination vCenter Name: "
$srcClusterName = Read-Host "Source Cluster Name: "
$destClusterName = Read-Host "Destination Cluster Name: "
$srcDvsName = Read-Host "Source Distributed Switch Name: "
$destDvsName = Read-Host "Destination Distributed Switch Name: "
$destDcName= Read-Host "Destination Datacenter Name: "
$vssName = Read-Host "Standard Switch Name: "

# vmnic mapping to the Uplink Ports
$uplinkMappings = @{vmnic1 = "vMotion"; vmnic2="FT"; vmnic3 = "Server1"; vmnic4 = "Server2"}

$conn = Connect-VIServer -Server $sourceVcName

try {
  $cluster = Get-Cluster -Name $srcClusterName
  $vmHosts = $cluster | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected" -or $_.ConnectionState -eq "Maintenance"}
  $dvs = Get-VDSwitch -Name $srcDvsName
  $portgroupsOld = $dvs | Get-VDPortgroup
} catch {
  Write-Error "Cluster or DVSwitch couldn't be found, exiting..."
  [Environment]::Exit(1)
}

try {
  $cluster | Set-Cluster -DrsAutomationLevel Manual | Out-Null
  Write-Host "$([char]8730) Cluster DRS Automation Level was set to Manual"
} catch {
  Write-Host "$([char]215) Cluster DRS Automation Level couldn't be set to Manual, exiting..."
  [Environment]::Exit(1)
}

function Clone-DvsToVss {
  Write-Host "`nCloning the Distributed Switch and its Portgroups to a Standard Switch`n"

  $portgroups = $dvs | Get-VDPortgroup | Where-Object {$_.IsUplink -eq $false}

  foreach($vmHost in $vmHosts) {
    $existingSwitches = $vmHost | Get-VirtualSwitch

    # Check if Switch already exists on ESXi, skip when true
    if($existingSwitches.Name -notcontains $vssName){
      $vss = $vmHost | New-VirtualSwitch -Name $vssName -Mtu $dvs.Mtu
      Write-Host "`n$([char]8730) Created new Switch $vss on ESXi $vmHost"

      foreach($pg in $portgroups) {
        $vlanId = $pg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanID
        $newPortgroup = $vss | New-VirtualPortGroup -Name $pg.Name -VlanId $vlanId
        Write-Host "$([char]8730) Created new Portgroup $newPortgroup with VlanID $vlanId"
      }
    } else {
      Write-Host "$([char]215) Standard Switch $vssName already present on ESXi $vmHost, skipping..." 
      Continue
    }
  }
}

function Move-VmnicToVss {
  param([string]$vmnic)
  Write-Host "`nMigrating a vmnic to the new Standard Switch`n"

  foreach($vmHost in $vmHosts) {
    $vss = $vmHost | Get-VirtualSwitch -Name $vssName
    $pnic = $vmHost | Get-VMHostNetworkAdapter -Physical | Where-Object {$_.Name -eq $vmnic}
    
    # Add vmnic to Standard Switch    
    try {
      $vss | Add-VirtualSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $pnic
      Write-Host "$([char]8730) Added $vmnic to the Standard Switch $vss"
    } catch {
      Write-Host "$([char]215) Couldn't add $vmnic to the Standard Switch $vss" 
      Continue
    }
  }
}

function Change-VmnetToVss {
  Write-Host "`nChanging the networking on the VMs to the new Standard Switch Portgroups`n"

  $dvsPortgroups = $dvs | Get-VDPortgroup | Where-Object {$_.IsUplink -eq $false}

 
  $allvms = ($cluster | Get-VM | Get-NetworkAdapter | Where-Object -FilterScript {$dvsPortgroups.Name -eq $_.NetworkName} | Select Parent).Parent | Get-Unique -AsString

  $vmcount = $allvms.Count
  $counter = 0

  foreach($vmHost in $vmHosts) {
    $vms = ($vmHost | Get-VM | Get-NetworkAdapter | Where-Object -FilterScript {$DVPortGroups.Name -eq $_.NetworkName} | Select Parent).Parent | Get-Unique -AsString
    
    $vss = $vmHost | Get-VirtualSwitch -Name $vssName

    foreach($vm in $vms){
      $vmNets = Get-VM -Name $vm | Get-NetworkAdapter | Select Name, NetworkName

      foreach($vmNet in $vmNets){
        $vmAdapter = $vm | Get-NetworkAdapter -Name $vmNet.Name
        $portgroup = $vss | Get-VirtualPortGroup -Name $vmNet.NetworkName

        if($portgroup.Name -eq $vmNet.NetworkName){
          try {
            Set-NetworkAdapter -NetworkAdapter $vmAdapter -Portgroup $portgroup | Out-Null
            Write-Host "[$counter|$vmcount] $([char]8730) Changed the Network Adapter on the VM $VM to the new Portgroup on the Standard Switch"
          } catch {
            Write-Host "[$counter|$vmcount] $([char]215) Couldn't add $vmnic to the Standard Switch $VSS" 
            Continue
          }
          $Counter += 1
        }
      }
    }
  }
}

function Remove-VmnicFromDvs {
  param([string[]]$vmnics)
  Write-Host "`nRemoving vmnic from the Distributed Switch`n"

  foreach($vmHost in $vmHosts) {
    foreach($vmnic in $vmnics) {
        $pnic = $vmHost | Get-VMHostNetworkAdapter -Physical | Where-Object {$_.Name -eq $vmnic}
        try {
          $pnic | Remove-VDSwitchPhysicalNetworkAdapter 
          Write-Host "$([char]8730) Removed $vmnic from the Distributed Switch $dvs"
        } catch {
          Write-Host "$([char]215) Couldn't remove $vmnic from the Distributed Switch $dvs" 
          Continue
        }
    }
  }
}

function Remove-HostFromDvs {
  foreach($vmHost in $vmHost) {
    try {
      $dvs | Remove-VDSwitchVMHost -VMHost $vmHost
      Write-Host "$([char]8730) Removed the host $vmHost from the Distributed Switch $dvs"
    } catch {
      Write-Host "$([char]215) Couldn't remove $vmHost from the Distributed Switch $dvs" 
      Continue
    }
        
  }
}

function Move-HostToVc {
  Write-Host "`nDisconnecting the hosts from the source vCenter and connecting them to the new one`n"

  foreach($vmHost in $vmHosts){
    try {
      Set-VMHost -VMHost $vmHost -State Disconnected | Out-Null
      Start-Sleep -Seconds 5
      Write-Host "$([char]8730) Disconnected host $vmHost from vCenter"
    } catch {
      Write-Host "$([char]215) Couldn't disconnect $vmHost from vCenter" 
      Continue
    }
        
  }

  Disconnect-VIServer -Server $sourceVcName 

  $conn = Connect-VIServer -Server $newVcName

  $newCluster = Get-Cluster -Name $newClusterName

  $credentials = Get-Credential -UserName root -Message "ESXi Credentials (root needed)"

  foreach($vmHost in $vmHosts) {
    $hostname = $vmHost.Name
    try {
      Add-VMHost -Name $hostname -Location $newCluster -User $credentials.UserName -Password $credentials.GetNetworkCredential().Password -RunAsync -Force | Out-Null
      Start-Sleep -Seconds 5
      Write-Host "$([char]8730) Added host $hostname to the vCenter"
    } catch {
      Write-Host "$([char]215) Couldn't add $vmHost to the vCenter" 
      Continue
    }
        
  }

  $newvmhosts = $newCluster | Get-VMHost

  Create-DVS
    
  Start-Sleep -Seconds 10

  foreach($vmHost in $vmHosts) {
    try {
      Get-VDSwitch -Name $newDvsName | Add-VDSwitchVMHost -VMHost $vmHost
      Start-Sleep -Seconds 10
      Write-Host "$([char]8730) Added host $vmHost to the new DVSwitch"
    } catch {
      Write-Host "$([char]215) Couldn't add $vmHost to the new DVSwitch" 
      Continue
    }
        
  }
}

function Create-Dvs {
  Write-Host "`nCreating a new Distributed Switch`n"
  try {
    New-VDSwitch -Name $newDvsName -Mtu 1500 -Location $newDcName | Out-Null
    Write-Host "$([char]8730) Created new Distributed Switch $newDvsName"
  } catch {
    Write-Host "$([char]215) Couldn't create new Distributed Switch $newDvsName" 
    [Environment]::Exit(1)
  }

  Rename-Uplink -OldName uplink1 -NewName vmotion
  Rename-Uplink -OldName uplink2 -NewName ft
  Rename-Uplink -OldName uplink3 -NewName lan-1
  Rename-Uplink -OldName uplink4 -NewName lan-2

  Start-Sleep -Seconds 5

  $pgBaseName = "pg-" + $newDvsName.Substring(3) # sw- trimmen
  foreach($pg in $portgroupsOld) {
    if($pg.Name.StartsWith("Server")){
      $vlanId = $pg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
      $portgroupName = "$pgBaseName-$vlanId"
      try {
        Get-VDSwitch -Name $newDvsName | New-VDPortgroup -Name $portgroupName -VlanId $vlanId | Out-Null
        Write-Host "$([char]8730) Created new Portgroup $portgroupName with VlanID $vlanId"
      } catch {
        Write-Host "$([char]215) Couldn't create new Portgroup $portgroupName with VlanID $vlanId"
        Continue
      }
    }
  }  

  $newvmhosts = Get-Cluster -Name $newClusterName | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected" -or $_.ConnectionState -eq "Maintenance"}

  foreach($vmHost in $newvmhosts) {
    $unusedUplinks = "vmotion", "ft"
    try {
      Get-VDSwitch -Name $newDvsName | Get-VDPortgroup | Get-VDUplinkTeamingPolicy | Set-VDUplinkTeamingPolicy -UnusedUplinkPort $unusedUplinks -LoadBalancingPolicy LoadBalanceLoadBased | Out-Null
      Write-Host "$([char]8730) Made the uplinks vMotion and FT unused on host $vmHost"
    } catch {
      Write-Host "$([char]215) Couldn't make the Uplinks vmotion and ft unused on host $vmHost"
      Continue
    }
    
  }
}

function Rename-Uplink {
  param([string]$OldName, [string]$NewName)
  Write-Host "`nRenaming Uplink`n"
  
  $newDvs = Get-VDSwitch -Name $newDvsName
  
  try {
    $spec = New-Object VMware.Vim.DVSConfigSpec
    $spec.ConfigVersion = $NewDVSwitch.ExtensionData.Config.ConfigVersion
    $spec.UplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
    $newDvs.ExtensionData.Config.UplinkPortPolicy.UplinkPortName | %{
      $spec.UplinkPortPolicy.UplinkPortName += $_.Replace($OldName,$NewName)
    }
    $newDvs.ExtensionData.ReconfigureDvs($spec)
    Write-Host "$([char]8730) Renamed Uplink $OldName to $NewName"
  } catch {
    Write-Host "$([char]215) Couldn't rename Uplink $OldName to $NewName"
    Continue
  }
}

function Move-VmnicToDvs {
  param([string[]]$vmnics)
  Write-Host "`nMigrating vmnics to the Distributed Switch`n"

  $vmHosts = Get-Cluster -Name $newClusterName | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected" -or $_.ConnectionState -eq "Maintenance"}
  $pnics = @()

  foreach($vmHost in $vmHosts) {
    $newDvs = $vmHost | Get-VDSwitch -Name $newDvsName
    foreach($vmnic in $vmnics) {
      $pnics += $vmHost | Get-VMHostNetworkAdapter -Physical | Where-Object {$_.Name -eq $vmnic}
    }
    try {
      AssignTo-Uplink -vmnic $pnics -HostName $vmHost.Name
      Write-Host "$([char]8730) Added vmnics to the Distributed Switch $newDvs"
    } catch {
      Write-Host "$([char]215) Couldn't add vmnics to the Distributed Switch $newDvs"
      Continue
    }
  }
}

function AssignTo-Uplink {
  param([VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.Nic.HostNicImpl[]]$vmnics, [string]$Hostname)

  $vmHost = Get-VMHost -Name $Hostname
  $newDvs = $vmHost | Get-VDSwitch -Name $newDvsName

  $config = New-Object VMware.Vim.HostNetworkConfig
  $config.proxySwitch = New-Object VMware.Vim.HostProxySwitchConfig
  $config.proxySwitch[0].changeOperation = "edit"
  $config.proxySwitch[0].uuid = $newDvs.Key
  $config.proxySwitch[0].spec = New-Object VMware.Vim.HostProxySwitchSpec
  $config.proxySwitch[0].spec.backing = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberPnicBacking
  $config.proxySwitch[0].spec.backing.pnicSpec = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberPnicSpec[] ($vmnics.Length) 

  # Create config based on array passed in function
  for($i = 0; $i -lt $vmnics.Length; $i += 1) {
    $uplinkName = $uplinkMappings[$vmnics[$i].Name]
    $uplink = $newDvs | Get-VDPort -Uplink | Where-Object {($_.ProxyHost -like $vmHost.Name) -and ($_.Name -eq $uplinkName)}

    $config.proxySwitch[0].spec.backing.pnicSpec[$i] = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberPnicSpec
    $config.proxySwitch[0].spec.backing.pnicSpec[$i].pnicDevice = $vmnics[$i]
    $config.proxySwitch[0].spec.backing.pnicSpec[$i].uplinkPortKey = $uplink.Key
  }

  $_this = Get-View (Get-View $vmHost).ConfigManager.NetworkSystem
  $_this.UpdateNetworkConfig($config, "modify") | Out-Null
}

function Change-VmnetToDvs {
  Write-Host "`nMigrating the VM networking back to the DV Switch`n"

  $newPortgroups = Get-VDSwitch -Name $newDvsName | Get-VDPortGroup | Where-Object -FilterScript { $_.IsUplink -eq $false} | Select Name, @{N="VLANId";E={$_.Extensiondata.Config.DefaultPortCOnfig.Vlan.VlanId}}
  $newvmhost = Get-Cluster -Name $newClusterName | Get-VMHost

  $vmcount = (Get-Cluster -Name $newClusterName | Get-VM).Count
  $counter = 0

  foreach($vmHost in $newvmhost){
    $vms = $vmHost | Get-VM 

    foreach ($vm in $vms){
      $vmNets = $vm | Get-NetworkAdapter | Select Name, NetworkName
      foreach($vmNet in $vmNets) {
        $vmAdapterName = $VMNetwork.Name
        $vmAdapter = Get-VM -Name $vm | Get-NetworkAdapter -Name $vmAdapterName
        $vlanId = $vmNet.NetworkName -replace '\D+(\d+)','$1'

        if($newPortgroups.Name -like "*$VlanId"){
          $newPgName = ($newPortgroups | Where-Object {$_.Name -like "*$vlanId"}).Name
          $newPg = $vmHost | Get-VDSwitch | Get-VDPortgroup -Name $newPgName
          try {
            Set-NetworkAdapter -NetworkAdapter $vmAdapter -Portgroup $newPg | Out-Null
            Write-Host "[$counter|$vmcount] $([char]8730) Changed the VM $vm Network to the Distributed Switch $newDvs"
          } catch {
            Write-Host "[$counter|$vmcount] $([char]215) Couldn't change the VM $VM Network to the Distributed Switch $newDvs"
            Continue
          }
          $counter += 1
        } 
      }
    }
  }
}


function Remove-VmnicFromVss {
  param([string]$vmnic)
  Write-Host "`nRemoving vmnic from the Standard Switch`n"
  $vmHosts = Get-Cluster -Name $newClusterName | Get-VMHost | Where-Object {$_.ConnectionState -eq "Connected" -or $_.ConnectionState -eq "Maintenance"}

  foreach($vmHost in $vmHosts) {
    $pnic = $vmHost | Get-VMHostNetworkAdapter -Physical | Where-Object {$_.Name -eq $vmnic}
    try {
      $pnic | Remove-VirtualSwitchPhysicalNetworkAdapter
      Write-Host "$([char]8730) Removed $vmnic from the Standard Switch $VSSName"
    } catch {
      Write-Host "$([char]215) Couldn't remove $vmnic from the Standard Switch $VSSName" 
      Continue
    }
  }
}

# clone existing dvs to new vss
Clone-DvsToVss

# move one vmnic to to vss
Move-VmnicToVss -vmnic vmnic4

# change vmnet to vss 
Change-VmnetToVss

# remove vmnics from dvs
Remove-VmnicFromDvs -vmnics vmnic3, vmnic1 

# remove hosts from dvs
Remove-HostFromDvs

# move hosts to new vc and add them to dvs
Move-HostToVc

# move vmnic to dvs
Move-VmnicToDvs -vmnic vmnic3, vmnic1 

# change vmnet to dvs
Change-VmnetToDvs

# remove vmnic from dvs
Remove-VmnicFromDvs -vmnic vmnic4

# move vmnic to dvs
Move-VmnicToDvs -vmnic vmnic3, vmnic1, vmnic4 

Disconnect-VIServer
