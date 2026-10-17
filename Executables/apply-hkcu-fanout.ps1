#Requires -Version 5.1
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
  @{ k='Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'; v='System.IsPinnedToNameSpaceTree'; t='REG_DWORD'; d='0'; o='remove-onedrive'; op='add' }
  @{ k='Software\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'; v='System.IsPinnedToNameSpaceTree'; t='REG_DWORD'; d='0'; o='remove-onedrive'; op='add' }
  @{ k='Software\Microsoft\GameBar'; v='ShowStartupPanel'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='PreInstalledAppsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='OemPreInstalledAppsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SilentInstalledAppsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; v='HideSCAMeetNow'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Policies\Attachments'; v='SaveZoneInformation'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Policies\Attachments'; v='ScanWithAntiVirus'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Policies\Associations'; v='DefaultFileTypeRisk'; t='REG_DWORD'; d='6152'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost'; v='EnableWebContentEvaluation'; t='REG_DWORD'; d='0'; o='disable-defender'; op='add' }
  @{ k='SOFTWARE\Microsoft\Edge'; v='SmartScreenEnabled'; t='REG_DWORD'; d='0'; o='disable-defender'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost'; v='PreventOverride'; t='REG_DWORD'; d='0'; o='disable-defender'; op='add' }
  @{ k='SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect'; v='LoadBehavior'; t='REG_DWORD'; d='0'; o='remove-bloat'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Run'; v='Teams'; t=''; d=''; o='remove-bloat'; op='delete' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Run'; v='com.squirrel.Teams.Teams'; t=''; d=''; o='remove-bloat'; op='delete' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Run'; v='MSTeams'; t=''; d=''; o='remove-bloat'; op='delete' }
  @{ k='Software\Microsoft\Windows\Shell\Copilot\BingChat'; v='IsUserEligible'; t='REG_DWORD'; d='0'; o='remove-ai'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='AutoOpenCopilotLargeScreens'; t='REG_DWORD'; d='0'; o='remove-ai'; op='add' }
  @{ k='SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; v='TurnOffWindowsCopilot'; t='REG_DWORD'; d='1'; o='remove-ai'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='NOC_GLOBAL_SETTING_SHOW_IN_SETTINGS'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-370697Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; v='GlobalUserDisabled'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\InputPersonalization\TrainedDataStore'; v='HarvestContacts'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\CloudStore'; v='DisableRoamingSync'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-353696Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-370700Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Siuf\Rules'; v='NumberOfSIUFInPeriod'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; v='ShowGlobalPrompts'; t='REG_DWORD'; d='0'; o='disable-location'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='BingSearchEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; v='HasAccepted'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Personalization\Settings'; v='AcceptedPrivacyPolicy'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Siuf\Rules'; v='NumberOfSIUFInPeriod'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Siuf\Rules'; v='PeriodInNanoSeconds'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\International\User Profile'; v='HttpAcceptLanguageOptOut'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; v='ScoobeSystemSettingEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='DeviceHistoryEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-400923Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338393Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\AppManagement\AppSettings'; v='ArchiveAppsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-353694Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Input\Settings'; v='InsightsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\InputPersonalization'; v='RestrictImplicitInkCollection'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='BackgroundAppGlobalToggle'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\CPSS\Store\InkingAndTypingPersonalization'; v='Value'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\InputPersonalization'; v='RestrictImplicitTextCollection'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='HistoryViewEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\GameDVR'; v='CursorCaptureEnabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\GameDVR'; v='AudioCaptureEnabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\GameDVR'; v='MicrophoneCaptureEnabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; v='HasAccepted'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='NOC_GLOBAL_SETTING_TOASTS_ENABLED'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Personalization\Settings'; v='AcceptedPrivacyPolicy'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='NOC_GLOBAL_SETTING_BADGE_ENABLED'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsDynamicSearchBoxEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='SafeSearchMode'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsAADCloudSearchEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsMSACloudSearchEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsDeviceSearchHistoryEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsMSFTSearchFeedEnabled'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SearchSettings'; v='IsMSFTCloudSearchEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Multimedia\Audio'; v='UserDuckingPreference'; t='REG_DWORD'; d='3'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='RawMouseThrottleEnabled'; t=''; d=''; o=''; op='delete' }
  @{ k='Control Panel\Mouse'; v='RawMouseThrottleForced'; t=''; d=''; o=''; op='delete' }
  @{ k='Control Panel\Mouse'; v='RawMouseThrottleDuration'; t=''; d=''; o=''; op='delete' }
  @{ k='Control Panel\Mouse'; v='RawMouseThrottleLeeway'; t=''; d=''; o=''; op='delete' }
  @{ k='Control Panel\Mouse'; v='DoubleClickSpeed'; t='REG_SZ'; d='480'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='ScreenSaveActive'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='MouseThreshold2'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='MenuShowDelay'; t='REG_SZ'; d='1'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='ActiveWindowTracking'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='MouseSpeed'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='Beep'; t='REG_SZ'; d='No'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='MouseThreshold1'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='ScreenSaveTimeOut'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='MouseTrails'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='MouseAccel'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='JPEGImportQuality'; t='REG_DWORD'; d='100'; o=''; op='add' }
  @{ k='Control Panel\Mouse'; v='SnapToDefaultButton'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; v='VisualFXSetting'; t='REG_DWORD'; d='3'; o='fs-noanimations'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\DWM'; v='AlwaysHibernateThumbnails'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Control Panel\Desktop'; v='UserPreferencesMask'; t='REG_BINARY'; d='9032038010000000'; o='fs-noanimations'; op='add' }
  @{ k='Control Panel\Desktop\WindowMetrics'; v='MinAnimate'; t='REG_SZ'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='IconsOnly'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Control Panel\Desktop'; v='FontSmoothing'; t='REG_SZ'; d='2'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ListviewShadow'; t='REG_DWORD'; d='1'; o='fs-noanimations'; op='add' }
  @{ k='Control Panel\Desktop'; v='DragFullWindows'; t='REG_SZ'; d='1'; o='fs-noanimations'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ListviewAlphaSelect'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarAnimations'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\DWM'; v='EnableAeroPeek'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarGlomLevel'; t='REG_DWORD'; d='2'; o='fs-w10-taskbar'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='MMTaskbarGlomLevel'; t='REG_DWORD'; d='2'; o='fs-w10-taskbar'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_ShowFrequentList'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='System\GameConfigStore'; v='GameDVR_Enabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\GameDVR'; v='AppCaptureEnabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_AccountNotifications'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='EnableSnapAssistFlyoutOnHover'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='EnableSnapAssistFlyout'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\ActionManager\Installed\System.DescribeImage'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\TabletTip\1.7'; v='EnableAutocorrection'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_ShowRecentList'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='SnapAssist'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='MultiTaskingAltTabFilter'; t='REG_DWORD'; d='3'; o=''; op='add' }
  @{ k='Control Panel\UnsupportedHardwareNotificationCache'; v='SV2'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='SnapFill'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\PushNotifications'; v='ToastEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\GameBar'; v='UseNexusForGameBarEnabled'; t='REG_DWORD'; d='0'; o='remove-xbox'; op='add' }
  @{ k='Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; v='FolderType'; t='REG_SZ'; d='NotSpecified'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='EnableSnapBar'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\TabletTip\1.7'; v='EnableSpellchecking'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='JointResize'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; v=''; t='REG_SZ'; d=''; o='fs-w10-context'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='SearchboxTaskbarMode'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarMn'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowCopilotButton'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='IsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; v='TaskbarEndTask'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='TaskbarAl'; t='REG_DWORD'; d='0'; o='fs-w10-tbleft'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\CDP'; v='DragTrayEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Environment'; v='DOTNET_CLI_TELEMETRY_OPTOUT'; t='REG_SZ'; d='1'; o=''; op='add' }
  @{ k='Environment'; v='POWERSHELL_TELEMETRY_OPTOUT'; t='REG_SZ'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\AppSync'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Personalization'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\BrowserSettings'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Credentials'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Accessibility'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Windows'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync'; v='SyncPolicy'; t='REG_DWORD'; d='5'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Credentials'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Personalization'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-280815Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\HighContrast'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackSavePickerContract'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Sound'; v='Beep'; t='REG_SZ'; d='no'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='WaitToKillAppTimeOut'; t='REG_SZ'; d='2000'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackConnectedSearchHistory'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; v='ShowCloudFilesInQuickAccess'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='04'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Preferences'; v='VoiceActivationEnableAboveLockscreen'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; v='ShowRecommendations'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\PackageState'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='HungAppTimeout'; t='REG_SZ'; d='2000'; o=''; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Preferences'; v='VoiceActivationOn'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Blind Access'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowCortanaButton'; t='REG_DWORD'; d='0'; o='remove-ai'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\DesktopTheme'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\On'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='256'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='RotatingLockScreenEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='RemediationRequired'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Accessibility'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Policies\Microsoft\Messenger\Client'; v='CEIP'; t='REG_DWORD'; d='2'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Preference'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\ToggleKeys'; v='Flags'; t='REG_SZ'; d='56'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\AudioDescription'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\StickyKeys'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='08'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\SlateLaunch'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Personalization\Desktop Slideshow'; v='AnimationDuration'; t='REG_DWORD'; d='0'; o='fs-noanimations'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless'; v='ScoobeCheckCompleted'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-314559Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='1024'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; v='AllowSearchToUseLocation'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Classes\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='01'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='Control Panel\Accessibility\SoundSentry'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338388Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\StartLayout'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='NoNetCrawling'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\TimeOut'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Input\Settings'; v='MultilingualEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackShareContractMFU'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Clipboard'; v='CloudClipRDPOverride'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Input\TIPC'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Search\Preferences'; v='WholeFileSystem'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='PreInstalledAppsEverEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Windows'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='01'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338387Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Input\Settings'; v='UserStatsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='2048'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='02'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='ContentDeliveryAllowed'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Desktop'; v='AutoEndTasks'; t='REG_SZ'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-280811Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\ShowSounds'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-202914Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; v='VoiceShortcut'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-314563Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='32'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='Control Panel\Accessibility\MouseKeys'; v='Flags'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-353698Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; v='DisableSearchBoxSuggestions'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='CanCortanaBeEnabled'; t='REG_DWORD'; d='0'; o='remove-ai'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\settingSync\Groups\Language'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='FeatureManagementEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; v='128'; t='REG_DWORD'; d='0'; o='disable-storage-sense'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'; v='ShowedToastAtLevel'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackSearchContract'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackOpenPickerContract'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; v='Value'; t='REG_SZ'; d='Deny'; o='disable-location'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_TrackCachedFileUpdaterContract'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SoftLandingEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Input\Settings'; v='EnableHwkbTextPrediction'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Input\Settings'; v='Insights'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-310093Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Preferences'; v='ModelDownloadAllowed'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Response'; v='Flags'; t='REG_SZ'; d='61'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Response'; v='AutoRepeatDelay'; t='REG_SZ'; d='300'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Response'; v='AutoRepeatRate'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Response'; v='DelayBeforeAcceptance'; t='REG_SZ'; d='0'; o=''; op='add' }
  @{ k='Control Panel\Accessibility\Keyboard Response'; v='BounceTime'; t='REG_SZ'; d='300'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SystemPaneSuggestionsEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContentEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Input\Settings'; v='EnableHwkbAutocorrection'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Clipboard'; v='CloudClipboardAutomaticUpload'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync'; v='SyncPolicy'; t='REG_DWORD'; d='5'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Notepad'; v='ShowStoreBanner'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync\Groups\BrowserSettings'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='DisablePreviewWindow'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='DisablePreviewDesktop'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Classes\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; v='Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='RotatingLockScreenOverlayEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-280810Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; v='CortanaEnabled'; t='REG_DWORD'; d='0'; o='remove-ai'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; v='SubscribedContent-338389Enabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowSyncProviderNotifications'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync'; v='Value'; t='REG_SZ'; d='Deny'; o='disable-bluetooth'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiData'; v='Value'; t='REG_SZ'; d='Deny'; o='disable-wifi'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiDirect'; v='Value'; t='REG_SZ'; d='Deny'; o='disable-wifi'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\cellularData'; v='Value'; t='REG_SZ'; d='Deny'; o='disable-wifi'; op='add' }
  @{ k='Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; v='NoAUAsDefaultShutdownOption'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Microsoft\GameBar'; v='GamePanelStartupTipIndex'; t='REG_DWORD'; d='3'; o='remove-xbox'; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps'; v='AgentActivationLastUsed'; t='REG_SZ'; d=''; o=''; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps'; v='AgentActivationOnLockScreenEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps'; v='AgentActivationEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Privacy'; v='TailoredExperiencesWithDiagnosticDataEnabled'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Search'; v='CortanaConsent'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Clipboard'; v='EnableClipboardHistory'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Security and Maintenance\Checks\{E8433B72-5842-4d43-8645-BC2C35960837}.check.101'; v='CheckSetting'; t='REG_BINARY'; d='23000000b200000000000000000000000200000001000000a4d1d6002fe7dc0100000000000000000000000000000000'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\Security\EnergySaver'; v='EnergyRecommendations'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; v='ShowInSettings'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='LaunchTo'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowFrequent'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer'; v='ShowFrequent'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='ShowRecent'; t='REG_DWORD'; d='0'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; v='Start_AllAppsView'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Start'; v='StartLayoutMode'; t='REG_DWORD'; d='1'; o=''; op='add' }
  @{ k='SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; v='NoTileApplicationNotification'; t='REG_DWORD'; d='1'; o='fs-privacy'; op='add' }
  @{ k='SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\LooselyCoupled'; v='Value'; t='REG_SZ'; d='Deny'; o='fs-privacy'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\Explorer'; v='ShowRecent'; t='REG_DWORD'; d='0'; o='fs-privacy'; op='add' }
  @{ k='Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications'; v='EnableAccountNotifications'; t='REG_DWORD'; d='0'; o='fs-privacy'; op='add' }
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
