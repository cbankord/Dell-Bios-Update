#requires -Version 5.1
# Unprivileged WPF client. No firmware, BitLocker, task or restart commands here.
param([switch]$Demo)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
. "$PSScriptRoot\Client.ps1"
$transport = Join-Path $PSScriptRoot 'Transport.ps1'
if (-not (Test-Path -LiteralPath $transport)) { $transport = Join-Path $PSScriptRoot '..\Scheduler\Transport.ps1' }
. $transport
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$mutex = New-Object Threading.Mutex($false, "Local\ManagedDellBiosV2-UI-$sessionId")
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$script:quitting = $false
$tray = $null
try {
    $brand = Import-PowerShellDataFile "$PSScriptRoot\Branding.psd1"
    [xml]$xaml = Get-Content "$PSScriptRoot\Window.xaml" -Raw
    $reader = New-Object Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    # WPF work-area units follow display scaling. Fit the initial notice above
    # the taskbar instead of assuming 760 units of vertical space are available.
    $workArea = [Windows.SystemParameters]::WorkArea
    $window.MinWidth = [math]::Min($window.MinWidth, [math]::Max(240, $workArea.Width - 24))
    $window.MinHeight = [math]::Min($window.MinHeight, [math]::Max(240, $workArea.Height - 24))
    $window.Width = [math]::Min($window.Width, [math]::Max($window.MinWidth, $workArea.Width - 24))
    $window.Height = [math]::Min($window.Height, [math]::Max($window.MinHeight, $workArea.Height - 24))
    $controls = @{}
    foreach ($name in @('Logo','Banner','Mark','Company','Heading','Purpose','Phase','StatusText','Deadline','Remaining','Scheduled','Day','Hour','Minute','TimeZone','PreparationText','Power','ErrorText','Support','PickerCard','StatusCard','ActionBar','ContentScroll','InstallButton','ScheduleButton','CancelScheduleButton','RestartButton','DeferButton','CloseButton')) { $controls[$name] = $window.FindName($name) }
    $window.Title = $brand.AppTitle
    if ($Demo) { $window.Title += ' (Preview)' }
    $window.Background = $brand.BackgroundColor
    $window.Foreground = $brand.TextColor
    foreach ($name in @('PickerCard','StatusCard','ActionBar')) { $controls[$name].Background = $brand.SurfaceColor }
    foreach ($name in @('InstallButton','RestartButton','Mark')) { $controls[$name].Background = $brand.AccentColor }
    foreach ($name in @('Purpose','Remaining','TimeZone','Support')) { $controls[$name].Foreground = $brand.MutedColor }
    $controls.Company.Text = $brand.CompanyName
    $controls.Heading.Text = $brand.Heading
    $controls.Purpose.Text = $brand.Purpose
    $controls.Power.Text = $brand.PowerMessage
    $controls.Support.Text = $brand.SupportText
    $controls.TimeZone.Text = [TimeZoneInfo]::Local.DisplayName
    foreach ($pair in @(@('Logo','LogoFile'), @('Banner','BannerFile'))) {
        $relative = $brand[$pair[1]]
        if (-not $relative) { continue }
        $base = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
        $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relative))
        if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -notin @('.png','.jpg','.jpeg')) { throw 'Branding images must be local PNG/JPG files inside the UI folder.' }
        if (Test-Path -LiteralPath $path) {
            $controls[$pair[0]].Source = New-Object Windows.Media.Imaging.BitmapImage([uri]$path)
            $controls[$pair[0]].Visibility = 'Visible'
            if ($pair[0] -eq 'Logo') { $controls.Mark.Visibility = 'Collapsed' }
        }
    }
    0..23 | ForEach-Object { $null = $controls.Hour.Items.Add($_.ToString('00')) }
    0..59 | ForEach-Object { $null = $controls.Minute.Items.Add($_.ToString('00')) }
    $default = (Get-Date).AddHours(1)
    $controls.Day.SelectedDate = $default.Date; $controls.Hour.SelectedIndex = $default.Hour; $controls.Minute.SelectedIndex = $default.Minute
    $script:view = $null
    $script:choosingSchedule = $false
    $script:demoView = [pscustomobject]@{ WindowHours=72; PreparationLeadMinutes=30; FinalWarningMinutes=15; Phase='Pending'; DeadlineUtc=[datetimeoffset]::UtcNow.AddHours(72).ToString('o'); ScheduledUtc=''; InstallRequestedUtc=''; RestartUtc=''; ServerUtc=[datetimeoffset]::UtcNow.ToString('o'); CanSchedule=$true; CanInstallNow=$true; Overdue=$false; ShouldShow=$true; Message=''; CanRestart=$false }
    function Invoke-UIRequest($Request) {
        if ($Demo) {
            if ($Request.Action -eq 'Schedule') { $script:demoView.Phase='Scheduled'; $script:demoView.ScheduledUtc=$Request.Utc; $script:demoView.InstallRequestedUtc='' }
            if ($Request.Action -eq 'InstallNow') {
                $script:demoView.Phase='Preparing'; $script:demoView.InstallRequestedUtc=[datetimeoffset]::UtcNow.ToString('o')
                $script:demoView.ScheduledUtc=''; $script:demoView.CanSchedule=$false; $script:demoView.CanInstallNow=$false
            }
            if ($Request.Action -in @('NoticeShown','Defer')) { $script:demoView.ShouldShow=$false }
            return $script:demoView
        }
        Send-BiosRequest $Request
    }
    function Show-UIMessage([string]$Message, [switch]$IsError) {
        $controls.ErrorText.Text = $Message
        $controls.ErrorText.ToolTip = $Message
        $controls.ErrorText.Foreground = if ($IsError) { '#B42318' } else { $brand.MutedColor }
        $controls.ErrorText.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
    }
    function Render-Status($View) {
        if ($null -ne $script:view -and $script:view.Phase -ne $View.Phase) { Show-UIMessage '' }
        $script:view = $View
        $lead = Get-BiosViewValue $View 'PreparationLeadMinutes' 30
        $windowHours = Get-BiosViewValue $View 'WindowHours' 72
        $installRequested = Get-BiosViewValue $View 'InstallRequestedUtc' ''
        $actions = Get-NoticeActions $View
        $controls.PreparationText.Text = 'Choose the restart time in your local time zone. Preparation may start up to {0} minutes earlier. Save your work before then; the restart may be later if safety checks need more time.' -f $lead
        $labels = @{ AwaitingNotice='Choose a time that works for you'; Pending='Ready to schedule'; Scheduled='Your restart is scheduled'; Preparing='Preparing your BIOS update'; Blocked='Waiting for a safety requirement'; RestartRequired='Restart required'; Verifying='Verifying the update'; VerifiedComplete='Update verified complete'; NeedsAttention='Your IT team needs to take a look' }
        $controls.Phase.Text = $labels[$View.Phase]
        $text = 'You can postpone reminders as often as needed before the deadline. Your original deadline will stay the same.'
        if ($View.ScheduledUtc) { $text = 'Your selected time is saved. Defer hides this reminder without cancelling that time or extending the deadline.' }
        if ($installRequested -and $View.Phase -in @('Scheduled','Blocked')) {
            if ($View.Phase -eq 'Scheduled') { $controls.Phase.Text = 'Installation requested' }
            $text = 'Preparation will begin as soon as safety checks pass. Defer only hides this reminder. You can choose a later time before preparation begins, while the deadline remains open.'
        }
        if ($View.Phase -eq 'Preparing') { $text = 'Save your work and stay plugged in. Preparation is running silently. Scheduling is now locked.' }
        if ($View.Phase -eq 'RestartRequired') { $text = $brand.ReadyMessage }
        if ($View.Phase -eq 'Verifying') { $text = 'Windows has returned. We are checking the installed BIOS version and drive protection.' }
        if ($View.Phase -eq 'VerifiedComplete') { $text = 'The installed BIOS meets the approved version and drive protection has been checked. You can continue working.' }
        if ($View.Overdue -and $View.Phase -in @('Pending','Scheduled','Blocked')) { $text = 'The deadline has passed. Deferral is unavailable. The update will proceed when safety requirements are met.' }
        if ($actions.ShowInstall -and $null -eq (Get-BiosViewValue $View 'CanInstallNow' $null)) { $text += "`n`nYour installed update controller needs an IT update to enable Install Now." }
        if ($View.Message) { $text += "`n`n" + $View.Message }
        $controls.StatusText.Text = $text
        $controls.Deadline.Text = if ($View.DeadlineUtc) { 'Deadline: ' + (Get-LocalTimeLabel $View.DeadlineUtc) } else { 'Your {0}-hour window starts when this notice is delivered.' -f $windowHours }
        $controls.Remaining.Text = ''
        if ($View.DeadlineUtc) {
            $remaining = [datetimeoffset]::Parse($View.DeadlineUtc) - [datetimeoffset]::Parse($View.ServerUtc)
            $controls.Remaining.Text = if ($remaining.TotalSeconds -le 0) { 'Deadline reached - safety checks remain in effect.' } else { '{0} day(s), {1} hour(s), {2} minute(s) remaining' -f $remaining.Days,$remaining.Hours,$remaining.Minutes }
            if ($View.CanSchedule) {
                $controls.Day.DisplayDateEnd = ([datetimeoffset]::Parse($View.DeadlineUtc)).LocalDateTime.Date
                $controls.Day.DisplayDateStart = (Get-Date).Date
            }
        }
        $controls.Scheduled.Text = if ($View.RestartUtc) { 'Restart planned: ' + (Get-LocalTimeLabel $View.RestartUtc) } elseif ($View.ScheduledUtc) { 'Selected restart: ' + (Get-LocalTimeLabel $View.ScheduledUtc) } elseif ($installRequested) { 'Install Now requested. A restart warning will follow successful preparation.' } else { 'No time selected. The deadline remains the fallback.' }
        if (-not $actions.EnableSchedule) { $script:choosingSchedule = $false }
        $controls.PickerCard.Visibility = if ($script:choosingSchedule) { 'Visible' } else { 'Collapsed' }
        foreach ($pair in @(@('InstallButton','Install'),@('ScheduleButton','Schedule'),@('DeferButton','Defer'),@('RestartButton','Restart'))) {
            $controls[$pair[0]].Visibility = if ($actions['Show'+$pair[1]]) { 'Visible' } else { 'Collapsed' }
            $controls[$pair[0]].IsEnabled = $actions['Enable'+$pair[1]]
        }
        $controls.ScheduleButton.ToolTip = if ($script:choosingSchedule) { 'Save the selected date and time' } else { 'Choose a date and time' }
        $controls.InstallButton.ToolTip = if ($null -eq (Get-BiosViewValue $View 'CanInstallNow' $null)) { 'IT must update the installed controller to enable Install Now.' } elseif ($installRequested) { 'Installation has already been requested.' } else { 'Begin preparation after checking power and other safety requirements.' }
    }
    # An initially locked desktop must not acknowledge first delivery.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BiosVisibleDesktop {
 [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
 public static bool Available() { var d=OpenInputDesktop(0,false,1); if(d==IntPtr.Zero)return false; CloseDesktop(d); return true; }
}
'@
    function Refresh-Status {
        try {
            $v = Invoke-UIRequest @{ Action='Status' }
            Render-Status $v
            if ($v.ShouldShow -and [BiosVisibleDesktop]::Available()) {
                if (-not $window.IsVisible) { $window.Show(); $null = $window.Activate() }
                # Dispatcher idle runs after WPF has had an opportunity to render.
                $null = $window.Dispatcher.BeginInvoke([Action]{
                    try { Render-Status (Invoke-UIRequest @{ Action='NoticeShown' }) } catch { Show-UIMessage 'The scheduler is temporarily unavailable. Your deadline has not been reset.' -IsError }
                }, [Windows.Threading.DispatcherPriority]::ContextIdle)
            }
            if ($v.Phase -eq 'VerifiedComplete' -and -not $v.ShouldShow -and -not $window.IsVisible) { $script:quitting=$true; $app.Shutdown() }
        } catch { if ($window.IsVisible) { Show-UIMessage 'The scheduler is temporarily unavailable. Existing scheduling remains in effect; contact IT if this persists.' -IsError } }
    }
    $controls.InstallButton.Add_Click({
        $warning = Get-BiosViewValue $script:view 'FinalWarningMinutes' 15
        $message = 'Start preparing the BIOS update now? Save your work and connect AC power. Safety checks must pass first. After preparation, a restart will be scheduled with at least {0} minutes of warning. You can choose Restart Now once the update is ready.' -f $warning
        if ([Windows.MessageBox]::Show($message, $brand.AppTitle, 'YesNo', 'Question') -eq 'Yes') {
            try {
                $script:choosingSchedule = $false
                Render-Status (Invoke-UIRequest @{Action='InstallNow'})
                Show-UIMessage 'Installation requested. Keep AC power connected.'
            } catch { Show-UIMessage $_.Exception.Message -IsError }
        }
    })
    $controls.ScheduleButton.Add_Click({
        try {
            if (-not $script:choosingSchedule) {
                $script:choosingSchedule = $true
                Render-Status (Invoke-UIRequest @{Action='Status'})
                if (-not $script:choosingSchedule) { Show-UIMessage 'Scheduling is no longer available. Check the current update status.' -IsError; return }
                $controls.PickerCard.BringIntoView()
                $null = $controls.Day.Focus()
                Show-UIMessage 'Choose a date and time, then click Schedule Install again to save.'
                return
            }
            if ($null -eq $controls.Day.SelectedDate) { throw 'Choose a date.' }
            $utc = Convert-LocalSelectionToUtc $controls.Day.SelectedDate ([int]$controls.Hour.SelectedItem) ([int]$controls.Minute.SelectedItem)
            $updated = Invoke-UIRequest @{Action='Schedule'; Utc=$utc}
            $script:choosingSchedule = $false
            Render-Status $updated
            Show-UIMessage 'Your scheduled time has been saved. Keep AC power connected.'
        } catch { Show-UIMessage $_.Exception.Message -IsError }
    })
    $controls.CancelScheduleButton.Add_Click({ $script:choosingSchedule=$false; $controls.PickerCard.Visibility='Collapsed'; Show-UIMessage '' })
    $controls.DeferButton.Add_Click({
        try { Render-Status (Invoke-UIRequest @{Action='Defer'}); $window.Hide() }
        catch { Show-UIMessage $_.Exception.Message -IsError }
    })
    $controls.RestartButton.Add_Click({
        if ([Windows.MessageBox]::Show('Have you saved your work? Restart now to complete the BIOS update. Keep AC power connected.', $brand.AppTitle, 'YesNo', 'Question') -eq 'Yes') {
            try { Render-Status (Invoke-UIRequest @{Action='RestartNow'}) } catch { Show-UIMessage $_.Exception.Message -IsError }
        }
    })
    $controls.CloseButton.Add_Click({ $window.Close() })
    $window.Add_Closing({ param($sender,$e)
        if (-not $script:quitting) {
            $e.Cancel=$true; $window.Hide()
            # Closing only hides the UI. It never cancels the schedule.
            if ($script:view -and $script:view.CanSchedule) { try { $null=Invoke-UIRequest @{Action='Defer'} } catch { } }
        }
    })
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = [Drawing.SystemIcons]::Information
    $tray.Text = 'Device care - BIOS update'; $tray.Visible=$true
    $tray.Add_DoubleClick({ $window.Show(); $null=$window.Activate(); Refresh-Status })
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add('Open device care'); $open.Add_Click({ $window.Show(); $null=$window.Activate(); Refresh-Status })
    $tray.ContextMenuStrip=$menu
    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnExplicitShutdown'
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromSeconds(15)
    $timer.Add_Tick({ Refresh-Status }); $timer.Start()
    $app.Add_Startup({ Refresh-Status })
    $null = $app.Run()
} catch {
    try {
        $logDir=Join-Path $env:LOCALAPPDATA 'ManagedDellBIOS-v2'
        $null=New-Item -ItemType Directory -Path $logDir -Force
        Add-Content -LiteralPath (Join-Path $logDir 'UI.log') -Encoding UTF8 -Value (([datetime]::UtcNow.ToString('o')) + ' UI stopped: ' + $_.Exception.Message)
    } catch { }
    exit 1
} finally {
    if ($null -ne $tray) { $tray.Visible=$false; $tray.Dispose() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
