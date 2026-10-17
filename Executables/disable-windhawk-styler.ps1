#Requires -Version 5.1
<#
.SYNOPSIS
  Emergency rollback: disables the Windhawk transparency mods and restarts the shell.

.DESCRIPTION
  Escape hatch for a machine where Taskbar Styler or File Explorer Styler left the shell
  unusable. Runs from an elevated prompt, Safe Mode, or a remote session; it does not need
  explorer.exe to be running and it never prompts.

  Three escalating actions:
    1. Disable both mods through whcli, restart the engine, restart the shell.
    2. If whcli is unavailable, stop and disable the WindhawkCLI service outright.
    3. If asked, uninstall the engine entirely and remove the styling.

  The taskbar mod is disabled last-resort only when -All is given: on its own it cannot break
  explorer, and losing it loses the only part that works.

.PARAMETER All
  Disable the taskbar mod too. Without it, only the File Explorer mod is disabled, because that
  is the one that can take the shell down.

.PARAMETER StopService
  Also stop and disable the WindhawkCLI service, so the mods cannot load again at boot.

.PARAMETER UninstallEngine
  Run the windhawk-cli uninstaller as well. Removes the engine from the machine.

.PARAMETER NoRestartExplorer
  Do not touch explorer.exe. Use when you are troubleshooting from a session where the shell
  is already dead and you want to reboot instead.

.OUTPUTS
  0  mods disabled (or already absent)
  1  something failed - see windhawk-styler.log
#>

[CmdletBinding()]
param(
    [switch]$All,
    [switch]$StopService,
    [switch]$UninstallEngine,
    [switch]$NoRestartExplorer,
    [int]$ShellTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

$Root        = 'C:\Program Files\WindhawkCLI'
$Whcli       = Join-Path $Root 'whcli.exe'
$ServiceName = 'WindhawkCLI'
$LogDir      = Join-Path $env:WINDIR 'EBOS'
$LogFile     = Join-Path $LogDir 'windhawk-styler.log'

$TaskbarId  = 'windows-11-taskbar-styler'
$ExplorerId = 'windows-11-file-explorer-styler'

function Write-RbLog {
    param([string]$Message)
    $line = '{0} [rollback] {1}' -f (Get-Date -Format 's'), $Message
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
    try { [Console]::Out.WriteLine($line) } catch {}
}

function Invoke-Rb {
    param([string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutSec = 120)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WindowStyle     = 'Hidden'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return 1460 }
        return $p.ExitCode
    } catch {
        Write-RbLog ('exec failed: {0} -> {1}' -f $FilePath, $_.Exception.Message)
        return 1
    }
}

function Restart-Shell {
    param([int]$TimeoutSec)
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Write-RbLog 'explorer not running - starting it'
        try { Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden } catch {}
    } else {
        Write-RbLog 'restarting explorer'
        foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            try { $p.Kill() } catch {}
        }
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            try { Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden } catch {}
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
            Write-RbLog 'shell is running'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-RbLog 'shell did not come back'
    return $false
}

try {
    Write-RbLog '=== rollback start ==='

    $targets = @($ExplorerId)
    if ($All) { $targets += $TaskbarId }

    # --- 1. Disable via whcli -------------------------------------------
    if (Test-Path -LiteralPath $Whcli) {
        foreach ($modId in $targets) {
            $code = Invoke-Rb -FilePath $Whcli -Arguments @('disable', $modId, '--root', $Root) -TimeoutSec 120
            Write-RbLog ('disable {0} -> exit {1}' -f $modId, $code)
        }
        $code = Invoke-Rb -FilePath $Whcli -Arguments @('restart', '--root', $Root) -TimeoutSec 180
        Write-RbLog ('engine restart -> exit {0}' -f $code)
    } else {
        Write-RbLog ('whcli not found at {0} - falling through to service stop' -f $Whcli)
        $StopService = $true
    }

    # --- 2. Service ------------------------------------------------------
    if ($StopService) {
        try {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.Status -ne 'Stopped') {
                    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                    Write-RbLog ('service {0} stopped' -f $ServiceName)
                }
                Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
                Write-RbLog ('service {0} set to Disabled' -f $ServiceName)
            } else {
                Write-RbLog ('service {0} not present' -f $ServiceName)
            }
        } catch {
            Write-RbLog ('service handling failed: ' + $_.Exception.Message)
        }
    }

    # --- 3. Uninstall ----------------------------------------------------
    if ($UninstallEngine) {
        $candidate = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'windhawk-cli*-installer.exe' -File -ErrorAction SilentlyContinue) |
            Select-Object -First 1
        if ($candidate) {
            $code = Invoke-Rb -FilePath $candidate.FullName -Arguments @('--uninstall', '--silent') -TimeoutSec 600
            Write-RbLog ('engine uninstall -> exit {0}' -f $code)
        } else {
            Write-RbLog 'no engine uninstaller found next to this script; remove WindhawkCLI from Settings > Apps'
        }
    }

    # --- 4. Shell --------------------------------------------------------
    if ($NoRestartExplorer) {
        Write-RbLog 'shell restart skipped (-NoRestartExplorer) - reboot to finish'
    } else {
        [void](Restart-Shell -TimeoutSec $ShellTimeoutSec)
    }

    Write-RbLog '=== rollback done ==='
    exit 0
} catch {
    Write-RbLog ('rollback FAILED: ' + $_.Exception.Message)
    exit 1
}
