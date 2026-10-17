#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the offline Windhawk bundle that the playbook ships: the engine installer plus a
  mod cache, so a provisioned machine never has to reach GitHub or the Windhawk catalog.

.DESCRIPTION
  Run this ONCE on a reference Windows 11 machine that has internet and a working Windhawk
  CLI setup. It reproduces the exact mod set and settings the playbook applies, then exports
  them with "whcli export-cache".

  Output layout, ready to copy into the playbook's Executables folder:

    <OutDir>\
      windhawk-cli-<ver>-installer.exe   # engine (copied from -InstallerPath)
      windhawk-cache\
        windows-11-taskbar-styler\       # .wh.cpp + precompiled DLLs + config.json
        windows-11-file-explorer-styler\
      BUILDING-OFFLINE-BUNDLE.txt        # provenance: what built it, from which versions

  Then in the playbook:
    Executables\configure-windhawk-styler.ps1   - finds both automatically
    Executables\windhawk-cache\                 - used by "whcli install-cache"

.PARAMETER OutDir
  Where to build the bundle. Must not exist yet, or pass -Force to replace it.

.PARAMETER InstallerPath
  The windhawk-cli installer to copy into the bundle. If omitted, the newest
  windhawk-cli*-installer.exe next to this script is used.

.EXAMPLE
  .\build-windhawk-cache.ps1 -OutDir D:\ebos-offline-bundle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$InstallerPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Root      = 'C:\Program Files\WindhawkCLI'
$Whcli     = Join-Path $Root 'whcli.exe'
$CacheName = 'windhawk-cache'

function Write-Step { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated. The installer and whcli both need admin.'
}

# --- 0. Output directory -------------------------------------------------
if (Test-Path -LiteralPath $OutDir) {
    $existing = @(Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw ("{0} is not empty. Pass -Force to replace it, or pick another -OutDir." -f $OutDir)
    }
    if ($Force) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# --- 1. Engine + mods + settings on this machine -------------------------
# configure-windhawk-styler.ps1 is the same code path the playbook runs, so the cache is
# guaranteed to describe what the playbook will apply - not a hand-built approximation.
$configure = Join-Path $PSScriptRoot 'configure-windhawk-styler.ps1'
if (-not (Test-Path -LiteralPath $configure)) {
    throw ("configure-windhawk-styler.ps1 not found next to this script ({0})." -f $PSScriptRoot)
}

Write-Step 'Applying the playbook mod set on this machine (needs internet)...'
& $configure -AutoUpdate
if ($LASTEXITCODE -ne 0) { throw 'configure-windhawk-styler.ps1 failed. Fix that before building a cache.' }

if (-not (Test-Path -LiteralPath $Whcli)) { throw ("whcli.exe not found at {0}." -f $Whcli) }

# --- 2. Export the cache -------------------------------------------------
$cacheDir = Join-Path $OutDir $CacheName
Write-Step ("Exporting mod cache to {0}" -f $cacheDir)
& $Whcli export-cache $cacheDir --root $Root 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
if ($LASTEXITCODE -ne 0) { throw ('whcli export-cache exited {0}.' -f $LASTEXITCODE) }

$mods = @(Get-ChildItem -LiteralPath $cacheDir -Directory -ErrorAction SilentlyContinue)
if ($mods.Count -eq 0) { throw 'export-cache produced no mod folders.' }
Write-Ok ('Exported {0} mods: {1}' -f $mods.Count, (($mods | ForEach-Object Name) -join ', '))

# Every mod folder needs at least one DLL or the target machine installs nothing for it.
$missing = @()
foreach ($m in $mods) {
    $dlls = @(Get-ChildItem -LiteralPath $m.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) { $missing += $m.Name }
}
if ($missing.Count -gt 0) {
    Write-Warn ('No precompiled DLL in: {0}. Those mods will install without code on the target.' -f ($missing -join ', '))
}

# --- 3. Copy the engine installer ---------------------------------------
if (-not $InstallerPath) {
    $candidates = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'windhawk-cli*-installer.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) { $InstallerPath = $candidates[0].FullName }
}
if (-not $InstallerPath -or -not (Test-Path -LiteralPath $InstallerPath)) {
    Write-Warn 'No windhawk-cli installer found. The bundle has mods but no engine; copy the installer in by hand.'
} else {
    $sig = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($sig.Status -ne 'Valid') {
        Write-Warn ('Installer signature is "{0}". The playbook refuses non-Valid installers, so this will be rejected at apply time.' -f $sig.Status)
    }

    # Same pin table the playbook uses. A cache built around the wrong engine binary is worse
    # than no cache, because it looks correct until it runs on a target.
    $pinned = @{ 'windhawk-cli-1.1.0-installer.exe' = '63962b290a3c63c45cf442bf3a99e91ee721ac151c7b3f774dee4424f7a238ab' }
    $leaf = Split-Path -Leaf $InstallerPath
    $hash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLower()
    if ($pinned.ContainsKey($leaf)) {
        if ($hash -ne $pinned[$leaf]) {
            throw ('{0} has sha256 {1}, expected {2}. Refusing to build a cache around it.' -f $leaf, $hash, $pinned[$leaf])
        }
        Write-Ok ('engine hash matches pin: {0}' -f $hash.Substring(0, 16))
    } else {
        Write-Warn ('Unpinned engine build {0} (sha256 {1}).' -f $leaf, $hash)
        Write-Warn 'Add it to the pin tables in configure-windhawk-styler.ps1 and test-ebos-bundles.ps1.'
    }
    Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $OutDir (Split-Path -Leaf $InstallerPath)) -Force
    Write-Ok ('Engine installer copied: {0}' -f (Split-Path -Leaf $InstallerPath))
}

# --- 4. Provenance -------------------------------------------------------
# Without this, a bundle sitting in a repo has no record of which mod versions it froze.
$report = New-Object System.Collections.ArrayList
[void]$report.Add('EBOS offline Windhawk bundle')
[void]$report.Add('built     : ' + (Get-Date -Format s))
[void]$report.Add('built on  : ' + $env:COMPUTERNAME + ' (build ' + [Environment]::OSVersion.Version.Build + ')')
[void]$report.Add('installer : ' + $(if ($InstallerPath) { Split-Path -Leaf $InstallerPath } else { '(none)' }))
[void]$report.Add('')
[void]$report.Add('mods in cache:')
try {
    & $Whcli list --root $Root 2>&1 | ForEach-Object { [void]$report.Add('  ' + $_) }
} catch {
    [void]$report.Add('  (whcli list unavailable)')
}
[void]$report.Add('')
[void]$report.Add('Contents are precompiled DLLs from the official Windhawk catalog plus the')
[void]$report.Add('Windhawk engine (GPL-3.0). Windhawk is by Ramen Software; windhawk-cli is by')
[void]$report.Add('HansonXYZ. Both stay under GPL-3.0 - do not relicense this bundle.')
$report | Out-File -FilePath (Join-Path $OutDir 'BUILDING-OFFLINE-BUNDLE.txt') -Encoding utf8

Write-Ok ''
Write-Ok ('Bundle ready: {0}' -f (Resolve-Path $OutDir).Path)
Write-Host 'Copy the whole folder into the playbook''s Executables directory, then verify with:'
Write-Host '  .\configure-windhawk-styler.ps1 -ModCachePath .\windhawk-cache   # on the target, network unplugged'
