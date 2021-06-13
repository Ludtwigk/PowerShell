Param(
  [Parameter(Mandatory=$true, HelpMessage='Source vCenter')][String]$SourceVC, 
  [Parameter(Mandatory=$true, HelpMessage='Destination vCenter')][String]$DestinationVC,
  [Parameter(Mandatory=$false, HelpMessage='Modify existing Alarms')][Switch]$Modify
)

$ConfirmPreference = "None"
$ErrorActionPreference = "Continue"

function Get-CounterId() {
  param([VMware.Vim.PerfCounterInfo] $PerfCounterInfo, [VMware.Vim.PerfCounterInfo[]] $PerfCounters) 
  # This is needed to 'translate' metrics between vcenter servers.
  # Alarms definiton are based on performance counter Ids. 
  # But performance counter IDs may differ between vcenter servers.
  # Function takes two parameters. First one is a Vmware.Vim.Perfcounterinfo object representing the performance counter used for the original alarm expression
  # 2nd param is an array containing all perfcounters in the destination vcenter
  # Function returns the id of the perfcounter in the des vcenter that matches the perfcounter in the src vcenter
  $found = $false
  $cid = -1
  $i = 0
  while (($found -eq $false) -and ($i -lt $PerfCounters.Count )) {
    if (($PerfCounters[$i].NameInfo.Key -eq $PerfCounterInfo.NameInfo.Key) -and  ($PerfCounters[$i].GroupInfo.Key -eq $PerfCounters.GroupInfo.Key) -and  ($PerfCounters[$i].UnitInfo.Key -eq $PerfCounterInfo.UnitInfo.Key) -and ($availableperfcounters[$i].RollupType -eq $perfcounterinfo.RollupType)) {
      $found = $true
      $cid = $PerfCounters[$i].Key
    }
    $i++
  }
  return $cid
}

$sourceConnection = Connect-VIServer $SourceVC 

#get the inventory root folder
$sourceRootFolder = (Get-View ServiceInstance).Content.RootFolder
 
# get the alarm manager
$sourceAlarmManager=Get-View (Get-View ServiceInstance -Server $SourceVC).Content.AlarmManager

# get the alarm view
$sourceAlarms = Get-View $sourceAlarmManager.GetAlarm($sourceRootFolder)

#get the performance manager (needed for metrics alarms)
$sourcePerfManager = Get-View (Get-View ServiceInstance -Server $SourceVC).Content.PerfManager 

$myAlarms = New-Object System.Collections.ArrayList
$alarmMetrics = @{}

$sourceAlarms | ForEach-Object {
  [void]$myAlarms.add($_)
  # We need to check for MetricAlarmExpressions. 
  # It seems that Alarms containing MetricAlarmExpression will always have either an OrAlarmExpression or an AndAlarmExpression, even if tehy just have a single trigger
  # But unfortunately we cannot assume that every alarm will have one of those. It looks like Event alarms sometimes only have a singleton AlarmExpression. Phew.
  if (($_.Info.Expression.GetType().FullName -eq "VMware.Vim.OrAlarmExpression") -or ($_.Info.Expression.GetType().FullName -eq "VMware.Vim.AndAlarmExpression")) {
    # We need to determine all metric alarm (sub-)expression. We need to save the metrics into an array for future use
    # First we determine how many triggers (expressions) the alarm is based on
    $expressionCount = $_.Info.Expression.Expression.Count
    # Then we define an array to hold the perfcounters for that alarm			
    $perfCounters = New-Object Vmware.Vim.PerfCounterInfo[] $expressionCount
    # Then we retrieve all counters  for those triggers , if they are metrics (not StateAlarmexpressions)
    for ($i=0; $i -lt $expressionCount; $i++) {
      if ($_.Info.Expression.Expression[$i].GetType().FullName -eq "VMware.Vim.MetricAlarmExpression") {
        # The alarm expression only contains a  numeric counter id.
        # We need to get the complete counter semantic, so we can look up the appropriate counter id in the destination vcenter 
        $perfCounters[$i]=$sourcePerfManager.QueryPerfCounter($_.Info.Expression.Expression[$i].Metric.Counterid)[0]	
      }
    }
							
    # we now save the complete perfcounters corresponding to the metrics IDs . 
    $alarmMetrics[$_.Info.Key] = New-Object Vmware.Vim.PerfCounterInfo[] $expressionCount
    $alarmMetrics[$_.Info.Key] = $perfCounters
  }
}

Disconnect-VIServer $SourceVC 

$destConnection = Connect-VIServer $DestinationVC 
 
#get the inventory root folder
$destRootFolder = (Get-View ServiceInstance).Content.RootFolder 
 
# get the alarm manager 
$destAlarmManager= Get-View (Get-View ServiceInstance).Content.AlarmManager
$destAlarms = Get-View $destAlarmManager.GetAlarm($sourceRootFolder)

# get the performance manager 
$destPerfManager = Get-View (Get-View ServiceInstance -Server $DestinationVC).Content.PerfManager
#... and the available performance counters
$destPerfCounter = $destPerfManager.PerfCounter	

foreach ($alarm in $myAlarms) {
  $create=$True
  foreach ($existingAlarm in $destAlarms) {
    if ($alarm.Info.Name -eq $existingAlarm.Info.Name) {
      #an existing alarm with the same name was found, don't create but modify if $mod has been set to 1
      $create = $False
      if ($Modify) {
        $alarmSpec = New-Object VMware.Vim.AlarmSpec
        $alarmSpec.Name = $alarm.Info.Name
        $alarmSpec.Action = $alarm.Info.Action
        $actionCount = $alarm.Info.Action.Action.Count
        if ($actionCount -gt 0) {
          $alarmSpec.Action = New-Object VMware.Vim.GroupAlarmAction
          $alarmSpec.Action.Action = New-Object VMware.Vim.AlarmTriggeringAction[] $actionCount
          # we need to copy every alarm action
          for ($i=0; $i -lt $actionCount; $i++) {
            $alarmSpec.Action.Action[$i] = New-Object VMware.Vim.AlarmTriggeringAction
            $alarmSpec.Action.Action[$i].Action = New-Object $alarm.Info.Action.Action[$i].Action.GetType().FullName
            $alarmSpec.Action.Action[$i].Action = $alarm.Info.Action.Action[$i].Action
            $transitionSpecs = $alarm.Info.Action.Action[$i].TransitionSpecs.Count
            if ($transitionSpecs -gt 0) {
              $alarmSpec.Action.Action[$i].TransitionSpecs = New-Object VMware.Vim.AlarmTriggeringActionTransitionSpec[] $transitionSpecs
              for ($j = 0 ; $j -lt $transitionSpecs ; $j++ ) {
                $alarmSpec.Action.Action[$i].TransitionSpecs[$j] = New-Object VMware.Vim.AlarmTriggeringActionTransitionSpec
                $alarmSpec.Action.Action[$i].TransitionSpecs[$j] = $alarm.Info.Action.Action[$i].TransitionSpecs[$j]
              }
            }
            $alarmSpec.Action.Action[$i].Green2yellow = $alarm.Info.Action.Action[$i].Green2yellow
            $alarmSpec.Action.Action[$i].Red2yellow = $alarm.Info.Action.Action[$i].Red2yellow
            $alarmSpec.Action.Action[$i].Yellow2red = $alarm.Info.Action.Action[$i].Yellow2red
            $alarmSpec.Action.Action[$i].Yellow2green = $alarm.Info.Action.Action[$i].Yellow2green
				
          }	
        }
        $alarmSpec.Enabled = $alarm.Info.Enabled
        $alarmSpec.Description = $alarm.Info.Description
        $alarmSpec.ActionFrequency = $alarm.Info.ActionFrequency
        $Setting = New-Object VMware.Vim.AlarmSetting
        $Setting.ToleranceRange = $alarm.Info.Setting.ToleranceRange
        $Setting.ReportingFrequency = $alarm.Info.Setting.ReportingFrequency
        $alarmSpec.Setting = $Setting
        $alarmSpec.Expression = New-Object VMware.Vim.AlarmExpression
        $alarmSpec.Expression = $alarm.Info.Expression
        if (($alarm.Info.Expression.GetType().FullName -eq "VMware.Vim.OrAlarmExpression") -or ($alarm.Info.Expression.GetType().FullName -eq "VMware.Vim.AndAlarmExpression") ) {
          # We need to figure out the matching perfcounter id in the target vcenter for all MetricAlarmExpressions
          $expressionCount = $alarm.Info.Expression.Expression.Count
			
          for ($i=0; $i -lt $expressionCount; $i++) {
            if ($alarm.Info.Expression.Expression[$i].GetType().FullName -eq "VMware.Vim.MetricAlarmExpression") {
              $sourceCounterId = $alarmMetrics[$alarm.Info.Key][$i]
              $alarmSpec.Expression.Expression[$i].Metric.Counterid = Get-CounterId -PerfCounterInfo $sourceCounterId -PerfCounters $destPerfCounter
            }					
          }
        }
        try {
          [void]$existingAlarm.ReconfigureAlarm($alarmSpec)
          Write-Host "$([char]8730) Alarm $($alarmSpec.Name) was modified"
        } catch {
          Write-Host "$([char]215) Alarm $($alarmSpec.Name) couldn't be modified" -ForegroundColor Red
        }
        
      }   
    }
  }
  # if we didn't find an existing alarm with the same name then let's create it
  if ($create) {
    $alarmSpec = New-Object VMware.Vim.AlarmSpec
    $alarmSpec.Name = $alarm.Info.name
    $alarmSpec.Action = $alarm.Info.Action
    $actionCount = $alarm.Info.Action.Action.Count
    if ($actionCount -gt 0) {
      $alarmSpec.Action = New-Object vmware.vim.GroupAlarmAction
      $alarmSpec.Action.Action = New-Object VMware.Vim.AlarmTriggeringAction[] $actionCount
      # we need to copy every alarm action
      for ($i=0; $i -lt $actionCount; $i++) {
        $alarmSpec.Action.Action[$i] = New-Object VMware.Vim.AlarmTriggeringAction
        $alarmSpec.Action.Action[$i].Action = New-Object $alarm.Info.Action.Action[$i].Action.GetType().FullName
        $alarmSpec.Action.Action[$i].Action = $alarm.Info.Action.Action[$i].Action
        $transitionSpecs = $alarm.Info.Action.Action[$i].TransitionSpecs.Count
        if ($transitionSpecs -gt 0) {
          $alarmSpec.Action.Action[$i].TransitionSpecs = New-Object VMware.Vim.AlarmTriggeringActionTransitionSpec[] $transitionSpecs
          for ($j = 0 ; $j -lt $transitionSpecs ; $j++ ) {
            $alarmSpec.Action.Action[$i].TransitionSpecs[$j] = New-Object VMware.Vim.AlarmTriggeringActionTransitionSpec
            $alarmSpec.Action.Action[$i].TransitionSpecs[$j] = $alarm.Info.Action.Action[$i].TransitionSpecs[$j]
          }
        }
        $alarmSpec.Action.Action[$i].Green2yellow = $alarm.Info.Action.Action[$i].Green2yellow
        $alarmSpec.Action.Action[$i].Red2yellow = $alarm.Info.Action.Action[$i].Red2yellow
        $alarmSpec.Action.Action[$i].Yellow2red = $alarm.Info.Action.Action[$i].Yellow2red
        $alarmSpec.Action.Action[$i].Yellow2green = $alarm.Info.Action.Action[$i].Yellow2green
			
      }	
    }
    
    $alarmSpec.Enabled = $alarm.Info.Enabled
    $alarmSpec.Description = $alarm.Info.Description
    $alarmSpec.ActionFrequency = $alarm.Info.ActionFrequency
    $alarmSpec.setting = New-Object VMware.Vim.AlarmSetting
    $alarmSpec.Setting = $alarm.Info.Setting
    $alarmSpec.Expression = New-Object VMware.Vim.AlarmExpression
    $alarmSpec.Expression = $alarm.Info.Expression
    if (($alarm.Info.Expression.GetType().FullName -eq "VMware.Vim.OrAlarmExpression") -or ($alarm.Info.Expression.GetType().FullName -eq "VMware.Vim.AndAlarmExpression") ) {
      # We need to figure out the matching perfcounter id in the target vcenter for all MetricAlarmExpressions
      $expressionCount = $alarm.Info.Expression.Expression.Count
			
      for ($i=0; $i -lt $expressionCount; $i++) {
        if ($alarm.Info.Expression.Expression[$i].GetType().FullName -eq "VMware.Vim.MetricAlarmExpression") {
          $sourceCounterId = $alarmMetrics[$alarm.Info.Key][$i]
          $alarmSpec.Expression.Expression[$i].Metric.Counterid = Get-CounterId -PerfCounterInfo $sourceCounterId -PerfCounters $destPerfCounter
        }	
      }
    }
    
    try {
      [void]$destAlarmManager.CreateAlarm($destRootFolder,$alarmSpec)
      Write-Host "$([char]8730) Alarm $($alarmSpec.Name) was created"
    } catch {
      Write-Host "$([char]215) Alarm $($alarmSpec.Name) couldn't be created" -ForegroundColor Red
    }
  }
}

Disconnect-VIServer $DestinationVC