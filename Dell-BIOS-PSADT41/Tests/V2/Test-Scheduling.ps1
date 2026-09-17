$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaScheduleTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$count=0
function Check($Value,$Name) {$script:count++; if (-not $Value) {throw "FAIL: $Name"}}
function SameTime($A,$B) {[datetimeoffset]::Parse($A) -eq [datetimeoffset]::Parse($B)}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try {$null=&$Body} catch {$failed=$true};Check $failed $Name}
try {
    foreach ($name in @('Cache','State','Scheduling','Deployment')) {. "$root/Files/Simple/$name.ps1"}
    $cache=Join-Path $temp Cache; $source=Join-Path $temp Source; $files=Join-Path $source Files
    $null=[IO.Directory]::CreateDirectory((Join-Path $cache State));$null=[IO.Directory]::CreateDirectory($source)
    Copy-Item -LiteralPath "$root/Files" -Destination $files -Recurse
    $null=[IO.Directory]::CreateDirectory((Join-Path $source PSAppDeployToolkit))
    foreach ($name in @('Invoke-AppDeployToolkit.exe','Invoke-AppDeployToolkit.ps1','PSAppDeployToolkit/PSAppDeployToolkit.psd1')) {[IO.File]::WriteAllText((Join-Path $source $name),'INERT: never execute')}
    [IO.File]::WriteAllText((Join-Path $files 'BIOS-Password.psd1'),'INERT-TEST-SECRET')
    [IO.File]::WriteAllText((Join-Path $files 'ApprovedBIOS.exe'),'INERT-TEST-BIOS')
    $config=@{TargetVersion='2.7.3';SHA256=('a'*64);FileName='ApprovedBIOS.exe';MinimumFreeSpaceGB=0}
    Write-RuntimeManifest $files
    $script:task=$null; $script:registrations=0; $script:removals=0; $script:failRegister=$false
    $script:logs=New-Object 'Collections.Generic.List[string]'
    $script:protected=New-Object 'Collections.Generic.List[string]'
    function Write-BiosLog {param($Message) $script:logs.Add($Message)}
    function Get-MedelaRoot {$cache}
    function Protect-MedelaDirectory {param($Path,[bool]$UserReadable=$false)
        Assert-MedelaOwnedPath $Path; Check (-not $UserReadable) 'Retained source never receives public-read ACL'
        $script:protected.Add($Path);$null=[IO.Directory]::CreateDirectory($Path)
    }
    function Assert-Payload {param($Path,$Config) Check ((Get-Content -LiteralPath $Path -Raw) -ceq 'INERT-TEST-BIOS') 'Retained BIOS revalidated at signature boundary'}
    function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
        Check ($TaskName -eq 'ManagedDellBIOS-ScheduledInstall' -and $TaskPath -eq '\') 'Only this application install task is queried'
        $script:task
    }
    function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory) [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
    function New-ScheduledTaskTrigger {param([switch]$Once,$At,$RepetitionInterval)
        Check ($Once -and $RepetitionInterval -eq [timespan]::FromMinutes(15)) 'Task starts at selected time with bounded retry frequency'
        [pscustomobject]@{StartBoundary=$At.ToString('o');RepetitionInterval=$RepetitionInterval}
    }
    function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit)
        Check ($StartWhenAvailable -and $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries -and $MultipleInstances -eq 'IgnoreNew' -and $ExecutionTimeLimit -eq [timespan]::Zero) 'Missed runs retry; task settings never kill firmware on battery or timeout'
        [pscustomobject]@{Checked=$true}
    }
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)
        Check ($UserId -eq 'S-1-5-18' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest') 'Privileged task runs as SYSTEM'
        [pscustomobject]@{UserId=$UserId}
    }
    function Register-ScheduledTask {param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$Principal,[switch]$Force,$ErrorAction)
        if ($script:failRegister) {throw 'inert registration failure'}
        $script:registrations++;$script:task=[pscustomobject]@{TaskName=$TaskName;Actions=@($Action);Triggers=@($Trigger);Principal=$Principal}
    }
    function Unregister-ScheduledTask {param($InputObject,[switch]$Confirm,$ErrorAction)
        Check ($InputObject.TaskName -eq 'ManagedDellBIOS-ScheduledInstall' -and -not $Confirm) 'Only verified install task unregistered'
        $script:removals++;$script:task=$null
    }
    function Stop-ScheduledTask {throw 'Test must never stop a task/process'}
    $state=New-SimpleState (Get-PackageId $config) 72
    Start-SimpleNotice $state ([datetimeoffset]::UtcNow); Assert-SimpleState $state $state.PackageId
    $deadline=$state.DeadlineUtc; $path=Join-Path $cache 'State/appointment.json'
    $when=[datetimeoffset]::UtcNow.AddHours(2);$when=$when.AddTicks(-($when.Ticks%[timespan]::TicksPerSecond))
    Save-MedelaInstallSchedule $cache $files $config @{ReminderHours=4} $state $path $when.ToString('o')
    Check ((SameTime (Read-ScheduleFile $path).DeadlineUtc $deadline) -and $state.Phase -eq 'Scheduled') 'Scheduling preserves fixed deadline'
    Check ($state.ScheduledInstallUtc -eq $when.ToString('o') -and $task.Triggers[0].StartBoundary.EndsWith('Z')) 'Persisted schedule and UTC task boundary agree'
    $slot=Get-MedelaScheduledPackagePath $cache
    Check ((Get-Content (Join-Path $slot 'Source/Files/BIOS-Password.psd1') -Raw) -ceq 'INERT-TEST-SECRET') 'Only private complete package retains required credential'
    Check ($task.Actions[0].Execute -eq (Join-Path $slot 'Source/Invoke-AppDeployToolkit.exe') -and $task.Actions[0].WorkingDirectory -eq (Join-Path $slot Source)) 'Task uses retained complete framework, not expiring Intune content'
    Check (-not (($logs -join '')+(Get-Content (Join-Path $slot Ready.json) -Raw)).Contains('INERT-TEST-SECRET')) 'No credential in logs or ready metadata'
    $copies=$protected.Count; $before=$registrations
    Sync-MedelaInstallTask $cache $state
    Check ($registrations -eq $before) 'Matching task is left unchanged'
    $later=$when.AddHours(1)
    Save-MedelaInstallSchedule $cache $files $config @{ReminderHours=4} $state $path $later.ToString('o')
    Check ($registrations -eq ($before+1) -and $protected.Count -eq $copies -and $state.DeadlineUtc -ceq $deadline) 'Reschedule replaces same task without recopies or new window'
    $script:task=$null;Sync-MedelaInstallTask $cache $state
    Check ($task.Triggers[0].StartBoundary -eq $later.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) 'Missing task repaired from persisted original schedule'
    $script:failRegister=$true
    Reject {Save-MedelaInstallSchedule $cache $files $config @{ReminderHours=4} $state $path $later.AddHours(1).ToString('o')} 'Registration failure never reports schedule success'
    Check ((SameTime (Read-ScheduleFile $path).ScheduledInstallUtc $later.AddHours(1).ToString('o')) -and (SameTime (Read-ScheduleFile $path).DeadlineUtc $deadline)) 'Failed registration preserves intent and original deadline for repair'
    $script:failRegister=$false;Sync-MedelaInstallTask $cache (Read-ScheduleFile $path)
    Check ([datetimeoffset]::Parse($task.Triggers[0].StartBoundary) -eq $later.AddHours(1)) 'Retry reconciles stale task against saved intent'
    $now=[datetimeoffset]::UtcNow
    foreach ($value in @('arbitrary command', $now.AddMinutes(-1).ToString('o'),$now.AddDays(4).ToString('o'),'2026-09-19T12:00:00+02:00')) {Reject {Assert-MedelaScheduleChoice $value $state $now} 'SYSTEM rejects malformed, past or out-of-window times'}
    Reject {Assert-MedelaScheduleChoice $later.ToString('o') $state ([datetimeoffset]::Parse($deadline).AddSeconds(1))} 'Overdue state cannot acquire another schedule'
    $task.Actions[0].Arguments='unexpected'
    Reject {Remove-MedelaInstallTask $cache} 'Unexpected task is not changed'
    $task.Actions[0].Arguments='-DeploymentType Install -DeployMode Silent'
    Reject {Clear-MedelaScheduledPackage $cache 'another-package'} 'Cleanup preserves a different package'
    Clear-MedelaScheduledPackage $cache $state.PackageId (Join-Path $slot 'Source/Files')
    Check ($null -eq $task -and (Test-Path $slot)) 'Current-BIOS task retires future launches without deleting its own live framework'
    Clear-MedelaScheduledPackage $cache $state.PackageId $files
    Check (-not (Test-Path $slot) -and (SameTime (Read-ScheduleFile $path).DeadlineUtc $deadline)) 'Verified cleanup removes snapshot but preserves original state'

    # Interrupted copies never publish Ready or execute a partial framework.
    $script:failCopy=$true
    function Copy-Item {param([Parameter(ValueFromPipeline=$true)]$InputObject,$Destination,[switch]$Recurse,[switch]$Force)
        process {throw 'inert copy failure'}
    }
    try {Reject {New-MedelaScheduledPackage $cache $files $config} 'Interrupted copy fails before task publication'} finally {Remove-Item Function:Copy-Item}
    Check (-not (Test-Path $slot) -and $null -eq $task) 'Incomplete snapshot removed and no task installed'
    $null=[IO.Directory]::CreateDirectory((Join-Path $slot Source))
    $sentinel=Join-Path $slot Source/sentinel;[IO.File]::WriteAllText($sentinel,'keep')
    Reject {New-MedelaScheduledPackage $cache (Join-Path $slot Source/Files) $config} 'Lost metadata cannot delete or recursively copy current retained source'
    Check (Test-Path $sentinel) 'Overlapping source remains intact for review'

    # Real UI callback and PSADT response adapter; no WPF/firmware execution.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Files/UI/Show-BiosUI.ps1",[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'UI parses'
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-InstallSchedule'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $Overdue=$false;$deadline=[datetimeoffset]::UtcNow.AddHours(72)
    $selected=[datetime]::Now.AddHours(2)
    $c=@{InstallDate=@{SelectedDate=$selected.Date};InstallTime=@{Text=$selected.ToString('HH:mm')};ScheduleError=@{Text=''}}
    $window=[pscustomobject]@{Closed=$false};$window|Add-Member ScriptMethod Close {$this.Closed=$true}
    $script:choice=1;$script:accepted=$false;$script:selectedInstallUtc=''
    Confirm-InstallSchedule
    Check ($script:choice -eq 15 -and $window.Closed -and [datetimeoffset]::Parse($script:selectedInstallUtc).LocalDateTime.ToString('HH:mm') -eq $selected.ToString('HH:mm')) 'Date/time picker returns selected local instant as UTC'
    foreach ($case in @(@{Date=$selected.Date;Time='25:00'},@{Date=$selected.AddDays(4).Date;Time='12:00'},@{Date=$selected.AddDays(-1).Date;Time='12:00'})) {
        $c.InstallDate.SelectedDate=$case.Date;$c.InstallTime.Text=$case.Time;$c.ScheduleError.Text='';$window.Closed=$false;$script:choice=1
        Confirm-InstallSchedule
        Check ($script:choice -ne 15 -and -not $window.Closed -and $c.ScheduleError.Text) 'Invalid/past/out-of-window picker selection stays open with explanation'
    }
    $script:updateCalled=$false;function Update-Prompt {$script:updateCalled=$true}
    $Overdue=$true;Confirm-InstallSchedule
    Check ($script:updateCalled -and -not $window.Closed) 'Overdue click cannot commit a schedule'
    function Start-ADTProcessAsUser {param($FilePath,$ArgumentList,[switch]$CreateNoWindow,[switch]$NoStreamLogging,[switch]$PassThru,$IgnoreExitCodes) $script:reply}
    $script:reply=[pscustomobject]@{ExitCode=15;StdOut=('MEDELA_INSTALL_UTC='+$when.ToString('o')+"`r`n");StdErr=''}
    $answer=Invoke-MedelaPrompt $cache Install $state.DeadlineUtc 10
    Check ($answer.ExitCode -eq 15 -and $answer.ScheduledInstallUtc -ceq $when.ToString('o')) 'PSADT StdOut response reaches SYSTEM validator without command evaluation'
    foreach ($value in @('MEDELA_INSTALL_UTC=bad',('MEDELA_INSTALL_UTC='+$when.ToString('o')+"`nMEDELA_INSTALL_UTC="+$later.ToString('o')))) {
        $script:reply.StdOut=$value;Reject {Invoke-MedelaPrompt $cache Install $state.DeadlineUtc 10} 'Malformed or duplicate schedule reply rejected'
    }
    $script:reply.StdOut='MEDELA_INSTALL_UTC='+$when.ToString('o')
    Reject {Invoke-MedelaPrompt $cache Info $state.DeadlineUtc 1} 'Other prompt modes cannot submit schedules'
    Write-Output "PASS: $count scheduling/package/task/UI assertions. Real file IO/state; Windows task, trust and ACL boundaries mocked. No EXE run."
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
