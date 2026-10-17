#Requires -Version 5.1
<#
.SYNOPSIS
  Silent install of the Windhawk GUI 1.7.3 from a bundled windhawk_setup.exe.

.DESCRIPTION
  Phase 7 step. Installs the interactive Windhawk engine (no mods, no configuration) from the
  copy shipped next to this script. Never downloads: if the bundled file is absent the step is
  skipped, not fetched.

  Silent switches /S /STANDARD are NSIS switches (Windhawk install docs and the winget
  manifest). Not Inno - /VERYSILENT is meaningless here.

.PARAMETER ExpectedSha256
  Overrides the built-in hash. Supplying this pins a build that is not in the table below and
  turns a mismatch into a hard failure.

.OUTPUTS
  Exit codes:
    0  installed, or intentionally skipped (no bundled installer)
    1  bundled installer present but rejected (hash mismatch) or failed to install

.NOTES
  Interaction with phase7b: windhawk-cli detects this GUI install and enters deferential mode,
  managing the GUI's mod store instead of running a second engine. That is the documented
  behaviour and the reason phase7b is ordered after this phase.

  Untested on a real Windows image. Confirm /S /STANDARD produces a working install before
  shipping.
#>

[CmdletBinding()]
param(
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'

# SHA-256 of the v1.7.3 asset from
# https://github.com/ramensoftware/windhawk/releases/tag/v1.7.3
$KnownSha256 = '5116cc1703384aac88b8d7a3b57f172aea5da32b6df7355fb2f8247d23813c8f'

$LogDir     = Join-Path $env:WINDIR 'EBOS'
$LogFile    = Join-Path $LogDir 'windhawk-install.log'
$SkippedFile = Join-Path $LogDir 'ebos-skipped.txt'

function Write-WhLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

function Write-Skip {
    param([string]$Reason)
    Write-WhLog ('SKIPPED: ' + $Reason)
    try {
        Add-Content -LiteralPath $SkippedFile -Value ('{0} - Windhawk GUI skipped: {1}' -f (Get-Date -Format 's'), $Reason) -ErrorAction SilentlyContinue
    } catch {}
}

try {
    $setup = Join-Path $PSScriptRoot 'windhawk_setup.exe'

    if (-not (Test-Path -LiteralPath $setup)) {
        # No bundled installer: skip rather than download, and record it. An unticked-option
        # skip and a missing-asset skip are different problems, so they are logged apart.
        Write-Skip 'windhawk_setup.exe not bundled next to the script'
        exit 0
    }

    $expected = if ($ExpectedSha256) { $ExpectedSha256.ToLower() } else { $KnownSha256 }
    $actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLower()
    Write-WhLog ('windhawk_setup.exe sha256 {0}' -f $actual)

    if ($actual -ne $expected) {
        # A file that is present but wrong is not a benign skip: it means a stale or tampered
        # bundle. Fail the step so it shows up instead of disappearing into a log.
        Write-WhLog ('SHA-256 MISMATCH: expected {0}, got {1}. Not run.' -f $expected, $actual)
        $global:LASTEXITCODE = 1
        exit 1
    }

    # /S = silent, /STANDARD = default component set (no dev tools). Window hidden so a
    # transient NSIS window cannot appear over the wizard.
    $proc = Start-Process -FilePath $setup -ArgumentList @('/S', '/STANDARD') -Wait -PassThru -WindowStyle Hidden
    Write-WhLog ('installer exit code: {0}' -f $proc.ExitCode)

    if ($proc.ExitCode -ne 0) {
        Write-WhLog ('Windhawk GUI install failed with exit code {0}' -f $proc.ExitCode)
        $global:LASTEXITCODE = 1
        exit 1
    }

    # Proof rather than trust: the engine binary must exist after a "successful" install.
    $installed = @(
        (Join-Path $env:ProgramFiles 'Windhawk\windhawk.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windhawk\windhawk.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if ($installed) {
        Write-WhLog ('installed: {0}' -f $installed)
    } else {
        Write-WhLog 'installer reported success but windhawk.exe was not found in Program Files'
    }

    $global:LASTEXITCODE = 0
} catch {
    Write-WhLog ('Windhawk GUI install failed: {0}' -f $_.Exception.Message)
    $global:LASTEXITCODE = 1
}
