# MedelaBIOS-FileVersion: 4.0.0
#requires -Version 5.1
# One-shot unprivileged prompt. No firmware, tasks, pipe, state writes or restart.
param(
    [switch]$Demo,
    [switch]$Overdue,
    [switch]$DisableScheduling,
    [ValidateSet('Install','Restart','Progress','Live','Info')][string]$Mode='Install',
    [string]$DeadlineUtc='',
    [string]$ScheduledInstallUtc='',
    [ValidateRange(1,30)][int]$TimeoutMinutes=10,
    [string]$Message64='',
    [ValidateRange(15,120)][int]$RestartMinutes=60,
    [ValidateRange(1,30)][int]$RestartReminderMinutes=15,
    [string]$StatusPath=''
)
$ErrorActionPreference='Stop'
$script:choice=1; $script:accepted=$false; $timer=$null
$script:lastReminder=0; $script:livePhase=''; $script:liveSession=''
$script:selectedInstallUtc=''
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Use Windows PowerShell 5.1: powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo' }
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'Open the prompt in the signed-in user session, not session 0.' }
    if (-not $Demo -and -not $DeadlineUtc -and $Mode -eq 'Install') { throw 'For standalone preview, pass -Demo. Live installation must be launched by the PSADT package.' }
    if (-not $Demo -and $Mode -in @('Restart','Progress')) { throw 'Use -Demo for standalone previews. The live progress/restart monitor must be launched by SYSTEM.' }
    if ($Mode -eq 'Live' -and (-not $StatusPath -or $Demo)) { throw 'Live mode requires a SYSTEM-owned status file. Preview with -Demo -Mode Progress or Restart.' }
    if ($Demo -and -not $DeadlineUtc) { $DeadlineUtc=[datetimeoffset]::UtcNow.AddHours(72).ToString('o') }
    $deadline=if ($DeadlineUtc) { [datetimeoffset]::Parse($DeadlineUtc) } else { [datetimeoffset]::MaxValue }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    . (Join-Path $PSScriptRoot 'WindowChrome.ps1')
    $brand=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Branding.psd1')
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Window.xaml') -Raw
    $reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $c=@{}
    foreach ($name in @('Logo','Banner','Company','Heading','Purpose','StatusCard','StatusText','Progress','Deadline','Remaining','Power','Support','ActionBar','Primary','Secondary','Schedule','SchedulePanel','InstallDate','InstallTime','ScheduleError','ConfirmSchedule','Back','CaptionClose')) {
        $c[$name]=$window.FindName($name)
        if ($null -eq $c[$name]) { throw "Missing UI control: $name" }
    }
    $window.Title=$brand.AppTitle
    if ($Demo) { $window.Title+=' (Preview - no deployment actions)' }
    Initialize-BiosWindowChrome $window (Join-Path $PSScriptRoot 'Theme.xaml') $brand (Get-BiosBrandIconPath $PSScriptRoot $brand)
    $c.Company.Text=$brand.CompanyName; $c.Heading.Text=$brand.Heading
    $c.Purpose.Text=$brand.Purpose; $c.Power.Text=$brand.PowerMessage; $c.Support.Text=$brand.SupportText
    foreach ($pair in @(@('Logo','LogoFile'),@('Banner','BannerFile'))) {
        $relative=$brand[$pair[1]]
        if ($relative) {
            $relative=$relative.Replace('\','/')
            if ($relative -notmatch '^Assets/[A-Za-z0-9_-]+\.(png|jpg|jpeg)$') { throw 'Brand images must be local PNG/JPG assets.' }
            $path=Join-Path $PSScriptRoot $relative
            $c[$pair[0]].Source=New-Object Windows.Media.Imaging.BitmapImage([uri]$path)
            $c[$pair[0]].Visibility='Visible'
        }
    }
    $c.StatusText.Text='Install Now, choose an installation time, or Defer. After preparation, you will have '+$RestartMinutes+' minutes to save your work before a guarded automatic restart. Defer keeps the original deadline and any existing installation time.'
    if ($DisableScheduling -and $Mode -eq 'Install') { $c.StatusText.Text='Choose Install Now or Defer. After preparation, you will have '+$RestartMinutes+' minutes to save your work before a guarded automatic restart. Deferring keeps the original deadline.' }
    if ($Mode -ne 'Install' -or $DisableScheduling) { $c.Schedule.Visibility='Collapsed' }
    if ($Mode -eq 'Install') {
        $suggested=[datetime]::Now.AddMinutes(15)
        if ($ScheduledInstallUtc) {
            $suggested=([datetimeoffset]::Parse($ScheduledInstallUtc)).LocalDateTime
            $c.StatusText.Text='Installation scheduled: '+$suggested.ToString('ddd, MMM d, yyyy h:mm tt')+'. Install Now starts sooner; Defer keeps this appointment. '+$(if ($DisableScheduling) {'This previously accepted time remains in effect; new scheduling is disabled.'} else {'Schedule Install changes the time.'})+' The restart warning begins after preparation.'
        }
        # Overdue or missed appointments must not make DatePicker initialization
        # fail before the Install Now-only prompt can appear.
        $lastDate=if ($deadline.LocalDateTime.Date -lt [datetime]::Today) {[datetime]::Today} else {$deadline.LocalDateTime.Date}
        if ($suggested.Date -lt [datetime]::Today) { $suggested=[datetime]::Now.AddMinutes(15) }
        if ($suggested.Date -gt $lastDate) { $suggested=$lastDate.AddHours(23).AddMinutes(59) }
        $c.InstallDate.DisplayDateStart=[datetime]::Today; $c.InstallDate.DisplayDateEnd=$lastDate
        $c.InstallDate.SelectedDate=$suggested.Date
        for ($hour=0;$hour -lt 24;$hour++) { foreach ($minute in @(0,15,30,45)) { $null=$c.InstallTime.Items.Add(('{0:00}:{1:00}' -f $hour,$minute)) } }
        $c.InstallTime.Text=$suggested.ToString('HH:mm')
    }
    if ($Mode -eq 'Restart') {
        $c.Heading.Text='Restart required'; $c.StatusText.Text=$brand.ReadyMessage
        $c.Primary.Content='_Restart Now'; $c.Secondary.Content='_Minimize'
        $c.Remaining.Text='Automatic restart in '+$RestartMinutes+':00 (preview only)'
    } elseif ($Mode -in @('Progress','Live')) {
        $c.Heading.Text='Preparing BIOS update'; $c.StatusText.Text='The update is being prepared. Keep your computer plugged in and do not turn it off. Firmware installation may finish during restart.'
        $c.Progress.Visibility='Visible';$c.Primary.Visibility='Collapsed';$c.Secondary.Content='_Minimize'
    } elseif ($Mode -eq 'Info') {
        $c.Heading.Text='Update status'; $c.Primary.Content='_Close'; $c.Secondary.Visibility='Collapsed'
        if ($Message64) { $c.StatusText.Text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Message64)) }
    }
    [Windows.Automation.AutomationProperties]::SetName($c.Primary,($c.Primary.Content -replace '_',''))
    [Windows.Automation.AutomationProperties]::SetName($c.Secondary,($c.Secondary.Content -replace '_',''))
    if ($Mode -eq 'Live') { $c.CaptionClose.ToolTip='Minimize update window'; [Windows.Automation.AutomationProperties]::SetName($c.CaptionClose,'Minimize update window') }
    elseif ($Demo) { $c.CaptionClose.ToolTip='Close preview' }
    elseif ($Mode -eq 'Install') { $c.CaptionClose.ToolTip='Defer until the next notice; any accepted appointment remains in effect' }
    $c.Deadline.Text=if ($DeadlineUtc -and $Mode -eq 'Install') { 'Install deferral deadline: '+$deadline.ToLocalTime().ToString('ddd, MMM d, yyyy h:mm tt zzz') } else { '' }
    $script:expires=[datetimeoffset]::UtcNow.AddMinutes($TimeoutMinutes)
    $script:demoRestartAt=[datetimeoffset]::UtcNow.AddMinutes($RestartMinutes)
    function Close-LivePrompt {
        $script:choice=14;$script:accepted=$true;$window.Close()
    }
    function Show-RestartReminder {
        # Respect the current monitor's work area and device scaling. Restoring
        # is explicit every 15 minutes; dragging/minimizing otherwise stays put.
        $window.WindowState='Normal';$window.UpdateLayout()
        $handle=(New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        $area=[Windows.Forms.Screen]::FromHandle($handle).WorkingArea
        $source=[Windows.PresentationSource]::FromVisual($window)
        $transform=$source.CompositionTarget.TransformFromDevice
        $corner=$transform.Transform((New-Object Windows.Point($area.X,$area.Y)))
        $size=$transform.Transform((New-Object Windows.Point($area.Width,$area.Height)))
        $window.Left=$corner.X+[math]::Max(0,($size.X-$window.ActualWidth)/2)
        $window.Top=$corner.Y+[math]::Max(0,($size.Y-$window.ActualHeight)/2)
        $oldTop=$window.Topmost;$window.Topmost=$true;$null=$window.Activate();$window.Topmost=$oldTop
        [Media.SystemSounds]::Exclamation.Play()
    }
    function Update-LivePrompt {
        # This is a display feed, never a privileged command/credential channel.
        # An absent/stale heartbeat retires the window, including after host loss.
        if (-not (Test-Path -LiteralPath $StatusPath)) { Close-LivePrompt; return }
        try {
            # Delete-sharing lets SYSTEM atomically replace the heartbeat while
            # WPF reads it on Windows. Default Get-Content sharing can block it.
            $stream=[IO.File]::Open($StatusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite,Delete')
            try {
                $reader=New-Object IO.StreamReader($stream)
                try { $data=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
            $age=([datetimeoffset]::UtcNow-[datetimeoffset]::Parse([string]$data.HeartbeatUtc)).TotalSeconds
            if ($data.Schema -ne 1 -or $data.Session -notmatch '^[a-f0-9]{32}$' -or $age -gt 30 -or $age -lt -30) { Close-LivePrompt; return }
            if ($script:liveSession -and $script:liveSession -ne $data.Session) { Close-LivePrompt; return }
            $script:liveSession=$data.Session;$script:livePhase=$data.Phase
            $c.Progress.Visibility='Collapsed';$c.Primary.Visibility='Collapsed'
            $c.Secondary.Content='_Minimize';$c.Deadline.Text='';$c.Remaining.Text=''
            if ($data.Phase -eq 'Preparing') {
                $c.Heading.Text='Preparing BIOS update';$c.Progress.Visibility='Visible'
                $c.StatusText.Text='The update is being prepared. Keep your computer plugged in and do not turn it off. Firmware installation may finish during restart.'
            } elseif ($data.Phase -eq 'StartingRestart') {
                $c.Heading.Text='Restart required';$c.StatusText.Text='Checking power and preparing the restart warning. Keep your computer plugged in.'
            } elseif ($data.Phase -eq 'Restart') {
                $c.Heading.Text='Restart required';$c.StatusText.Text=$brand.ReadyMessage
                $c.Primary.Visibility='Visible';$c.Primary.Content='_Restart Now'
                $seconds=[math]::Max(0,[int]$data.RemainingSeconds-[int][math]::Floor([math]::Max(0,$age)))
                $c.Remaining.Text='Automatic restart in {0:00}:{1:00}. Save your work now.' -f [int][math]::Floor($seconds/60),($seconds%60)
                $c.Deadline.Text='Restart time: '+([datetimeoffset]::Parse([string]$data.DeadlineUtc)).ToLocalTime().ToString('h:mm tt zzz')
                if ([int]$data.Reminder -gt $script:lastReminder) { $script:lastReminder=[int]$data.Reminder;Show-RestartReminder }
            } elseif ($data.Phase -eq 'Paused') {
                $c.Heading.Text='Automatic restart cancelled';$c.StatusText.Text=$data.Message
            } else { Close-LivePrompt;return }
            [Windows.Automation.AutomationProperties]::SetName($c.Primary,($c.Primary.Content -replace '_',''))
            [Windows.Automation.AutomationProperties]::SetName($c.Secondary,'Minimize')
        } catch { Close-LivePrompt }
    }
    function Update-Prompt {
        if ($Mode -eq 'Live') { Update-LivePrompt;return }
        $now=[datetimeoffset]::UtcNow
        if ($Demo -and $Mode -eq 'Restart') {
            $seconds=[math]::Max(0,[math]::Ceiling(($script:demoRestartAt-$now).TotalSeconds))
            $c.Remaining.Text='Preview countdown {0:00}:{1:00}. No restart will occur.' -f [int][math]::Floor($seconds/60),($seconds%60)
            $reminder=[int][math]::Floor(($RestartMinutes*60-$seconds)/($RestartReminderMinutes*60))
            if ($reminder -gt $script:lastReminder -and $seconds -gt 0) { $script:lastReminder=$reminder;Show-RestartReminder }
            if ($seconds -le 0) { $script:choice=13;$script:accepted=$true;$window.Close() }
            return
        }
        if ($Mode -eq 'Install') {
            $isOverdue=$Overdue -or $now -ge $deadline
            $c.CaptionClose.IsEnabled=$Demo -or -not $isOverdue
            $c.Secondary.Visibility=if ($isOverdue) {'Collapsed'} else {'Visible'}
            $c.Schedule.Visibility=if ($isOverdue -or $DisableScheduling) {'Collapsed'} else {'Visible'}
            if ($isOverdue) {
                $c.SchedulePanel.Visibility='Collapsed'
                $c.StatusText.Text='The deferral deadline has passed. Save your work and connect AC power. Preparation will start after this notice; every firmware safety check must still pass.'
                $seconds=[math]::Max(0,[math]::Ceiling(($script:expires-$now).TotalSeconds))
                $c.Remaining.Text='Preparation will be requested in '+$seconds+' seconds, or choose Install Now.'
            } else {
                $left=$deadline-$now
                $c.Remaining.Text='{0} day(s), {1} hour(s), {2} minute(s) until Install Now is the only option.' -f $left.Days,$left.Hours,$left.Minutes
            }
        }
        if ($now -ge $script:expires) {
            $script:choice=if ($Mode -eq 'Install' -and ($Overdue -or $now -ge $deadline)) {10} elseif ($Mode -eq 'Install') {11} elseif ($Mode -eq 'Restart') {13} else {14}
            $script:accepted=$true; $window.Close()
        }
    }
    function Confirm-InstallSchedule {
        try {
            $now=[datetimeoffset]::UtcNow
            if ($DisableScheduling) { $c.SchedulePanel.Visibility='Collapsed'; $c.ScheduleError.Text='Installation scheduling is disabled for this package.'; return }
            if ($Overdue -or $now -ge $deadline) { Update-Prompt; return }
            if ($null -eq $c.InstallDate.SelectedDate -or $c.InstallTime.Text -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'Select a date and enter a time as HH:mm, for example 14:30.' }
            $local=[datetime]::SpecifyKind(([datetime]$c.InstallDate.SelectedDate).Date.Add([timespan]::ParseExact(($c.InstallTime.Text+':00'),'hh\:mm\:ss',[Globalization.CultureInfo]::InvariantCulture)),[DateTimeKind]::Unspecified)
            $zone=[TimeZoneInfo]::Local
            if ($zone.IsInvalidTime($local) -or $zone.IsAmbiguousTime($local)) { throw 'That local time is skipped or repeated by daylight saving time. Choose another time.' }
            $utc=[datetimeoffset]([TimeZoneInfo]::ConvertTimeToUtc($local,$zone))
            if ($utc -lt $now.AddMinutes(5) -or $utc -gt $deadline) { throw 'Choose a time at least five minutes from now and no later than the original deadline.' }
            $script:selectedInstallUtc=$utc.ToUniversalTime().ToString('o')
            $script:choice=15; $script:accepted=$true; $window.Close()
        } catch { $c.ScheduleError.Text=$_.Exception.Message }
    }
    $c.Schedule.Add_Click({
        if ($Mode -ne 'Install' -or $DisableScheduling -or $Overdue -or [datetimeoffset]::UtcNow -ge $deadline) { Update-Prompt; return }
        $c.SchedulePanel.Visibility='Visible'; $c.ScheduleError.Text=''
    })
    $c.ConfirmSchedule.Add_Click({ Confirm-InstallSchedule })
    $c.Back.Add_Click({ $c.SchedulePanel.Visibility='Collapsed' })
    $c.Primary.Add_Click({
        if ($Mode -eq 'Live' -and $script:livePhase -ne 'Restart') { return }
        $script:choice=if ($Mode -eq 'Install') {10} elseif ($Mode -eq 'Restart' -or $Mode -eq 'Live') {12} else {14}
        $script:accepted=$true; $window.Close()
    })
    $c.Secondary.Add_Click({
        if ($Mode -in @('Live','Restart','Progress')) { $window.WindowState='Minimized';return }
        # The deadline can expire between a timer tick and a click.
        if ($Mode -eq 'Install' -and ($Overdue -or [datetimeoffset]::UtcNow -ge $deadline)) { Update-Prompt; return }
        $script:choice=if ($Mode -eq 'Install') {11} else {13}; $script:accepted=$true; $window.Close()
    })
    $window.Add_Closing({param($sender,$event)
        if (-not $script:accepted) {
            if ($Mode -eq 'Live') { $event.Cancel=$true;$window.WindowState='Minimized';return }
            if ($Mode -eq 'Install' -and ($Overdue -or [datetimeoffset]::UtcNow -ge $deadline) -and -not $Demo) { $event.Cancel=$true; return }
            $script:choice=if ($Mode -eq 'Install') {11} elseif ($Mode -eq 'Restart') {13} else {14}
        }
    })
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[timespan]::FromSeconds(1); $timer.Add_Tick({Update-Prompt})
    $window.Add_ContentRendered({$timer.Start(); Update-Prompt})
    $null=$window.ShowDialog()
    if ($Demo) { Write-Output "Preview choice=$script:choice. No system action was performed."; exit 0 }
    if ($script:choice -eq 15) { [Console]::Out.WriteLine(('MEDELA_INSTALL_UTC='+$script:selectedInstallUtc)) }
    exit $script:choice
} catch {
    [Console]::Error.WriteLine('BIOS UI startup failed: '+$_.Exception.Message)
    if ($Mode -ne 'Live') { try { Add-Type -AssemblyName PresentationFramework; $null=[Windows.MessageBox]::Show($_.Exception.Message,'BIOS UI startup failed','OK','Error') } catch { } }
    exit 1
} finally { if ($null -ne $timer) { $timer.Stop() } }
