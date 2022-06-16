param(
  [Parameter(Mandatory=$false, HelpMessage='Path to template folder (e.g. datacenter/cluster/folder)')][String]$Path,
  [Parameter(Mandatory=$true, HelpMessage='vCenter')][String]$vCenter
)

$ConfirmPreference = "None"

Import-Module -Name VMware.VimAutomation.Core

function Get-FolderByPath{
  <#
      .SYNOPSIS Retrieve folders by giving a path
      .DESCRIPTION The function will retrieve a folder by it's path.
      The path can contain any type of leave (folder or datacenter).
      .NOTES
      Author: Luc Dekens .PARAMETER Path The path to the folder. This is a required parameter.
      .PARAMETER
      Path The path to the folder. This is a required parameter.
      .PARAMETER
      Separator The character that is used to separate the leaves in the path. The default is '/'
      .EXAMPLE
      PS> Get-FolderByPath -Path "Folder1/Datacenter/Folder2"
      .EXAMPLE
      PS> Get-FolderByPath -Path "Folder1>Folder2" -Separator '>'
  #>
  param(
    [CmdletBinding()]
    [parameter(Mandatory = $true)]
    [System.String[]]${Path},
    [char]${Separator} = '/'
  )
  process{
    if((Get-PowerCLIConfiguration).DefaultVIServerMode -eq "Multiple"){
      $vcs = $global:defaultVIServers
    }
    else{
      $vcs = $global:defaultVIServers[0]
    }
    foreach($vc in $vcs){
      $si = Get-View ServiceInstance -Server $vc
      $rootName = (Get-View -Id $si.Content.RootFolder -Property Name).Name
      foreach($strPath in $Path){
        $root = Get-Folder -Name $rootName -Server $vc -ErrorAction SilentlyContinue
        $strPath.Split($Separator) | %{
          $root = Get-Inventory -Name $_ -Location $root -Server $vc -ErrorAction SilentlyContinue
          if((Get-Inventory -Location $root -NoRecursion | Select -ExpandProperty Name) -contains "vm"){
            $root = Get-Inventory -Name "vm" -Location $root -Server $vc -NoRecursion
          }
        }
        $root | where {$_ -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.FolderImpl]}|%{
          Get-Folder -Name $_.Name -Location $root.Parent -NoRecursion -Server $vc
        }
      }
    }
  }
}

$connection = Connect-VIServer -Server $vCenter -Credential (Get-Credential -Message "vCenter Credentials")

$tasksStart = @()

$templates = $null

if($Path) {
    $templates = Get-Template -Location $Path
} else {
    $templates = Get-Template
}

# convert to vm
$vms = Set-Template -Template $templates -ToVM

Start-Sleep -Seconds 5

# start vms
$tasksStart = Start-VM -VM $vms -RunAsync

Wait-Task -Task $tasksStart

# patch windows server
Invoke-VMScript -VM $vms -GuestCredential (Get-Credential -Message "Guest Credentials") -ErrorAction SilentlyContinue -ScriptText {
    Import-Module -Name PSWindowsUpdate
    Install-WindowsUpdate -AcceptAll -AutoReboot
}

Wait-Tools -VM $vms

# templates (currently vms)
$vms = $templatePath | Get-VM

# shutdown vms
Shutdown-VMGuest -VM $vms

Start-Sleep -Seconds 120

# convert vms back to templates
Set-VM -VM $vms -ToTemplate

Disconnect-VIServer -Server $vCenter