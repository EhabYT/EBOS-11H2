#Requires -Version 5.1
<#
.SYNOPSIS
  Applies the EBOS Dark accent palette and registers the theme, for every local user hive.

.DESCRIPTION
  phase5 copies ebos-dark.theme into %SystemRoot%\Resources\Themes but nothing ever applies it,
  so the accent colours in [VisualStyles] never reached a user. This script does the part the
  theme file cannot do on its own, at install time, without a UI:

    [VisualStyles]        ColorizationColor, AccentColor, AccentColorInactive
    [Control Panel\Colors] Background
    [Sounds]              SchemeName=No Sounds
    VisualStyles dark mode + the CurrentTheme registration

  It does not call the theme engine. Double-clicking the file or OpenThemeAction would, but
  both can put a window on screen, and this playbook has to stay silent. Writing the state is
  enough: Windows loads CurrentTheme at the next sign-in.

  Two different byte orders are involved and mixing them swaps red and blue:

    DWM\ColorizationColor, ColorizationAfterglow   ARGB  0xAARRGGBB
    DWM\AccentColor, AccentColorInactive           ABGR  0xAABBGGRR
    Explorer\Accent\AccentColorMenu, StartColorMenu ABGR  0xAABBGGRR

  Microsoft documents the colour format of WM_DWMCOLORIZATIONCOLORCHANGED as 0xAARRGGBB, and
  the Accent values are widely documented as ABGR. Verified against those references before
  writing; do not "simplify" both to the same helper.

  ColorPrevalence is deliberately left at 0 by the rest of the playbook, so the accent stays
  off title bars and the Start surface. The DWORDs are still written because Windows uses them
  for the accent picker and for apps that query the system accent.

.OUTPUTS
  0 always. Results go to %WINDIR%\EBOS\theme-apply.txt.
#>

$ErrorActionPreference = 'SilentlyContinue'

$LogDir  = Join-Path $env:WINDIR 'EBOS'
$LogFile = Join-Path $LogDir 'theme-apply.txt'
$ThemePath = Join-Path $env:WINDIR 'Resources\Themes\EBOS-dark.theme'
# ebos-dark.theme points [Control Panel\Desktop] at this file. Wallpaper is an optional
# tick, so it may not be on disk - registering a theme whose wallpaper is missing is how
# you turn a custom desktop into a black one.
$ThemeWallpaper = Join-Path $env:WINDIR 'Web\Wallpaper\EBOS\wallpaper.png'

function Write-TLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message)
    } catch {}
}

# --- palette (single source) --------------------------------------------
# EBOS Blue: accent Mittelblau #3778B5, background Marineblau #14263F.
# Change these three numbers to re-tint the whole image; everything below derives from them.
$AccentR = 0x37
$AccentG = 0x78
$AccentB = 0xB5

function To-Dword {
    # Registry DWORD is int32; colour constants exceed int32 max, and a checked PowerShell
    # cast throws. Reinterpret the bits instead of converting the value.
    param([uint32]$Value)
    return [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
}

# Plain arithmetic, not -shl on typed literals: shift semantics differ between
# PowerShell 5.1 and 7 for uint32, and these two constants must never drift.
$argb = [uint32](4278190080 + ($AccentR * 65536) + ($AccentG * 256) + $AccentB)
$abgr = [uint32](4278190080 + ($AccentB * 65536) + ($AccentG * 256) + $AccentR)

$dwordArgb = To-Dword $argb
$dwordAbgr = To-Dword $abgr

# [Control Panel\Colors] in ebos-dark.theme. A .theme file only delivers this section when
# the theme engine applies it, which is not something an unattended pass can do, so the one
# colour the file declares is written directly. Keep in step with the theme file: verify
# compares this string against 'Background=20 38 63' inside the file.
$DesktopBackground = '20 38 63'

# [Sounds] SchemeName=No Sounds in the same file. Windows implements that scheme as
# "every event points at no file", so it has to be written per event, not as one value.
$SoundScheme = 'No Sounds'

Write-TLog ('accent #{0:X2}{1:X2}{2:X2}  ARGB=0x{3:X8}  ABGR=0x{4:X8}' -f $AccentR, $AccentG, $AccentB, $argb, $abgr)

# --- hives ---------------------------------------------------------------
# Full root names, not the HKU drive: 'Registry::' addresses the provider, where the
# children are HKEY_USERS and friends, not the drive aliases.
$hives = @('Registry::HKEY_USERS\.DEFAULT')
if (Test-Path 'Registry::HKEY_USERS\AME_UserHive_Default') { $hives += 'Registry::HKEY_USERS\AME_UserHive_Default' }
foreach ($u in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    $n = $u.PSChildName
    if ($n -match '^S-1-5-21-' -and $n -notmatch '_Classes$') { $hives += ('Registry::HKEY_USERS\' + $n) }
}

# New accounts are cloned from the Default profile, so the theme has to be preloaded
# there as well or the first account created after install starts plain. Same load/unload
# dance as apply-hkcu-fanout.ps1: AME may already have mounted its own copy.
$offlineLoaded = $false
$defaultNtu = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (-not (Test-Path 'Registry::HKEY_USERS\AME_UserHive_Default') -and (Test-Path -LiteralPath $defaultNtu)) {
    & reg.exe load 'HKU\EBOS_THEME_Default' $defaultNtu 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $hives += 'Registry::HKEY_USERS\EBOS_THEME_Default'
        $offlineLoaded = $true
    }
}

$applied = 0
$failed  = 0
$skipLogged = $false

foreach ($h in $hives) {
    # --- DWM ------------------------------------------------------------
    $dwm = $h + '\Software\Microsoft\Windows\DWM'
    try {
        if (-not (Test-Path $dwm)) { New-Item -Path $dwm -Force -ErrorAction Stop | Out-Null }
        $k = Get-Item -LiteralPath $dwm -ErrorAction Stop

        $k.SetValue('ColorizationColor',         $dwordArgb, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorizationAfterglow',     $dwordArgb, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('AccentColor',               $dwordAbgr, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('AccentColorInactive',       $dwordAbgr, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorizationColorBalance',  [int]89,    [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorizationAfterglowBalance', [int]10, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorizationBlurBalance',   [int]1,     [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('EnableWindowColorization',  [int]1,     [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorizationGlassAttribute',[int]1,     [Microsoft.Win32.RegistryValueKind]::DWord)
        $applied++
    } catch { $failed++ }

    # --- Explorer accent -------------------------------------------------
    # StartColorMenu is a colour, not an index. Earlier builds wrote 0 here, which is
    # transparent black and reads as "no Start accent".
    $acc = $h + '\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    try {
        if (-not (Test-Path $acc)) { New-Item -Path $acc -Force -ErrorAction Stop | Out-Null }
        $k = Get-Item -LiteralPath $acc -ErrorAction Stop
        $k.SetValue('AccentColorMenu', $dwordAbgr, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('StartColorMenu',  $dwordAbgr, [Microsoft.Win32.RegistryValueKind]::DWord)
        $applied++
    } catch { $failed++ }

    # --- desktop colours -------------------------------------------------
    $cp = $h + '\Control Panel\Colors'
    try {
        if (-not (Test-Path $cp)) { New-Item -Path $cp -Force -ErrorAction Stop | Out-Null }
        (Get-Item -LiteralPath $cp).SetValue('Background', $DesktopBackground, [Microsoft.Win32.RegistryValueKind]::String)
        $applied++
    } catch { $failed++ }

    # --- dark mode --------------------------------------------------------
    # phase5 already writes these for .DEFAULT / the AME hive / real SIDs, but never for
    # the Default profile, so an account created after install came up light. This loop
    # already covers that hive, which closes the gap without touching phase5.
    $pers = $h + '\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    try {
        if (-not (Test-Path $pers)) { New-Item -Path $pers -Force -ErrorAction Stop | Out-Null }
        $k = Get-Item -LiteralPath $pers -ErrorAction Stop
        $k.SetValue('AppsUseLightTheme',   [int]0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('SystemUsesLightTheme',[int]0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('ColorPrevalence',     [int]0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $applied++
    } catch { $failed++ }

    # --- sound scheme -----------------------------------------------------
    # Nothing else in the playbook touches AppEvents, so the theme's silent scheme used to
    # stay a comment. Delete this block if EBOS should keep notification sounds.
    $ae = $h + '\AppEvents\Schemes'
    try {
        if (-not (Test-Path $ae)) { New-Item -Path $ae -Force -ErrorAction Stop | Out-Null }
        (Get-Item -LiteralPath $ae).SetValue('', $SoundScheme, [Microsoft.Win32.RegistryValueKind]::String)
        foreach ($ev in @(Get-ChildItem -Path ($ae + '\Apps') -Recurse -ErrorAction SilentlyContinue)) {
            if ($ev.PSChildName -eq '.Current') { $ev.SetValue('', '', [Microsoft.Win32.RegistryValueKind]::String) }
        }
        $applied++
    } catch { $failed++ }

    # --- theme registration ----------------------------------------------
    # Pointing CurrentTheme at the file is what makes Windows treat EBOS Dark as the active
    # theme, so it shows as selected in Settings instead of sitting unused on disk.
    if ((Test-Path -LiteralPath $ThemePath) -and (Test-Path -LiteralPath $ThemeWallpaper)) {
        $th = $h + '\Software\Microsoft\Windows\CurrentVersion\Themes'
        try {
            if (-not (Test-Path $th)) { New-Item -Path $th -Force -ErrorAction Stop | Out-Null }
            (Get-Item -LiteralPath $th).SetValue('CurrentTheme', $ThemePath, [Microsoft.Win32.RegistryValueKind]::String)
            $applied++
        } catch { $failed++ }
    } elseif (-not $skipLogged) {
        Write-TLog 'CurrentTheme skipped: wallpaper asset absent, theme not registered'
        $skipLogged = $true
    }
}

Write-TLog ('applied={0} failed={1} hives={2}' -f $applied, $failed, $hives.Count)

if ($offlineLoaded) {
    try {
        [gc]::Collect()
        Start-Sleep -Milliseconds 300
        & reg.exe unload 'HKU\EBOS_THEME_Default' 2>&1 | Out-Null
        Write-TLog 'default hive unloaded'
    } catch { Write-TLog 'default hive unload failed' }
}

# --- notify the shell ----------------------------------------------------
# Same broadcast apply-darkmode.ps1 uses; without it the values sit in the registry until the
# next sign-in and the user sees no change.
try {
    if (-not ('Win32.ThemeNotify' -as [type])) {
        Add-Type -Namespace Win32 -Name ThemeNotify -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
    }
    $result = [IntPtr]::Zero
    [void][Win32.ThemeNotify]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x0002, 5000, [ref]$result)
    Write-TLog 'broadcast ImmersiveColorSet'
} catch {
    Write-TLog ('broadcast failed: ' + $_.Exception.Message)
}

$global:LASTEXITCODE = 0
exit 0
