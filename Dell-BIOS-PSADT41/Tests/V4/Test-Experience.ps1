# Portable behavior checks. Real callbacks, inert controls; no WPF or firmware.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Simple/State.ps1"
. "$root/Files/UI/WindowChrome.ps1"
$count=0
function Check($Value,$Name) {$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try{&$Body}catch{$failed=$true};Check $failed $Name}
Check (Get-AllowScheduleLater @{}) 'Legacy policy defaults to enabled'
Check (Get-AllowScheduleLater @{AllowScheduleLater=$true}) 'Explicit true enables scheduling'
Check (-not (Get-AllowScheduleLater @{AllowScheduleLater=$false})) 'Explicit false disables scheduling'
foreach($bad in @('false','true',0,1,$null)) {Reject {Get-AllowScheduleLater @{AllowScheduleLater=$bad}} 'Only literal Boolean policy values are accepted'}

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Files/UI/Show-BiosUI.ps1",[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'UI source parses'
foreach($name in @('Update-Prompt','Confirm-InstallSchedule')) {
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Get-Handler($Target,$Event) {
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq $Target -and $n.Member.Value -eq $Event},$true))
    if($nodes.Count -ne 1){throw 'Expected one UI event handler'}
    return $nodes[0].Arguments[0].ScriptBlock.GetScriptBlock()
}
$script:closing=Get-Handler '$window' Add_Closing
$scheduleClick=Get-Handler '$c.Schedule' Add_Click
$deferClick=Get-Handler '$c.Secondary' Add_Click
$primaryClick=Get-Handler '$c.Primary' Add_Click
function Reset-UI {
    $script:window=[pscustomobject]@{WindowState='Normal';Closed=$false;CloseAttempts=0}
    $window | Add-Member ScriptMethod Close {
        $this.CloseAttempts++;$event=[pscustomobject]@{Cancel=$false}
        & $script:closing $this $event
        if(-not $event.Cancel){$this.Closed=$true}
    }
    $script:c=@{}
    foreach($name in @('CaptionClose','Primary','Secondary','Schedule','SchedulePanel','Remaining','StatusText','ScheduleError')) {
        $script:c[$name]=[pscustomobject]@{IsEnabled=$true;Visibility='Visible';Text=''}
    }
    $script:c.SchedulePanel.Visibility='Collapsed'
    $script:Mode='Install';$script:Demo=$false;$script:Overdue=$false;$script:DisableScheduling=$false
    $script:deadline=[datetimeoffset]::UtcNow.AddDays(2);$script:expires=[datetimeoffset]::UtcNow.AddMinutes(5)
    $script:choice=1;$script:accepted=$false;$script:selectedInstallUtc=''
}
foreach($disabled in @($false,$true)) {
    Reset-UI;$DisableScheduling=$disabled;Update-Prompt
    Check ($c.Primary.Visibility -eq 'Visible' -and $c.Secondary.Visibility -eq 'Visible') 'Install Now and Defer are available before deadline in both modes'
    Check (($c.Schedule.Visibility -eq 'Visible') -eq (-not $disabled)) 'Schedule visibility follows the flag'
    & $scheduleClick
    Check (($c.SchedulePanel.Visibility -eq 'Visible') -eq (-not $disabled)) 'Schedule click honors the setting'
    if($disabled) {
        Confirm-InstallSchedule
        Check ($script:choice -ne 15 -and -not $window.Closed -and -not $script:selectedInstallUtc) 'Disabled confirmation cannot return a scheduling command'
    }
    & $deferClick
    Check ($window.Closed -and $script:choice -eq 11) 'Deferral still works with either flag'
    Reset-UI;$DisableScheduling=$disabled;$script:expires=[datetimeoffset]::UtcNow.AddSeconds(-1);Update-Prompt
    Check ($window.Closed -and $script:choice -eq 11) 'Predeadline timeout still defers with either flag'

    Reset-UI;$DisableScheduling=$disabled;$deadline=[datetimeoffset]::UtcNow.AddSeconds(-1);Update-Prompt
    Check ($c.Primary.Visibility -eq 'Visible' -and $c.Secondary.Visibility -eq 'Collapsed' -and $c.Schedule.Visibility -eq 'Collapsed' -and -not $c.CaptionClose.IsEnabled) 'Overdue offers only Install Now with either flag'
    & $deferClick; & $scheduleClick; Confirm-InstallSchedule
    Check (-not $window.Closed -and $script:choice -eq 1 -and $c.SchedulePanel.Visibility -eq 'Collapsed') 'Stale defer/schedule clicks cannot accept a new choice after expiry'
    Invoke-BiosCaptionAction $window Close
    Check (-not $window.Closed) 'Closing via caption/Alt-F4 guard cannot defer an overdue deployment'
    $script:expires=[datetimeoffset]::UtcNow.AddSeconds(-1);Update-Prompt
    Check ($window.Closed -and $script:choice -eq 10) 'Overdue timeout requests preparation, not a new deferral'
}
Reset-UI;$Overdue=$true;Update-Prompt
Check ($c.Schedule.Visibility -eq 'Collapsed' -and $c.Secondary.Visibility -eq 'Collapsed') 'SYSTEM overdue state wins over a future local deadline'
Reset-UI;Invoke-BiosCaptionAction $window Close
Check ($window.Closed -and $script:choice -eq 11) 'Predeadline caption Close means Defer'
Reset-UI;$Demo=$true;$Overdue=$true;Update-Prompt;Invoke-BiosCaptionAction $window Close
Check ($window.Closed -and $c.CaptionClose.IsEnabled) 'Overdue demo can close without deployment effects'
foreach($phase in @('Preparing','StartingRestart','Restart','Paused')) {
    Reset-UI;$Mode='Live';$script:livePhase=$phase
    Invoke-BiosCaptionAction $window Close
    Check (-not $window.Closed -and $window.WindowState -eq 'Minimized' -and $script:choice -eq 1) "Live $phase caption Close only minimizes"
    $window.WindowState='Normal';Invoke-BiosCaptionAction $window Minimize
    Check (-not $window.Closed -and $window.WindowState -eq 'Minimized' -and -not $script:accepted) "Live $phase minimize leaves the controller running"
}
Reset-UI;$Mode='Live';$script:livePhase='Preparing';& $primaryClick
Check (-not $window.Closed -and $script:choice -eq 1) 'Stale Restart Now click cannot act during preparation'
$script:livePhase='Restart';& $primaryClick
Check ($window.Closed -and $script:choice -eq 12) 'Restart Now returns a request for SYSTEM safety validation'
Reset-UI;Invoke-BiosCaptionAction $window Maximize
Check ($window.WindowState -eq 'Maximized') 'Maximize action retains native window state'
Invoke-BiosCaptionAction $window Maximize
Check ($window.WindowState -eq 'Normal' -and -not $window.Closed) 'Maximize toggles back to restored state'
foreach($scale in @(1,1.5,2)) {
    $bounds=[pscustomobject]@{Width=920;Height=740;MinWidth=560;MinHeight=460}
    $area=[pscustomobject]@{Width=1366/$scale;Height=728/$scale}
    Set-BiosWindowBounds $bounds $area
    Check ($bounds.Width -le $area.Width -and $bounds.Height -le $area.Height -and $bounds.MinWidth -le $bounds.Width -and $bounds.MinHeight -le $bounds.Height) "Window bounds fit simulated work area at $($scale*100)% (not a rendering test)"
}
Check ((Get-BiosBrandIconPath $root @{}) -eq '') 'Legacy branding selects default icon'
Check ((Get-BiosBrandIconPath $root @{IconFile='Assets/company.ico'}) -eq (Join-Path $root 'Assets/company.ico')) 'Local ICO is accepted for packaged branding'
foreach($path in @('../outside.png','Assets/../outside.png','https://example.com/icon.png','\\server\share\icon.ico','Assets/script.ps1')) {
    Reject {Get-BiosBrandIconPath $root @{IconFile=$path}} 'Icon cannot redirect loading outside local assets'
}
foreach($path in @('Builder/Window.xaml','Files/UI/Window.xaml')) {
    [xml]$xml=Get-Content (Join-Path $root $path) -Raw
    Check ($xml.DocumentElement.WindowStyle -eq 'None' -and $xml.DocumentElement.ResizeMode -eq 'CanResize') "$path uses custom caption with resizing"
    $chrome=$xml.SelectSingleNode('//*[local-name()="WindowChrome"]')
    Check ($chrome.CaptionHeight -eq '48' -and [int]$chrome.ResizeBorderThickness -gt 0 -and $chrome.GlassFrameThickness -eq '0') "$path keeps native dragging and resize hit testing"
    foreach($control in @('CaptionMinimize','CaptionMaximize','CaptionClose')) {
        $node=$xml.SelectSingleNode('//*[@*[local-name()="Name"]="'+$control+'"]')
        Check ($node.GetAttribute('WindowChrome.IsHitTestVisibleInChrome','clr-namespace:System.Windows.Shell;assembly=PresentationFramework') -eq 'True' -and $node.GetAttribute('AutomationProperties.Name')) "$path $control is interactive and labeled"
    }
}
Write-Output "PASS: $count v4 scheduling/presentation assertions. Callbacks exercised; native WPF, DPI and accessibility require the Windows pilot."
