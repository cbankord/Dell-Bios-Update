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
    $controls = @{}
    foreach ($name in @('Logo','Banner','Mark','Company','Heading','Purpose','Phase','StatusText','Deadline','Remaining','Scheduled','Day','Hour','Minute','TimeZone','PreparationText','Power','ErrorText','Support','PickerCard','StatusCard','ScheduleButton','RestartButton','DeferButton','CloseButton')) { $controls[$name] = $window.FindName($name) }
    $window.Title = $brand.AppTitle
    $window.Background = $brand.BackgroundColor
    $window.Foreground = $brand.TextColor
    foreach ($name in @('PickerCard','StatusCard')) { $controls[$name].Background = $brand.SurfaceColor }
    foreach ($name in @('ScheduleButton','RestartButton','Mark')) { $controls[$name].Background = $brand.AccentColor }
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
    $script:demoView = [pscustomobject]@{ WindowHours=72; PreparationLeadMinutes=30; Phase='Pending'; DeadlineUtc=[datetimeoffset]::UtcNow.AddHours(72).ToString('o'); ScheduledUtc=''; RestartUtc=''; ServerUtc=[datetimeoffset]::UtcNow.ToString('o'); CanSchedule=$true; Overdue=$false; ShouldShow=$true; Message=''; CanRestart=$false }
    function Invoke-UIRequest($Request) {
        if ($Demo) {
            if ($Request.Action -eq 'Schedule') { $script:demoView.Phase='Scheduled'; $script:demoView.ScheduledUtc=$Request.Utc }
            if ($Request.Action -in @('NoticeShown','Defer')) { $script:demoView.ShouldShow=$false }
            return $script:demoView
        }
        Send-BiosRequest $Request
    }
    function Render-Status($View) {
        $script:view = $View
        $controls.PreparationText.Text = 'Use your local time. Preparation can begin up to {0} minutes earlier; save your work before then.' -f $View.PreparationLeadMinutes
        $labels = @{ AwaitingNotice='Choose a time that works for you'; Pending='Ready to schedule'; Scheduled='Your restart is scheduled'; Preparing='Preparing your BIOS update'; Blocked='Waiting for a safety requirement'; RestartRequired='Restart required'; Verifying='Verifying the update'; VerifiedComplete='Update verified complete'; NeedsAttention='Your IT team needs to take a look' }
        $controls.Phase.Text = $labels[$View.Phase]
        $text = 'You can postpone reminders as often as needed before the deadline. Your original deadline will stay the same.'
        if ($View.Phase -eq 'Preparing') { $text = 'Save your work and stay plugged in. Preparation is running silently. Scheduling is now locked.' }
        if ($View.Phase -eq 'RestartRequired') { $text = $brand.ReadyMessage }
        if ($View.Phase -eq 'Verifying') { $text = 'Windows has returned. We are checking the installed BIOS version and drive protection.' }
        if ($View.Phase -eq 'VerifiedComplete') { $text = 'The installed BIOS meets the approved version and drive protection has been checked. You can continue working.' }
        if ($View.Overdue -and $View.Phase -in @('Pending','Scheduled','Blocked')) { $text = 'The deadline has passed. Deferral is unavailable. The update will proceed when safety requirements are met.' }
        if ($View.Message) { $text += "`n`n" + $View.Message }
        $controls.StatusText.Text = $text
        $controls.Deadline.Text = if ($View.DeadlineUtc) { 'Deadline: ' + (Get-LocalTimeLabel $View.DeadlineUtc) } else { 'Your {0}-hour window starts when this notice is delivered.' -f $View.WindowHours }
        $controls.Remaining.Text = ''
        if ($View.DeadlineUtc) {
            $remaining = [datetimeoffset]::Parse($View.DeadlineUtc) - [datetimeoffset]::Parse($View.ServerUtc)
            $controls.Remaining.Text = if ($remaining.TotalSeconds -le 0) { 'Deadline reached - safety checks remain in effect.' } else { '{0} day(s), {1} hour(s), {2} minute(s) remaining' -f $remaining.Days,$remaining.Hours,$remaining.Minutes }
            if ($View.CanSchedule) {
                $controls.Day.DisplayDateEnd = ([datetimeoffset]::Parse($View.DeadlineUtc)).LocalDateTime.Date
                $controls.Day.DisplayDateStart = (Get-Date).Date
            }
        }
        $controls.Scheduled.Text = if ($View.RestartUtc) { 'Restart planned: ' + (Get-LocalTimeLabel $View.RestartUtc) } elseif ($View.ScheduledUtc) { 'Selected restart: ' + (Get-LocalTimeLabel $View.ScheduledUtc) } else { 'No time selected. The deadline remains the fallback.' }
        $controls.PickerCard.Visibility = if ($View.CanSchedule) { 'Visible' } else { 'Collapsed' }
        $controls.ScheduleButton.Visibility = $controls.PickerCard.Visibility
        $controls.DeferButton.Visibility = $controls.PickerCard.Visibility
        $controls.RestartButton.Visibility = if ($View.CanRestart) { 'Visible' } else { 'Collapsed' }
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
                    try { Render-Status (Invoke-UIRequest @{ Action='NoticeShown' }) } catch { $controls.ErrorText.Text = 'The scheduler is temporarily unavailable. Your deadline has not been reset.' }
                }, [Windows.Threading.DispatcherPriority]::ContextIdle)
            }
            if ($v.Phase -eq 'VerifiedComplete' -and -not $v.ShouldShow -and -not $window.IsVisible) { $script:quitting=$true; $app.Shutdown() }
        } catch { if ($window.IsVisible) { $controls.ErrorText.Text = 'The scheduler is temporarily unavailable. Existing scheduling remains in effect; contact IT if this persists.' } }
    }
    $controls.ScheduleButton.Add_Click({
        try {
            if ($null -eq $controls.Day.SelectedDate) { throw 'Choose a date.' }
            $utc = Convert-LocalSelectionToUtc $controls.Day.SelectedDate ([int]$controls.Hour.SelectedItem) ([int]$controls.Minute.SelectedItem)
            Render-Status (Invoke-UIRequest @{Action='Schedule'; Utc=$utc})
            $controls.ErrorText.Text = 'Your restart time has been saved. Keep AC power connected.'
        } catch { $controls.ErrorText.Text = $_.Exception.Message }
    })
    $controls.DeferButton.Add_Click({
        try { Render-Status (Invoke-UIRequest @{Action='Defer'}); $window.Hide() }
        catch { $controls.ErrorText.Text = $_.Exception.Message }
    })
    $controls.RestartButton.Add_Click({
        if ([Windows.MessageBox]::Show('Have you saved your work? Restart now to complete the BIOS update. Keep AC power connected.', $brand.AppTitle, 'YesNo', 'Question') -eq 'Yes') {
            try { Render-Status (Invoke-UIRequest @{Action='RestartNow'}) } catch { $controls.ErrorText.Text = $_.Exception.Message }
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
