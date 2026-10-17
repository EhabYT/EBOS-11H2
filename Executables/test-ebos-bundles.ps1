#Requires -Version 5.1
<#
.SYNOPSIS
  Preflight check for the offline bundle. Run this on the build machine before packaging;
  it fails loudly if a bundled asset is missing, unsigned or the wrong architecture.

.DESCRIPTION
  Verifies the four optional-but-required-for-offline assets and reports what the playbook
  will do with each one. Exit code 0 when the bundle is complete for the requested mode,
  non-zero otherwise. Never prompts.

.PARAMETER RequireOffline
  Treat every bundle asset as mandatory. Without it, a missing Brave installer is only a
  warning (the playbook can still run online).

.PARAMETER Quiet
  Print only failures and the summary line.

.EXAMPLE
  .\test-ebos-bundles.ps1 -RequireOffline
#>

[CmdletBinding()]
param(
    [switch]$RequireOffline,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$results = New-Object System.Collections.ArrayList
$failed  = 0

# SHA-256 of known-good release assets. Kept here as well as in configure-windhawk-styler.ps1
# on purpose: the preflight must be able to fail a bad bundle without executing anything.
# A hash mismatch is a hard failure; an unpinned file is a warning, not a pass.
$PinnedHashes = @{
    'windhawk-cli-1.1.0-installer.exe' = '63962b290a3c63c45cf442bf3a99e91ee721ac151c7b3f774dee4424f7a238ab'
    'windhawk_setup.exe'               = '5116cc1703384aac88b8d7a3b57f172aea5da32b6df7355fb2f8247d23813c8f'
}

function Add-Result {
    param([string]$Name, [string]$State, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail })
    if ($State -eq 'MISSING' -or $State -eq 'BAD') { $script:failed++ }
    if (-not $Quiet -or $State -eq 'MISSING' -or $State -eq 'BAD') {
        $colour = switch ($State) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'MISSING' { 'Red' } 'BAD' { 'Red' } default { 'Gray' } }
        Write-Host ('  {0,-8} {1,-34} {2}' -f $State, $Name, $Detail) -ForegroundColor $colour
    }
}

function Test-Asset {
    param(
        [string]$Name,
        [string[]]$Paths,
        [switch]$RequireSignature,
        [long]$MinBytes = 1MB,
        [switch]$Mandatory
    )
    $hit = $null
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) { $hit = $p; break }
    }
    if (-not $hit) {
        if ($Mandatory) { Add-Result $Name 'MISSING' ('not found: ' + ($Paths -join ', ')) }
        else            { Add-Result $Name 'WARN'    ('not bundled: ' + ($Paths -join ', ')) }
        return
    }
    $len = (Get-Item -LiteralPath $hit).Length
    if ($len -lt $MinBytes) {
        Add-Result $Name 'BAD' ('{0} is only {1} bytes - truncated or a stub' -f $hit, $len)
        return
    }
    $leaf = Split-Path -Leaf $hit
    $hash = (Get-FileHash -LiteralPath $hit -Algorithm SHA256).Hash.ToLower()
    if ($PinnedHashes.ContainsKey($leaf)) {
        if ($hash -ne $PinnedHashes[$leaf]) {
            Add-Result $Name 'BAD' ('sha256 mismatch: expected {0}, got {1}' -f $PinnedHashes[$leaf].Substring(0,16), $hash.Substring(0,16))
            return
        }
    } else {
        Add-Result $Name 'WARN' ('unpinned build {0} - sha256 {1}' -f $leaf, $hash)
    }
    if ($RequireSignature) {
        $sig = Get-AuthenticodeSignature -LiteralPath $hit
        if ($sig.Status -ne 'Valid') {
            Add-Result $Name 'BAD' ('signature {0} - playbook will refuse to run it' -f $sig.Status)
            return
        }
        Add-Result $Name 'OK' ('{0:N1} MB, signed by {1}, sha256 {2}' -f ($len / 1MB), $sig.SignerCertificate.GetNameInfo('SimpleName', $false), $hash.Substring(0,16))
        return
    }
    Add-Result $Name 'OK' ('{0:N1} MB, sha256 {1}' -f ($len / 1MB), $hash.Substring(0,16))
}

$here = $PSScriptRoot

Write-Host ''
Write-Host 'EBOS offline bundle preflight' -ForegroundColor Cyan
Write-Host ('  scanning {0}' -f $here) -ForegroundColor DarkGray
Write-Host ''

# --- Engine -------------------------------------------------------------
$engineCandidates = @(
    Get-ChildItem -LiteralPath $here -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'windhawk-cli*-installer.exe' } |
        ForEach-Object { $_.FullName }
)
if ($engineCandidates.Count -eq 0) { $engineCandidates = @((Join-Path $here 'windhawk-cli-installer.exe')) }

Test-Asset -Name 'windhawk-cli installer' -Paths $engineCandidates -RequireSignature -MinBytes 2MB -Mandatory:$RequireOffline

# --- Windhawk GUI installer (phase7) ------------------------------------
Test-Asset -Name 'windhawk_setup.exe' -Paths @((Join-Path $here 'windhawk_setup.exe')) -MinBytes 5MB

# --- Mod cache ----------------------------------------------------------
$cacheDir = Join-Path $here 'windhawk-cache'
if (Test-Path -LiteralPath $cacheDir) {
    $mods = @(Get-ChildItem -LiteralPath $cacheDir -Directory -ErrorAction SilentlyContinue)
    if ($mods.Count -eq 0) {
        Add-Result 'windhawk-cache' 'BAD' 'directory exists but holds no mod folders'
    } else {
        $noDll = @()
        foreach ($m in $mods) {
            if (@(Get-ChildItem -LiteralPath $m.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count -eq 0) {
                $noDll += $m.Name
            }
        }
        if ($noDll.Count -gt 0) {
            Add-Result 'windhawk-cache' 'BAD' ('no precompiled DLL in: ' + ($noDll -join ', '))
        } else {
            Add-Result 'windhawk-cache' 'OK' ('{0} mods: {1}' -f $mods.Count, (($mods | ForEach-Object Name) -join ', '))
        }
        foreach ($required in @('windows-11-taskbar-styler', 'windows-11-file-explorer-styler')) {
            if ($mods.Name -notcontains $required) {
                Add-Result ('cache/' + $required) 'BAD' 'required mod absent from cache'
            }
        }
    }
} else {
    if ($RequireOffline) { Add-Result 'windhawk-cache' 'MISSING' 'offline mods would need mods.windhawk.cloud' }
    else                 { Add-Result 'windhawk-cache' 'WARN' 'not bundled - mods will download' }
}

# --- VC++ runtime -------------------------------------------------------
Test-Asset -Name 'vc_redist.x64.exe' -Paths @((Join-Path $here 'vc_redist.x64.exe')) -RequireSignature -MinBytes 10MB -Mandatory:$RequireOffline

# --- Browser ------------------------------------------------------------
Test-Asset -Name 'BraveSetup.exe' -Paths @(
    (Join-Path $here 'BraveSetup.exe'),
    (Join-Path $here 'brave-setup.exe')
) -MinBytes 50MB

# --- Scripts referenced by the playbook ---------------------------------
foreach ($s in @('configure-windhawk-styler.ps1')) {
    $path = Join-Path $here $s
    if (Test-Path -LiteralPath $path) { Add-Result $s 'OK' 'present' }
    else { Add-Result $s 'BAD' 'referenced by phase7b but missing' }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host 'Bundle OK.' -ForegroundColor Green
    if ($RequireOffline) { Write-Host 'Suitable for an air-gapped install.' -ForegroundColor Green }
    else { Write-Host 'Suitable for an online install; tick Offline Mode only after adding the WARN assets.' -ForegroundColor Yellow }
    exit 0
}
Write-Host ('{0} blocking problem(s).' -f $failed) -ForegroundColor Red
exit 1
