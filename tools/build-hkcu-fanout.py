#!/usr/bin/env python3
"""
Regenerates Executables/apply-hkcu-fanout.ps1 from the task YAML.

Run from the repository root after changing any HKCU registryValue action:

    python3 tools/build-hkcu-fanout.py

The generated script re-asserts every HKCU setting against real user hives, because the
playbook runs as TrustedInstaller where HKCU is SYSTEM's hive.

Requires PyYAML.
"""

import glob
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")


class Loader(yaml.SafeLoader):
    pass


def _multi(loader, suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return None


Loader.add_multi_constructor("!", _multi)

OUT = "Executables/apply-hkcu-fanout.ps1"
PREFIX = "HKCU\\"

HEADER = r'''#Requires -Version 5.1
<#
.SYNOPSIS
  Re-asserts every HKCU registry setting from the task files against the hives that matter.

.DESCRIPTION
  GENERATED FILE - do not edit by hand.
  Produced from Configuration/Tasks/*.yml by tools/build-hkcu-fanout.py.

  Why this exists: the playbook runs as TrustedInstaller. In that context HKCU is SYSTEM's
  hive, not the signed-in user's, and HKU\.DEFAULT is the LocalSystem profile rather than the
  template new accounts are built from. A plain "!registryValue" with an HKCU path therefore
  writes somewhere no user reads - which is exactly what the verify pass reports as missing
  and what two blocks in phase2/phase6 were already hand-patched to work around.

  This pass applies the same data to:
    * every loaded S-1-5-21-* user hive
    * AME_UserHive_Default when AME provides it
    * HKU\.DEFAULT
    * C:\Users\Default\NTUSER.DAT, loaded offline when it is not already mounted
  so a setting lands for current users and for accounts created later.

  Gating: each entry carries the option it was declared under. ebos-options.txt records the
  ticks, so an unticked option is skipped here exactly as it was skipped in the action list.
  A leading "!" means "runs when NOT ticked", matching ebos-verify.ps1.

.OUTPUTS
  Exit codes: 0 always - this is a repair pass and a partial write is worse than a retry.
  Per-entry results go to %WINDIR%\EBOS\hkcu-fanout.txt.
#>

$ErrorActionPreference = 'SilentlyContinue'

$LogDir  = Join-Path $env:WINDIR 'EBOS'
$LogFile = Join-Path $LogDir 'hkcu-fanout.txt'
$OptFile = Join-Path $LogDir 'ebos-options.txt'

function Write-FanLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message)
    } catch {}
}

# --- option gates -------------------------------------------------------
$opts = @()
try { if (Test-Path -LiteralPath $OptFile) { $opts = @(Get-Content -LiteralPath $OptFile | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } } catch {}

function Test-Gate {
    param([string]$g)
    if (-not $g) { return $true }
    if ($g.StartsWith('!')) { return -not ($opts -contains $g.Substring(1)) }
    return ($opts -contains $g)
}

# --- hive list ----------------------------------------------------------
$hives = New-Object System.Collections.Generic.List[string]
$hives.Add('Registry::HKEY_USERS\.DEFAULT')
if (Test-Path 'Registry::HKEY_USERS\AME_UserHive_Default') { $hives.Add('Registry::HKEY_USERS\AME_UserHive_Default') }
foreach ($s in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    $n = $s.PSChildName
    if ($n -like 'S-1-5-21-*' -and $n -notlike '*_Classes') { $hives.Add('Registry::HKEY_USERS\' + $n) }
}

# The Default profile is what new accounts are cloned from. Load it offline if AME did not.
$offlineLoaded = $false
$defaultNtu = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (-not (Test-Path 'Registry::HKEY_USERS\AME_UserHive_Default') -and (Test-Path -LiteralPath $defaultNtu)) {
    & reg.exe load 'HKU\EBOS_HKCU_Default' $defaultNtu 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $hives.Add('Registry::HKEY_USERS\EBOS_HKCU_Default')
        $offlineLoaded = $true
    }
}

Write-FanLog ('hives: ' + ($hives -join ', '))
Write-FanLog ('options ticked: ' + ($opts -join ', '))

# --- type map -----------------------------------------------------------
$typeMap = @{
    'REG_DWORD'    = 'DWord'
    'REG_QWORD'    = 'QWord'
    'REG_SZ'       = 'String'
    'REG_EXPAND_SZ'= 'ExpandString'
    'REG_BINARY'   = 'Binary'
    'REG_MULTI_SZ' = 'MultiString'
}

function Convert-Data {
    param([string]$Type, [string]$Data)
    switch ($Type) {
        'REG_DWORD' { return [int64]([Convert]::ToUInt32($Data, 10)) }
        'REG_QWORD' { return [int64]$Data }
        'REG_BINARY' {
            # Stored as a hex string in the YAML.
            $bytes = New-Object byte[] ($Data.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Data.Substring($i * 2, 2), 16) }
            return $bytes
        }
        default { return $Data }
    }
}

# --- the data -----------------------------------------------------------
$entries = @(
'''

FOOTER = r'''
)

# --- apply --------------------------------------------------------------
$applied = 0
$skippedGate = 0
$failed = 0

foreach ($e in $entries) {
    if (-not (Test-Gate $e.o)) { $skippedGate++; continue }

    foreach ($h in $hives) {
        $full = $h + '\' + $e.k
        try {
            if ($e.op -eq 'delete') {
                if ($e.v) { Remove-ItemProperty -Path $full -Name $e.v -Force -ErrorAction SilentlyContinue }
                else { Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue }
                continue
            }

            if (-not (Test-Path -LiteralPath $full)) {
                New-Item -Path $full -Force -ErrorAction Stop | Out-Null
            }

            $name = $e.v
            if (-not $name) { $name = '(default)' }

            $psType = $typeMap[$e.t]
            if (-not $psType) { $psType = 'String' }

            $value = Convert-Data -Type $e.t -Data $e.d
            Set-ItemProperty -Path $full -Name $name -Value $value -Type $psType -Force -ErrorAction Stop
            $applied++
        } catch {
            $failed++
        }
    }
}

Write-FanLog ('applied={0} skipped_gate={1} failed={2} entries={3} hives={4}' -f $applied, $skippedGate, $failed, $entries.Count, $hives.Count)

if ($offlineLoaded) {
    try {
        [gc]::Collect()
        Start-Sleep -Milliseconds 300
        & reg.exe unload 'HKU\EBOS_HKCU_Default' 2>&1 | Out-Null
        Write-FanLog 'default hive unloaded'
    } catch { Write-FanLog 'default hive unload failed' }
}

$global:LASTEXITCODE = 0
exit 0
'''


def psq(value):
    return "'" + str(value).replace("'", "''") + "'"


def collect():
    rows = []
    for path in sorted(glob.glob("Configuration/**/*.yml", recursive=True)):
        with open(path, encoding="utf-8") as fh:
            doc = yaml.load(fh, Loader=Loader)

        def walk(node):
            if isinstance(node, dict):
                p = node.get("path")
                if isinstance(p, str) and p.startswith(PREFIX):
                    rows.append(node)
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for item in node:
                    walk(item)

        walk(doc)
    return rows


def main():
    rows = collect()
    if not rows:
        sys.exit("no HKCU registryValue actions found - wrong working directory?")

    lines = []
    for r in rows:
        key = r["path"][len(PREFIX):]
        lines.append(
            "  @{{ k={k}; v={v}; t={t}; d={d}; o={o}; op={op} }}".format(
                k=psq(key),
                v=psq(r.get("value") or ""),
                t=psq(r.get("type") or ""),
                d=psq(r.get("data") if r.get("data") is not None else ""),
                o=psq(r.get("option") or ""),
                op=psq(r.get("operation") or "add"),
            )
        )

    with open(OUT, "w", encoding="utf-8", newline="\r\n") as fh:
        fh.write(HEADER + "\n".join(lines) + FOOTER)

    print("wrote {} with {} entries".format(OUT, len(rows)))


if __name__ == "__main__":
    main()
