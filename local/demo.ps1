#Requires -Version 5.1
# Mirrors local/demo.sh for Windows PowerShell 5.1 and PowerShell 7+.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

$script:FailCode = 1
$script:CurlPath = ''

function Fail {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [int]$Code = 1)
  $script:FailCode = $Code
  throw $Message
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory, Position = 0)][string]$Command,
    [Parameter(Position = 1)][string[]]$Arguments = @(),
    [switch]$Capture,
    [switch]$Quiet,
    [switch]$AllowFailure
  )
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Capture) {
      if ($Quiet) { $output = & $Command @Arguments 2>$null } else { $output = & $Command @Arguments }
    } elseif ($Quiet) {
      & $Command @Arguments 2>$null
    } else {
      & $Command @Arguments
    }
  } finally {
    $ErrorActionPreference = $previous
  }
  $code = $LASTEXITCODE
  if ($code -ne 0 -and -not $AllowFailure) {
    Fail ('Command failed with exit code {0}: {1} {2}' -f $code, $Command, ($Arguments -join ' ')) $code
  }
  if (-not $Capture) { return }
  if ($code -ne 0 -or $null -eq $output) { return '' }
  return ((@($output) -join "`n") -replace "`r", '').Trim()
}

function Invoke-Native {
  param([Parameter(Mandatory, Position = 0)][string]$Command, [Parameter(Position = 1)][string[]]$Arguments = @())
  Invoke-NativeCommand -Command $Command -Arguments $Arguments
}

function Get-Native {
  param([Parameter(Mandatory, Position = 0)][string]$Command, [Parameter(Position = 1)][string[]]$Arguments = @())
  return (Invoke-NativeCommand -Command $Command -Arguments $Arguments -Capture)
}

# -CommandType Application skips Windows PowerShell's curl alias for
# Invoke-WebRequest, which would also pool connections between requests.
function Resolve-Executable {
  param([Parameter(Mandatory)][string]$Name)
  $found = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.Source }
  return ''
}

function Get-CurlPath {
  if (-not $script:CurlPath) {
    $script:CurlPath = Resolve-Executable 'curl'
    if (-not $script:CurlPath) { Fail 'Missing command: curl' }
  }
  return $script:CurlPath
}

foreach ($tool in @('docker', 'curl')) {
  if (-not (Resolve-Executable $tool)) { [Console]::Error.WriteLine("Missing command: $tool"); exit 1 }
}
trap { [Console]::Error.WriteLine($_.Exception.Message); exit $script:FailCode }
Invoke-NativeCommand -Command 'docker' -Arguments @('compose', 'version') -Capture | Out-Null

$port = if ($env:LOCAL_PORT) { $env:LOCAL_PORT } else { '8080' }
$statsPort = if ($env:LOCAL_STATS_PORT) { $env:LOCAL_STATS_PORT } else { '8404' }
$URL = "http://127.0.0.1:$port"
$STATS = "http://127.0.0.1:$statsPort"

function Invoke-Compose {
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
  Invoke-NativeCommand -Command 'docker' -Arguments (@('compose', '-f', 'compose.yaml') + $Arguments)
}

function Get-Compose {
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
  return (Get-Native docker (@('compose', '-f', 'compose.yaml') + $Arguments))
}

function Confirm-Action {
  param([Parameter(Mandatory)][string]$Question, [AllowEmptyString()][string]$Flag = '')
  if ($Flag -eq '--yes') { return }
  [Console]::Out.Write("$Question Type yes to confirm: ")
  [Console]::Out.Flush()
  $answer = [Console]::In.ReadLine()
  if ($null -eq $answer) { $answer = '' }
  if ($answer.Trim() -ne 'yes') { Write-Output 'Cancelled.'; exit 1 }
}

function Get-BackendsUp {
  $csv = Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Quiet -AllowFailure `
    -Arguments @('-fsS', '--max-time', '3', "$STATS/;csv")
  if ($LASTEXITCODE -ne 0) { return 0 }
  $count = 0
  foreach ($line in ($csv -split "`n")) {
    $fields = $line -split ','
    if ($fields.Count -ge 18 -and $fields[0] -eq 'apps' -and
      ($fields[1] -eq 'app1' -or $fields[1] -eq 'app2') -and $fields[17] -eq 'UP') { $count++ }
  }
  return $count
}

function Get-BackendState {
  param([Parameter(Mandatory)][string]$Server)
  $csv = Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Quiet -AllowFailure `
    -Arguments @('-fsS', '--max-time', '3', "$STATS/;csv")
  if ($LASTEXITCODE -ne 0) { return '' }
  foreach ($line in ($csv -split "`n")) {
    $fields = $line -split ','
    if ($fields.Count -ge 18 -and $fields[0] -eq 'apps' -and $fields[1] -eq $Server) {
      return $fields[17]
    }
  }
  return ''
}

function Wait-LocalDown {
  param([Parameter(Mandatory)][string]$Server)
  for ($i = 0; $i -lt 40; $i++) {
    $state = Get-BackendState $Server
    if ($state -match '^(DOWN|MAINT|NOLB)') {
      Write-Output ('Load balancer marked {0}: {1}' -f $Server, $state)
      return
    }
    Start-Sleep -Seconds 1
  }
  Fail "Timed out waiting for the load balancer to mark $Server down."
}

function Wait-LocalReady {
  for ($i = 0; $i -lt 60; $i++) {
    if ((Get-BackendsUp) -eq 2) {
      Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Quiet -AllowFailure `
        -Arguments @('-fsS', '--max-time', '3', $URL) | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Output "Ready: two healthy backends. URL: $URL"
        return
      }
    }
    Start-Sleep -Seconds 2
  }
  Fail 'Readiness timed out. Run local\demo.ps1 status or docker compose -f local/compose.yaml logs.'
}

function Invoke-Requests {
  $identities = New-Object 'System.Collections.Generic.List[string]'
  for ($i = 1; $i -le 20; $i++) {
    $body = Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Arguments @(
      '-fsS', '--http1.1', '-H', 'Connection: close', '--connect-timeout', '3', '--max-time', '5', $URL)
    $match = [regex]::Match($body, '<h2>Served by: ([^<]*)</h2>')
    if (-not $match.Success -or -not $match.Groups[1].Value) { Fail 'Missing backend identity' }
    $backend = $match.Groups[1].Value
    Write-Output ('Request {0:d2} -> {1}' -f $i, $backend)
    $identities.Add($backend)
    Start-Sleep -Milliseconds 300
  }
  Write-Output ''
  Write-Output 'Backend request counts:'
  foreach ($group in ($identities | Group-Object | Sort-Object Name)) {
    Write-Output ('{0,7} {1}' -f $group.Count, $group.Name)
  }
  $count = @($identities | Sort-Object -Unique).Count
  Write-Output "Unique backends observed: $count"
  if ($count -lt 2) { Write-Output 'WARNING: only one backend observed; inspect status and retry.' }
}

if ($args.Count -lt 1 -or $args.Count -gt 2) {
  [Console]::Error.WriteLine('Usage: local\demo.ps1 setup|status|demo|self-heal|failover|destroy [--yes]')
  exit 2
}
$command = [string]$args[0]
$flag = ''
if ($args.Count -eq 2) { $flag = [string]$args[1] }
if ($flag -and -not ($flag -eq '--yes' -and @('failover', 'self-heal', 'destroy') -contains $command)) { exit 2 }

switch ($command) {
  'setup' {
    Invoke-Compose @('up', '-d', '--wait', '--wait-timeout', '180')
    Wait-LocalReady
    Write-Output "Health dashboard: $STATS"
  }
  'status' {
    Invoke-Compose @('ps', '-a')
    Write-Output ''
    Write-Output "URL: $URL"
    Write-Output "Health dashboard: $STATS"
    $csv = Invoke-NativeCommand -Command (Get-CurlPath) -Capture -Arguments @('-fsS', '--max-time', '5', "$STATS/;csv")
    foreach ($line in ($csv -split "`n")) {
      $fields = $line -split ','
      if ($fields.Count -ge 18 -and $fields[0] -eq 'apps' -and ($fields[1] -eq 'app1' -or $fields[1] -eq 'app2')) {
        Write-Output ('{0}: {1}' -f $fields[1], $fields[17])
      }
    }
  }
  'demo' { Invoke-Requests }
  'self-heal' {
    Wait-LocalReady
    $victim = Get-Compose @('ps', '-q', 'app1')
    if (-not $victim) { exit 1 }
    Confirm-Action "Terminate Apache inside app1 ($victim) to demonstrate automatic restart?" $flag
    # Docker restart policies become active after a successful 10-second run.
    Start-Sleep -Seconds 11
    $before = [int](Get-Native docker @('inspect', '--format', '{{.RestartCount}}', $victim))
    Invoke-Native docker @('exec', $victim, 'sh', '-c', 'kill -TERM 1')
    $recovered = $false
    $after = $before
    for ($i = 0; $i -lt 60; $i++) {
      $after = [int](Get-Native docker @('inspect', '--format', '{{.RestartCount}}', $victim))
      if ($after -gt $before) { $recovered = $true; break }
      Start-Sleep -Seconds 2
    }
    if (-not $recovered) { Fail 'Automatic restart was not observed.' }
    Wait-LocalReady
    Write-Output "Automatic recovery: same container $victim; restart count $before -> $after"
    Invoke-Requests
  }
  'failover' {
    Wait-LocalReady
    $old = Get-Compose @('ps', '-q', 'app1')
    if (-not $old) { exit 1 }
    Confirm-Action "Stop and recreate app1 ($old)?" $flag
    Invoke-Compose @('stop', 'app1')
    Write-Output 'app1 stopped; waiting for the load balancer to mark it down.'
    Wait-LocalDown 'app1'
    Invoke-Requests
    Write-Output 'Compose does not replace stopped containers automatically. Recreating app1 explicitly...'
    Invoke-Compose @('up', '-d', '--no-deps', '--force-recreate', '--wait', '--wait-timeout', '120', 'app1')
    $new = Get-Compose @('ps', '-q', 'app1')
    if (-not $new -or $new -eq $old) { Fail 'Replacement not confirmed' }
    Wait-LocalReady
    Write-Output "Old container: $old"
    Write-Output "Replacement: $new"
    Invoke-Requests
  }
  'destroy' {
    Invoke-Compose @('ps', '-a')
    Confirm-Action 'Remove only the aws-class-demo-local Compose containers and network?' $flag
    Invoke-Compose @('down', '--timeout', '15')
    $remaining = Get-Native docker @('ps', '-aq', '--filter', 'label=com.docker.compose.project=aws-class-demo-local')
    $networks = Get-Native docker @('network', 'ls', '-q', '--filter', 'label=com.docker.compose.project=aws-class-demo-local')
    if ($remaining -or $networks) { Fail 'WARNING: local cleanup incomplete.' }
    Write-Output 'Local cleanup complete. Downloaded images remain cached; AWS resources are unaffected.'
  }
  default {
    [Console]::Error.WriteLine("Unknown command: $command")
    exit 2
  }
}
