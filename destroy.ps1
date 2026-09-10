#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/common.ps1')
$yes = $false
if ($args.Count -eq 1 -and $args[0] -eq '--yes') { $yes = $true }
elseif ($args.Count -ne 0) { [Console]::Error.WriteLine('Usage: .\destroy.ps1 [--yes]'); exit 2 }
try {
  Require-Commands @('terraform', 'aws')
  Invoke-Native terraform @('init', '-input=false')
  $script:REGION = Get-TerraformOutput -Name 'region' -AllowFailure
  if (-not $script:REGION) { $script:REGION = Get-ConfiguredRegion }
  $env:AWS_DEFAULT_REGION = $script:REGION
  $env:AWS_REGION = $script:REGION
  Test-DeploymentIdentity
  $configured = Get-ConfiguredRegion
  if ($configured -ne $script:REGION) {
    Fail "Refusing: configured region $configured differs from recorded region $script:REGION. Restore the original configuration before cleanup."
  }
  Write-Output ''
  Write-Output 'Terraform resources in the current workspace:'
  Invoke-Native terraform @('state', 'list')
  if (-not $yes) {
    Write-Output ''
    $confirmation = Read-Confirmation 'Destroy this Terraform project in the account above? Type destroy to confirm: '
    if ($confirmation -ne 'destroy') { Write-Output 'Cancelled; resources remain running.'; exit 1 }
  }
  # Explicit confirmation above, or --yes, authorizes Terraform auto-approval.
  Invoke-Native terraform @('destroy', '-input=false', '-auto-approve')
  $state = Get-Native terraform @('state', 'pull')
  $remaining = @()
  $parsed = $state | ConvertFrom-Json
  if ($parsed -and $parsed.PSObject.Properties['resources']) {
    foreach ($resource in @($parsed.resources)) {
      if ($resource.PSObject.Properties['mode'] -and $resource.mode -eq 'managed' -and
        $resource.PSObject.Properties['instances'] -and @($resource.instances).Count) {
        $remaining += ($resource.type + '.' + $resource.name)
      }
    }
  }
  if ($remaining.Count) { Fail ('WARNING: managed resources remain: ' + ($remaining -join ', ')) }
  Write-Output 'Cleanup successful: Terraform state contains no managed resources. ALB and Fargate resources managed by this project have been destroyed.'
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  [Console]::Error.WriteLine('WARNING: cleanup is incomplete or could not be verified. Resources may still incur charges. Keep the state, resolve the error, and rerun .\destroy.ps1.')
  exit $script:FailCode
}
