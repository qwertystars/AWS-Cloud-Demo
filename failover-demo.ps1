#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/common.ps1')
$yes = $false
if ($args.Count -eq 1 -and $args[0] -eq '--yes') { $yes = $true }
elseif ($args.Count -ne 0) { [Console]::Error.WriteLine('Usage: .\failover-demo.ps1 [--yes]'); exit 2 }
trap { Write-FailureAndExit $_ }
Import-DemoOutputs
Wait-DemoReady
Write-Output ''
Write-Output 'Before stopping one task:'
& (Join-Path $PSScriptRoot 'status.ps1')
$before = @(Get-RunningTask)
if ($before.Count -lt 2) { Fail 'Need at least two tasks.' }
$victim = $before[0]
if (-not $yes) {
  Write-Output ''
  Write-Output 'Stop exactly this task?'
  Write-Output $victim
  $confirmation = Read-Confirmation 'Type stop to confirm: '
  if ($confirmation -ne 'stop') { Write-Output 'Cancelled.'; exit 1 }
}
# The ARN comes exclusively from this Terraform-managed service.
Invoke-Native aws @('ecs', 'stop-task', '--cluster', $script:CLUSTER, '--task', $victim,
  '--reason', 'Classroom self-healing demonstration', '--query', 'task.[taskArn,lastStatus]', '--output', 'table')
Write-Output ''
Write-Output 'ECS still desires the configured count. Watching the transient dip (it may be too brief to sample):'
for ($i = 0; $i -lt 12; $i++) {
  Write-Output ('Desired / running / pending: ' + (Get-ServiceCounts))
  Start-Sleep -Seconds 5
}
Invoke-Native aws @('ecs', 'wait', 'tasks-stopped', '--cluster', $script:CLUSTER, '--tasks', $victim)
Wait-DemoReady
$after = @(Get-RunningTask)
$replacement = $false
foreach ($task in $after) {
  if ($task -eq $victim) { Fail 'Stopped task is unexpectedly still listed.' }
  if ($before -notcontains $task) {
    Write-Output "Replacement task: $task"
    $replacement = $true
  }
}
if (-not $replacement) { Fail 'No replacement task was observed.' }
Write-Output ''
Write-Output 'Recovery complete: the desired number of tasks and healthy targets is restored.'
& (Join-Path $PSScriptRoot 'status.ps1')
