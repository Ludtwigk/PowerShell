param([string[]]$vCenter, [PSCredential]$Credential)

$ErrorActionPreference = "Continue"
$ConfirmPreference = "None"

Import-Module -Name VMware.VimAutomation.Core

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCeip:$false -DefaultVIServerMode Multiple -Scope Session

Connect-VIServer -Server $vCenter -Credential $Credential

Get-VMHost | ForEach-Object { Stop-VMHostService -HostService ($_ | Get-VMHostService | Where {$_.Key -eq "TSM-SSH"}) }

Disconnect-VIServer -Server $vCenter