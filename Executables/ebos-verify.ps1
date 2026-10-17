# EBOS post-apply verification. Read-only.
# Everything the playbook declares is re-read here; anything that did not take goes to
# %windir%\EBOS\ebos-skipped.txt.
#
# Gates: ebos-options.txt lists the ticked options. An action gated on an option that
# was not ticked is counted 'not applicable', not reported. '!option' is the inverse.
# Where the playbook writes the same value more than once, only the LAST action is
# checked - a value deliberately written then deleted later is not a failure.
$ErrorActionPreference = 'SilentlyContinue'
$out = @(); $checked = 0; $bad = 0; $na = 0
$dir = Join-Path $env:windir 'EBOS'
$opts = @()
$optFile = Join-Path $dir 'ebos-options.txt'
if (Test-Path $optFile) { foreach ($l in (Get-Content $optFile)) { $t=$l.Trim(); if ($t) { $opts += $t } } }
function Test-Gate { param([string]$g)
  if (-not $g) { return $true }
  if ($g.StartsWith('!')) { return -not ($opts -contains $g.Substring(1)) }
  # 'a+b' = both options. Needed because some values are only written when two ticks
  # line up (the theme is only registered when dark mode AND wallpaper are on: the
  # theme file points at the wallpaper image, and that image is not copied otherwise).
  if ($g.Contains('+')) { foreach ($p in $g.Split('+')) { if (-not (Test-Gate $p)) { return $false } }; return $true }
  return ($opts -contains $g) }
$userHives = @()
foreach ($s in (Get-ChildItem 'Registry::HKEY_USERS')) {
  $n = $s.PSChildName
  if ($n -like 'S-1-5-21-*' -and $n -notlike '*_Classes') { $userHives += ('Registry::HKEY_USERS\' + $n) } }
function Expand-RegPath { param([string]$p)
  # HKCU inside a TrustedInstaller process is SYSTEM's hive, so HKCU entries are
  # checked against every real user hive instead.
  if ($p -like 'HKLM\*') { return @('Registry::HKEY_LOCAL_MACHINE\' + $p.Substring(5)) }
  if ($p -like 'HKCR\*') { return @('Registry::HKEY_CLASSES_ROOT\' + $p.Substring(5)) }
  if ($p -like 'HKEY_CLASSES_ROOT\*') { return @('Registry::' + $p) }
  if ($p -like 'HKU\*')  { return @('Registry::HKEY_USERS\' + $p.Substring(4)) }
  if ($p -like 'HKCU\*') { $r=@(); foreach ($h in $userHives) { $r += ($h + '\' + $p.Substring(5)) }; return $r }
  return @() }
function Read-RegValue { param([string]$full,[string]$name)
  # An empty value name is the key's DEFAULT value, which Get-ItemProperty cannot
  # read. DoNotExpandEnvironmentNames keeps REG_EXPAND_SZ raw so %SystemRoot% entries
  # compare against what the playbook actually wrote.
  $k = Get-Item -Path $full -ErrorAction SilentlyContinue
  if (-not $k) { return $null }
  try { return $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames') } catch { return $k.GetValue($name) } }
function Test-SameValue { param([string]$have,[string]$want)
  if ($have -eq $want) { return $true }
  if ($have -eq $want.Replace('-','')) { return $true }
  # A DWORD written as 4294967295 reads back as signed -1, so comparing as text made
  # every high-bit DWORD look wrong. Both sides are compared numerically when they
  # are integers.
  try {
    $h = [int64]$have; $w = [int64]$want
    if ($h -eq $w) { return $true }
    # 0xFFFFFFFF without the L suffix is parsed as Int32 -1, so this compared -1
    # against -1 on one side and 4294967295 on the other and never matched. The L
    # forces Int64 and the two representations of the same DWORD now agree.
    if (($h -band 0xFFFFFFFFL) -eq ($w -band 0xFFFFFFFFL)) { return $true }
  } catch {}
  return $false }

function Format-RegValue { param($v)
  if ($null -eq $v) { return $null }
  # REG_MULTI_SZ first - it is also an array, so it must be caught before bytes.
  if ($v -is [string[]]) { return ($v -join ' ') }
  # REG_BINARY. Testing -is [byte[]] was not enough: an untyped parameter can receive
  # the value as Object[], which is why every binary value was still reported wrong.
  if ($v -is [System.Array]) {
    try { return ((($v | ForEach-Object { ([byte]$_).ToString('x2') })) -join '') } catch { return ($v -join ' ') }
  }
  return [string]$v }

$regs = @(
  # EBOS Dark accent, written by apply-ebos-theme.ps1. Two byte orders on purpose:
  # ColorizationColor is ARGB, AccentColorMenu is ABGR. Values are decimal because the
  # registry returns these DWORDs as signed ints and Test-SameValue masks with 0xFFFFFFFF.
  @{p='HKCU\Software\Microsoft\Windows\DWM';v='ColorizationColor';d='4281825461';op='add';g='fs-darkmode'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';v='AccentColorMenu';d='4290082871';op='add';g='fs-darkmode'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';v='StartColorMenu';d='4290082871';op='add';g='fs-darkmode'},
  # fs-darkmode had no verification at all before these: the option was written by two
  # different blocks and nothing ever read the result back.
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';v='AppsUseLightTheme';d='0';op='add';g='fs-darkmode'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';v='SystemUsesLightTheme';d='0';op='add';g='fs-darkmode'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';v='ColorPrevalence';d='0';op='add';g='fs-darkmode'},
  # fs-notransparency rewrites this to 0, so a single ungated row reported the correct 0 as
  # a failure. Complementary gates: exactly one of the two is active on any given build.
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';v='EnableTransparency';d='1';op='add';g='!fs-notransparency'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';v='EnableTransparency';d='0';op='add';g='fs-notransparency'},
  # One representative event proves the [Sounds] scheme landed; blanking every event is
  # the mechanism, so a non-empty one here means the sweep never ran.
  @{p='HKCU\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current';v='';d='';op='add';g='fs-darkmode'},
  # Applied state, not file text: without this the theme only sits in Resources\Themes.
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes';v='CurrentTheme';d=($env:windir + '\Resources\Themes\EBOS-dark.theme');op='add';g='fs-darkmode+fs-wallpaper'},
  @{p='HKCU\Control Panel\Colors';v='Background';d='20 38 63';op='add';g='fs-darkmode'},
  # Writes that existed in the playbook with no assertion behind them. Found by diffing
  # every !registryValue against this table: 7 of 670 were missing.
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='HideSCAMeetNow';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='HideSCAMeetNow';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='HideSCAMeetNow';d='1';op='add';g=''},
  # Ungated deletes of legacy MPO values. A delete that silently did nothing is invisible
  # unless absence is asserted, which is exactly what these four rows do.
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';v='DisableOverlays';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm';v='EnableOverlay';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm';v='OverlayTestMode';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\Dwm';v='OverlayMinFPS';d='';op='delete';g=''},
  # Legacy cleanup done by !powerShell blocks: success means the value is gone.
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters';v='TcpTimedWaitDelay';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer';v='SimplifyQuickSettings';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Stickers';v='EnableStickers';d='';op='delete';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\WSearch';v='DelayedAutostart';d='';op='delete';g=''},
  # Deliberately absent: phase 5 also deletes Explorer\StuckRects3\Settings, which is
  # live taskbar state that Explorer recreates within seconds of logon. Asserting it is
  # gone would fail on every machine, so it is excluded from coverage on purpose.
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='FlightSettingsMaxPauseDays';d='3650';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseFeatureUpdatesStartTime';d='2025-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseFeatureUpdatesEndTime';d='2033-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseQualityUpdatesStartTime';d='2025-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseQualityUpdatesEndTime';d='2033-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseUpdatesStartTime';d='2025-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='PauseUpdatesExpiryTime';d='2033-01-01T00:00:00Z';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching';v='SearchOrderConfig';d='0';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching';v='DontSearchWindowsUpdate';d='1';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='ExcludeWUDriversInQualityUpdate';d='1';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update';v='ExcludeWUDriversInQualityUpdate';d='1';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\Update';v='ExcludeWUDriversInQualityUpdate';d='1';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\Update\ExcludeWUDriversInQualityUpdate';v='value';d='1';op='add';g='disable-auto-driver-updates'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='';d='';op='delete';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='';d='';op='delete';g='remove-onedrive'},
  @{p='HKCU\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='System.IsPinnedToNameSpaceTree';d='0';op='add';g='remove-onedrive'},
  @{p='HKCU\Software\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='System.IsPinnedToNameSpaceTree';d='0';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='System.IsPinnedToNameSpaceTree';d='0';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Wow6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}';v='System.IsPinnedToNameSpaceTree';d='0';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFT.exe';v='Debugger';d='%SystemRoot%\System32\taskkill.exe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBar.exe';v='Debugger';d='%SystemRoot%\System32\taskkill.exe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFTServer.exe';v='Debugger';d='%SystemRoot%\System32\taskkill.exe';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Microsoft\GameBar';v='ShowStartupPanel';d='0';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebar';v='';d='URL:ms-gamebar';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebar';v='URL Protocol';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebar';v='NoOpenWith';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebar\shell\open\command';v='';d='%SystemRoot%\System32\systray.exe';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebarservices';v='';d='URL:ms-gamebarservices';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebarservices';v='URL Protocol';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebarservices';v='NoOpenWith';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamebarservices\shell\open\command';v='';d='%SystemRoot%\System32\systray.exe';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamingoverlay';v='';d='URL:ms-gamingoverlay';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamingoverlay';v='URL Protocol';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamingoverlay';v='NoOpenWith';d='';op='add';g='remove-xbox'},
  @{p='HKCR\ms-gamingoverlay\shell\open\command';v='';d='%SystemRoot%\System32\systray.exe';op='add';g='remove-xbox'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='PreInstalledAppsEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='PreInstalledAppsEnabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications';v='NoCloudApplicationNotification';d='1';op='add';g='remove-store'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='OemPreInstalledAppsEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SilentInstalledAppsEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SilentInstalledAppsEnabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\WindowsStore';v='DisableOSUpgrade';d='1';op='add';g='remove-store'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\WindowsStore';v='AutoDownload';d='2';op='add';g='remove-store'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender';v='DisableAntiSpyware';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender';v='DisableAntiVirus';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection';v='DisableRealtimeMonitoring';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection';v='DisableBehaviorMonitoring';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection';v='DisableOnAccessProtection';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection';v='DisableScanOnRealtimeEnable';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet';v='SpyNetReporting';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet';v='SubmitSamplesConsent';d='2';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='ServiceEnabled';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';v='SecurityHealth';d='';op='delete';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='SettingsPageVisibility';d='hide:windowsdefender';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';v='WindowsDefender';d='';op='delete';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';v='SecurityHealth';d='030000000000000000000000';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='SmartScreenEnabled';d='Off';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='EnableSmartScreen';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments';v='ScanWithAntiVirus';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments';v='SaveZoneInformation';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments';v='ScanWithAntiVirus';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments';v='SaveZoneInformation';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments';v='ScanWithAntiVirus';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Associations';v='DefaultFileTypeRisk';d='6152';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Associations';v='DefaultFileTypeRisk';d='6152';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard';v='EnableVirtualizationBasedSecurity';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard';v='HyperVVirtualizationBasedSecurityOptout';d='1';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard';v='RequirePlatformSecurityFeatures';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard';v='LsaCfgFlags';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard';v='ConfigureSystemGuardLaunch';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity';v='Enabled';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity';v='WasEnabledBy';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard';v='Enabled';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard';v='Enabled';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Lsa';v='LsaCfgFlags';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard';v='EnableVirtualizationBasedSecurity';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard';v='RequirePlatformSecurityFeatures';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard';v='LsaCfgFlags';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity';v='Enabled';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard\Scenarios\CredentialGuard';v='Enabled';d='0';op='add';g='disable-mitigations'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost';v='EnableWebContentEvaluation';d='0';op='add';g='disable-defender'},
  @{p='HKCU\SOFTWARE\Microsoft\Edge';v='SmartScreenEnabled';d='0';op='add';g='disable-defender'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost';v='PreventOverride';d='0';op='add';g='disable-defender'},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost';v='EnableWebContentEvaluation';d='0';op='add';g='disable-defender'},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost';v='PreventOverride';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='NotifyMalicious';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='NotifyPasswordReuse';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='NotifyUnsafeApp';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='CaptureThreatWindow';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WTDS\Components';v='AutomaticDataCollection';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';v='FeatureSettingsOverride';d='3';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';v='FeatureSettingsOverrideMask';d='3';op='add';g='disable-mitigations'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Office\16.0\Teams';v='PreventInstallationFromMsi';d='1';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Office\16.0\common\officeupdate';v='preventteamsinstall';d='1';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Office\Teams';v='PreventInstallationFromMsi';d='1';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect';v='LoadBehavior';d='0';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect';v='LoadBehavior';d='0';op='add';g='remove-bloat'},
  @{p='HKCU\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect';v='LoadBehavior';d='0';op='add';g='remove-bloat'},
  @{p='HKU\.DEFAULT\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect';v='LoadBehavior';d='0';op='add';g='remove-bloat'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Run';v='Teams';d='';op='delete';g='remove-bloat'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Run';v='com.squirrel.Teams.Teams';d='';op='delete';g='remove-bloat'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Run';v='MSTeams';d='';op='delete';g='remove-bloat'},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Run';v='TeamsMachineInstaller';d='';op='delete';g='remove-bloat'},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration';v='IsResumeAllowed';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume';v='Enabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CDP';v='CdpSessionUserAuthzPolicy';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CDP';v='NearShareChannelUserAuthzPolicy';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CDP';v='RomeSdkChannelUserAuthzPolicy';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='EnableMmx';d='';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='EnableCdp';d='';op='delete';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\1387020943';v='EnabledState';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\Wifi\AllowAutoConnectToWiFiSenseHotspots';v='value';d='0';op='add';g='disable-wifi'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';v='TurnOffWindowsCopilot';d='1';op='add';g='remove-ai'},
  @{p='HKCU\Software\Microsoft\Windows\Shell\Copilot\BingChat';v='IsUserEligible';d='0';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\WindowsNotepad';v='DisableAIFeatures';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\WindowsNotepad';v='DisableWritingTools';d='1';op='add';g='remove-ai'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='AutoOpenCopilotLargeScreens';d='0';op='add';g='remove-ai'},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='DisableCopilotAI';d='1';op='add';g='remove-ai'},
  @{p='HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';v='TurnOffWindowsCopilot';d='1';op='add';g='remove-ai'},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='DisableAIDataAnalysis';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\WindowsNotepad';v='DisableAIFeaturesInNotepad';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';v='DisableAIDataAnalysis';d='1';op='add';g='remove-ai'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='NOC_GLOBAL_SETTING_SHOW_IN_SETTINGS';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='NOC_GLOBAL_SETTING_SHOW_IN_SETTINGS';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Office\16.0\Common\OfficeUpdate';v='preventcopilotinstall';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\PushToInstall';v='DisablePushToInstall';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\WindowsAI';v='TurnOffWindowsCopilot';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\WindowsAI';v='DisableAIDataAnalysis';d='1';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent';v='DisableConsumerAccountStateContent';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent';v='DisableCloudOptimizedContent';d='1';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System';v='EnableFirstLogonAnimation';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsMitigation';v='UserPreference';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-370697Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications';v='GlobalUserDisabled';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore';v='HarvestContacts';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore';v='DisableRoamingSync';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-353696Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-370700Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Siuf\Rules';v='NumberOfSIUFInPeriod';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';v='ShowGlobalPrompts';d='0';op='add';g='disable-location'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='BingSearchEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';v='HasAccepted';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Personalization\Settings';v='AcceptedPrivacyPolicy';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Siuf\Rules';v='PeriodInNanoSeconds';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\International\User Profile';v='HttpAcceptLanguageOptOut';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';v='HasAccepted';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Personalization\Settings';v='AcceptedPrivacyPolicy';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Siuf\Rules';v='NumberOfSIUFInPeriod';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Siuf\Rules';v='PeriodInNanoSeconds';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\International\User Profile';v='HttpAcceptLanguageOptOut';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';v='ScoobeSystemSettingEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='DeviceHistoryEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-400923Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-338393Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\AppManagement\AppSettings';v='ArchiveAppsEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-353694Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Input\Settings';v='InsightsEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\InputPersonalization';v='RestrictImplicitInkCollection';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='BackgroundAppGlobalToggle';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\InkingAndTypingPersonalization';v='Value';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\InputPersonalization';v='RestrictImplicitTextCollection';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='HistoryViewEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR';v='CursorCaptureEnabled';d='0';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR';v='AudioCaptureEnabled';d='0';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR';v='MicrophoneCaptureEnabled';d='0';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\MdmCommon\SettingValues';v='LocationSyncEnabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';v='HasAccepted';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='NOC_GLOBAL_SETTING_TOASTS_ENABLED';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='NOC_GLOBAL_SETTING_BADGE_ENABLED';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy';v='fMinimizeConnections';d='3';op='add';g='disable-wifi'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\MRT';v='DontOfferThroughWUAU';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet';v='LocalSettingOverrideSpynetReporting';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet';v='DisableBlockAtFirstSeen';d='1';op='add';g='disable-defender'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsDynamicSearchBoxEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='SafeSearchMode';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsAADCloudSearchEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsMSACloudSearchEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsDeviceSearchHistoryEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsMSFTSearchFeedEnabled';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsMSFTSearchFeedEnabled';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings';v='IsMSFTCloudSearchEnabled';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';v='IOMMUFlags';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control';v='SvcHostSplitThresholdInKB';d='4294967295';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control';v='WaitToKillServiceTimeout';d='2000';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat';v='AllowTelemetry';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\FTH';v='Enabled';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';v='DisablePagingExecutive';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel';v='GlobalTimerResolutionRequests';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel';v='SerializeTimerExpiration';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Superfetch/StoreLog';v='Enable';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Superfetch/Main';v='Enable';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Superfetch/PfApLog';v='Enable';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions';v='IoPriority';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sppsvc.exe\PerfOptions';v='CpuPriorityClass';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sppsvc.exe\PerfOptions';v='IoPriority';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions';v='CpuPriorityClass';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions';v='CpuPriorityClass';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions';v='IoPriority';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\lsass.exe\PerfOptions';v='CpuPriorityClass';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='HibernateEnabled';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';v='HideHibernate';d='1';op='add';g='disable-power-saving'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters';v='MaxUserPort';d='65534';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile';v='SystemResponsiveness';d='10';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Multimedia\Audio';v='UserDuckingPreference';d='3';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Multimedia\Audio';v='UserDuckingPreference';d='3';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\AFD\Parameters';v='DynamicSendBufferDisable';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\ea062031-0e34-4ff1-9b6d-eb1059334028';v='Attributes';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\5d76a2ca-e8c0-402f-a133-2158492d58ad';v='Attributes';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\2430ab6f-a520-44a2-9601-f7f23b5134b1';v='Attributes';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583';v='Attributes';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';v='TdrDelay';d='10';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters';v='MouseDataQueueSize';d='100';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters';v='KeyboardDataQueueSize';d='100';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl';v='Win32PrioritySeparation';d='2';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='RawMouseThrottleEnabled';d='';op='delete';g=''},
  @{p='HKCU\Control Panel\Mouse';v='RawMouseThrottleForced';d='';op='delete';g=''},
  @{p='HKCU\Control Panel\Mouse';v='RawMouseThrottleDuration';d='';op='delete';g=''},
  @{p='HKCU\Control Panel\Mouse';v='RawMouseThrottleLeeway';d='';op='delete';g=''},
  @{p='HKCU\Control Panel\Mouse';v='DoubleClickSpeed';d='480';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='SleepStudyDisabled';d='1';op='add';g='disable-power-saving'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters';v='DisableBandwidthThrottling';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\AFD\Parameters';v='FastSendDatagramThreshold';d='1500';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\Activation';v='Manual';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance';v='fAllowToGetHelp';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='CoalescingFlushInterval';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows';v='RITdemonTimerPowerSaveElapse';d='';op='delete';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\CI\Config';v='VulnerableDriverBlocklistEnable';d='0';op='add';g='disable-mitigations'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='EnergyEstimationEnabled';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='CoalescingTimerInterval';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Power';v='DeepIoCoalescingEnabled';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows';v='RITdemonTimerPowerSaveCoalescing';d='';op='delete';g=''},
  @{p='HKCU\Control Panel\Desktop';v='ScreenSaveActive';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='MouseThreshold2';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='MenuShowDelay';d='1';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='ActiveWindowTracking';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='MouseSpeed';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='Beep';d='No';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='MouseThreshold1';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='ScreenSaveTimeOut';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='MouseTrails';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Mouse';v='MouseAccel';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='JPEGImportQuality';d='100';op='add';g=''},
  # fs-wallpaper: the PNGs are already checked as files. These are the pointers that
  # make them appear - a correct file that nothing references is a black screen.
  @{p='HKU\.DEFAULT\Control Panel\Desktop';v='Wallpaper';d='%SystemRoot%\Web\Wallpaper\EBOS\wallpaper.png';op='add';g='fs-wallpaper'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization';v='LockScreenImagePath';d='%SystemRoot%\Web\Wallpaper\EBOS\lockscreen.png';op='add';g='fs-wallpaper'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization';v='LockScreenImageUrl';d='%SystemRoot%\Web\Wallpaper\EBOS\lockscreen.png';op='add';g='fs-wallpaper'},
  @{p='HKCU\Control Panel\Mouse';v='SnapToDefaultButton';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';v='VisualFXSetting';d='3';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\FontSmoothing';v='DefaultValue';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\TooltipAnimation';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DropShadow';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListBoxSmoothScrolling';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\DWM';v='AlwaysHibernateThumbnails';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Control Panel\Desktop';v='UserPreferencesMask';d='9032038010000000';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\SelectionFade';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DragFullWindows';v='DefaultValue';d='1';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop\WindowMetrics';v='MinAnimate';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ControlAnimations';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\CursorShadow';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='IconsOnly';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListviewAlphaSelect';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Control Panel\Desktop';v='FontSmoothing';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\MenuAnimation';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ListviewShadow';d='1';op='add';g='fs-noanimations'},
  @{p='HKCU\Control Panel\Desktop';v='DragFullWindows';d='1';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ListviewAlphaSelect';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\TaskbarAnimations';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarAnimations';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\DWM';v='EnableAeroPeek';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\AnimateMinMax';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DWMSaveThumbnailEnabled';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListviewShadow';v='DefaultValue';d='1';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ThumbnailsOrIcon';v='DefaultValue';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ComboBoxAnimation';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DWMAeroPeekEnabled';v='DefaultValue';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarGlomLevel';d='2';op='add';g='fs-w10-taskbar'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='MMTaskbarGlomLevel';d='2';op='add';g='fs-w10-taskbar'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power';v='HiberbootEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Desktop';v='JPEGImportQuality';d='100';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell';v='SignInMode';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device';v='DevicePasswordLessBuildVersion';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell';v='TabletMode';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='DisableEdgeDesktopShortcutCreation';d='1';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='ShowRecommendations';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='EnablePrelaunch';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance';v='MaintenanceDisabled';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_ShowFrequentList';d='0';op='add';g=''},
  @{p='HKCU\System\GameConfigStore';v='GameDVR_Enabled';d='0';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR';v='AppCaptureEnabled';d='0';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_AccountNotifications';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='EnableSnapAssistFlyoutOnHover';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='EnableSnapAssistFlyout';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\ActionManager\Installed\System.DescribeImage';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\TabletTip\1.7';v='EnableAutocorrection';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_ShowRecentList';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='SnapAssist';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='MultiTaskingAltTabFilter';d='3';op='add';g=''},
  @{p='HKCU\Control Panel\UnsupportedHardwareNotificationCache';v='SV2';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='SnapFill';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications';v='ToastEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\GameBar';v='UseNexusForGameBarEnabled';d='0';op='add';g='remove-xbox'},
  @{p='HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell';v='FolderType';d='NotSpecified';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='EnableSnapBar';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\TabletTip\1.7';v='EnableSpellchecking';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='JointResize';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32';v='';d='';op='add';g='fs-w10-context'},
  @{p='HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32';v='';d='';op='add';g='fs-w10-context'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='SearchboxTaskbarMode';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search';v='SearchboxTaskbarMode';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarMn';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarMn';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowCopilotButton';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowCopilotButton';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='IsEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='IsEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings';v='TaskbarEndTask';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings';v='TaskbarEndTask';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarAl';d='0';op='add';g='fs-w10-tbleft'},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='TaskbarAl';d='0';op='add';g='fs-w10-tbleft'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\14\3895955085';v='EnabledStateOptions';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\14\3895955085';v='EnabledState';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\CDP';v='DragTrayEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CDP';v='DragTrayEnabled';d='0';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\PowerOptions';v='Position';d='Middle';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\PowerOptions';v='MUIVerb';d='Power Plans';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\PowerOptions';v='Icon';d='powercpl.dll';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\PowerOptions\command';v='';d='control.exe powercfg.cpl';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\003-SafeNet';v='';d='Safe Mode + Networking';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode';v='MUIVerb';d='Safe Mode';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\002-Safe';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\001-Normal\command';v='';d='powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/c,bcdedit /deletevalue {current} safeboot & bcdedit /deletevalue {current} safebootalternateshell & shutdown -r -t 00 -f'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\003-SafeNet\command';v='';d='powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/c,bcdedit /set {current} safeboot network & bcdedit /deletevalue {current} safebootalternateshell & shutdown -r -t 00 -f'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\001-Normal';v='';d='Normal Mode';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\002-Safe\command';v='';d='powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/c,bcdedit /set {current} safeboot minimal & bcdedit /deletevalue {current} safebootalternateshell & shutdown -r -t 00 -f'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\001-Normal';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\003-SafeNet';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\004-SafeCmd';v='';d='Safe Mode + CMD';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\004-SafeCmd\command';v='';d='powershell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/c,bcdedit /set {current} safeboot minimal & bcdedit /set {current} safebootalternateshell yes & shutdown -r -t 00 -f'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode';v='SubCommands';d='';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode';v='icon';d='bootux.dll,-1032';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\002-Safe';v='';d='Safe Mode';op='add';g=''},
  @{p='HKCR\DesktopBackground\Shell\BootMode\Shell\004-SafeCmd';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\002-OptOne\command';v='';d='PowerShell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/k, defrag %1 /O /H'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\Drive\shell\DriveTools';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\003-OptAll\command';v='';d='PowerShell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/k, defrag /C /O /H'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\002-OptOne';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\002-OptOne';v='MUIVerb';d='Optimize Drive';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\001-Analyze\command';v='';d='PowerShell -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/s,/k, defrag %1 /A'' -Verb runAs"';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\003-OptAll';v='MUIVerb';d='Optimize All Drives';op='add';g=''},
  @{p='HKCR\Drive\shell\DriveTools';v='Icon';d='dfrgui.exe';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\003-OptAll';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\001-Analyze';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Drive\Shell\DriveTools\shell\001-Analyze';v='MUIVerb';d='Analyze Drive';op='add';g=''},
  @{p='HKCR\Drive\shell\DriveTools';v='SubCommands';d='';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';v='EditionSubManufacturer';d='EBOS';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';v='EditionSubstring';d='EBOS';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';v='EditionSubVersion';d='EBOS';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation';v='Manufacturer';d='EBOS';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation';v='SupportURL';d='https://discord.gg/9cHp2Jwq4b';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation';v='Model';d='EBOS';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion';v='RegisteredOrganization';d='EBOS';op='add';g=''},
  @{p='HKCU\Environment';v='DOTNET_CLI_TELEMETRY_OPTOUT';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Environment';v='DOTNET_CLI_TELEMETRY_OPTOUT';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Arrow';d='%SystemRoot%\Cursors\EBOS\ebos-arrow.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Help';d='%SystemRoot%\Cursors\EBOS\ebos-help.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='AppStarting';d='%SystemRoot%\Cursors\EBOS\ebos-appstarting.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Wait';d='%SystemRoot%\Cursors\EBOS\ebos-wait.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Crosshair';d='%SystemRoot%\Cursors\EBOS\ebos-cross.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='IBeam';d='%SystemRoot%\Cursors\EBOS\ebos-ibeam.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='NWPen';d='%SystemRoot%\Cursors\EBOS\ebos-pen.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='No';d='%SystemRoot%\Cursors\EBOS\ebos-no.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='SizeNS';d='%SystemRoot%\Cursors\EBOS\ebos-sizens.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='SizeWE';d='%SystemRoot%\Cursors\EBOS\ebos-sizewe.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='SizeNWSE';d='%SystemRoot%\Cursors\EBOS\ebos-sizenwse.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='SizeNESW';d='%SystemRoot%\Cursors\EBOS\ebos-sizenesw.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='SizeAll';d='%SystemRoot%\Cursors\EBOS\ebos-sizeall.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='UpArrow';d='%SystemRoot%\Cursors\EBOS\ebos-up.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Hand';d='%SystemRoot%\Cursors\EBOS\ebos-hand.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Pin';d='%SystemRoot%\Cursors\EBOS\ebos-pin.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Person';d='%SystemRoot%\Cursors\EBOS\ebos-person.ani';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='Scheme Source';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Control Panel\Cursors';v='CursorBaseSize';d='32';op='add';g=''},
  @{p='HKCU\Environment';v='POWERSHELL_TELEMETRY_OPTOUT';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Environment';v='POWERSHELL_TELEMETRY_OPTOUT';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device';v='DisableDSTThrottle';d='1';op='add';g='disable-power-saving'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications';v='ConfigureChatAutoInstall';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\Maps';v='AutoUpdateEnabled';d='0';op='add';g='disable-location'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo';v='Enabled';d='0';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Search';v='BackgroundAppGlobalToggle';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata';v='PreventDeviceMetadataFromNetwork';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate';v='workCompleted';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate';v='workCompleted';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='HideMCTLink';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';v='Value';d='Deny';op='add';g='disable-location'},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\CrashControl';v='AutoReboot';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\CrashControl\StorageTelemetry';v='DeviceDumpEnabled';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\BitLocker';v='PreventDeviceEncryption';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked';v='{7AD84985-87B4-4a16-BE58-8B72A5B390F7}';d='';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey';v='EnableEventTranscript';d='0';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate';v='UpdateNotificationLevel';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray';v='HideSystray';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Speech_OneCore\Preferences';v='ModelDownloadAllowed';d='0';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Internet Explorer\SQM';v='DisableCustomerImprovementProgram';d='1';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\Windows Error Reporting\Consent';v='DefaultOverrideBehavior';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Speech_OneCore\Preferences';v='VoiceActivationEnableAboveLockscreen';d='0';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient';v='CEIPEnabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input\TIPC';v='Enabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting';v='Disabled';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='TrayIconVisibility';d='0';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\Windows Error Reporting\Consent';v='DefaultConsent';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe';v='BlockedOobeUpdaters';d='["MS_Outlook","MS_Copilot","MS_CopilotUpdate","MS_WindowsCopilot","MS_WindowsAIX","MS_WindowsPhoton","MS_DevHome"]';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='RestartNotificationsAllowed2';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener';v='Start';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\SQMLogger';v='Start';d='0';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate';v='SetAllowOptionalContent';d='1';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate';v='AllowOptionalContent';d='3';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate';v='SetUpdateNotificationLevel';d='1';op='add';g=''},
  @{p='HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked';v='{596AB062-B4D2-4215-9F74-E9109B0A8153}';d='';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked';v='{e2bf9676-5f8f-435c-97eb-11607a5bedf7}';d='';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\DomainProfile';v='DisableNotifications';d='1';op='add';g=''},
  @{p='HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked';v='{e2bf9676-5f8f-435c-97eb-11607a5bedf7}';d='';op='add';g=''},
  @{p='HKLM\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked';v='{596AB062-B4D2-4215-9F74-E9109B0A8153}';d='';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\PublicProfile';v='DisableNotifications';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\StandardProfile';v='DisableNotifications';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\stornvme\Parameters\Device';v='IdlePowerMode';d='0';op='add';g='disable-power-saving'},
  @{p='HKLM\Software\Policies\Microsoft\EventViewer';v='MicrosoftEventVwrDisableLinks';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input\Settings';v='EnableHwkbAutocorrection';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input\Settings';v='InsightsEnabled';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input\Settings';v='MultilingualEnabled';d='0';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Messenger\Client';v='CEIP';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input\Settings';v='EnableHwkbTextPrediction';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input';v='InputServiceEnabled';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Input';v='InputServiceEnabledForCCI';d='1';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel';v='EnableWerUserReporting';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel';v='PowerOffFrozenProcessors';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\NDIS\Parameters';v='EnableNicAutoPowerSaverInSleepStudy';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\CloudExperienceHostOOBE';v='Start';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\AppSync';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Personalization';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\BrowserSettings';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Credentials';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Accessibility';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Windows';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync';v='SyncPolicy';d='5';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync';v='DisableSettingSync';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync';v='DisableSettingSyncUserOverride';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-280815Enabled';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\HighContrast';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackSavePickerContract';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Sound';v='Beep';d='no';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='WaitToKillAppTimeOut';d='2000';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackConnectedSearchHistory';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='ShowCloudFilesInQuickAccess';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='04';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Preferences';v='VoiceActivationEnableAboveLockscreen';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';v='ShowRecommendations';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\PackageState';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='HungAppTimeout';d='2000';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Preferences';v='VoiceActivationOn';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Blind Access';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowCortanaButton';d='0';op='add';g='remove-ai'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\DesktopTheme';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\On';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='256';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='RotatingLockScreenEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='RemediationRequired';d='0';op='add';g=''},
  @{p='HKCU\Software\Policies\Microsoft\Messenger\Client';v='CEIP';d='2';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Preference';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\ToggleKeys';v='Flags';d='56';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\AudioDescription';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\StickyKeys';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='08';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\SlateLaunch';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Personalization\Desktop Slideshow';v='AnimationDuration';d='0';op='add';g='fs-noanimations'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless';v='ScoobeCheckCompleted';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-314559Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='1024';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='AllowSearchToUseLocation';d='0';op='add';g=''},
  @{p='HKCU\Software\Classes\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='01';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Control Panel\Accessibility\SoundSentry';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-338388Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\StartLayout';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='NoNetCrawling';d='1';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\TimeOut';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Input\Settings';v='MultilingualEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackShareContractMFU';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Clipboard';v='CloudClipRDPOverride';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Input\TIPC';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Search\Preferences';v='WholeFileSystem';d='1';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='PreInstalledAppsEverEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='01';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-338387Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Input\Settings';v='UserStatsEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='2048';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='02';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='ContentDeliveryAllowed';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Desktop';v='AutoEndTasks';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-280811Enabled';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\ShowSounds';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-202914Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='VoiceShortcut';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-314563Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='32';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Control Panel\Accessibility\MouseKeys';v='Flags';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-353698Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='DisableSearchBoxSuggestions';d='1';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='CanCortanaBeEnabled';d='0';op='add';g='remove-ai'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Language';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='FeatureManagementEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy';v='128';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack';v='ShowedToastAtLevel';d='1';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackSearchContract';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackOpenPickerContract';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';v='Value';d='Deny';op='add';g='disable-location'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_TrackCachedFileUpdaterContract';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SoftLandingEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Input\Settings';v='EnableHwkbTextPrediction';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Input\Settings';v='Insights';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-310093Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Preferences';v='ModelDownloadAllowed';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Response';v='Flags';d='61';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Response';v='AutoRepeatDelay';d='300';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Response';v='AutoRepeatRate';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Response';v='DelayBeforeAcceptance';d='0';op='add';g=''},
  @{p='HKCU\Control Panel\Accessibility\Keyboard Response';v='BounceTime';d='300';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SystemPaneSuggestionsEnabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContentEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Input\Settings';v='EnableHwkbAutocorrection';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Clipboard';v='CloudClipboardAutomaticUpload';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Notepad';v='ShowStoreBanner';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='DisablePreviewWindow';d='1';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='DisablePreviewDesktop';d='1';op='add';g=''},
  @{p='HKCU\SOFTWARE\Classes\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';v='Enabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='RotatingLockScreenOverlayEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-280810Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='CortanaEnabled';d='0';op='add';g='remove-ai'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';v='SubscribedContent-338389Enabled';d='0';op='add';g=''},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowSyncProviderNotifications';d='0';op='add';g=''},
  @{p='HKCR\Directory\shell\runas\command';v='IsolatedCommand';d='cmd.exe /c takeown /f %1 /r /d y && icacls %1 /grant administrators:F';op='add';g=''},
  @{p='HKCR\.pow';v='FriendlyTypeName';d='Power Plan';op='add';g=''},
  @{p='HKCR\Directory\shell\runas';v='NoWorkingDirectory';d='';op='add';g=''},
  @{p='HKCR\Microsoft.PowerShellScript.1\Shell\RunAs';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Microsoft.PowerShellScript.1';v='FriendlyTypeName';d='Windows PowerShell Script';op='add';g=''},
  @{p='HKCR\Directory\shell\runas';v='HasLUAShield';d='';op='add';g=''},
  @{p='HKCR\Microsoft.PowerShellScript.1\Shell\Open\Command';v='';d='"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File "%1"';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync';v='Value';d='Deny';op='add';g='disable-bluetooth'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync';v='Value';d='Deny';op='add';g='disable-bluetooth'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiData';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiData';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiDirect';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiDirect';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\cellularData';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\cellularData';v='Value';d='Deny';op='add';g='disable-wifi'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator';v='NoActiveProbe';d='0';op='add';g=''},
  @{p='HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet';v='EnableActiveProbing';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Microsoft Antimalware\Real-Time Protection';v='DisableScanOnRealtimeEnable';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Microsoft Antimalware\Real-Time Protection';v='DisableOnAccessProtection';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\MRT';v='DontReportInfectionInformation';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\RemovalTools\MpGears';v='HeartbeatTrackingIndex';d='0';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\RemovalTools\MpGears';v='SpyNetReportingLocation';d='';op='add';g='disable-defender'},
  @{p='HKLM\Software\Policies\Microsoft\Windows Defender\Signature Updates';v='DisableScheduledSignatureUpdateOnBattery';d='1';op='add';g='disable-defender'},
  @{p='HKLM\Software\Policies\Microsoft\Windows Defender\Reporting';v='DisableGenericRePorts';d='1';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SmartScreenSettings';v='ConfigureAppInstallControl';d='Anywhere';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume';v='value';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='AUPowerManagement';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';v='NoAUAsDefaultShutdownOption';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='DeferFeatureUpdates';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='ManagePreviewBuildsPolicyValue';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='DeferFeatureUpdatesPeriodInDays';d='365';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='ManagePreviewBuilds';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';v='NoAutoRebootWithLoggedOnUsers';d='1';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU';v='AUOptions';d='2';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';v='ExcludeWUDriversInQualityUpdate';d='1';op='add';g=''},
  @{p='HKCU\Software\Policies\Microsoft\Windows\WindowsUpdate\AU';v='NoAUAsDefaultShutdownOption';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';v='TargetReleaseVersion';d='1';op='add';g=''},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Install{65C35B14-6C1D-4122-AC46-7148CC9D6497}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';d='1';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate';v='Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='InstallDefault';d='0';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate';v='IsEdgeStableUninstalled';d='1';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Update{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Update{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Microsoft\EdgeUpdate';v='IsEdgeStableUninstalled';d='1';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\MicrosoftEdge\Main';v='AllowPrelaunch';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='UpdateDefault';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Update{65C35B14-6C1D-4122-AC46-7148CC9D6497}';d='0';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Microsoft\EdgeUpdate';v='DoNotUpdateToEdgeWithChromium';d='1';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate';v='DoNotUpdateToEdgeWithChromium';d='1';op='add';g='remove-edge'},
  @{p='HKLM\Software\OEM\MicrosoftEdge';v='AutoLaunchOnLogonBehavior';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='CreateDesktopShortcutDefault';d='0';op='add';g='remove-edge'},
  @{p='HKLM\Software\Policies\Microsoft\EdgeUpdate';v='Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';d='1';op='add';g='remove-edge'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate';v='AutoDownload';d='2';op='add';g='remove-store'},
  @{p='HKCU\SOFTWARE\Microsoft\GameBar';v='GamePanelStartupTipIndex';d='3';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings';v='DownloadMode';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config';v='DODownloadMode';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config';v='DownloadMode_BackCompat';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings';v='DOPercentageMaxBackgroundBandwidth';d='10';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings';v='DOPercentageMaxForegroundBandwidth';d='70';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings';v='DOPercentageMaxUploadBandwidth';d='50';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings';v='DOMonthlyUploadDataCap';d='500';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps';v='AgentActivationLastUsed';d='';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps';v='AgentActivationOnLockScreenEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps';v='AgentActivationEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy';v='TailoredExperiencesWithDiagnosticDataEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Search';v='CortanaConsent';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Clipboard';v='EnableClipboardHistory';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Clipboard';v='EnableClipboardHistory';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense';v='AllowStorageSenseGlobal';d='0';op='add';g='disable-storage-sense'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Security and Maintenance\Checks\{E8433B72-5842-4d43-8645-BC2C35960837}.check.101';v='CheckSetting';d='23000000b200000000000000000000000200000001000000a4d1d6002fe7dc0100000000000000000000000000000000';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\EnergyRecommendations\Settings\EnergyRecommendations';v='ShowRecommendations';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Energy\EnergySaverState';v='EnergySaverState';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\Security\EnergySaver';v='EnergyRecommendations';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\Security\EnergySaver';v='EnergyRecommendations';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';v='SettingsPageVisibilityNotifications';d='0';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System';v='NoConnectedUser';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='ShowInSettings';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings';v='ShowInSettings';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\PushNotifications';v='ToastEnabled';d='0';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';v='ScoobeSystemSettingEnabled';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='LaunchTo';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowFrequent';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer';v='ShowFrequent';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='ShowRecent';d='0';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_AllAppsView';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';v='Start_AllAppsView';d='1';op='add';g=''},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Start';v='StartLayoutMode';d='1';op='add';g=''},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Start';v='StartLayoutMode';d='1';op='add';g=''},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive';v='DisableFileSyncNGSC';d='1';op='add';g='remove-onedrive'},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search';v='BackgroundAppGlobalToggle';d='0';op='add';g='fs-privacy'},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications';v='GlobalUserDisabled';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\humanPresence';v='Value';d='Allow';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\System\AllowExperimentation';v='value';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Maps';v='AutoDownloadAndUpdateMapData';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\Maps';v='AllowUntriggeredNetworkTrafficOnSettingsPage';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\TabletPC';v='PreventHandwritingDataSharing';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Microsoft\SQMClient';v='UploadDisableFlag';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots';v='Enabled';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config';v='AutoConnectAllowedOEM';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform';v='NoGenTicket';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe';v='Debugger';d='%SYSTEMROOT%\System32\taskkill.exe';op='add';g='fs-privacy'},
  @{p='HKCU\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications';v='NoTileApplicationNotification';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Microsoft\Speech_OneCore\Preferences';v='VoiceActivationDefaultOn';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetooth';v='Value';d='Deny';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting';v='value';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Microsoft\Windows\Windows Error Reporting';v='LoggingDisabled';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='CortanaEnabled';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds';v='EnableExperimentation';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\humanInterfaceDevice';v='Value';d='Allow';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\spatialPerception';v='Value';d='Allow';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='DisableLockScreenAppNotifications';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe';v='Debugger';d='%SYSTEMROOT%\System32\taskkill.exe';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Policies\Microsoft\SQMClient\Windows';v='CEIPEnable';d='0';op='add';g='fs-privacy'},
  @{p='HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\LooselyCoupled';v='Value';d='Deny';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Microsoft\Windows\Windows Error Reporting';v='DontSendAdditionalData';d='1';op='add';g='fs-privacy'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer';v='ShowRecent';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='AllowOnlineTips';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds';v='AllowBuildPreview';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\System';v='EnableActivityFeed';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports';v='PreventHandwritingErrorReports';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Microsoft\SQMClient\Windows';v='CEIPEnable';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE';v='DisableVoice';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\backgroundSpatialPerception';v='Value';d='Allow';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds';v='EnableConfigFlighting';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\PolicyManager\default\Experience\AllowCortana';v='value';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Search';v='CortanaInAmbientMode';d='0';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\gazeInput';v='Value';d='Allow';op='add';g='fs-privacy'},
  @{p='HKLM\Software\Policies\Microsoft\Windows\Windows Error Reporting';v='Disabled';d='1';op='add';g='fs-privacy'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility';v='HideInsiderPage';d='1';op='add';g='fs-privacy'},
  @{p='HKCU\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications';v='EnableAccountNotifications';d='0';op='add';g='fs-privacy'},
  @{p='HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications';v='EnableAccountNotifications';d='0';op='add';g='fs-privacy'}
)
# A registryKey delete cancels any registryValue written under that path. Last-write-
# wins only compared values against values, so the GameBar IFEO entries - written, then
# their whole key removed - were reported missing on every single run.
$keys = @(
  # 2 of 76 !registryKey actions were unchecked; both are deprovision markers.
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MSPaint_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WidgetsPlatformRuntime_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.549981C3F5F10_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingNews_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingWeather_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Clipchamp.Clipchamp_yxz26nhyzhsrt';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.GetHelp_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Getstarted_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.OutlookForWindows_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.People_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SkypeApp_kzf8qxf38zg5c';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Todos_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsAlarms_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsMaps_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.YourPhone_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneMusic_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneVideo_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Copilot_8wekyb3d8bbwe';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Copilot_cw5n1h2txyewy';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.Client.Copilot_cw5n1h2txyewy';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.Client.AIX_cw5n1h2txyewy';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Ai.Copilot.Provider_cw5n1h2txyewy';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxApp_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.GamingApp_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxGameCallableUI_cw5n1h2txyewy';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxGamingOverlay_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxIdentityProvider_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.XboxSpeechToTextOverlay_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Xbox.TCUI_8wekyb3d8bbwe';op='add';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingSearch_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.DevHome_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Advertising.Xaml_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftPowerBIForWindows_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MixedReality.Portal_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Word_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Excel_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.PowerPoint_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.OutlookPWA_8wekyb3d8bbwe';op='add';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Flipgrid_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MailforSurfaceHub_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftTeamsforSurfaceHub_8wekyb3d8bbwe';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\7EE7776C.LinkedInforWindows_w1wdnht996qgy';op='add';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.OneDrive_8wekyb3d8bbwe';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.microsoftskydrive_8wekyb3d8bbwe';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SkyDrive_8wekyb3d8bbwe';op='add';g='remove-onedrive'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBar.exe';op='delete';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFT.exe';op='delete';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFTServer.exe';op='delete';g='remove-xbox'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy';op='add';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe';op='delete';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\AMSI\Providers\{2781761E-28E0-4109-99FE-B9D127C57AFE}';op='delete';g='disable-defender'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams Machine-Wide Installer';op='delete';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Teams Machine-Wide Installer';op='delete';g='remove-bloat'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftCopilot_8wekyb3d8bbwe';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MSCopilot_8wekyb3d8bbwe';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Copilot365_8wekyb3d8bbwe';op='add';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\CopilotUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\CopilotUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\MicrosoftWindowsClientAIXUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\MicrosoftWindowsClientAIXUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\MicrosoftWindowsClientCopilotUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\MicrosoftWindowsClientCopilotUpdate';op='delete';g='remove-ai'},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate';op='delete';g=''},
  @{p='HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate';op='delete';g=''},
  @{p='HKCR\DesktopBackground\Shell\Idle';op='delete';g=''}
)

$deletedKeys = @()
foreach ($k in $keys) { if ($k.op -eq 'delete') { $deletedKeys += $k.p.ToLower() } }

foreach ($e in $regs) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  $pl = $e.p.ToLower(); $under = $false
  foreach ($dk in $deletedKeys) { if ($pl -eq $dk -or $pl.StartsWith($dk + '\\')) { $under = $true; break } }
  if ($under) { $na++; continue }
  foreach ($full in (Expand-RegPath $e.p)) {
    $checked++
    $have = Format-RegValue (Read-RegValue $full $e.v)
    $label = $(if ($e.v) { $e.v } else { '(default)' })
    if ($e.op -eq 'delete') {
      if ($null -ne $have) { $bad++; $out += ('REGVALUE STILL PRESENT ' + $full + ' -> ' + $label + ' = ' + $have) }
    } elseif ($null -eq $have) {
      $bad++; $out += ('REGVALUE MISSING       ' + $full + ' -> ' + $label + ' (wanted ' + $e.d + ')')
    } elseif (-not (Test-SameValue $have ([string]$e.d))) {
      $bad++; $out += ('REGVALUE WRONG         ' + $full + ' -> ' + $label + ' = ' + $have + ' (wanted ' + $e.d + ')')
    } } }

foreach ($e in $keys) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  foreach ($full in (Expand-RegPath $e.p)) {
    $checked++
    $ex = Test-Path -Path $full
    if ($e.op -eq 'delete' -and $ex) { $bad++; $out += ('REGKEY STILL PRESENT   ' + $full) }
    if ($e.op -ne 'delete' -and -not $ex) { $bad++; $out += ('REGKEY MISSING         ' + $full) } } }

$svcs = @(
  @{n='DiagTrack';s='4';g=''},
  @{n='PcaSvc';s='4';g=''},
  @{n='InventorySvc';s='4';g=''},
  @{n='WpnService';s='4';g=''},
  @{n='webthreatdefsvc';s='4';g='disable-defender'},
  @{n='webthreatdefusersvc';s='4';g='disable-defender'},
  @{n='Spooler';s='4';g='disable-printing'},
  @{n='PrintNotify';s='4';g='disable-printing'},
  @{n='WlanSvc';s='3';g='disable-wifi'},
  @{n='wcncsvc';s='4';g='disable-wifi'},
  @{n='bthserv';s='4';g='disable-bluetooth'},
  @{n='BthAvctpSvc';s='4';g='disable-bluetooth'},
  @{n='BluetoothUserService';s='4';g='disable-bluetooth'},
  @{n='diagnosticshub.standardcollector.service';s='4';g=''},
  @{n='dmwappushservice';s='4';g=''},
  @{n='wisvc';s='4';g=''},
  @{n='MapsBroker';s='4';g='disable-location'},
  @{n='lfsvc';s='4';g='disable-location'},
  @{n='CDPUserSvc';s='4';g=''},
  @{n='Telemetry';s='4';g=''},
  @{n='GpuEnergyDrv';s='4';g='disable-power-saving'},
  @{n='NetBT';s='4';g='disable-wifi'},
  @{n='icssvc';s='4';g='disable-wifi'},
  @{n='lmhosts';s='4';g=''},
  @{n='TrkWks';s='4';g=''},
  @{n='edgeupdate';s='4';g='remove-edge'},
  @{n='edgeupdatem';s='4';g='remove-edge'},
  @{n='svsvc';s='4';g=''},
  @{n='wlidsvc';s='3';g=''},
  @{n='RetailDemo';s='4';g=''},
  @{n='WMPNetworkSvc';s='4';g=''},
  @{n='DialogBlockingService';s='4';g=''},
  @{n='AssignedAccessManagerSvc';s='4';g=''},
  @{n='AppVClient';s='4';g=''},
  @{n='DevQueryBroker';s='4';g=''},
  @{n='WSAIFabricSvc';s='4';g=''},
  @{n='PimIndexMaintenanceSvc';s='4';g=''},
  @{n='shpamsvc';s='4';g=''},
  @{n='SgrmBroker';s='4';g='disable-defender'},
  @{n='SgrmAgent';s='4';g='disable-defender'},
  @{n='BcastDVRUserService';s='4';g='remove-xbox'},
  @{n='xbgm';s='4';g='remove-xbox'},
  @{n='XblAuthManager';s='4';g='remove-xbox'},
  @{n='XblGameSave';s='4';g='remove-xbox'},
  @{n='XboxNetApiSvc';s='4';g='remove-xbox'},
  @{n='XboxGipSvc';s='4';g='remove-xbox'},
  @{n='uhssvc';s='4';g=''},
  @{n='whesvc';s='4';g=''},
  @{n='Fax';s='4';g=''},
  @{n='RemoteRegistry';s='4';g=''},
  @{n='RemoteAccess';s='4';g=''},
  @{n='SharedAccess';s='4';g='disable-wifi'},
  @{n='MessagingService';s='4';g=''},
  @{n='EFS';s='4';g=''},
  @{n='CscService';s='4';g=''},
  @{n='fdc';s='4';g=''},
  @{n='flpydisk';s='4';g=''},
  @{n='sfloppy';s='4';g=''},
  @{n='serial';s='4';g=''},
  @{n='serenum';s='4';g=''},
  @{n='sermouse';s='4';g=''},
  @{n='ErrDev';s='4';g=''},
  @{n='CompositeBus';s='4';g=''},
  @{n='SEMgrSvc';s='4';g=''},
  @{n='SCardSvr';s='4';g=''},
  @{n='ScDeviceEnum';s='4';g=''},
  @{n='HvHost';s='4';g='remove-hyperv'},
  @{n='hvservice';s='4';g='remove-hyperv'},
  @{n='hvcrash';s='4';g='remove-hyperv'},
  @{n='hyperkbd';s='4';g='remove-hyperv'},
  @{n='hypervideo';s='4';g='remove-hyperv'},
  @{n='Vid';s='4';g='remove-hyperv'},
  @{n='vmicguestinterface';s='4';g='remove-hyperv'},
  @{n='vmicheartbeat';s='4';g='remove-hyperv'},
  @{n='vmickvpexchange';s='4';g='remove-hyperv'},
  @{n='vmicrdv';s='4';g='remove-hyperv'},
  @{n='vmicshutdown';s='4';g='remove-hyperv'},
  @{n='vmictimesync';s='4';g='remove-hyperv'},
  @{n='vmicvmsession';s='4';g='remove-hyperv'},
  @{n='vmicvss';s='4';g='remove-hyperv'},
  @{n='WerSvc';s='4';g=''},
  @{n='troubleshootingsvc';s='4';g=''},
  @{n='UCPD';s='4';g=''},
  @{n='wercplsupport';s='4';g=''},
  @{n='WPCMonSvc';s='4';g=''},
  @{n='diagsvc';s='4';g=''},
  @{n='Wecsvc';s='4';g=''},
  @{n='Microsoft_Bluetooth_AvrcpTransport';s='4';g='disable-bluetooth'},
  @{n='BthA4dp';s='4';g='disable-bluetooth'},
  @{n='BthEnum';s='4';g='disable-bluetooth'},
  @{n='BthHFEnum';s='4';g='disable-bluetooth'},
  @{n='BthLEEnum';s='4';g='disable-bluetooth'},
  @{n='BTHMODEM';s='4';g='disable-bluetooth'},
  @{n='RFCOMM';s='4';g='disable-bluetooth'},
  @{n='BTAGService';s='4';g='disable-bluetooth'},
  @{n='BTHUSB';s='4';g='disable-bluetooth'},
  @{n='BTHPORT';s='4';g='disable-bluetooth'},
  @{n='BthMini';s='4';g='disable-bluetooth'},
  @{n='HidBth';s='4';g='disable-bluetooth'},
  @{n='DevicesFlowUserSvc';s='3';g=''},
  @{n='printworkflowusersvc';s='4';g='disable-printing'},
  @{n='PrintDeviceConfigurationService';s='4';g='disable-printing'},
  @{n='PrintScanBrokerService';s='4';g='disable-printing'},
  @{n='usbprint';s='4';g='disable-printing'},
  @{n='fhsvc';s='4';g='disable-printing'},
  @{n='stisvc';s='4';g='disable-printing'},
  # Written by phase 2 / phase 5 PowerShell, not by a !service action, so nothing
  # used to read them back. Same rule: absent service is N/A, wrong Start is a fail.
  @{n='PhoneSvc';s='4';g=''},
  @{n='CDPSvc';s='4';g=''},
  @{n='AppIDSvc';s='4';g='remove-ai'},
  @{n='WSearch';s='2';g=''}
)
foreach ($e in $svcs) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $e.n
  if (-not (Test-Path $k)) { $na++; continue }
  $checked++
  $cur = (Get-ItemProperty -Path $k -Name 'Start').Start
  if ($null -eq $cur) { $bad++; $out += ('SERVICE NO START VALUE ' + $e.n) }
  elseif ([string]$cur -ne [string]$e.s) { $bad++; $out += ('SERVICE WRONG START    ' + $e.n + ' = ' + $cur + ' (wanted ' + $e.s + ')') } }

$allTasks = @{}
foreach ($t in (Get-ScheduledTask)) { $allTasks[($t.TaskPath + $t.TaskName)] = $t.State }
$tasks = @(
  @{t='\Microsoft\Windows\UpdateOrchestrator\Driver Install';g='disable-auto-driver-updates'},
  @{t='\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance';g='disable-defender';op='delete'},
  @{t='\Microsoft\Windows\Windows Defender\Windows Defender Cleanup';g='disable-defender';op='delete'},
  @{t='\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan';g='disable-defender';op='delete'},
  @{t='\Microsoft\Windows\Windows Defender\Windows Defender Verification';g='disable-defender';op='delete'},
  @{t='\Microsoft\Windows\CrossDevice\CleanupResumeTimelineData';g='';op='delete'},
  @{t='\Microsoft\Windows\SystemUptime\Resume on Boot';g='';op='delete'},
  @{t='\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser';g=''},
  @{t='\Microsoft\Windows\Application Experience\StartupAppTask';g=''},
  @{t='\Microsoft\Windows\Customer Experience Improvement Program\Consolidator';g=''},
  @{t='\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip';g=''},
  @{t='\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector';g=''},
  @{t='\Microsoft\Windows\Feedback\Siuf\DmClient';g=''},
  @{t='\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\ReconcileFeatures';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\UsageDataFlushing';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting';g=''},
  @{t='\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem';g=''},
  @{t='\Microsoft\Windows\Windows Error Reporting\QueueReporting';g=''},
  @{t='\Microsoft\Windows\DiskFootprint\Diagnostics';g=''},
  @{t='\Microsoft\Windows\Device Information\Device';g=''},
  @{t='\Microsoft\Windows\Device Information\Device User';g=''},
  @{t='\Microsoft\Windows\Diagnosis\Scheduled';g=''},
  @{t='\Microsoft\Windows\Diagnosis\RecommendedTroubleshootingScanner';g=''},
  @{t='\Microsoft\Windows\MemoryDiagnostic\ProcessMemoryDiagnosticEvents';g=''},
  @{t='\Microsoft\Windows\MemoryDiagnostic\RunFullMemoryDiagnostic';g=''},
  @{t='\Microsoft\Windows\PI\Sqm-Tasks';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Scan';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Wake To Work';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Start Oobe Expedite Work';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScanAfterUpdate';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\Scheduled Start';g=''},
  @{t='\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration';g=''},
  @{t='\Microsoft\Windows\WindowsAI\Settings\InitialConfiguration';g=''},
  @{t='\Microsoft\Windows\Input\LocalUserSyncDataAvailable';g=''},
  @{t='\Microsoft\Windows\Input\MouseSyncDataAvailable';g=''},
  @{t='\Microsoft\Windows\Maps\MapsToastTask';g=''},
  @{t='\Microsoft\Windows\Maps\MapsUpdateTask';g=''},
  @{t='\Microsoft\Windows\Location\Notifications';g=''},
  @{t='\Microsoft\Windows\Location\WindowsActionDialog';g=''},
  @{t='\Microsoft\Windows\DUSM\dusmtask';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\BootstrapUsageDataReporting';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\GovernedFeatureUsageProcessing';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\ReconcileConfigs';g=''},
  @{t='\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReceiver';g=''},
  @{t='\Microsoft\Windows\Flighting\OneSettings\RefreshCache';g=''},
  @{t='\Microsoft\Windows\Sustainability\PowerGridForecastTask';g=''},
  @{t='\Microsoft\Windows\Maintenance\WinSAT';g=''},
  @{t='\Microsoft\Windows\Application Experience\MareBackup';g=''},
  @{t='\Microsoft\Windows\InstallService\ScanForUpdates';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task';g=''},
  @{t='\Microsoft\Windows\WDI\ResolutionHost';g=''},
  @{t='\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver';g=''},
  @{t='\Microsoft\Windows\InstallService\ScanForUpdatesAsUser';g=''},
  @{t='\Microsoft\Windows\InstallService\SmartRetry';g=''},
  @{t='\Microsoft\Windows\Autochk\Proxy';g=''},
  @{t='\Microsoft\Windows\Registry\RegIdleBackup';g=''},
  @{t='\Microsoft\Windows\AppxDeploymentClient\UCPD velocity';g=''},
  @{t='\Microsoft\Windows\Application Experience\PcaPatchDbTask';g=''},
  @{t='\Microsoft\Windows\SettingSync\BackgroundUploadTask';g=''},
  @{t='\Microsoft\Windows\CloudRestore\Backup';g=''},
  @{t='\Microsoft\Windows\CloudRestore\Restore';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Work';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UUS Failover Task';g=''},
  @{t='\Microsoft\Windows\Shell\FamilySafetyMonitor';g=''},
  @{t='\Microsoft\Windows\WaaSMedic\PerformRemediation';g=''},
  @{t='\Microsoft\Windows\CloudExperienceHost\CreateObjectTask';g=''},
  @{t='\Microsoft\Windows\RemoteAssistance\RemoteAssistanceTask';g=''},
  @{t='\Microsoft\Windows\UPnP\UPnPHostConfig';g=''},
  @{t='\Microsoft\Windows\Device Setup\Metadata Refresh';g=''},
  @{t='\Microsoft\Windows\Shell\FamilySafetyRefreshTask';g=''},
  @{t='\Microsoft\Windows\RetailDemo\CleanupOfflineContent';g=''},
  @{t='\Microsoft\Windows\SettingSync\NetworkStateChangeTask';g=''},
  @{t='\Microsoft\Windows\Sustainability\SustainabilityTelemetry';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScan_LicenseAccepted';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker';g=''},
  @{t='\Microsoft\Windows\ApplicationData\appuriverifierdaily';g=''},
  @{t='\Microsoft\Windows\ApplicationData\DsSvcCleanup';g=''},
  @{t='\Microsoft\Windows\Input\PenSyncDataAvailable';g=''},
  @{t='\Microsoft\Windows\Wininet\CacheTask';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Report Policies';g=''},
  @{t='\Microsoft\Windows\ApplicationData\CleanupTemporaryState';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\Refresh Group Policy Cache';g=''},
  @{t='\Microsoft\Windows\ApplicationData\appuriverifierinstall';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Report policies';g=''},
  @{t='\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate';g=''},
  @{t='\Microsoft\Windows\WaaSMedic';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\AUSessionConnect';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\AC Power Download';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UpdateAssistantAllUsersRun';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Maintenance Install';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\Scheduled Start With Network';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Reboot_AC';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScan_OobeAppReady';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Idle Start';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Start';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\RUXIM\PLUGScheduler';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\USO_Broker_Display';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Battery Saver Deferred Install';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\sih';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScan';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\MusUx_LogonUpdateResults';g=''},
  @{t='\Microsoft\Windows\MemoryDiagnostic\AutomaticOfflineMemoryDiagnostic';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_ReadyToReboot';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Retry Scan';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Refresh Settings';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Resume On Boot';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UpdateAssistant';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\Automatic App Update';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\AC Power Install';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UpdateAssistantCalendarRun';g=''},
  @{t='\Microsoft\Windows\InstallService\WakeUpAndScanForUpdates';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Schedule Maintenance Work';g=''},
  @{t='\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UpdateAssistantWakeupRun';g=''},
  @{t='\Microsoft\Windows\InstallService\WakeUpAndContinueUpdates';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\MusUx_UpdateInterval';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\sihpostreboot';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Policy Install';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\AUScheduledInstall';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UIEOrchestrator';g=''},
  @{t='\Microsoft\Windows\InstallService\RestoreDevice';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Reboot';g=''},
  @{t='\Microsoft\Windows\Application Experience\ProgramDataUpdater';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask';g=''},
  @{t='\Microsoft\Windows\WindowsUpdate\sihboot';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_Display';g=''},
  @{t='\Microsoft\Windows\UpdateOrchestrator\Backup Scan';g=''},
  @{t='\Microsoft\Windows\Customer Experience Improvement Program\Server\ServerCeipAssistant';g=''},
  @{t='\Microsoft\Windows\Input\TouchPadSyncDataAvailable';g=''},
  @{t='\Microsoft\Windows\Input\syncpensettings';g=''},
  @{t='\Microsoft\Windows\Shell\sSyncedImageDownload';g=''},
  @{t='\Microsoft\Windows\Speech\SpeechModelDownloadTask';g=''},
  @{t='\Microsoft\Windows\Shell\ThemesSyncedImageDownload';g=''},
  @{t='\Microsoft\Windows\USB\Usb-Notifications';g=''},
  @{t='\Microsoft\Windows\International\Synchronize Language Settings';g=''},
  @{t='\Microsoft\Windows\Time Synchronization\SynchronizeTime';g=''},
  @{t='\Microsoft\Windows\Time Synchronization\ForceSynchronizeTime';g=''},
  @{t='\Microsoft\Windows\Input\TouchpadSyncDataAvailable';g=''},
  @{t='\Microsoft\Windows\AppListBackup\Backup';g=''},
  @{t='\Microsoft\Windows\BrokerInfrastructure\BgTaskRegistrationMaintenanceTask';g=''},
  @{t='\Microsoft\Windows\Chkdsk\ProactiveScan';g=''},
  @{t='\Microsoft\Windows\Data Integrity Scan\Data Integrity Scan';g=''},
  @{t='\Microsoft\Windows\Data Integrity Scan\Data Integrity Scan for Crash Recovery';g=''},
  @{t='\Microsoft\Windows\DeviceDirectoryClient\HandleCommandVerb';g=''},
  @{t='\Microsoft\Windows\HelloFace\FODCleanupTask';g=''},
  @{t='\Microsoft\Windows\LanguageComponentsInstaller\Installation';g=''},
  @{t='\Microsoft\Windows\LanguageComponentsInstaller\Uninstallation';g=''},
  @{t='\Microsoft\Windows\NetTrace\GatherNetworkInfo';g=''},
  @{t='\Microsoft\Windows\Offline Files\Background Synchronization';g=''},
  @{t='\Microsoft\Windows\PushToInstall\LoginCheck';g=''},
  @{t='\Microsoft\Windows\PushToInstall\Registration';g=''},
  @{t='\Microsoft\Windows\RecoveryEnvironment\VerifyWinRE';g=''},
  @{t='\Microsoft\Windows\Servicing\StartComponentCleanup';g=''},
  @{t='\Microsoft\Windows\StateRepository\MaintenanceTasks';g=''},
  @{t='\Microsoft\Windows\Subscription\EnableLicenseAcquisition';g=''},
  @{t='\Microsoft\Windows\Subscription\LicenseAcquisition';g=''},
  @{t='\Microsoft\Windows\Workplace Join\Automatic-Device-Join';g=''},
  @{t='\Microsoft\Windows\Workplace Join\Device-Sync';g=''},
  @{t='\Microsoft\Windows\Workplace Join\Recovery-Check';g=''}
)
foreach ($e in $tasks) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  # A deleted task never reports 'Disabled' - it is simply absent, which the old code
  # counted as not-applicable and therefore could never fail.
  if ($e.op -eq 'delete') {
    $checked++
    if ($allTasks.ContainsKey($e.t)) { $bad++; $out += ('TASK STILL PRESENT     ' + $e.t + ' = ' + $allTasks[$e.t]) }
    continue
  }
  if (-not $allTasks.ContainsKey($e.t)) { $na++; continue }
  $checked++
  if ($allTasks[$e.t] -ne 'Disabled') { $bad++; $out += ('TASK NOT DISABLED      ' + $e.t + ' = ' + $allTasks[$e.t]) } }

$installed = @(Get-AppxPackage -AllUsers)
$appx = @(
  @{n='Microsoft.549981C3F5F10*';g='remove-bloat'},
  @{n='Microsoft.BingNews*';g='remove-bloat'},
  @{n='Microsoft.BingWeather*';g='remove-bloat'},
  @{n='Microsoft.BingSearch*';g='remove-bloat'},
  @{n='MicrosoftCorporationII.Bing*';g='remove-bloat'},
  @{n='Clipchamp.Clipchamp*';g='remove-bloat'},
  @{n='Microsoft.GetHelp*';g='remove-bloat'},
  @{n='Microsoft.Getstarted*';g='remove-bloat'},
  @{n='7EE7776C.LinkedInforWindows*';g='remove-bloat'},
  @{n='Microsoft.Microsoft3DViewer*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftOfficeHub*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftSolitaireCollection*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftStickyNotes*';g='remove-bloat'},
  @{n='Microsoft.MSPaint*';g='remove-bloat'},
  @{n='Microsoft.Office.OneNote*';g='remove-bloat'},
  @{n='Microsoft.OutlookForWindows*';g='remove-bloat'},
  @{n='Microsoft.People*';g='remove-bloat'},
  @{n='Microsoft.PowerAutomateDesktop*';g='remove-bloat'},
  @{n='Microsoft.SkypeApp*';g='remove-bloat'},
  @{n='Microsoft.StartExperiencesApp*';g='remove-bloat'},
  @{n='Microsoft.Todos*';g='remove-bloat'},
  @{n='Microsoft.Whiteboard*';g='remove-bloat'},
  @{n='Microsoft.WidgetsPlatformRuntime*';g='remove-bloat'},
  @{n='Microsoft.Windows.PeopleExperienceHost*';g='remove-bloat'},
  @{n='Microsoft.Windows.SecureAssessmentBrowser*';g='remove-bloat'},
  @{n='Microsoft.WindowsAlarms*';g='remove-bloat'},
  @{n='Microsoft.WindowsCamera*';g='remove-bloat'},
  @{n='Microsoft.WindowsFeedbackHub*';g='remove-bloat'},
  @{n='Microsoft.WindowsMaps*';g='remove-bloat'},
  @{n='Microsoft.WindowsSoundRecorder*';g='remove-bloat'},
  @{n='Microsoft.ZuneMusic*';g='remove-bloat'},
  @{n='Microsoft.ZuneVideo*';g='remove-bloat'},
  @{n='MicrosoftCorporationII.MicrosoftFamily*';g='remove-bloat'},
  @{n='MicrosoftCorporationII.QuickAssist*';g='remove-bloat'},
  @{n='microsoft.windowscommunicationsapps*';g='remove-bloat'},
  @{n='Microsoft.Windows.DevHome*';g='remove-bloat'},
  @{n='Microsoft.Advertising.Xaml*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftPowerBIForWindows*';g='remove-bloat'},
  @{n='Microsoft.MixedReality.Portal*';g='remove-bloat'},
  @{n='Microsoft.Office.Word*';g='remove-bloat'},
  @{n='Microsoft.Office.Excel*';g='remove-bloat'},
  @{n='Microsoft.Office.PowerPoint*';g='remove-bloat'},
  @{n='Microsoft.OutlookPWA*';g='remove-bloat'},
  @{n='Microsoft.Flipgrid*';g='remove-bloat'},
  @{n='MicrosoftCorporationII.MailforSurfaceHub*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftTeamsforSurfaceHub*';g='remove-bloat'},
  @{n='AppleInc.AppleMusicWin*';g='remove-bloat'},
  @{n='AppleInc.iTunes*';g='remove-bloat'},
  @{n='Microsoft.M365Companions*';g='remove-bloat'},
  @{n='Microsoft.MicrosoftJournal*';g='remove-bloat'},
  @{n='Microsoft.PCManager*';g='remove-bloat'},
  @{n='Microsoft.Office.Sway*';g='remove-bloat'},
  @{n='Microsoft.NetworkSpeedTest*';g='remove-bloat'},
  @{n='Microsoft.Windows.AIHub*';g='remove-bloat'},
  @{n='AdobeSystemsIncorporated.AdobePhotoshopExpress*';g='remove-bloat'},
  @{n='king.com.CandyCrushSaga*';g='remove-bloat'},
  @{n='king.com.CandyCrushSodaSaga*';g='remove-bloat'},
  @{n='king.com.BubbleWitch3Saga*';g='remove-bloat'},
  @{n='king.com.FarmHeroesSaga*';g='remove-bloat'},
  @{n='Amazon.com.Amazon*';g='remove-bloat'},
  @{n='AmazonVideo.PrimeVideo*';g='remove-bloat'},
  @{n='BookingApp*';g='remove-bloat'},
  @{n='HULULLC.HULUPLUS*';g='remove-bloat'},
  @{n='*DisneyMagicKingdoms*';g='remove-bloat'},
  @{n='*Facebook*';g='remove-bloat'},
  @{n='*Instagram*';g='remove-bloat'},
  @{n='*Twitter*';g='remove-bloat'},
  @{n='*Pandora*';g='remove-bloat'},
  @{n='*iHeartRadio*';g='remove-bloat'},
  @{n='*Plex*';g='remove-bloat'},
  @{n='*Shazam*';g='remove-bloat'},
  @{n='*Viber*';g='remove-bloat'},
  @{n='*WinZip*';g='remove-bloat'},
  @{n='*NYTCrossword*';g='remove-bloat'},
  @{n='*Duolingo*';g='remove-bloat'},
  @{n='*Fitbit*';g='remove-bloat'},
  @{n='*Flipboard*';g='remove-bloat'},
  @{n='*EclipseManager*';g='remove-bloat'},
  @{n='*ActiproSoftwareLLC*';g='remove-bloat'},
  @{n='*CyberLinkMediaSuiteEssentials*';g='remove-bloat'},
  @{n='*PicsArt*';g='remove-bloat'},
  @{n='*PolarrPhotoEditor*';g='remove-bloat'},
  @{n='*PhototasticCollage*';g='remove-bloat'},
  @{n='*DrawboardPDF*';g='remove-bloat'},
  @{n='*AutodeskSketchBook*';g='remove-bloat'},
  @{n='*XING*';g='remove-bloat'},
  @{n='*Wunderlist*';g='remove-bloat'},
  @{n='*TuneInRadio*';g='remove-bloat'},
  @{n='*SlingTV*';g='remove-bloat'},
  @{n='*OneCalendar*';g='remove-bloat'},
  @{n='*ACGMediaPlayer*';g='remove-bloat'},
  @{n='*LiveWallpaper*';g='remove-bloat'},
  @{n='*Asphalt8*';g='remove-bloat'},
  @{n='*CaesarsSlots*';g='remove-bloat'},
  @{n='*COOKINGFEVER*';g='remove-bloat'},
  @{n='*HiddenCity*';g='remove-bloat'},
  @{n='*MarchofEmpires*';g='remove-bloat'},
  @{n='*RoyalRevolt*';g='remove-bloat'},
  @{n='AD2F1837.HPAIExperienceCenter*';g='remove-bloat'},
  @{n='AD2F1837.HPConnectedMusic*';g='remove-bloat'},
  @{n='AD2F1837.HPConnectedPhoto*';g='remove-bloat'},
  @{n='AD2F1837.HPDesktopSupportUtilities*';g='remove-bloat'},
  @{n='AD2F1837.HPEasyClean*';g='remove-bloat'},
  @{n='AD2F1837.HPFileViewer*';g='remove-bloat'},
  @{n='AD2F1837.HPJumpStarts*';g='remove-bloat'},
  @{n='AD2F1837.HPPCHardwareDiagnostics*';g='remove-bloat'},
  @{n='AD2F1837.HPPowerManager*';g='remove-bloat'},
  @{n='AD2F1837.HPPrinterControl*';g='remove-bloat'},
  @{n='AD2F1837.HPPrivacySettings*';g='remove-bloat'},
  @{n='AD2F1837.HPQuickDrop*';g='remove-bloat'},
  @{n='AD2F1837.HPQuickTouch*';g='remove-bloat'},
  @{n='AD2F1837.HPRegistration*';g='remove-bloat'},
  @{n='AD2F1837.HPSupportAssistant*';g='remove-bloat'},
  @{n='AD2F1837.HPSureShieldAI*';g='remove-bloat'},
  @{n='AD2F1837.HPSystemInformation*';g='remove-bloat'},
  @{n='AD2F1837.HPWelcome*';g='remove-bloat'},
  @{n='AD2F1837.HPWorkWell*';g='remove-bloat'},
  @{n='AD2F1837.myHP*';g='remove-bloat'},
  @{n='DellInc.DellDigitalDelivery*';g='remove-bloat'},
  @{n='DellInc.DellMobileConnect*';g='remove-bloat'},
  @{n='DellInc.DellSupportAssist*';g='remove-bloat'},
  @{n='E046963F.LenovoCompanion*';g='remove-bloat'},
  @{n='LenovoCompanyLimited.LenovoVantageService*';g='remove-bloat'},
  @{n='Microsoft.Xbox*';g='remove-xbox'},
  @{n='Microsoft.XboxApp*';g='remove-xbox'},
  @{n='Microsoft.GamingApp*';g='remove-xbox'},
  @{n='Microsoft.XboxGameOverlay*';g='remove-xbox'},
  @{n='Microsoft.XboxGamingOverlay*';g='remove-xbox'},
  @{n='Microsoft.XboxIdentityProvider*';g='remove-xbox'},
  @{n='Microsoft.XboxSpeechToTextOverlay*';g='remove-xbox'},
  @{n='Microsoft.Edge.GameAssist*';g='remove-xbox'},
  @{n='Microsoft.WindowsStore*';g='remove-store'},
  @{n='*SecHealthUI*';g='disable-defender'},
  @{n='Microsoft.Windows.Apprep.ChxApp*';g='disable-defender'},
  @{n='Microsoft.Copilot*';g='remove-ai'},
  @{n='Microsoft.Windows.Copilot*';g='remove-ai'},
  @{n='MicrosoftWindows.Client.Copilot*';g='remove-ai'},
  @{n='Microsoft.MicrosoftCopilot*';g='remove-ai'},
  @{n='MSCopilot*';g='remove-ai'},
  @{n='Microsoft.Copilot365*';g='remove-ai'},
  @{n='MicrosoftWindows.Client.AIX*';g='remove-ai'},
  @{n='Microsoft.Windows.AugLoop.CBS*';g='remove-ai'},
  @{n='MicrosoftWindows.UndockedDevKit*';g='remove-ai'},
  @{n='Disney.*';g='remove-bloat'},
  @{n='MSTeams*';g='remove-bloat'},
  @{n='MicrosoftTeams*';g='remove-bloat'},
  @{n='Microsoft.Windows.Ai.Copilot.Provider*';g='remove-ai'},
  @{n='Microsoft.549981C3F5F10*';g='remove-ai'}
)
foreach ($e in $appx) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  $checked++
  $hit = $installed | Where-Object { $_.Name -like $e.n -or $_.PackageFamilyName -like $e.n } | Select-Object -First 1
  if ($hit) { $bad++; $out += ('APPX STILL INSTALLED   ' + $e.n + ' -> ' + $hit.Name) } }

# --- file checks (theme / wallpaper / cursors / icons) - read-only ----
# These prove the artefacts were laid down and are well formed. They do NOT prove the
# theme is active - a file can sit in Resources\Themes forever and never be used. Active
# state is the DWM\ColorizationColor and Themes\CurrentTheme checks in $regs above.
$files = @(
  @{p='%SystemRoot%\Resources\Themes\EBOS-dark.theme';g='fs-darkmode';contains=@('ColorizationColor=0XFF3778B5','Background=20 38 63','wallpaper.png','ebos-arrow.ani')},
  @{p='%SystemRoot%\Web\Wallpaper\EBOS\wallpaper.png';g='fs-wallpaper';contains=@()},
  @{p='%SystemRoot%\Web\Wallpaper\EBOS\lockscreen.png';g='fs-wallpaper';contains=@()},
  @{p='%SystemRoot%\Cursors\EBOS\ebos-arrow.ani';g='';contains=@()},
  @{p='%SystemRoot%\Cursors\EBOS\ebos-wait.ani';g='';contains=@()},
  @{p='%SystemRoot%\EBOS\ebos.ico';g='';contains=@()},
  @{p='%SystemRoot%\EBOS\profile.png';g='fs-wallpaper';contains=@()},
  @{p='%ProgramFiles%\WindhawkCLI\whcli.exe';g='windhawk-styler';contains=@()}
)
foreach ($e in $files) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  $checked++
  $full = [Environment]::ExpandEnvironmentVariables($e.p)
  if (-not (Test-Path -LiteralPath $full)) { $bad++; $out += ('FILE MISSING           ' + $e.p); continue }
  foreach ($c in $e.contains) {
    $hit = $false
    try {
      if ((Get-Item -LiteralPath $full).PSIsContainer) { $hit = $true }
      elseif ($full -like '*.theme') { $hit = (Select-String -LiteralPath $full -Pattern $c -SimpleMatch -Quiet) }
      else { $hit = $true }
    } catch { $hit = $false }
    if (-not $hit) { $bad++; $out += ('FILE WRONG CONTENT     ' + $e.p + ' missing [' + $c + ']') }
  }
}
# !file actions delete these paths and nothing ever checked the delete. A file left behind
# by a failed delete is a live Defender component (WdNisDrv.sys) or a re-created OneDrive
# folder, so absence is worth asserting.
$absent = @(
  @{p='%SystemDrive%\OneDriveTemp';g='remove-onedrive'},
  @{p='%ProgramData%\Microsoft OneDrive';g='remove-onedrive'},
  @{p='%systemroot%\System32\SecurityHealthSystray.exe';g='disable-defender'},
  @{p='%systemroot%\System32\SecurityHealthHost.exe';g='disable-defender'},
  @{p='%systemroot%\System32\SecurityHealthCore.dll';g='disable-defender'},
  @{p='%systemroot%\System32\SecurityHealthUdk.dll';g='disable-defender'},
  @{p='%systemroot%\System32\drivers\WdNisDrv.sys';g='disable-defender'},
  @{p='%systemroot%\System32\drivers\wd\WdNisDrv.sys';g='disable-defender'}
)
foreach ($e in $absent) {
  if (-not (Test-Gate $e.g)) { $na++; continue }
  $checked++
  $full = [Environment]::ExpandEnvironmentVariables($e.p)
  if (Test-Path -LiteralPath $full) { $bad++; $out += ('FILE STILL PRESENT     ' + $e.p) }
}

# cursor set completeness: 17x ebos-*.ani expected (legacy names containing 'hq' excluded)
if (Test-Gate '') {
  $checked++
  $cdir = Join-Path $env:windir 'Cursors\EBOS'
  $count = 0
  try { $count = @(Get-ChildItem -LiteralPath $cdir -Filter 'ebos-*.ani' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*hq*' }).Count } catch { $count = 0 }
  if ($count -lt 17) { $bad++; $out += ('CURSORS INCOMPLETE     ' + $cdir + ' = ' + $count + ' (wanted 17)') }
}
# ebos.ico must be a real ICO (00 00 01 00), not a renamed PNG (89 50 4E 47)
if (Test-Gate '') {
  $checked++
  $ico = Join-Path $env:windir 'EBOS\ebos.ico'
  if (Test-Path -LiteralPath $ico) {
    try {
      $b = [IO.File]::ReadAllBytes($ico)
      $isIco = ($b.Length -gt 4 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0)
      $isPng = ($b.Length -gt 4 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)
      if (-not $isIco -or $isPng) { $bad++; $out += ('ICON NOT ICO           ' + $ico + ' (renamed PNG, wanted ICO 00 00 01 00)') }
    } catch {}
  }
}

# --- options that had no verification at all -------------------------------
# A coverage pass over playbook.conf found five options with actions but zero checks:
# browser-brave, disable-webview2, remove-accessibility, fs-small-icons, offline-mode.
# Each check below mirrors what its action actually does - no invented success conditions.

if (Test-Gate 'offline-mode') {
  $checked++
  $flag = Join-Path $env:windir 'EBOS\offline-mode.flag'
  if (-not (Test-Path -LiteralPath $flag)) { $bad++; $out += ('OFFLINE FLAG MISSING   ' + $flag) }
}

if (Test-Gate 'disable-webview2') {
  $checked++
  $wvDirs = @()
  if (${env:ProgramFiles(x86)}) { $wvDirs += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView') }
  if ($env:ProgramFiles)      { $wvDirs += (Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView') }
  foreach ($d in $wvDirs) {
    if (Test-Path -LiteralPath $d) { $bad++; $out += ('WEBVIEW2 STILL THERE   ' + $d) }
  }
}

if (Test-Gate 'remove-accessibility') {
  $checked++
  foreach ($t in @('Narrator.exe','Magnify.exe','osk.exe','VoiceAccess.exe','LiveCaptions.exe')) {
    $f = Join-Path $env:windir ('System32\' + $t)
    if (Test-Path -LiteralPath $f) { $bad++; $out += ('ACCESSIBILITY STILL PRESENT  ' + $t) }
  }
}

if (Test-Gate 'browser-brave') {
  $checked++
  $brave = Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'
  if (-not (Test-Path -LiteralPath $brave)) {
    # An offline run with no bundled installer skips Brave on purpose. phase1 drops a flag
    # for exactly that case and deletes it at the start of every run, so this cannot be
    # satisfied by a skip recorded during some earlier run.
    $skipFlag = Join-Path $env:windir 'EBOS\brave-skip.flag'
    if (-not (Test-Path -LiteralPath $skipFlag)) { $bad++; $out += ('BRAVE NOT INSTALLED    ' + $brave) }
  }
}

if (Test-Gate 'fs-small-icons') {
  # The action seeds the AME default hive when it exists, otherwise the on-disk
  # NTUSER.DAT which it unloads again - nothing readable is left in that second case.
  $ameHive = 'Registry::HKEY_USERS\AME_UserHive_Default'
  if (-not (Test-Path $ameHive)) {
    $na++
  } else {
    $checked++
    $bag = $ameHive + '\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
    if (-not (Test-Path $bag)) {
      $bad++; $out += ('SMALL ICONS NOT SET    ' + $bag + ' (key absent)')
    } else {
      $sz = (Get-Item -LiteralPath $bag -ErrorAction SilentlyContinue).GetValue('IconSize', $null)
      if ($null -eq $sz -or [int]$sz -ne 32) { $bad++; $out += ('SMALL ICONS NOT SET    IconSize=' + $sz) }
    }
  }
}

# windhawk-styler was the only software-installing option with no verification at all.
# Its log is appended to across runs, so "contains the marker" would let an older success
# hide a newer failure - the last non-empty line is what counts.
if (Test-Gate 'windhawk-styler') {
  $checked++
  $whLog = Join-Path $env:windir 'EBOS\windhawk-styler.log'
  if (-not (Test-Path -LiteralPath $whLog)) {
    $bad++; $out += ('WINDHAWK LOG MISSING   ' + $whLog)
  } else {
    $lastLine = @(Get-Content -LiteralPath $whLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($lastLine -notmatch 'windhawk-styler done') {
      $bad++; $out += ('WINDHAWK INCOMPLETE    last line: ' + $lastLine)
    }
  }
}

if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
$hdr = @()
$hdr += ('EBOS verification - ' + (Get-Date -Format s))
$hdr += ('options ticked: ' + $(if ($opts.Count) { $opts -join ', ' } else { '(none recorded)' }))
$hdr += ('checked ' + $checked + ', not applicable ' + $na + ', DID NOT TAKE ' + $bad)
$hdr += ('-' * 74)
if ($bad -eq 0) { $out += 'Everything that was meant to apply, applied.' }
($hdr + $out) | Out-File -FilePath (Join-Path $dir 'ebos-skipped.txt') -Append -Encoding utf8
$global:LASTEXITCODE = 0
