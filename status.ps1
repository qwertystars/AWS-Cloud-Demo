#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/common.ps1')
if ($args.Count -ne 0) { [Console]::Error.WriteLine('Usage: .\status.ps1'); exit 2 }
trap { Write-FailureAndExit $_ }
Import-DemoOutputs
Write-Output ''
Write-Output "Cluster: $script:CLUSTER"
Write-Output "Service: $script:SERVICE"
Write-Output ('ALB DNS: ' + (Get-TerraformOutput -Name 'load_balancer_dns'))
Write-Output "Demo URL: $script:URL"
Write-Output ''
Invoke-Native aws @('ecs', 'describe-services', '--cluster', $script:CLUSTER, '--services', $script:SERVICE,
  '--query', 'services[].{Service:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}',
  '--output', 'table')
$tasks = @(Get-RunningTask)
if ($tasks.Count) {
  Invoke-Native aws (@('ecs', 'describe-tasks', '--cluster', $script:CLUSTER, '--tasks') + $tasks +
    @('--query', 'tasks[].{Task:taskArn,Status:lastStatus,Desired:desiredStatus,Health:healthStatus}', '--output', 'table'))
} else {
  Write-Output 'No running or starting tasks.'
}
Invoke-Native aws @('elbv2', 'describe-target-health', '--target-group-arn', $script:TG,
  '--query', 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}',
  '--output', 'table')
Write-Output ''
Write-Output 'Recent ECS events:'
Invoke-Native aws @('ecs', 'describe-services', '--cluster', $script:CLUSTER, '--services', $script:SERVICE,
  '--query', 'services[0].events[:5].[createdAt,message]', '--output', 'table')
