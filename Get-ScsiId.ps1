param([Parameter(Mandatory=$true)][string]$VMName, [Parameter(Mandatory=$true)][string]$vCenter)
$ErrorActionPreference = "Continue"
$ConfirmPreference = "None"

Import-Module -Name VMware.VimAutomation.Core

$connection = Connect-VIServer -Server $vCenter

Get-VM -Name $VMName | Get-HardDisk | Select @{N='VM';E={$_.Parent.Name}},Name, @{N='SCSIid';E={
        $hd = $_
        $ctrl = $hd.Parent.Extensiondata.Config.Hardware.Device | Where {$_.Key -eq $hd.ExtensionData.ControllerKey}
        "$($ctrl.BusNumber):$($_.ExtensionData.UnitNumber)"
     }} 


Disconnect-VIServer -Server $vCenter