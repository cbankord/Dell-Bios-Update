# Pure/mocked checks; no privileged operations, firmware launch or restart.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Scheduler/Core.ps1"
. "$root/Files/Scheduler/Transport.ps1"
. "$root/Files/UI/Client.ps1"
$script:count=0
function Assert($Value,[string]$Name) { $script:count++; if (-not $Value) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Action,[string]$Name) { $caught=$false; try { &$Action } catch { $caught=$true }; Assert $caught $Name }
Get-ChildItem $root -Recurse -File | Where-Object Extension -in @('.ps1','.psd1') | ForEach-Object {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ("Parse " + $_.Name + ': ' + (($errors | ForEach-Object { $_.Message }) -join ', '))
}
[xml]$xaml = Get-Content "$root/Files/UI/Window.xaml" -Raw
Assert ($null -ne $xaml.DocumentElement) 'Well-formed XAML'
$p=Import-PowerShellDataFile "$root/Files/Scheduler/Policy.psd1"
Assert-SchedulerPolicy $p
$t=[datetimeoffset]'2026-09-16T12:00:00Z'
# New packages can choose a window; it becomes immutable persisted state.
$custom=$p.Clone(); $custom.WindowHours=48
Assert-SchedulerPolicy $custom
$new=New-ScheduleState custom $t $custom.WindowHours
Invoke-ScheduleRequest $new $custom @{Action='NoticeShown'} $t
Assert ((Read-Utc $new.DeadlineUtc) -eq $t.AddHours(48)) 'Configured 48-hour window starts on delivery'
$custom.WindowHours=168
Invoke-ScheduleRequest $new $custom @{Action='NoticeShown'} $t.AddHours(1)
Assert ((Read-Utc $new.DeadlineUtc) -eq $t.AddHours(48)) 'Changed policy cannot extend enrolled deadline'
$unnoticed=New-ScheduleState custom $t 24
Invoke-ScheduleRequest $unnoticed $custom @{Action='NoticeShown'} $t.AddHours(10)
Assert ((Read-Utc $unnoticed.DeadlineUtc) -eq $t.AddHours(34)) 'Window persisted before first notice also remains fixed'
$old=New-ScheduleState legacy $t
$old.Remove('WindowHours')
Assert-ScheduleState $old legacy
Invoke-ScheduleRequest $old $custom @{Action='NoticeShown'} $t
Assert ($old.WindowHours -eq 72 -and (Read-Utc $old.DeadlineUtc) -eq $t.AddHours(72)) 'Earlier schema-2 state migrates to original 72 hours'
$old.Remove('WindowHours'); Assert-ScheduleState $old legacy
Assert ((Read-Utc $old.DeadlineUtc) -eq $t.AddHours(72)) 'Already delivered legacy deadline remains unchanged'
$v=Get-ScheduleView $new $custom $t.AddHours(2)
Assert ($v.WindowHours -eq 48 -and $v.PreparationLeadMinutes -eq $p.PreparationLeadMinutes) 'UI receives actual persisted window and preparation lead'
Reject { Invoke-ScheduleRequest $new $custom @{Action='Defer'} $t.AddHours(49) } 'Custom deadline also stops deferral'
$bad=$p.Clone(); $bad.WindowHours=0
Reject { Assert-SchedulerPolicy $bad } 'Zero-hour policy rejected'
$bad.WindowHours=169; Reject { Assert-SchedulerPolicy $bad } 'Unbounded policy rejected'
$bad.WindowHours=48.5; Reject { Assert-SchedulerPolicy $bad } 'Fractional policy rejected'
$s=New-ScheduleState test $t
Assert-ScheduleState $s test
Assert (-not $s.DeadlineUtc) 'No clock before delivered notice'
Invoke-ScheduleRequest $s $p @{Action='Status'} $t.AddHours(48)
Assert (-not $s.DeadlineUtc) 'Offline/enrollment polls do not start window'
Invoke-ScheduleRequest $s $p @{Action='NoticeShown'} $t.AddHours(48)
$first=$s.FirstNotifiedUtc; $deadline=$s.DeadlineUtc
Assert ((Read-Utc $deadline) -eq $t.AddHours(120)) 'Exactly 72 hours from delivery'
1..100 | ForEach-Object { Invoke-ScheduleRequest $s $p @{Action='Defer'} $t.AddHours(49) }
Assert ($s.DeadlineUtc -eq $deadline) 'Unlimited deferrals never extend deadline'
Invoke-ScheduleRequest $s $p @{Action='NoticeShown'} $t.AddHours(50)
Assert ($s.FirstNotifiedUtc -eq $first -and $s.DeadlineUtc -eq $deadline) 'Repeated delivery never resets clock'
Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(80))} $t.AddHours(50)
Assert ($s.Phase -eq 'Scheduled') 'Schedule accepted inside window'
Invoke-ScheduleRequest $s $p @{Action='Defer'} $t.AddHours(51)
Assert ((Read-Utc $s.ScheduledUtc) -eq $t.AddHours(80)) 'Closing/deferring does not cancel selection'
Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(110))} $t.AddHours(60)
Assert ($s.DeadlineUtc -eq $deadline) 'Reschedule preserves deadline'
Reject { Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(121))} $t.AddHours(60) } 'Reject date beyond deadline'
Reject { Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(59))} $t.AddHours(60) } 'Reject date in past'
Reject { Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc='2026-09-18T10:00:00'} $t.AddHours(60) } 'Reject ambiguous unzoned wire time'
Reject { Invoke-ScheduleRequest $s $p @{Action='Defer';Command='anything'} $t.AddHours(60) } 'Reject extra request fields'
Reject { Invoke-ScheduleRequest $s $p @{Action='RunCommand'} $t.AddHours(60) } 'Reject arbitrary command'
Reject { Invoke-ScheduleRequest $s $p @{Action='Defer'} $t.AddHours(120) } 'Deadline blocks deferral'
Reject { Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(121))} $t.AddHours(120) } 'Deadline blocks late scheduling'
$v=Get-ScheduleView $s $p $t.AddHours(121)
Assert ($v.Overdue -and -not $v.CanSchedule) 'Overdue UI disables scheduling and defer'
$copy=@{}; (ConvertFrom-SchedulerJson ($s|ConvertTo-Json)).PSObject.Properties|ForEach-Object{$copy[$_.Name]=$_.Value}
Assert-ScheduleState $copy test
Assert ($copy.DeadlineUtc -eq $deadline) 'Persistence roundtrip retains deadline'
$copy.DeadlineUtc=Get-UtcText $t.AddHours(122)
Reject { Assert-ScheduleState $copy test } 'Reject extended persisted deadline'
$copy=$s.Clone(); $copy.Remove('Phase')
Reject { Assert-ScheduleState $copy test } 'Corrupt state fails closed'
Reject { Assert-ScheduleState $s another } 'Reject different package'
$s.Phase='Preparing'
Reject { Invoke-ScheduleRequest $s $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(100))} $t.AddHours(61) } 'Preparation locks rescheduling'
$s.Phase='RestartRequired'
Invoke-ScheduleRequest $s $p @{Action='RestartNow'} $t.AddHours(61)
Assert ((Read-Utc $s.RestartUtc) -eq $t.AddHours(61)) 'Explicit restart-now records intent'
# Common DST edge cases: Windows and IANA IDs are both supported where available.
$zone = try { [TimeZoneInfo]::FindSystemTimeZoneById('America/Chicago') } catch { [TimeZoneInfo]::FindSystemTimeZoneById('Central Standard Time') }
Reject { Convert-LocalSelectionToUtc ([datetime]'2026-03-08') 2 30 $zone } 'Reject nonexistent spring-forward time'
Reject { Convert-LocalSelectionToUtc ([datetime]'2026-11-01') 1 30 $zone } 'Reject ambiguous fall-back time'
Assert (([datetimeoffset](Convert-LocalSelectionToUtc ([datetime]'2026-09-16') 10 30 $zone)) -eq [datetimeoffset]'2026-09-16T15:30:00Z') 'Local date maps to correct UTC'

# Exercise the real engine with mocked Windows boundaries.
. "$root/Files/Scheduler/Engine.ps1"
$script:policy=$p
$script:config=@{TargetVersion='2.1.1';SHA256=('a'*64);FileName='inert.exe'}
$script:RuntimeDir='unused'
$script:worker=$null; $script:lastTick=$t
$script:txn=$null; $script:busy=$false; $script:power=$true; $script:restarts=0; $script:launches=0; $script:boot='one'; $script:actual='1.0.0'; $script:healthy=$true
function Convert-BiosVersion($x) { [version]$x }
function Get-BootId { $script:boot }
function Get-TransactionSnapshot { @{Busy=$script:busy;Transaction=$script:txn} }
function Get-CimInstance { [pscustomobject]@{SMBIOSBIOSVersion=$script:actual} }
function Assert-Model { }
function Assert-Power { if (-not $script:power) { throw 'Retry: AC power is disconnected.' } }
function Assert-NoPendingReboot { }
function Assert-Payload { }
function Assert-PostBootHealth { if (-not $script:healthy) { throw 'BitLocker recovery pending.' } }
function Assert-RestartSafe { Assert-Power }
function Save-EngineState { }
function Write-SchedulerLog { }
function Invoke-ManagedRestart { $script:restarts++ }
function Start-FirmwareWorker {
    $script:launches++
    $process=[pscustomobject]@{HasExited=$false;ExitCode=3010;Id=123}
    $process|Add-Member ScriptMethod Dispose {}
    $process
}
function Fresh {
    $script:schedule=New-ScheduleState test $t
    Invoke-ScheduleRequest $script:schedule $p @{Action='NoticeShown'} $t
    $script:worker=$null; $script:txn=$null; $script:busy=$false; $script:boot='one'; $script:power=$true; $script:actual='1.0.0'; $script:lastTick=$t
}
Fresh
Invoke-SchedulerTick $t.AddHours(71)
Assert ($script:launches -eq 0) 'No selection does not stage before deadline'
Invoke-SchedulerTick $t.AddHours(72)
Assert ($script:launches -eq 0 -and $script:schedule.NextAttemptUtc) 'Missed deadline provides warning'
$script:power=$false
Invoke-SchedulerTick $t.AddHours(72).AddMinutes(16)
Assert ($script:launches -eq 0 -and $script:schedule.Phase -eq 'Blocked') 'Overdue power failure never launches'
Assert ($script:schedule.DeadlineUtc -eq (Get-UtcText $t.AddHours(72))) 'Safety hold retains original deadline'
$script:power=$true
Invoke-SchedulerTick $t.AddHours(72).AddMinutes(22)
Assert ($script:launches -eq 1 -and $script:schedule.Phase -eq 'Preparing') 'Restored power permits guarded preparation'
$script:worker.HasExited=$true
$script:txn=[pscustomobject]@{Status='Staged';TargetVersion='2.1.1';PayloadHash=('a'*64);BootId='one';StagedUtc=(Get-UtcText $t.AddHours(72).AddMinutes(23))}
Invoke-SchedulerTick $t.AddHours(72).AddMinutes(24)
Assert ($script:schedule.Phase -eq 'RestartRequired' -and $script:restarts -eq 0) 'Dell staging starts final warning'
$script:lastTick=$t.AddHours(72).AddMinutes(38)
$script:power=$false
Invoke-SchedulerTick $t.AddHours(72).AddMinutes(40)
Assert ($script:restarts -eq 0 -and $script:schedule.LastError) 'Power loss blocks managed restart'
$script:power=$true; $script:lastTick=$t.AddHours(72).AddMinutes(45)
Invoke-SchedulerTick $t.AddHours(72).AddMinutes(46)
Assert ((Read-Utc $script:schedule.RestartUtc) -eq $t.AddHours(73).AddMinutes(1)) 'Power recovery grants fresh warning'
$script:lastTick=$t.AddHours(73)
Invoke-SchedulerTick $t.AddHours(73).AddMinutes(1)
Assert ($script:restarts -eq 1) 'Restart happens only after renewed safety check and warning'
$script:boot='two'
Invoke-SchedulerTick $t.AddHours(73).AddMinutes(2)
Assert ($script:schedule.Phase -eq 'Verifying') 'New boot waits for firmware verification'
$script:txn.Status='FailedAfterReboot'
Invoke-SchedulerTick $t.AddHours(73).AddMinutes(8)
Assert ($script:schedule.Phase -eq 'NeedsAttention' -and $script:launches -eq 1) 'Failed flash cannot be reflashed automatically'
Fresh
$script:txn=[pscustomobject]@{Status='Verified';TargetVersion='2.1.1';PayloadHash=('a'*64)}
$script:healthy=$false
Reject { Invoke-SchedulerTick $t.AddHours(1) } 'Verified marker alone cannot conceal unhealthy BitLocker'
$script:healthy=$true
Invoke-SchedulerTick $t.AddHours(1)
Assert ($script:schedule.Phase -eq 'VerifiedComplete') 'Completion requires healthy post-boot verification'
Fresh
$script:schedule.Phase='Preparing'
Invoke-SchedulerTick $t.AddHours(2)
Assert ($script:schedule.Phase -eq 'NeedsAttention') 'Ambiguous preparation after crash fails closed'
Fresh
Invoke-ScheduleRequest $script:schedule $p @{Action='Schedule';Utc=(Get-UtcText $t.AddHours(5))} $t
Invoke-SchedulerTick $t.AddHours(4)
Assert ($script:schedule.Phase -eq 'Scheduled') 'No early suspension far ahead of selected time'
Invoke-SchedulerTick $t.AddHours(4).AddMinutes(31)
Assert ($script:schedule.Phase -eq 'Preparing') 'Preparation starts near selected time'
Write-Output "PASS: $script:count V2 assertions (parser, schedule, DST, mocked engine). No Windows/firmware operations performed."
