#Requires -Version 5.1
<#
.SYNOPSIS
  Unattended, offline-capable Windhawk provisioning: transparent Windows 11 taskbar and
  File Explorer, applied through the headless windhawk-cli engine.

.DESCRIPTION
  Runs with zero prompts, zero dialogs and zero Read-Host. All output goes to
  %WINDIR%\EBOS\windhawk-styler.log. Every failure path returns a non-zero exit code so the
  playbook can surface it; nothing waits for a human.

  Stages:
    1. Locate the engine installer (bundled first, network only if permitted).
    2. Install the engine silently, signature-checked, no window.
    3. Start/verify the windhawk-cli service is READY.
    4. Install the two Styler mods (from a local cache when present).
    5. Apply transparency control styles.
    6. Restart the engine, then restart explorer.exe and wait for the shell to return.
    7. Export a profile snapshot as the audit artifact.

.PARAMETER InstallerPath
  Explicit path to windhawk-cli-<ver>-installer.exe.
  Resolution order when omitted:
    1. windhawk-cli*-installer.exe next to this script   (bundled - always wins)
    2. C:\Program Files\WindhawkCLI\whcli.exe already present (nothing to install)
    3. GitHub releases/latest                            (only if -AllowDownload)

.PARAMETER ModCachePath
  Folder produced by "whcli export-cache". Defaults to .\windhawk-cache next to this script.
  When it contains mod folders, mods and their settings are installed with
  "whcli install-cache" and the catalog at mods.windhawk.cloud is never contacted.

.PARAMETER InstallerSha256
  Expected SHA-256 of the engine installer. Optional: a known release is verified against a
  pinned table automatically. Supplying this pins a build we do not have a hash for, and turns
  an unknown build into a hard failure instead of a logged warning.

.PARAMETER AllowDownload
  Forces network fallback even when Offline Mode is ticked. Normally offline is driven by
  %WINDIR%\EBOS\offline-mode.flag, written by phase1 from the wizard checkbox, so one tick
  governs every download site. With the flag set, a missing asset fails fast (exit 3) instead
  of hanging on a DNS lookup against a machine with no network.

.PARAMETER AddDefenderExclusion
  Passes --add-defender-exclusion to the installer. This disables AV coverage for
  C:\Program Files\WindhawkCLI, C:\ProgramData\WindhawkCLI, windhawk.exe and whcli.exe.
  It is a deliberate trade: the engine injects a DLL into every process, which Defender's
  behavioural ML flags as Behavior:Win32/DefenseEvasion.A!ml. Only enable it on an image
  where that is acceptable, or deploy the same exclusions through Intune/GPO instead.

.PARAMETER NoRestartExplorer
  Skips the explorer.exe restart. Use when applying to a machine with no interactive session.

.PARAMETER StrictOffline
  Fails the run (exit 3) if any asset is missing, instead of falling back to the network.
  Implied by the absence of -AllowDownload.

.OUTPUTS
  Exit codes:
    0  applied successfully, or intentionally skipped (Windows 10)
    1  failed - see windhawk-styler.log
    2  not elevated
    3  offline asset missing

.NOTES
  Verified against hansonxyz/windhawk-cli README (main, 2026-07):
    installer   --silent --auto-updates --add-defender-exclusion --no-system-tray --update
    whcli       install | install-cache | set-setting | status | restart | export |
                mod-status | cooperation | list
  Unverified on a real Windows image as of this edit. First run should be on a VM.
#>

[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$ModCachePath,
    [string]$InstallerSha256,
    [switch]$AllowDownload,
    [switch]$AddDefenderExclusion,
    [switch]$NoRestartExplorer,
    [int]$ReadyTimeoutSec = 180,
    [int]$ShellTimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$Root       = 'C:\Program Files\WindhawkCLI'
$Whcli      = Join-Path $Root 'whcli.exe'
$ServiceName = 'WindhawkCLI'
$LogDir     = Join-Path $env:WINDIR 'EBOS'
$LogFile    = Join-Path $LogDir 'windhawk-styler.log'
$FailFile   = Join-Path $LogDir 'failure.txt'

$TaskbarId  = 'windows-11-taskbar-styler'
$ExplorerId = 'windows-11-file-explorer-styler'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-WhLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 's'), $Message
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
    # [Console]::Out rather than Write-Output: a function that logs must not add to its
    # own return value, or Invoke-Exe hands back log strings instead of an exit code.
    try { [Console]::Out.WriteLine($line) } catch {}
}

function Write-WhFail {
    param([string]$Message)
    Write-WhLog ('FAILED: ' + $Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $FailFile -Value ('{0} - windhawk-styler: {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

# ---------------------------------------------------------------------------
# Process helpers - every external binary is launched hidden and waited for.
# ---------------------------------------------------------------------------

function ConvertTo-ArgString {
    <#
      Joins arguments into a command line using the quoting rules the Windows C runtime
      applies when it re-parses. This is not cosmetic: $Root is
      "C:\Program Files\WindhawkCLI" and the mod cache path can also contain spaces, so a
      plain -join ' ' produced

          whcli.exe status --root C:\Program Files\WindhawkCLI

      which the child parses as "--root C:\Program" plus a stray "Files\WindhawkCLI"
      argument. Every whcli call would fail. ProcessStartInfo.ArgumentList would avoid this
      but does not exist on PowerShell 5.1, which is what Windows ships.
    #>
    param([string[]]$Arguments)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) {
        if ([string]::IsNullOrEmpty($a)) { $parts.Add('""'); continue }
        if ($a -notmatch '[\s"]') { $parts.Add($a); continue }
        # Backslashes are special only immediately before a quote, and at the very end of a
        # quoted argument; both cases must be doubled.
        $escaped = $a -replace '(\\*)"', '$1$1\"'
        if ($escaped -match '\\+$') { $escaped = $escaped -replace '(\\+)$', '$1$1' }
        $parts.Add('"' + $escaped + '"')
    }
    return ($parts -join ' ')
}

function Invoke-Exe {
    <#
      Launches a binary with no window and waits. Returns the exit code.
      Nothing here inherits the wizard's stdout/stderr pipes, because an
      installer still holding them when the script returns makes AME report
      "Output processing did not finish".
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 900
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = (ConvertTo-ArgString -Arguments $ArgumentList)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WindowStyle     = 'Hidden'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    Write-WhLog ('  exec: {0} {1}' -f $FilePath, $psi.Arguments)
    $proc = [System.Diagnostics.Process]::Start($psi)

    # Drain both streams concurrently. Reading them after WaitForExit deadlocks the moment an
    # installer writes past the 4 KB pipe buffer: the child blocks on write, we block on exit,
    # and the step sits there until the timeout.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        Write-WhLog ('  timed out after {0}s, process killed' -f $TimeoutSec)
        return 1460
    }
    try {
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        foreach ($s in @($stdout, $stderr)) {
            foreach ($line in ("$s" -split "`r?`n")) {
                if ($line.Trim()) { Write-WhLog ('    | ' + $line.Trim()) }
            }
        }
    } catch {}
    return $proc.ExitCode
}

function Invoke-Whcli {
    <#
      Runs whcli and throws on failure. A native exit code does not trip
      $ErrorActionPreference, so without this check a failed set-setting still prints
      "applied" and the playbook reports success on a no-op.
    #>
    param([Parameter(Mandatory)][string[]]$WhcliArgs, [int]$TimeoutSec = 300)
    $argv = @($WhcliArgs) + @('--root', $Root)
    $code = Invoke-Exe -FilePath $Whcli -ArgumentList $argv -TimeoutSec $TimeoutSec
    if ($code -ne 0) {
        throw ('whcli {0} exited {1}' -f ($WhcliArgs -join ' '), $code)
    }
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Signature {
    <# Refuses to execute an unsigned or tampered engine binary. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
    } catch {
        throw ('Signature check failed for {0}: {1}' -f $Path, $_.Exception.Message)
    }
    if ($sig.Status -ne 'Valid') {
        throw ('{0} is not validly signed (status: {1}). Refusing to execute it as SYSTEM.' -f $Path, $sig.Status)
    }
    Write-WhLog ('  signature OK: {0}' -f $sig.SignerCertificate.Subject)
}

# SHA-256 of released windhawk-cli installers, as published in the GitHub release asset
# metadata (the release API exposes a "digest" field). Signature verification alone proves who
# signed the binary, not which build it is; pinning the hash proves the latter. Add a line when
# you adopt a new release.
$script:KnownInstallerHashes = @{
    'windhawk-cli-1.1.0-installer.exe' = '63962b290a3c63c45cf442bf3a99e91ee721ac151c7b3f774dee4424f7a238ab'
}

function Assert-InstallerHash {
    <#
      -InstallerSha256 wins if supplied. Otherwise the hash is looked up by filename for a
      release we know. An unknown build is not blocked - a user may legitimately bundle a newer
      version - but it is recorded so the next person can pin it instead of trusting it.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $expected = $InstallerSha256
    $source   = 'parameter'
    if (-not $expected) {
        $leaf = Split-Path -Leaf $Path
        if ($script:KnownInstallerHashes.ContainsKey($leaf)) {
            $expected = $script:KnownInstallerHashes[$leaf]
            $source   = 'pinned table'
        }
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-WhLog ('  sha256 {0}' -f $actual)

    if (-not $expected) {
        Write-WhLog ('  UNPINNED BUILD {0} - signature was verified but not the hash. Pin it with -InstallerSha256 or add it to $KnownInstallerHashes.' -f (Split-Path -Leaf $Path))
        return
    }
    if ($actual -ne $expected) {
        throw ('SHA-256 mismatch for {0}: expected {1} ({2}), got {3}. Refusing to run it.' -f (Split-Path -Leaf $Path), $expected, $source, $actual)
    }
    Write-WhLog ('  sha256 matches {0}' -f $source)
}

function Find-BundledInstaller {
    <# Returns the first windhawk-cli installer sitting next to this script, or $null. #>
    if ($InstallerPath) {
        if (Test-Path -LiteralPath $InstallerPath) { return (Resolve-Path -LiteralPath $InstallerPath).Path }
        Write-WhLog ('  -InstallerPath was given but does not exist: {0}' -f $InstallerPath)
        return $null
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'windhawk-cli*-installer.exe' } |
            Sort-Object LastWriteTime -Descending
    )
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

function Get-ModCache {
    <# Returns the cache path when it holds at least one mod folder, otherwise $null. #>
    if (-not $ModCachePath) { $ModCachePath = Join-Path $PSScriptRoot 'windhawk-cache' }
    if (-not (Test-Path -LiteralPath $ModCachePath)) { return $null }
    $folders = @(Get-ChildItem -LiteralPath $ModCachePath -Directory -ErrorAction SilentlyContinue)
    if ($folders.Count -eq 0) { return $null }
    return (Resolve-Path -LiteralPath $ModCachePath).Path
}

function Wait-ForService {
    <# Polls until whcli reports READY. The installer gates on this too, but a service left
       stopped by a previous run needs the retry. #>
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Whcli) {
            try {
                $code = Invoke-Exe -FilePath $Whcli -ArgumentList @('status', '--root', $Root) -TimeoutSec 30
                if ($code -eq 0) { return $true }
            } catch {}
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Restart-ExplorerShell {
    <#
      Restarts the shell and waits for it to come back, so the next playbook action does not
      race a half-initialised desktop. No dialogs, no prompts.
    #>
    param([int]$TimeoutSec)

    $running = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        Write-WhLog '  no explorer.exe process (non-interactive session) - skipping shell restart'
        return
    }

    Write-WhLog '  stopping explorer.exe'
    foreach ($p in $running) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 1200
    foreach ($p in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        try { $p.Kill() } catch {}
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    Start-Sleep -Seconds 2

    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Write-WhLog '  shell did not respawn - starting explorer.exe'
        try { Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden } catch {}
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
            Write-WhLog '  shell is back'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-WhLog ('  WARNING: explorer.exe did not return within {0}s' -f $TimeoutSec)
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-WhLog '=== windhawk-styler start ==='

    if (-not (Test-Elevated)) {
        Write-WhFail 'not running elevated - nothing applied'
        exit 2
    }

    # --- Platform gate ---------------------------------------------------
    # File Explorer Styler hooks the WinUI explorer frame that only exists on Windows 11.
    # On Windows 10 the taskbar mod would apply and the explorer mod would silently do
    # nothing, leaving a half-styled image. Skip cleanly instead.
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        Write-WhLog ('build {0} is pre-Windows 11 - File Explorer Styler cannot apply, skipping' -f $build)
        Write-WhLog '=== windhawk-styler skipped ==='
        exit 0
    }
    Write-WhLog ('windows build {0}' -f $build)

    # --- Asset resolution ------------------------------------------------
    $cache    = Get-ModCache
    $haveWhcli = Test-Path -LiteralPath $Whcli

    # Offline is decided by the wizard, not by the command line: phase1 writes this flag when
    # the "Offline Mode" checkbox is ticked, so the same tick controls every download site.
    # -AllowDownload overrides it for testing on a connected machine.
    $offlineFlag = Test-Path -LiteralPath (Join-Path $env:windir 'EBOS\offline-mode.flag')
    $offline = ($offlineFlag -and -not $AllowDownload)
    if ($offline) { Write-WhLog 'offline-mode flag set - network fallbacks disabled' }

    if ($cache) {
        Write-WhLog ('offline mod cache: {0} ({1} mods)' -f $cache, @(Get-ChildItem -LiteralPath $cache -Directory).Count)
    } else {
        Write-WhLog 'no mod cache - mods would come from mods.windhawk.cloud'
    }

    $installer = Find-BundledInstaller
    if ($installer) {
        Write-WhLog ('bundled installer: {0}' -f $installer)
    } elseif ($haveWhcli) {
        Write-WhLog 'engine already installed - no installer needed'
    }

    # Strict offline preflight: decide before touching the machine.
    if ($offline) {
        if (-not $haveWhcli -and -not $installer) {
            Write-WhFail 'no engine and no bundled installer; refusing to reach GitHub in offline mode'
            exit 3
        }
        if (-not $cache) {
            Write-WhFail 'no mod cache; refusing to reach mods.windhawk.cloud in offline mode'
            exit 3
        }
    }

    # --- 1. Engine -------------------------------------------------------
    if ($haveWhcli) {
        Write-WhLog 'engine present, install step skipped'
    } else {
        if (-not $installer) {
            Write-WhLog 'resolving latest release from GitHub'
            $api = 'https://api.github.com/repos/hansonxyz/windhawk-cli/releases/latest'
            $rel = Invoke-RestMethod -Uri $api -Headers @{
                Accept       = 'application/vnd.github+json'
                'User-Agent' = 'EBOS-Playbook'
            } -TimeoutSec 60
            $asset = @($rel.assets) | Where-Object { $_.name -like '*installer.exe' } | Select-Object -First 1
            if (-not $asset) { throw 'no installer asset in the latest windhawk-cli release' }

            $installer = Join-Path $env:TEMP $asset.name
            Write-WhLog ('  downloading {0}' -f $asset.browser_download_url)
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing -TimeoutSec 300
        }

        Assert-Signature -Path $installer
        Assert-InstallerHash -Path $installer

        # Silent flag set for windhawk-cli's installer, from its README:
        #   --silent              no UI, no prompts
        #   --no-system-tray      fully headless, no tray icon
        #   --auto-updates        self-update + mod refresh on start; needs network, so it is
        #                         omitted in an offline run
        #   --add-defender-exclusion  optional, see .PARAMETER above
        # --update is deliberately NOT passed: a plain install refuses if one already exists,
        # which is the behaviour we want, and --update would let a re-run clobber a live setup.
        $installerArgs = @('--silent', '--no-system-tray')
        if (-not $offline)      { $installerArgs += '--auto-updates' }
        if ($AddDefenderExclusion) { $installerArgs += '--add-defender-exclusion' }

        $code = Invoke-Exe -FilePath $installer -ArgumentList $installerArgs -TimeoutSec 900
        Write-WhLog ('  installer exit code: {0}' -f $code)
        if ($code -ne 0) { throw ('windhawk-cli installer exited {0}' -f $code) }

        if (-not (Test-Path -LiteralPath $Whcli)) {
            throw ('installer reported success but {0} is missing' -f $Whcli)
        }
        if ($installer -like (Join-Path $env:TEMP '*')) {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 2. Service readiness --------------------------------------------
    if (-not (Wait-ForService -TimeoutSec $ReadyTimeoutSec)) {
        throw ('windhawk-cli service did not report READY within {0}s' -f $ReadyTimeoutSec)
    }
    Write-WhLog 'whcli reports READY'

    # Cooperative mode: with a stock Windhawk GUI installed (phase7), windhawk-cli defers
    # and every command below targets the GUI's mod store. Logged, not changed.
    try {
        $coop = & $Whcli cooperation --root $Root 2>&1
        foreach ($line in @($coop)) { if ("$line".Trim()) { Write-WhLog ('  cooperation: ' + "$line") } }
    } catch {
        Write-WhLog '  cooperation query unavailable, continuing'
    }

    # --- 3. Mods ---------------------------------------------------------
    if ($cache) {
        Invoke-Whcli -WhcliArgs @('install-cache', $cache) -TimeoutSec 600
        Write-WhLog 'mods installed from cache'
    } else {
        Invoke-Whcli -WhcliArgs @('install', $TaskbarId, $ExplorerId) -TimeoutSec 900
        Write-WhLog 'mods installed from catalog'
    }

    # Confirm the engine actually knows about both ids before styling them.
    foreach ($modId in @($TaskbarId, $ExplorerId)) {
        $code = Invoke-Exe -FilePath $Whcli -ArgumentList @('mod-status', $modId, '--root', $Root) -TimeoutSec 120
        if ($code -ne 0) {
            throw ('mod {0} is not present after install (mod-status exit {1})' -f $modId, $code)
        }
    }
    Write-WhLog 'both mods present'

    # --- 4. Taskbar styles -----------------------------------------------
    # Targets from ramensoftware/windows-11-taskbar-styling-guide.
    # The background fill is Rectangle#BackgroundFill under Grid#RootGrid. A bare
    # "Rectangle" target also matches Rectangle#RunningIndicator and Rectangle#BackgroundStroke,
    # which blanks the running-app indicators - never widen it.
    $taskbarSettings = [ordered]@{
        'theme'                      = '""'
        'controlStyles[0].target'    = 'Taskbar.TaskbarFrame > Grid#RootGrid > Taskbar.TaskbarBackground > Grid > Rectangle#BackgroundFill'
        'controlStyles[0].styles[0]' = 'Fill=Transparent'
        'controlStyles[1].target'    = 'Rectangle#BackgroundStroke'
        'controlStyles[1].styles[0]' = 'Fill=Transparent'
    }

    Write-WhLog 'applying taskbar styles'
    foreach ($k in $taskbarSettings.Keys) {
        Invoke-Whcli -WhcliArgs @('set-setting', $TaskbarId, $k, $taskbarSettings[$k])
    }

    # --- 5. File Explorer styles -----------------------------------------
    # Targets from ramensoftware/windows-11-file-explorer-styling-guide. The Win11 frame is
    # WinUI; the legacy "DirectUI.Element > Element" / "NavPane > TreeView" selectors match
    # nothing here and produce a silent no-op.
    $explorerSettings = [ordered]@{
        'theme'                      = '""'
        'controlStyles[0].target'    = 'FileExplorerExtensions.CommandBarControl_Wave1 > Grid, Grid#CommandBarControlRootGrid'
        'controlStyles[0].styles[0]' = 'Background=Transparent'
        'controlStyles[1].target'    = 'CommandBar#FileExplorerCommandBar'
        'controlStyles[1].styles[0]' = 'Background=Transparent'
        'controlStyles[2].target'    = 'Grid#NavigationBarControlGrid'
        'controlStyles[2].styles[0]' = 'Background=Transparent'
        'controlStyles[3].target'    = 'Grid#DetailsViewControlRootGrid'
        'controlStyles[3].styles[0]' = 'Background=Transparent'
        'controlStyles[4].target'    = 'Grid#HomeViewRootGrid'
        'controlStyles[4].styles[0]' = 'Background=Transparent'
        'controlStyles[5].target'    = 'FileExplorerExtensions.GalleryViewControl#GalleryViewControl > Grid'
        'controlStyles[5].styles[0]' = 'Background=Transparent'
    }

    Write-WhLog 'applying explorer styles'
    foreach ($k in $explorerSettings.Keys) {
        Invoke-Whcli -WhcliArgs @('set-setting', $ExplorerId, $k, $explorerSettings[$k])
    }

    # --- 6. Reload + shell restart ---------------------------------------
    Invoke-Whcli -WhcliArgs @('restart') -TimeoutSec 180
    Write-WhLog 'engine restarted, settings pushed to live processes'

    if (-not $NoRestartExplorer) {
        $shellOk = Restart-ExplorerShell -TimeoutSec $ShellTimeoutSec

        if (-not $shellOk) {
            # Fail-safe. A mod that prevents the shell from coming back leaves the machine
            # unusable and the user cannot fix it without another session. Auto-rollback the
            # File Explorer mod first (it is the newer, larger surface), keep the taskbar
            # styling, and try once more. See docs/RISK-explorer-styler.md.
            Write-WhLog 'shell did not return - rolling back File Explorer Styler and retrying'
            $rolledBack = $false
            try {
                Invoke-Whcli -WhcliArgs @('disable', $ExplorerId) -TimeoutSec 120
                Invoke-Whcli -WhcliArgs @('restart') -TimeoutSec 180
                $rolledBack = $true
                Write-WhLog 'File Explorer Styler disabled'
            } catch {
                Write-WhLog ('rollback of {0} failed: {1}' -f $ExplorerId, $_.Exception.Message)
            }

            # Belt and braces: if the CLI is what broke, stop the service outright. A machine
            # with no transparency beats a machine with no desktop.
            if (-not $rolledBack) {
                try {
                    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -ne 'Stopped') {
                        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
                        Write-WhLog ('stopped and disabled service {0}' -f $ServiceName)
                    }
                } catch {
                    Write-WhLog ('service stop failed: ' + $_.Exception.Message)
                }
            }

            try { Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}
            $recovered = $false
            $deadline = (Get-Date).AddSeconds($ShellTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { $recovered = $true; break }
                Start-Sleep -Milliseconds 500
            }

            Write-WhFail ('shell did not return; rollback attempted (mod disabled: {0}, shell recovered: {1})' -f $rolledBack, $recovered)
            exit 1
        }
    }

    # --- 7. Audit artifact ------------------------------------------------
    $profileOut = Join-Path $LogDir 'windhawk-styler-profile.json'
    try {
        Invoke-Whcli -WhcliArgs @('export', '--out', $profileOut) -TimeoutSec 120
        Write-WhLog ('profile exported: {0}' -f $profileOut)
    } catch {
        Write-WhLog ('profile export failed: ' + $_.Exception.Message)
    }
    foreach ($modId in @($TaskbarId, $ExplorerId)) {
        try { Invoke-Whcli -WhcliArgs @('mod-status', $modId) -TimeoutSec 120 } catch {
            Write-WhLog ('mod-status {0} failed: {1}' -f $modId, $_.Exception.Message)
        }
    }

    Write-WhLog '=== windhawk-styler done ==='
    exit 0
} catch {
    Write-WhFail $_.Exception.Message
    exit 1
}
