#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/common.ps1')
if ($args.Count -ne 0) { [Console]::Error.WriteLine('Usage: .\setup.ps1 (Terraform asks for apply confirmation)'); exit 2 }
$exitCode = 0
$planFile = ''
try {
  Require-Commands @('terraform', 'aws', 'curl')
  Invoke-Native terraform @('init', '-input=false')
  Invoke-Native terraform @('fmt', '-check', '-recursive')
  Invoke-Native terraform @('validate')
  $script:REGION = Get-ConfiguredRegion
  $env:AWS_DEFAULT_REGION = $script:REGION
  $env:AWS_REGION = $script:REGION
  Test-DeploymentIdentity
  # A saved plan guarantees the approved actions are the actions applied.
  $planFile = Join-Path (Get-Location).Path ('aws-class-demo-plan-' + [IO.Path]::GetRandomFileName())
  Invoke-Native terraform @('plan', '-input=false', "-out=$planFile")
  Write-Output ''
  $confirmation = Read-Confirmation 'This plan creates billable AWS resources. Type apply to apply this exact plan: '
  if ($confirmation -ne 'apply') { Write-Output 'Cancelled; no plan applied.'; exit 1 }
  Invoke-Native terraform @('apply', '-input=false', $planFile)
  Import-DemoOutputs
  Wait-DemoReady
  Write-Output ''
  Write-Output "DEMO READY: $script:URL"
  Write-Output "Cluster: $script:CLUSTER"
  Write-Output "Service: $script:SERVICE"
  Write-Output ('Desired / running / pending: ' + (Get-ServiceCounts))
  Write-Output ''
  Write-Output 'After class, run .\destroy.ps1 to stop charges.'
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  [Console]::Error.WriteLine('Setup failed; resources may still exist. Inspect .\status.ps1, then retry setup or run .\destroy.ps1. Nothing was automatically destroyed.')
  $exitCode = $script:FailCode
} finally {
  if ($planFile -and (Test-Path -LiteralPath $planFile)) {
    Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
  }
}
if ($exitCode -ne 0) { exit $exitCode }
