# Execute the actual UI polling/rendering/acknowledgement functions with inert
# window/dispatcher/pipe boundaries. No Windows UI or firmware is launched.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Scheduler/Core.ps1"
. "$root/Files/UI/Client.ps1"
$script:count = 0
function Check($Value, [string]$Name) { $script:count++; if (-not $Value) { throw "FAIL: $Name" } }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Files/UI/Show-BiosUI.ps1",[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'UI entry point parses'
foreach ($name in @('Get-UIFailureText','Get-UIInstanceName','Show-UIMessage','Render-Status','Show-NoticeWindow','Report-UIFailure','Confirm-NoticeRendered','Refresh-Status','Receive-UIActivation')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if ($null -eq $node) { throw "Missing real UI function $name" }
    # Only substitute the WPF enum at the mock dispatcher boundary.
    . ([scriptblock]::Create($node.Extent.Text.Replace('[Windows.Threading.DispatcherPriority]::ContextIdle',"'ContextIdle'")))
}
$script:policy=Import-PowerShellDataFile "$root/Files/Scheduler/Policy.psd1"
$brand=Import-PowerShellDataFile "$root/Files/UI/Branding.psd1"
$script:now=[datetimeoffset]'2026-09-16T12:00:00Z'
function Write-UILog([string]$Message) { $script:logs.Add($Message) }
function Test-NoticeDesktop { $script:desktopAvailable }
function Invoke-UIRequest($Request) {
    $script:requests.Add($Request.Action)
    if ($script:offline) { throw 'Inert controller connection failure.' }
    Invoke-ScheduleRequest $script:state $script:policy $Request $script:now
    Get-ScheduleView $script:state $script:policy $script:now
}
function Fresh([bool]$Foreground=$false) {
    $script:state=New-ScheduleState ui-test $script:now
    $script:view=$null; $script:choosingSchedule=$false; $script:quitting=$false
    $script:openRequested=$Foreground; $script:lastFailure=''; $script:noticeQueued=$false
    $script:desktopAvailable=$true; $script:offline=$false; $script:queued=$null
    $script:requests=New-Object 'Collections.Generic.List[string]'
    $script:logs=New-Object 'Collections.Generic.List[string]'
    $script:controls=@{}
    foreach ($name in @('PreparationText','Phase','StatusText','Deadline','Remaining','Scheduled','Day','PickerCard','InstallButton','ScheduleButton','DeferButton','RestartButton','ErrorText')) {
        $script:controls[$name]=[pscustomobject]@{Text='';Visibility='Visible';IsEnabled=$false;ToolTip='';Foreground='';DisplayDateEnd=$null;DisplayDateStart=$null}
    }
    $dispatcher=[pscustomobject]@{}
    $dispatcher|Add-Member ScriptMethod BeginInvoke {param([Action]$Callback,$Priority) $script:queued=$Callback}
    $script:window=[pscustomobject]@{IsVisible=$false;WindowState='Normal';Dispatcher=$dispatcher;Activations=0}
    $script:window|Add-Member ScriptMethod Show {$this.IsVisible=$true}
    $script:window|Add-Member ScriptMethod Activate {$this.Activations++; return $true}
    $script:app=[pscustomobject]@{Stopped=$false}
    $script:app|Add-Member ScriptMethod Shutdown {$this.Stopped=$true}
    $script:activation=[pscustomobject]@{Signaled=$false}
    $script:activation|Add-Member ScriptMethod WaitOne {param($Timeout) $result=$this.Signaled; $this.Signaled=$false; return $result}
}
function Render-QueuedNotice {
    if ($null -ne $script:queued) { $callback=$script:queued; $script:queued=$null; $callback.Invoke() }
}
function Defer-State {
    Invoke-ScheduleRequest $script:state $script:policy @{Action='NoticeShown'} $script:now
    Invoke-ScheduleRequest $script:state $script:policy @{Action='Schedule';Utc=($script:now.AddHours(24).ToString('o'))} $script:now
    Invoke-ScheduleRequest $script:state $script:policy @{Action='Defer'} $script:now
}

Check ((Get-UIInstanceName 7 $true) -ne (Get-UIInstanceName 7 $false)) 'Preview and live UI cannot suppress each other'
Check ((Get-UIInstanceName 7 $false) -ne (Get-UIInstanceName 8 $false)) 'Different interactive sessions have separate instances'
Fresh $true
$script:offline=$true
Refresh-Status
Check ($window.IsVisible -and $controls.Phase.Text -eq 'Update status is unavailable') 'Direct launch displays an unavailable-service explanation before enrollment'
Check (-not $state.DeadlineUtc -and $null -eq $queued -and $requests.Count -eq 1) 'Failed connection never acknowledges delivery or starts the deadline'
Check (-not $controls.InstallButton.IsEnabled -and -not $controls.ScheduleButton.IsEnabled -and -not $controls.DeferButton.IsEnabled) 'No actions enabled without trusted status'
Refresh-Status
Check ($logs.Count -eq 1 -and $logs[0] -match 'controller connection failure') 'Repeated polling failure logs its cause once'
$script:offline=$false
Refresh-Status
Check ($window.IsVisible -and $null -ne $queued -and -not $state.DeadlineUtc) 'Recovery queues acknowledgement only after the window is shown'
Render-QueuedNotice
Check ($state.Phase -eq 'Pending' -and (Read-Utc $state.DeadlineUtc) -eq $now.AddHours(72)) 'Rendered notice starts the single original window'
Check ($controls.InstallButton.IsEnabled -and $controls.ScheduleButton.IsEnabled -and $controls.DeferButton.IsEnabled) 'Authenticated recovery enables all initial choices'
Check ($logs[-1] -eq 'Status connection/rendering recovered.') 'Recovery is recorded'
$deadline=$state.DeadlineUtc
Refresh-Status
Check ($state.DeadlineUtc -eq $deadline -and $null -eq $queued) 'Subsequent polls do not reset deadline or acknowledge repeatedly'

Fresh
Defer-State
$deadline=$state.DeadlineUtc; $selected=$state.ScheduledUtc; $reminder=$state.NextNoticeUtc
Refresh-Status
Check (-not $window.IsVisible -and $null -eq $queued) 'Automatic activation respects a deferred reminder'
$script:openRequested=$true
Refresh-Status
Check ($window.IsVisible -and -not $script:openRequested) 'Manual open overrides reminder visibility once'
Check ($state.DeadlineUtc -eq $deadline -and $state.ScheduledUtc -eq $selected -and $state.NextNoticeUtc -eq $reminder -and $null -eq $queued) 'Opening a deferred notice changes no schedule or reminder state'
$window.IsVisible=$false
Refresh-Status
Check (-not $window.IsVisible) 'Closing a manually opened deferred notice does not reopen on every poll'
$activation.Signaled=$true; $window.WindowState='Minimized'
Receive-UIActivation
Check ($window.IsVisible -and $window.WindowState -eq 'Normal' -and $window.Activations -eq 2) 'Duplicate manual activation opens and restores the existing window'
$window.IsVisible=$false
Receive-UIActivation
Check (-not $window.IsVisible) 'Consumed activation cannot repeatedly steal focus'

Fresh
$script:desktopAvailable=$false
Refresh-Status
Check (-not $window.IsVisible -and -not $state.DeadlineUtc -and $null -eq $queued) 'Locked desktop does not acknowledge first delivery'
$script:desktopAvailable=$true
Refresh-Status
Check ($window.IsVisible -and $null -ne $queued) 'First notice opens after unlock'
$script:desktopAvailable=$false
Render-QueuedNotice
Check (-not $state.DeadlineUtc -and -not $script:noticeQueued) 'Lock between show and render prevents acknowledgement'
$script:desktopAvailable=$true
Refresh-Status
$window.IsVisible=$false
Render-QueuedNotice
Check (-not $state.DeadlineUtc) 'Closing before render does not falsely start the deadline'
Refresh-Status
Render-QueuedNotice
Check ($state.Phase -eq 'Pending') 'Next rendered notice can still acknowledge delivery'

Fresh
Defer-State
$script:offline=$true
Refresh-Status
Check (-not $window.IsVisible -and $logs.Count -eq 1) 'Background connection failure logs without interrupting a deferred user'
$script:openRequested=$true
Refresh-Status
Check ($window.IsVisible -and $controls.ErrorText.Visibility -eq 'Visible') 'Manual reopening exposes that connection problem'
$script:offline=$false
Refresh-Status
$deadline=$state.DeadlineUtc
$script:offline=$true
Refresh-Status
Check (-not $controls.InstallButton.IsEnabled -and $state.DeadlineUtc -eq $deadline -and $controls.StatusText.Text -match 'last received') 'Losing a live connection disables stale actions and labels retained times'

Fresh
$state.Phase='VerifiedComplete'; $state.CompletedNoticeShown=$true
Refresh-Status
Check ($app.Stopped -and -not $window.IsVisible) 'Background completed deployment can exit silently'
Fresh $true
$state.Phase='VerifiedComplete'; $state.CompletedNoticeShown=$true
Refresh-Status
Check ($window.IsVisible -and -not $app.Stopped -and $controls.Phase.Text -eq 'Update verified complete') 'Manual launch can still inspect an already acknowledged completion'

# Verify both real automatic launch paths opt into reminder mode. Capture the
# generated task/process arguments instead of registering tasks or starting PSADT.
$windowsAst=[Management.Automation.Language.Parser]::ParseFile("$root/Files/Scheduler/Windows.ps1",[ref]$tokens,[ref]$errors)
$register=$windowsAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-V2Tasks'},$true)
. ([scriptblock]::Create($register.Extent.Text))
$oldSystemRoot=$env:SystemRoot; $oldProgramFiles=$env:ProgramFiles
try {
    $env:SystemRoot='C:\Windows'; $env:ProgramFiles=$root
    $script:taskArgs=''; $script:userArgs=''; $script:closed=-1
    function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit) @{} }
    function New-ScheduledTaskTrigger {param([switch]$Once,$At,$RepetitionInterval,[switch]$AtStartup,[switch]$AtLogOn) @{} }
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel,$GroupId) @{} }
    function New-ScheduledTaskAction {param($Execute,$Argument) @{Arguments=$Argument} }
    function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) if ($TaskName -like '*UserUI') {$script:taskArgs=$Action.Arguments} }
    Register-V2Tasks 'C:\inert\runtime' 'C:\inert\ui'
    Check ($taskArgs -match '-STA.*-File "C:\\inert\\ui\\Show-BiosUI.ps1" -Background$') 'Periodic user task opts into background mode'
    . "$root/PSADT-Install-Function.ps1"
    $adtSession=@{DirFiles=$root;InstallPhase=''}
    function Start-ADTProcess {[pscustomobject]@{ExitCode=0}}
    function Get-ADTLoggedOnUser {[pscustomobject]@{IsActiveUserSession=$true}}
    function Start-ADTProcessAsUser {param($FilePath,$ArgumentList,$WindowStyle,[switch]$NoWait) $script:userArgs=$ArgumentList}
    function Write-ADTLogEntry {param($Message,$Severity) $script:logs.Add($Message)}
    function Close-ADTSession {param($ExitCode) $script:closed=$ExitCode}
    Install-ADTDeployment
    Check ($userArgs -match '-STA.*-File ".*Show-BiosUI.ps1" -Background$' -and $closed -eq 0) 'PSADT retry respects background reminders and returns enrollment status'
} finally { $env:SystemRoot=$oldSystemRoot; $env:ProgramFiles=$oldProgramFiles }
Write-Output "PASS: $count UI startup/visibility assertions. Window, dispatcher, IPC and launch boundaries mocked; WPF was not rendered."
