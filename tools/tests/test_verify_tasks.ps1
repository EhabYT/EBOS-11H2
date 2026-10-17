# Tests the ACTUAL verifier blocks with mocked task/registry reads. It does not
# register tasks, touch the Windows registry, install software, or run the playbook.
# Works with Windows PowerShell 5.1 or pwsh; no Pester dependency.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Get-Content -LiteralPath (Join-Path $root 'Executables/ebos-verify.ps1') -Raw
$parseErrors = $null; $parseTokens = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

function Get-Section {
  param([string]$Start, [string]$End)
  $a = $source.IndexOf($Start, [StringComparison]::Ordinal)
  if ($a -lt 0) { throw ('Missing section start: ' + $Start) }
  $b = $source.IndexOf($End, $a + $Start.Length, [StringComparison]::Ordinal)
  if ($b -lt 0) { throw ('Missing section end: ' + $End) }
  return [scriptblock]::Create($source.Substring($a, $b - $a))
}
$gateCode = Get-Section 'function Test-Gate' '$userHives = @()'
$queryCode = Get-Section '$allTasks = @{}' '$tasks = @('
$taskCode = Get-Section 'foreach ($e in $tasks) {' '$installed = @('
$regCode = Get-Section 'foreach ($e in $regs) {' 'foreach ($e in $keys) {'
$contextCode = Get-Section '$optFile = Join-Path' 'function Test-Gate'
$tableCode = Get-Section '$tasks = @(' 'foreach ($e in $tasks) {'
. $tableCode
$timerRow = @($tasks | Where-Object { $_.t -eq '\EBOS-TimerResolution' })[0]
$timerRegText = [regex]::Match($source, "(?m)^\s*@\{p='[^']+';v='GlobalTimerResolutionRequests';[^\r\n]+\}").Value.Trim()
if (-not $timerRegText) { throw 'Timer registry row missing' }
$timerReg = & ([scriptblock]::Create($timerRegText))

$script:assertions = 0
function Assert-Equal {
  param($Have, $Want, [string]$Label)
  $script:assertions++
  if ($Have -ne $Want) { throw ('{0}: got {1}, wanted {2}' -f $Label, $Have, $Want) }
}

function Invoke-TaskCase {
  param([hashtable]$Row, [hashtable]$Inventory = @{}, [string]$Mode = 'fresh-install',
        [string[]]$Options = @(), [switch]$QueryFailure)
  $out = @(); $checked = 0; $bad = 0; $na = 0
  $tasks = @($Row); $opts = $Options; $installMode = $Mode
  function Get-ScheduledTask {
    param($ErrorAction)
    foreach ($name in $Inventory.Keys) {
      $slash = $name.LastIndexOf('\')
      [pscustomobject]@{ TaskPath = $name.Substring(0, $slash + 1); TaskName = $name.Substring($slash + 1); State = $Inventory[$name] }
    }
    # Simulate both complete and PARTIAL failure; neither can prove a task absent.
    if ($QueryFailure) { Write-Error 'Scheduler unavailable' -ErrorAction $ErrorAction }
  }
  . $gateCode
  . $queryCode
  . $taskCode
  return @{ bad=$bad; checked=$checked; na=$na; output=($out -join "`n") }
}

$created = @{t='\Guard';g='';op='create'}
foreach ($state in @('Ready','Running','Queued')) {
  $r = Invoke-TaskCase -Row $created -Inventory @{'\Guard'=$state}
  Assert-Equal $r.bad 0 ('create ' + $state)
  Assert-Equal $r.checked 1 ('create checked ' + $state)
}
foreach ($state in @('Disabled','Unknown','')) {
  $r = Invoke-TaskCase -Row $created -Inventory @{'\Guard'=$state}
  Assert-Equal $r.bad 1 ('create must reject ' + $state)
}
$r = Invoke-TaskCase -Row $created
Assert-Equal $r.bad 1 'missing create fails'
Assert-Equal ($r.output -match 'TASK NOT CREATED') $true 'missing create diagnostic'

$deleted = @{t='\Guard';g='';op='delete'}
Assert-Equal (Invoke-TaskCase -Row $deleted).bad 0 'absent delete passes'
foreach ($state in @('Disabled','Ready')) {
  Assert-Equal (Invoke-TaskCase -Row $deleted -Inventory @{'\Guard'=$state}).bad 1 ('present delete fails ' + $state)
}
$disabled = @{t='\Guard';g=''}
Assert-Equal (Invoke-TaskCase -Row $disabled -Inventory @{'\Guard'='Disabled'}).bad 0 'disabled passes'
Assert-Equal (Invoke-TaskCase -Row $disabled -Inventory @{'\Guard'='Ready'}).bad 1 'ready is not disabled'
Assert-Equal (Invoke-TaskCase -Row $disabled).na 1 'absent built-in task is N/A'

Assert-Equal $timerRow.scope 'fresh-install' 'actual timer task scope'
Assert-Equal (Invoke-TaskCase -Row $timerRow).bad 1 'fresh timer must exist'
Assert-Equal (Invoke-TaskCase -Row $timerRow -Mode 'reapply').na 1 'reapply preserves absent timer'
Assert-Equal (Invoke-TaskCase -Row $timerRow -Mode 'reapply' -Inventory @{'\EBOS-TimerResolution'='Disabled'}).bad 0 'reapply preserves disabled timer'
Assert-Equal (Invoke-TaskCase -Row $created -Mode 'reapply').bad 1 'guard is still required on reapply'
Assert-Equal (Invoke-TaskCase -Row $timerRow -Mode 'unknown').bad 1 'unknown context cannot skip fresh assertions'
$gated = @{t='\Guard';g='selected';op='create'}
Assert-Equal (Invoke-TaskCase -Row $gated).na 1 'unticked option'
Assert-Equal (Invoke-TaskCase -Row $gated -Options @('selected')).bad 1 'ticked option'
foreach ($inventory in @(@{}, @{'\Other'='Ready'})) {
  $r = Invoke-TaskCase -Row $deleted -Inventory $inventory -QueryFailure
  Assert-Equal $r.bad 1 'query failure is an explicit failure'
  Assert-Equal $r.checked 1 'failed query does not count absence checks'
  Assert-Equal ($r.output -match 'TASK QUERY FAILED') $true 'query failure diagnostic'
}

function Invoke-RegCase {
  param([string]$Mode, [hashtable]$Row)
  $out = @(); $checked = 0; $bad = 0; $na = 0; $opts = @()
  $installMode = $Mode; $regs = @($Row); $deletedKeys = @()
  function Expand-RegPath { param($p); return $p }
  function Read-RegValue { param($p, $v); return 0 }
  function Format-RegValue { param($v); return [string]$v }
  function Test-SameValue { param($a, $b); return ($a -eq $b) }
  . $gateCode
  . $regCode
  return @{ bad=$bad; checked=$checked; na=$na }
}
Assert-Equal $timerReg.scope 'fresh-install' 'actual timer registry scope'
Assert-Equal (Invoke-RegCase -Mode 'fresh-install' -Row $timerReg).bad 1 'fresh timer registry must be set'
Assert-Equal (Invoke-RegCase -Mode 'reapply' -Row $timerReg).na 1 'reapply leaves timer registry choice alone'
Assert-Equal (Invoke-RegCase -Mode 'unknown' -Row $timerReg).bad 1 'unknown context cannot skip registry assertion'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('ebos-verify-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
try {
  $optionPath = Join-Path $temp 'ebos-options.txt'
  $contextPath = Join-Path $temp 'verify-context.json'
  Set-Content -LiteralPath $optionPath -Value 'selected'
  $stamp = (Get-Item -LiteralPath $optionPath).LastWriteTimeUtc.Ticks.ToString()
  foreach ($case in @(
    @{mode='fresh-install';schema=1;optionsStamp=$stamp;bad=0;want='fresh-install'},
    @{mode='reapply';schema=1;optionsStamp=$stamp;bad=0;want='reapply'},
    @{mode='reapply';schema=1;optionsStamp='stale';bad=1;want='unknown'},
    @{mode='invalid';schema=1;optionsStamp=$stamp;bad=1;want='unknown'},
    @{mode='reapply';schema=99;optionsStamp=$stamp;bad=1;want='unknown'}
  )) {
    $case | ConvertTo-Json | Set-Content -LiteralPath $contextPath
    $dir = $temp; $opts = @(); $out = @(); $bad = 0; $checked = 0
    . $contextCode
    Assert-Equal $bad $case.bad 'context validity'
    Assert-Equal $installMode $case.want 'context mode'
    Assert-Equal ($opts -contains 'selected') $true 'options still read'
  }
  foreach ($missing in @($contextPath, $optionPath)) {
    Remove-Item -LiteralPath $missing
    $dir = $temp; $opts = @(); $out = @(); $bad = 0; $checked = 0
    . $contextCode
    Assert-Equal $bad 1 'missing context/options fails'
    Assert-Equal $installMode 'unknown' 'missing context/options is not reapply'
  }
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output ('Verifier unit tests passed: ' + $script:assertions + ' assertions (mocked reads, not a Windows integration test).')
