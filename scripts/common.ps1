#Requires -Version 5.1
# Shared helpers, mirroring scripts/common.sh for Windows PowerShell 5.1 and
# PowerShell 7+. Entry points enable strict mode before dot-sourcing this file.
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'
# The AWS CLI writes UTF-8; Windows consoles otherwise decode it as the OEM
# code page. Failure is harmless because every value read here is ASCII.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

$script:FailCode = 1
$script:CurlPath = ''
$script:REGION = ''
$script:CLUSTER = ''
$script:SERVICE = ''
$script:TG = ''
$script:URL = ''

function Fail {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [int]$Code = 1)
  $script:FailCode = $Code
  throw $Message
}

# Entry points install this as their trap so failures print one plain line to
# stderr instead of a PowerShell exception dump, as the Bash scripts do.
function Write-FailureAndExit {
  param([Parameter(Mandatory)]$ErrorRecord)
  [Console]::Error.WriteLine($ErrorRecord.Exception.Message)
  exit $script:FailCode
}

# Native programs report failure through their exit code, so $LASTEXITCODE is
# checked explicitly and $ErrorActionPreference is relaxed for the call itself:
# text on stderr is output, not a terminating PowerShell error.
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

function Get-TerraformOutput {
  param([Parameter(Mandatory)][string]$Name, [switch]$AllowFailure)
  return (Invoke-NativeCommand -Command 'terraform' -Arguments @('output', '-raw', $Name) `
      -Capture -Quiet:$AllowFailure -AllowFailure:$AllowFailure)
}

# -CommandType Application skips aliases and functions, so Windows PowerShell's
# built-in curl alias for Invoke-WebRequest cannot satisfy the curl requirement.
function Resolve-Executable {
  param([Parameter(Mandatory)][string]$Name)
  $found = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.Source }
  return ''
}

function Require-Commands {
  param([Parameter(Mandatory, Position = 0)][string[]]$Names)
  foreach ($name in $Names) {
    if (-not (Resolve-Executable $name)) { Fail "Missing required command: $name" }
  }
}

# Requests must not share connections, so the demos always shell out to curl
# rather than Invoke-WebRequest, which pools them.
function Get-CurlPath {
  if (-not $script:CurlPath) {
    $script:CurlPath = Resolve-Executable 'curl'
    if (-not $script:CurlPath) { Fail 'Missing required command: curl' }
  }
  return $script:CurlPath
}

function Read-Confirmation {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Prompt)
  [Console]::Out.Write($Prompt)
  [Console]::Out.Flush()
  $answer = [Console]::In.ReadLine()
  if ($null -eq $answer) { return '' }
  return $answer.Trim()
}

function Get-ConfiguredRegion {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $output = 'var.region' | & terraform console } finally { $ErrorActionPreference = $previous }
  if ($LASTEXITCODE -ne 0) { Fail "Command failed with exit code ${LASTEXITCODE}: terraform console" $LASTEXITCODE }
  return ((@($output) -join "`n") -replace '["\r]', '').Trim()
}

function Add-ArnAccount {
  # $Accounts is deliberately not mandatory: PowerShell rejects an empty
  # collection bound to a mandatory parameter, and the set starts out empty.
  param($Value, [System.Collections.Generic.HashSet[string]]$Accounts)
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    $match = [regex]::Match($Value, '^arn:[^:]+:[^:]+:[^:]*:(\d{12}):')
    if ($match.Success) { [void]$Accounts.Add($match.Groups[1].Value) }
  } elseif ($Value -is [System.Collections.IDictionary]) {
    foreach ($item in $Value.Values) { Add-ArnAccount -Value $item -Accounts $Accounts }
  } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
    foreach ($property in $Value.PSObject.Properties) { Add-ArnAccount -Value $property.Value -Accounts $Accounts }
  } elseif ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) { Add-ArnAccount -Value $item -Accounts $Accounts }
  }
}

function Get-ManagedArnAccounts {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$StateJson)
  $accounts = New-Object 'System.Collections.Generic.HashSet[string]'
  if (-not $StateJson) { return @() }
  $state = $StateJson | ConvertFrom-Json
  if (-not $state.PSObject.Properties['resources']) { return @() }
  foreach ($resource in @($state.resources)) {
    if ($resource.PSObject.Properties['mode'] -and $resource.mode -eq 'managed' -and $resource.PSObject.Properties['instances']) {
      Add-ArnAccount -Value $resource.instances -Accounts $accounts
    }
  }
  return @($accounts)
}

function Test-DeploymentIdentity {
  $account = Get-Native aws @('sts', 'get-caller-identity', '--region', $script:REGION, '--query', 'Account', '--output', 'text')
  $workspace = Get-Native terraform @('workspace', 'show')
  Write-Output "AWS account: $account"
  Write-Output "AWS region:  $script:REGION"
  Write-Output "Workspace:   $workspace"
  $expected = Get-TerraformOutput -Name 'account_id' -AllowFailure
  if ($expected -and $expected -ne $account) {
    Fail 'Refusing: credentials do not match the account recorded in Terraform outputs.'
  }
  # Also handles partial applies that have resource ARNs but no outputs yet.
  Invoke-NativeCommand -Command 'terraform' -Arguments @('state', 'list') -Capture -Quiet -AllowFailure | Out-Null
  if ($LASTEXITCODE -ne 0) { return }
  $state = Get-Native terraform @('state', 'pull')
  $others = @(Get-ManagedArnAccounts -StateJson $state | Where-Object { $_ -ne $account })
  if ($others.Count) { Fail 'Refusing: managed resource ARNs belong to another AWS account.' }
}

function Import-DemoOutputs {
  Require-Commands @('terraform', 'aws', 'curl')
  $script:REGION = Get-TerraformOutput -Name 'region'
  $env:AWS_DEFAULT_REGION = $script:REGION
  $env:AWS_REGION = $script:REGION
  $script:CLUSTER = Get-TerraformOutput -Name 'cluster_name'
  $script:SERVICE = Get-TerraformOutput -Name 'service_name'
  $script:TG = Get-TerraformOutput -Name 'target_group_arn'
  $script:URL = Get-TerraformOutput -Name 'demo_url'
  Test-DeploymentIdentity
}

function Get-ServiceCounts {
  return (Get-Native aws @('ecs', 'describe-services', '--cluster', $script:CLUSTER, '--services', $script:SERVICE,
      '--query', 'services[0].[desiredCount,runningCount,pendingCount]', '--output', 'text'))
}

function Get-RunningTask {
  $text = Get-Native aws @('ecs', 'list-tasks', '--cluster', $script:CLUSTER, '--service-name', $script:SERVICE,
    '--desired-status', 'RUNNING', '--query', 'taskArns', '--output', 'text')
  if (-not $text) { return @() }
  return @($text -split '\s+' | Where-Object { $_ })
}

function Wait-DemoReady {
  Write-Output 'Waiting for ECS service stability (up to approximately 10 minutes)...'
  Invoke-Native aws @('ecs', 'wait', 'services-stable', '--cluster', $script:CLUSTER, '--services', $script:SERVICE)
  for ($attempt = 1; $attempt -le 60; $attempt++) {
    $counts = @((Get-ServiceCounts) -split '\s+')
    $desired = $counts[0]
    $running = $counts[1]
    $pending = $counts[2]
    $healthy = Get-Native aws @('elbv2', 'describe-target-health', '--target-group-arn', $script:TG,
      '--query', 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])', '--output', 'text')
    $total = Get-Native aws @('elbv2', 'describe-target-health', '--target-group-arn', $script:TG,
      '--query', 'length(TargetHealthDescriptions)', '--output', 'text')
    Write-Output "Desired=$desired Running=$running Pending=$pending Healthy targets=$healthy Total targets=$total"
    if ($desired -match '^\d+$' -and [int]$desired -ge 2 -and $running -eq $desired -and $pending -eq '0' -and
      $healthy -eq $desired -and $total -eq $desired) {
      Invoke-NativeCommand -Command (Get-CurlPath) -Capture -AllowFailure -Arguments @(
        '--fail', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '10', $script:URL) | Out-Null
      if ($LASTEXITCODE -eq 0) { return }
    }
    Start-Sleep -Seconds 5
  }
  Fail 'Readiness timed out. Run .\status.ps1 and inspect ECS service events.'
}
