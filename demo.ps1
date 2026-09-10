#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/common.ps1')
if ($args.Count -ne 0) { [Console]::Error.WriteLine('Usage: .\demo.ps1 (self-healing: .\failover-demo.ps1)'); exit 2 }
trap { Write-FailureAndExit $_ }
Require-Commands @('terraform', 'curl')
$script:URL = Get-TerraformOutput -Name 'demo_url'
$identities = New-Object 'System.Collections.Generic.List[string]'
for ($i = 1; $i -le 20; $i++) {
  # Separate curl processes, HTTP/1.1, no cookie jar, and Connection: close.
  $body = Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Arguments @(
    '--fail', '--silent', '--show-error', '--http1.1', '-H', 'Connection: close',
    '--connect-timeout', '5', '--max-time', '15', $script:URL)
  $match = [regex]::Match($body, '<h2>Served by: ([^<]+)</h2>')
  if (-not $match.Success) { Fail 'Response did not contain a backend identity' }
  $backend = $match.Groups[1].Value.Trim()
  Write-Output ('Request {0:d2} -> {1}' -f $i, $backend)
  $identities.Add($backend)
  Start-Sleep -Milliseconds 300
}
Write-Output ''
Write-Output 'Observed backends (request counts):'
foreach ($group in ($identities | Group-Object | Sort-Object Name)) {
  Write-Output ('{0,7} {1}' -f $group.Count, $group.Name)
}
$unique = @($identities | Sort-Object -Unique).Count
Write-Output ''
Write-Output "Unique backends observed: $unique"
if ($unique -lt 2) {
  [Console]::Error.WriteLine('WARNING: multiple backends were not observed. Check .\status.ps1 and retry; request order is not guaranteed.')
}
