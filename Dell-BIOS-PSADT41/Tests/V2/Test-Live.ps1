# Real progress/countdown orchestration and UI callbacks, inert Windows edges.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaLiveTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData;$env:ProgramData=$temp
$count=0
function Check($Value,$Name) {$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try{&$Body}catch{$failed=$true};Check $failed $Name}
try {
    . "$root/Files/Common.ps1"
    foreach($name in @('Cache','State','Safety','Live','Deployment')){. "$root/Files/Simple/$name.ps1"}
    $source=New-Object 'Threading.Tasks.TaskCompletionSource[object]'
    Check ($null -eq (Get-MedelaProcessResult ([pscustomobject]@{Task=$source.Task}))) 'PSADT 4.1 LaunchInfo with incomplete Task is still running'
    $source.SetResult([pscustomobject]@{ExitCode=3010})
    Check ((Get-MedelaProcessResult ([pscustomobject]@{Task=$source.Task})).ExitCode -eq 3010) 'PSADT asynchronous result is awaited without losing exit code'
    Check ((Get-MedelaProcessResult ([pscustomobject]@{ExitCode=0})).ExitCode -eq 0) 'Fast-exit PSADT ProcessResult is supported'
    Reject {Get-MedelaProcessResult ([pscustomobject]@{Unexpected=1})} 'Unsupported process handle fails closed'
    Reject {Get-MedelaProcessResult ([pscustomobject]@{ExitCode=$null})} 'Unknown process exit code is never coerced to success'
    $fault=New-Object 'Threading.Tasks.TaskCompletionSource[object]';$fault.SetException((New-Object Exception('inert launch failure')))
    Reject {Get-MedelaProcessResult ([pscustomobject]@{Task=$fault.Task})} 'Asynchronous launch failure cannot appear successful'

    $config=@{MinimumBatteryPercent=51;RequireBattery=$true}
    $policy=Import-PowerShellDataFile "$root/Files/Simple/Policy.psd1"
    $script:frames=New-Object 'Collections.Generic.List[object]'
    function Get-MedelaClock { @{Utc=$script:epoch.AddMilliseconds($script:elapsed+$script:clockShift);Tick=(100000+$script:elapsed);Awake=(99000+$script:elapsed-$script:slept)} }
    function Get-MedelaSessionIdentity {$script:session}
    function Get-State {[pscustomobject]@{Status='Staged';SuspendedByUs='1'}}
    function Get-BootId {'same-boot'}
    function Assert-Power {param($Config) if(-not $script:ac -or $script:battery -lt $Config.MinimumBatteryPercent){throw 'Unsafe AC or battery charge.'}}
    function Assert-RestartSafe {param($Config,$Transaction,$Boot) $script:guards++;Assert-Power $Config;if($script:badRecovery){throw 'Protection recovery unresolved'}}
    function Write-BiosLog {param($Message) $script:logs.Add($Message)}
    function Start-ADTProcessAsUser {
        param($FilePath,$ArgumentList,[switch]$CreateNoWindow,[switch]$NoStreamLogging,[switch]$NoWait,[switch]$PassThru,$IgnoreExitCodes)
        $script:uiArguments=$ArgumentList
        $script:uiSource=New-Object 'Threading.Tasks.TaskCompletionSource[object]'
        if($script:uiStartupFail){return [pscustomobject]@{ExitCode=1}}
        [pscustomobject]@{Task=$script:uiSource.Task}
    }
    function Invoke-MedelaInstaller {
        param($Root,$Files,[switch]$NoWait)
        Check $NoWait 'Staging starts the worker without blocking status heartbeat'
        $script:workerSource=New-Object 'Threading.Tasks.TaskCompletionSource[object]'
        $script:workerLaunches++
        [pscustomobject]@{Task=$script:workerSource.Task}
    }
    function Request-MedelaWindowsRestart {
        if($script:restartFails){throw 'Inert Windows restart refusal'}
        $script:restartAt=$script:elapsed;$script:restarts++
    }
    function Start-Sleep {
        param([int]$Milliseconds,[int]$Seconds)
        $script:elapsed+=($Milliseconds+$Seconds*1000)
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $script:cache 'UI') -Filter Status.json -Recurse) {
            $script:frames.Add((Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json))
        }
        if($script:workerSource -and -not $script:workerSource.Task.IsCompleted -and $script:elapsed -ge 4000){$script:workerSource.SetResult([pscustomobject]@{ExitCode=$script:workerCode})}
        if($script:onWait){&$script:onWait}
    }
    function Fresh {
        $script:cache=Join-Path $temp ([guid]::NewGuid().ToString('N'))
        foreach($n in @('UI','State','Recovery')){$null=[IO.Directory]::CreateDirectory((Join-Path $script:cache $n))}
        $script:WorkDir=Join-Path $script:cache Recovery
        $script:path=Join-Path $script:cache 'State/fixture.json'
        $script:state=New-SimpleState 'test' 72;Start-SimpleNotice $script:state ([datetimeoffset]'2026-09-01T00:00:00Z')
        Save-ScheduleFile $script:state $script:path
        [IO.File]::WriteAllText((Join-Path $script:cache 'Recovery/keep.ps1'),'inert retained recovery')
        $script:epoch=[datetimeoffset]::UtcNow;$script:elapsed=0;$script:slept=0;$script:clockShift=0
        $script:session='DOMAIN\user|1';$script:ac=$true;$script:battery=51;$script:badRecovery=$false
        $script:restarts=0;$script:restartAt=-1;$script:restartFails=$false;$script:guards=0
        $script:uiSource=$null;$script:uiStartupFail=$false;$script:workerSource=$null;$script:workerLaunches=0;$script:workerCode=3010
        $script:frames.Clear();$script:onWait=$null;$script:logs=New-Object 'Collections.Generic.List[string]'
    }
    Fresh
    Check ((Invoke-MedelaStaging $cache 'inert Files') -eq 3010) 'Progress monitor returns the real completed staging code'
    Check ($workerSource.Task.IsCompleted -and @($frames | Where-Object Phase -eq Preparing).Count -ge 1) 'Preparation status is published while the worker runs'
    Check (@(Get-ChildItem (Join-Path $cache UI) -Filter Status.json -Recurse).Count -eq 0) 'Progress-only status is cleaned after staging'
    Fresh;$script:onWait={if(-not $script:uiSource.Task.IsCompleted){$script:uiSource.SetResult([pscustomobject]@{ExitCode=14})}}
    Check ((Invoke-MedelaStaging $cache 'inert Files') -eq 3010 -and $workerSource.Task.IsCompleted) 'Lost progress UI never terminates or abandons the running firmware worker'
    Fresh;$script:uiStartupFail=$true
    Reject {Invoke-MedelaStaging $cache 'inert Files'} 'UI launch failure blocks new firmware preparation'
    Check ($workerLaunches -eq 0) 'Failed progress startup never calls the installer'
    Fresh;$script:workerCode=1618
    Check ((Invoke-MedelaStaging $cache 'inert Files') -eq 1618) 'Installer safety retry is not turned into staged success'
    Fresh;$script:onWait={if(-not $script:workerSource.Task.IsCompleted){$script:workerSource.SetException((New-Object Exception('inert process-monitor fault')))}}
    Reject {Invoke-MedelaStaging $cache 'inert Files'} 'A faulted worker result never reports staged success'
    Check (@(Get-ChildItem (Join-Path $cache UI) -Filter Status.json -Recurse).Count -eq 0) 'Worker result failure still retires temporary UI status'

    Fresh;$originalDeadline=$state.DeadlineUtc
    Check ((Invoke-MedelaRestartCountdown $cache $config $policy $state $path) -eq 1618) 'Automatic restart remains undetected until actual firmware verification'
    Check ($restarts -eq 1 -and $restartAt -eq 3600000 -and $guards -ge 2) 'SYSTEM requests restart at one hour after repeated power and final transaction checks'
    Check ((@($frames | Where-Object Phase -eq Restart | Select-Object -ExpandProperty Reminder -Unique) -join ',') -eq '0,1,2,3') 'Reminder sequence corresponds to initial display and 15/30/45 minutes'
    Check ($state.RestartDisposition -eq 'Requested' -and -not $state.RestartDeadlineUtc -and $state.DeadlineUtc -eq $originalDeadline) 'Countdown retires without resetting the original deferral deadline'
    Check (@(Get-ChildItem (Join-Path $cache UI) -Filter Status.json -Recurse).Count -eq 0 -and (Test-Path (Join-Path $cache 'Recovery/keep.ps1'))) 'Transient prompt data is removed and recovery files survive'
    Fresh;$script:onWait={if(-not $script:uiSource.Task.IsCompleted){$script:uiSource.SetResult([pscustomobject]@{ExitCode=12})}}
    $null=Invoke-MedelaRestartCountdown $cache $config $policy $state $path
    Check ($restarts -eq 1 -and $restartAt -lt 3600000) 'Restart Now uses the same guarded SYSTEM path before the deadline'
    foreach($scenario in @('AC','Battery','Sleep','Gap','ForwardClock','BackwardClock','Session','UI','RestartRefused')) {
        Fresh
        $script:caseName=$scenario
        $script:onWait={
            switch($script:caseName){
                AC {$script:ac=$false}
                Battery {$script:battery=50}
                Sleep {$script:elapsed+=10000;$script:slept+=10000}
                Gap {$script:elapsed+=40000}
                ForwardClock {$script:clockShift=3600000}
                BackwardClock {$script:clockShift=-3600000}
                Session {$script:session='DOMAIN\other|2'}
                UI {if(-not $script:uiSource.Task.IsCompleted){$script:uiSource.SetResult([pscustomobject]@{ExitCode=1})}}
                RestartRefused {$script:restartFails=$true;if(-not $script:uiSource.Task.IsCompleted){$script:uiSource.SetResult([pscustomobject]@{ExitCode=12})}}
            }
        }
        $null=Invoke-MedelaRestartCountdown $cache $config $policy $state $path
        Check ($restarts -eq 0 -and $state.RestartDisposition -eq 'Cancelled' -and -not $state.RestartDeadlineUtc) ("$scenario cancels automatic restart instead of bypassing a guard")
        Check (@(Get-ChildItem (Join-Path $cache UI) -Filter Status.json -Recurse).Count -eq 0 -and (Test-Path (Join-Path $cache 'Recovery/keep.ps1'))) ("$scenario cleans only temporary UI data")
    }
    Fresh;$script:battery=50
    $null=Invoke-MedelaRestartCountdown $cache $config $policy $state $path
    Check ($restarts -eq 0 -and $null -eq $uiSource) 'Unsafe initial power does not launch a mandatory restart prompt'
    Fresh;$script:state.RestartDeadlineUtc=$epoch.AddHours(-2).ToString('o');$script:state.RestartDisposition='Active'
    $null=Invoke-MedelaRestartCountdown $cache $config $policy $state $path
    Check ($restarts -eq 1 -and $restartAt -eq 3600000) 'Interrupted owner state gets a fresh full warning, never an immediate catch-up restart'
    Fresh;$stale=Join-Path $cache ('UI/Live/'+('a'*32));$null=[IO.Directory]::CreateDirectory($stale)
    [IO.File]::WriteAllText((Join-Path $stale Status.json),'inert orphan after crash')
    Remove-MedelaStaleUI $cache
    Check (-not (Test-Path $stale) -and (Test-Path $path) -and (Test-Path (Join-Path $cache 'Recovery/keep.ps1'))) 'Next package attempt cleans crash leftovers without removing state/recovery'

    # Actual WPF callbacks with inert controls. Rendering/sound/DPI are Windows
    # pilot checks; the decision to minimize/remind/close is exercised here.
    if (-not ('Windows.Automation.AutomationProperties' -as [type])) {
        Add-Type 'namespace Windows.Automation { public static class AutomationProperties { public static void SetName(object o,string n) {} } }'
    }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Files/UI/Show-BiosUI.ps1",[ref]$tokens,[ref]$errors)
    foreach($name in @('Close-LivePrompt','Update-LivePrompt')){
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $c=@{};foreach($n in @('Heading','Progress','Primary','Secondary','Deadline','Remaining','StatusText')){$c[$n]=@{Text='';Content='';Visibility='Collapsed'}}
    $window=[pscustomobject]@{Closed=$false;WindowState='Normal'};$window|Add-Member ScriptMethod Close {$this.Closed=$true}
    $script:reminders=0;function Show-RestartReminder {$script:reminders++;$window.WindowState='Normal'}
    $brand=@{ReadyMessage='Keep AC connected.'};$script:liveSession='';$script:livePhase='';$script:lastReminder=0
    Fresh;$context=@{Id=('b'*32);BootId='same-boot';Path=(Join-Path $cache 'UI/fixture.json')};$StatusPath=$context.Path
    Write-MedelaLiveStatus $context Preparing;Update-LivePrompt
    Check ($c.Progress.Visibility -eq 'Visible' -and $c.Primary.Visibility -eq 'Collapsed' -and $c.Heading.Text -eq 'Preparing BIOS update') 'Preparing UI shows animated activity without fake percentage or restart action'
    Write-MedelaLiveStatus $context Restart -RemainingSeconds 3600 -DeadlineUtc ([datetimeoffset]::UtcNow.AddHours(1).ToString('o'));Update-LivePrompt
    Check ($c.Primary.Content -eq '_Restart Now' -and $c.Secondary.Content -eq '_Minimize' -and $c.Remaining.Text -match '^Automatic restart in (60:00|59:5[0-9])') 'Restart UI shows countdown, Restart Now and Minimize'
    $window.WindowState='Minimized';Write-MedelaLiveStatus $context Restart -RemainingSeconds 2700 -DeadlineUtc ([datetimeoffset]::UtcNow.AddMinutes(45).ToString('o')) -Reminder 1;Update-LivePrompt;Update-LivePrompt
    Check ($reminders -eq 1 -and $window.WindowState -eq 'Normal') 'A reminder restores/recenters/sounds once per interval, not every tick'
    $closing=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Closing'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $Mode='Live';$script:accepted=$false;$e=@{Cancel=$false}; &$closing $window $e
    Check ($e.Cancel -and $window.WindowState -eq 'Minimized') 'Closing a live progress/restart window minimizes it and cannot cancel the countdown'
    $secondary=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click' -and $n.Expression.Extent.Text -eq '$c.Secondary'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $script:choice=1;$window.WindowState='Normal';&$secondary
    Check ($window.WindowState -eq 'Minimized' -and $script:choice -eq 1) 'Minimize button does not return an exit code or postpone the deadline'
    $primary=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click' -and $n.Expression.Extent.Text -eq '$c.Primary'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $script:livePhase='Preparing';$script:choice=1;$window.Closed=$false;&$primary
    Check ($script:choice -eq 1 -and -not $window.Closed) 'Preparation never exposes a premature restart request'
    $script:livePhase='Restart';&$primary
    Check ($script:choice -eq 12 -and $window.Closed) 'Restart Now sends only the guarded request exit code'
    $staleData=Read-ScheduleFile $StatusPath;$staleData.HeartbeatUtc=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o');Save-ScheduleFile $staleData $StatusPath
    Update-LivePrompt
    Check ($window.Closed -and $script:choice -eq 14) 'Expired SYSTEM heartbeat closes the UI without issuing a restart request'
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-Prompt'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $Mode='Restart';$Demo=$true;$RestartMinutes=60;$RestartReminderMinutes=15;$script:lastReminder=0
    $script:demoRestartAt=[datetimeoffset]::UtcNow.AddMinutes(44);$before=$script:reminders;$window.Closed=$false;Update-Prompt
    Check ($script:reminders -eq ($before+1) -and $c.Remaining.Text -like '*No restart will occur*') 'Preview demonstrates countdown and reminder without privileged operations'
    $script:demoRestartAt=[datetimeoffset]::UtcNow.AddSeconds(-1);$script:choice=1;Update-Prompt
    Check ($script:choice -eq 13 -and $window.Closed) 'Expired preview closes without sending Restart Now'
    # Actual verifier cleanup body: do not execute its registry/firmware entry point.
    $verifyAst=[Management.Automation.Language.Parser]::ParseFile("$root/Files/Verify-AfterReboot.ps1",[ref]$tokens,[ref]$errors)
    $fn=$verifyAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-MedelaVerifiedUI'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    Fresh;$oldFolder=Join-Path $cache ('UI/Live/'+('c'*32));$newFolder=Join-Path $cache ('UI/Live/'+('d'*32))
    $null=[IO.Directory]::CreateDirectory($oldFolder);$null=[IO.Directory]::CreateDirectory($newFolder)
    Save-ScheduleFile @{Schema=1;Session=('c'*32);BootId='previous-boot'} (Join-Path $oldFolder Status.json)
    Save-ScheduleFile @{Schema=1;Session=('d'*32);BootId='current-boot'} (Join-Path $newFolder Status.json)
    Remove-MedelaVerifiedUI (Join-Path $cache Recovery) 'previous-boot' 'current-boot'
    Check (-not (Test-Path $oldFolder) -and (Test-Path $newFolder) -and (Test-Path $path)) 'Post-boot verifier removes only its old-boot UI status, preserving current UI and state'
    Write-Output "PASS: $count live progress/countdown/UI assertions. Real file IO and Task results; hardware/session/restart/WPF boundaries mocked."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
