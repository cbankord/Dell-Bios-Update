# MedelaBIOS-FileVersion: 2.2.0
#requires -Version 5.1
# One-shot unprivileged prompt. No firmware, tasks, pipe, state writes or restart.
param(
    [switch]$Demo,
    [switch]$Overdue,
    [ValidateSet('Install','Restart','Info')][string]$Mode='Install',
    [string]$DeadlineUtc='',
    [ValidateRange(1,30)][int]$TimeoutMinutes=10,
    [string]$Message64=''
)
$ErrorActionPreference='Stop'
$script:choice=1; $script:accepted=$false; $timer=$null
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Use Windows PowerShell 5.1: powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo' }
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'Open the prompt in the signed-in user session, not session 0.' }
    if (-not $Demo -and -not $DeadlineUtc -and $Mode -eq 'Install') { throw 'For standalone preview, pass -Demo. Live installation must be launched by the PSADT package.' }
    if ($Demo -and -not $DeadlineUtc) { $DeadlineUtc=[datetimeoffset]::UtcNow.AddHours(72).ToString('o') }
    $deadline=if ($DeadlineUtc) { [datetimeoffset]::Parse($DeadlineUtc) } else { [datetimeoffset]::MaxValue }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $brand=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Branding.psd1')
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Window.xaml') -Raw
    $reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $c=@{}
    foreach ($name in @('Logo','Banner','Company','Heading','Purpose','StatusCard','StatusText','Deadline','Remaining','Power','Support','ActionBar','Primary','Secondary')) {
        $c[$name]=$window.FindName($name)
        if ($null -eq $c[$name]) { throw "Missing UI control: $name" }
    }
    $area=[Windows.SystemParameters]::WorkArea
    $window.MinWidth=[math]::Min($window.MinWidth,[math]::Max(240,$area.Width-24))
    $window.MinHeight=[math]::Min($window.MinHeight,[math]::Max(240,$area.Height-24))
    $window.Width=[math]::Min($window.Width,[math]::Max($window.MinWidth,$area.Width-24))
    $window.Height=[math]::Min($window.Height,[math]::Max($window.MinHeight,$area.Height-24))
    $window.Title=$brand.AppTitle
    if ($Demo) { $window.Title+=' (Preview - no deployment actions)' }
    $window.Background=$brand.BackgroundColor; $window.Foreground=$brand.TextColor
    $c.StatusCard.Background=$brand.SurfaceColor; $c.ActionBar.Background=$brand.SurfaceColor
    $c.Primary.Background=$brand.AccentColor; $c.Primary.Foreground='White'
    $c.Company.Text=$brand.CompanyName; $c.Heading.Text=$brand.Heading
    $c.Purpose.Text=$brand.Purpose; $c.Power.Text=$brand.PowerMessage; $c.Support.Text=$brand.SupportText
    $c.Support.Foreground=$brand.MutedColor
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
    $c.StatusText.Text='Choose Install Now when you can save your work and restart soon afterward. Defer closes this notice; the original deadline remains. Your IT deployment will try again later.'
    if ($Mode -eq 'Restart') {
        $c.Heading.Text='Restart required'; $c.StatusText.Text=$brand.ReadyMessage
        $c.Primary.Content='_Restart Now'; $c.Secondary.Content='Restart _Later'
    } elseif ($Mode -eq 'Info') {
        $c.Heading.Text='Update status'; $c.Primary.Content='_Close'; $c.Secondary.Visibility='Collapsed'
        if ($Message64) { $c.StatusText.Text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Message64)) }
    }
    [Windows.Automation.AutomationProperties]::SetName($c.Primary,($c.Primary.Content -replace '_',''))
    [Windows.Automation.AutomationProperties]::SetName($c.Secondary,($c.Secondary.Content -replace '_',''))
    $c.Deadline.Text=if ($DeadlineUtc -and $Mode -eq 'Install') { 'Install deferral deadline: '+$deadline.ToLocalTime().ToString('ddd, MMM d, yyyy h:mm tt zzz') } else { '' }
    $script:expires=[datetimeoffset]::UtcNow.AddMinutes($TimeoutMinutes)
    function Update-Prompt {
        $now=[datetimeoffset]::UtcNow
        if ($Mode -eq 'Install') {
            $isOverdue=$Overdue -or $now -ge $deadline
            $c.Secondary.Visibility=if ($isOverdue) {'Collapsed'} else {'Visible'}
            if ($isOverdue) {
                $c.StatusText.Text='The deferral deadline has passed. Save your work and connect AC power. Preparation will start after this notice; every firmware safety check must still pass.'
                $seconds=[math]::Max(0,[math]::Ceiling(($script:expires-$now).TotalSeconds))
                $c.Remaining.Text='Preparation will be requested in '+$seconds+' seconds, or choose Install Now.'
            } else {
                $left=$deadline-$now
                $c.Remaining.Text='{0} day(s), {1} hour(s), {2} minute(s) remaining' -f $left.Days,$left.Hours,$left.Minutes
            }
        }
        if ($now -ge $script:expires) {
            $script:choice=if ($Mode -eq 'Install' -and ($Overdue -or $now -ge $deadline)) {10} elseif ($Mode -eq 'Install') {11} elseif ($Mode -eq 'Restart') {13} else {14}
            $script:accepted=$true; $window.Close()
        }
    }
    $c.Primary.Add_Click({
        $script:choice=if ($Mode -eq 'Install') {10} elseif ($Mode -eq 'Restart') {12} else {14}
        $script:accepted=$true; $window.Close()
    })
    $c.Secondary.Add_Click({
        # The deadline can expire between a timer tick and a click.
        if ($Mode -eq 'Install' -and ($Overdue -or [datetimeoffset]::UtcNow -ge $deadline)) { Update-Prompt; return }
        $script:choice=if ($Mode -eq 'Install') {11} else {13}; $script:accepted=$true; $window.Close()
    })
    $window.Add_Closing({param($sender,$event)
        if (-not $script:accepted) {
            if ($Mode -eq 'Install' -and ($Overdue -or [datetimeoffset]::UtcNow -ge $deadline) -and -not $Demo) { $event.Cancel=$true; return }
            $script:choice=if ($Mode -eq 'Install') {11} elseif ($Mode -eq 'Restart') {13} else {14}
        }
    })
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[timespan]::FromSeconds(1); $timer.Add_Tick({Update-Prompt})
    $window.Add_ContentRendered({$timer.Start(); Update-Prompt})
    $null=$window.ShowDialog()
    if ($Demo) { Write-Output "Preview choice=$script:choice. No system action was performed."; exit 0 }
    exit $script:choice
} catch {
    [Console]::Error.WriteLine('BIOS UI startup failed: '+$_.Exception.Message)
    try { Add-Type -AssemblyName PresentationFramework; $null=[Windows.MessageBox]::Show($_.Exception.Message,'BIOS UI startup failed','OK','Error') } catch { }
    exit 1
} finally { if ($null -ne $timer) { $timer.Stop() } }
