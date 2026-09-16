#requires -Version 5.1
# Unprivileged WPF client. No firmware, BitLocker, task or restart commands here.
param([switch]$Demo, [switch]$Background)
$ErrorActionPreference = 'Stop'
$script:quitting = $false
$script:openRequested = -not $Background
$script:lastFailure = ''
$script:noticeQueued = $false
$mutex = $null
$ownsMutex = $false
$activation = $null
$activationTimer = $null
$timer = $null
$tray = $null
function Write-UILog([string]$Message) {
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'ManagedDellBIOS-v2'
        $null = New-Item -ItemType Directory -Path $logDir -Force
        Add-Content -LiteralPath (Join-Path $logDir 'UI.log') -Encoding UTF8 -Value ('{0} PID={1} {2}' -f [datetime]::UtcNow.ToString('o'),$PID,$Message)
    } catch { } # A logging failure must not hide the original error.
}
function Get-UIFailureText($Record) {
    # Include nested exception messages and script location, never source lines,
    # arguments, request bodies, BIOS configuration or credential files.
    $parts = @()
    $exception = $Record.Exception
    while ($null -ne $exception) { $parts += $exception.GetType().Name + ': ' + $exception.Message; $exception = $exception.InnerException }
    'Line {0}; {1}; {2}' -f $Record.InvocationInfo.ScriptLineNumber,$Record.FullyQualifiedErrorId,($parts -join ' -> ')
}
function Get-UIInstanceName([int]$SessionId, [bool]$Preview) {
    $name = "Local\ManagedDellBiosV2-UI-$SessionId"
    if ($Preview) { $name += '-Preview' }
    $name
}
try {
    Write-UILog ('Starting; Demo={0}; Background={1}; host={2}; apartment={3}; source={4}' -f [bool]$Demo,[bool]$Background,$PSVersionTable.PSVersion,[Threading.Thread]::CurrentThread.GetApartmentState(),$PSScriptRoot)
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Open this script in Windows PowerShell 5.1 (powershell.exe), not pwsh or another host.' }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'The UI requires STA. Launch a fresh powershell.exe -NoProfile -STA -File process.' }
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $systemUser = $identity.User.Value -eq 'S-1-5-18' } finally { $identity.Dispose() }
    if ($sessionId -eq 0 -or $systemUser) { throw 'Run the UI as the signed-in user on their Windows desktop. SYSTEM enrolls the controller; it cannot show this window in session 0.' }
    if ($Demo -and $Background) { throw 'Preview is interactive. Use -Demo without -Background.' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    if ($null -ne [Windows.Application]::Current) { throw 'This host already owns a WPF application. Start the UI in a fresh powershell.exe -NoProfile -STA -File process.' }
    $instanceName = Get-UIInstanceName $sessionId ([bool]$Demo)
    $eventCreated = $false
    # Session-local, unprivileged signal: it can only open the existing window.
    # Create before acquiring the mutex so simultaneous launches can signal it.
    $activation = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, ($instanceName + '-Open'), [ref]$eventCreated)
    $mutex = [Threading.Mutex]::new($false, $instanceName)
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        if (-not $Background) {
            if ($eventCreated) { throw 'An older copy of the UI is already running. Open Device care from the notification area. IT must replace the cached UI and its launchers together before using this fix.' }
            $null = $activation.Set()
            Write-UILog 'Requested that the existing window open.'
        } else { Write-UILog 'Background duplicate skipped; existing UI owns reminders.' }
        exit 0
    }
    . "$PSScriptRoot\Client.ps1"
    $transport = Join-Path $PSScriptRoot 'Transport.ps1'
    if (-not (Test-Path -LiteralPath $transport)) { $transport = Join-Path $PSScriptRoot '..\Scheduler\Transport.ps1' }
    . $transport
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
    foreach ($name in @('Logo','Banner','Mark','Company','Heading','Purpose','Phase','StatusText','Deadline','Remaining','Scheduled','Day','Hour','Minute','TimeZone','PreparationText','Power','ErrorText','Support','PickerCard','StatusCard','ActionBar','ContentScroll','InstallButton','ScheduleButton','CancelScheduleButton','RestartButton','DeferButton','CloseButton')) {
        $controls[$name] = $window.FindName($name)
        if ($null -eq $controls[$name]) { throw "Window.xaml is missing the required control '$name'. Update the UI files together." }
    }
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
    $controls.Phase.Text = 'Connecting to the update service'
    $controls.StatusText.Text = 'Please wait while we check your update status. No installation is started by opening this window.'
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
    function Test-NoticeDesktop { [BiosVisibleDesktop]::Available() }
    function Show-NoticeWindow {
        if (-not (Test-NoticeDesktop)) { return $false }
        if (-not $window.IsVisible) { $window.Show() }
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
        $null = $window.Activate()
        $script:openRequested = $false
        return $true
    }
    function Report-UIFailure($Record) {
        $detail = Get-UIFailureText $Record
        if ($detail -ne $script:lastFailure) { Write-UILog ('Status unavailable: ' + $detail); $script:lastFailure = $detail }
        # Do not allow actions using stale permissions while the broker is offline
        # or rendering has failed. Only a fresh, authenticated view enables them.
        foreach ($name in @('InstallButton','ScheduleButton','DeferButton','RestartButton')) { $controls[$name].IsEnabled = $false }
        $controls.Phase.Text = 'Update status is unavailable'
        $controls.StatusText.Text = if ($null -eq $script:view) { 'We could not connect to the update service. This window will retry automatically. Contact IT if this continues.' } else { 'We could not refresh your update status. Any times shown are the last received values. The existing schedule remains in effect.' }
        $controls.Remaining.Text = ''
        Show-UIMessage 'The update service is unavailable. Actions are paused in this window; the existing deadline has not been reset.' -IsError
    }
    function Confirm-NoticeRendered {
        if ($script:noticeQueued) { return }
        $script:noticeQueued = $true
        # A queued acknowledgement must recheck visibility and the input desktop:
        # the user might close/lock the window before this callback executes.
        $null = $window.Dispatcher.BeginInvoke([Action]{
            try {
                if ($window.IsVisible -and (Test-NoticeDesktop)) { Render-Status (Invoke-UIRequest @{Action='NoticeShown'}) }
            } catch { Report-UIFailure $_ } finally { $script:noticeQueued = $false }
        }, [Windows.Threading.DispatcherPriority]::ContextIdle)
    }
    function Refresh-Status {
        try {
            # Manual opening is independent of the reminder cooldown and must
            # also show connection errors on an unenrolled/broken installation.
            if ($script:openRequested) { $null = Show-NoticeWindow }
            $v = Invoke-UIRequest @{ Action='Status' }
            Render-Status $v
            if ($script:lastFailure) { Write-UILog 'Status connection/rendering recovered.'; $script:lastFailure = ''; Show-UIMessage '' }
            if ($v.ShouldShow -and (Test-NoticeDesktop)) {
                if (-not $window.IsVisible) { $null = Show-NoticeWindow }
                Confirm-NoticeRendered
            }
            if ($v.Phase -eq 'VerifiedComplete' -and -not $v.ShouldShow -and -not $window.IsVisible -and -not $script:openRequested) { $script:quitting=$true; $app.Shutdown() }
        } catch { Report-UIFailure $_ }
    }
    function Receive-UIActivation {
        if ($activation.WaitOne(0)) { $script:openRequested=$true; Refresh-Status }
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
        if ($Demo) { $script:quitting=$true }
        if (-not $script:quitting) {
            $e.Cancel=$true; $window.Hide()
            # Closing only hides the UI. It never cancels the schedule.
            if ($script:view -and $script:view.CanSchedule) { try { $null=Invoke-UIRequest @{Action='Defer'} } catch { } }
        }
    })
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = [Drawing.SystemIcons]::Information
    $tray.Text = 'Device care - BIOS update'; $tray.Visible=$true
    $tray.Add_DoubleClick({ $script:openRequested=$true; Refresh-Status })
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add('Open device care'); $open.Add_Click({ $script:openRequested=$true; Refresh-Status })
    $tray.ContextMenuStrip=$menu
    $app = New-Object Windows.Application
    $app.MainWindow = $window
    $app.ShutdownMode = if ($Demo) { 'OnMainWindowClose' } else { 'OnExplicitShutdown' }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromSeconds(15)
    $timer.Add_Tick({ Refresh-Status }); $timer.Start()
    $activationTimer = New-Object Windows.Threading.DispatcherTimer
    $activationTimer.Interval = [timespan]::FromSeconds(1)
    $activationTimer.Add_Tick({ Receive-UIActivation }); $activationTimer.Start()
    $app.Add_Startup({ Refresh-Status })
    Write-UILog 'UI initialized; starting the window dispatcher.'
    $null = $app.Run()
} catch {
    $detail = Get-UIFailureText $_
    Write-UILog ('UI stopped: ' + $detail)
    $message = "The BIOS update window could not open.`r`n`r`n$detail`r`n`r`nDetails: %LOCALAPPDATA%\ManagedDellBIOS-v2\UI.log"
    [Console]::Error.WriteLine($message)
    if (-not $Background -and [Environment]::UserInteractive) {
        try { Add-Type -AssemblyName PresentationFramework; $null = [Windows.MessageBox]::Show($message, 'BIOS update - UI startup error', 'OK', 'Error') } catch { }
    }
    exit 1
} finally {
    if ($null -ne $timer) { $timer.Stop() }
    if ($null -ne $activationTimer) { $activationTimer.Stop() }
    if ($null -ne $tray) { $tray.Visible=$false; $tray.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    if ($null -ne $activation) { $activation.Dispose() }
}
