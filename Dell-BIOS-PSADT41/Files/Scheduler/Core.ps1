# Pure scheduling rules: no registry, process, task or firmware operations.
Set-StrictMode -Version 3
function Get-UtcText([datetimeoffset]$Time) { $Time.ToUniversalTime().ToString('o') }
function Read-Utc([string]$Text) {
    if ($Text -notmatch '(Z|\+00:00)$') { throw 'A UTC timestamp is required.' }
    [datetimeoffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture)
}
function Assert-SchedulerPolicy($Policy) {
    if ($Policy.Schema -ne 2) { throw 'Invalid scheduler policy schema.' }
    foreach ($name in @('WindowHours','ReminderHours','FinalWarningMinutes','PreparationLeadMinutes','SafetyRetryMinutes')) {
        if ($Policy[$name] -isnot [int]) { throw "$name must be a whole number." }
    }
    if ($Policy.WindowHours -lt 1 -or $Policy.WindowHours -gt 168) { throw 'WindowHours must be 1-168 (default 72).' }
    if ($Policy.ReminderHours -lt 1 -or $Policy.ReminderHours -gt 12) { throw 'ReminderHours must be 1-12.' }
    if ($Policy.FinalWarningMinutes -lt 15 -or $Policy.FinalWarningMinutes -gt 60) { throw 'FinalWarningMinutes must be 15-60.' }
    if ($Policy.PreparationLeadMinutes -lt $Policy.FinalWarningMinutes -or $Policy.PreparationLeadMinutes -gt 60) { throw 'Preparation lead must cover the warning and be at most 60 minutes.' }
    if ($Policy.SafetyRetryMinutes -lt 1 -or $Policy.SafetyRetryMinutes -gt 30) { throw 'SafetyRetryMinutes must be 1-30.' }
}
function New-ScheduleState([string]$PackageId, [datetimeoffset]$Now, [int]$WindowHours = 72) {
    if ($WindowHours -lt 1 -or $WindowHours -gt 168) { throw 'Invalid original scheduling window.' }
    @{
        Schema = 2; PackageId = $PackageId; Phase = 'AwaitingNotice'; WindowHours = $WindowHours
        EnrolledUtc = Get-UtcText $Now; FirstNotifiedUtc = ''; DeadlineUtc = ''
        ScheduledUtc = ''; RestartUtc = ''; NextNoticeUtc = ''; NextAttemptUtc = ''
        LastObservedUtc = Get-UtcText $Now; LastError = ''; WorkerBoot = ''
        WorkerPid = 0; WorkerStartedUtc = ''; LastRestartAttemptUtc = ''
        HeartbeatUtc = ''; CompletedNoticeShown = $false
    }
}
function Assert-ScheduleState($State, [string]$PackageId) {
    # Earlier schema-2 deployments always used 72 hours. Never adopt a new
    # package policy when recovering their state, even before first notice.
    if (-not $State.ContainsKey('WindowHours')) { $State.WindowHours = 72 }
    $required = (New-ScheduleState $PackageId ([datetimeoffset]::UtcNow)).Keys
    foreach ($name in $required) { if (-not $State.ContainsKey($name)) { throw "Damaged scheduler state: missing $name. Manual review required." } }
    if ($State.Schema -ne 2 -or $State.PackageId -ne $PackageId) { throw 'Different deployment or invalid scheduler schema. Manual review required.' }
    if ($State.Phase -notin @('AwaitingNotice','Pending','Scheduled','Preparing','Blocked','RestartRequired','Verifying','VerifiedComplete','NeedsAttention')) { throw 'Invalid scheduler phase.' }
    foreach ($name in @('EnrolledUtc','LastObservedUtc','FirstNotifiedUtc','DeadlineUtc','ScheduledUtc','RestartUtc','NextNoticeUtc','NextAttemptUtc','HeartbeatUtc','WorkerStartedUtc','LastRestartAttemptUtc')) {
        if ($State[$name]) { $null = Read-Utc $State[$name] }
    }
    if ([bool]$State.FirstNotifiedUtc -ne [bool]$State.DeadlineUtc) { throw 'Incomplete deadline state.' }
    if ($State.WindowHours -notmatch '^\d+$' -or $State.WindowHours -lt 1 -or $State.WindowHours -gt 168) { throw 'Invalid persisted scheduling window.' }
    if ($State.DeadlineUtc -and (Read-Utc $State.DeadlineUtc) -ne (Read-Utc $State.FirstNotifiedUtc).AddHours($State.WindowHours)) { throw 'Deadline has changed. Manual review required.' }
    if ($State.ScheduledUtc -and (-not $State.DeadlineUtc -or (Read-Utc $State.ScheduledUtc) -gt (Read-Utc $State.DeadlineUtc))) { throw 'Schedule exceeds its original deadline.' }
}
function Set-SchedulePhase($State, [string]$Phase, [string]$Reason = '') {
    if ($State.Phase -ne $Phase -or $State.LastError -ne $Reason) { $State.NextNoticeUtc = '' }
    $State.Phase = $Phase
    $State.LastError = $Reason
}
function Get-EffectiveNow($State, [datetimeoffset]$WallClock) {
    # Never move the observed clock backwards across retries or service restarts.
    if ($State.LastObservedUtc -and (Read-Utc $State.LastObservedUtc) -gt $WallClock) { return Read-Utc $State.LastObservedUtc }
    return $WallClock
}
function Get-MaintenanceTime($State) {
    if ($State.ScheduledUtc) { return Read-Utc $State.ScheduledUtc }
    if ($State.DeadlineUtc) { return Read-Utc $State.DeadlineUtc }
    return $null
}
function Test-CanSchedule($State, [datetimeoffset]$Now) {
    $State.Phase -in @('Pending','Scheduled','Blocked') -and $State.DeadlineUtc -and $Now -lt (Read-Utc $State.DeadlineUtc)
}
function Invoke-ScheduleRequest($State, $Policy, $Request, [datetimeoffset]$Now) {
    $Now = Get-EffectiveNow $State $Now
    if ($Request -isnot [hashtable] -or -not $Request.ContainsKey('Action') -or $Request.Action -isnot [string]) { throw 'Invalid request.' }
    foreach ($key in $Request.Keys) { if ($key -notin @('Action','Utc')) { throw 'Unexpected request field.' } }
    switch -Exact ($Request.Action) {
        Status { }
        NoticeShown {
            if (-not $State.FirstNotifiedUtc -and $State.Phase -eq 'AwaitingNotice') {
                $State.FirstNotifiedUtc = Get-UtcText $Now
                $State.DeadlineUtc = Get-UtcText ($Now.AddHours($State.WindowHours))
                Set-SchedulePhase $State Pending
            }
            if ($State.Phase -eq 'VerifiedComplete') { $State.CompletedNoticeShown = $true }
            $State.NextNoticeUtc = Get-UtcText ($Now.AddHours($Policy.ReminderHours))
            if ($State.Phase -eq 'RestartRequired' -and $State.RestartUtc -and -not $State.LastError) {
                $reminder = (Read-Utc $State.RestartUtc).AddMinutes(-5)
                if ($reminder -le $Now) { $reminder = Read-Utc $State.RestartUtc }
                if ($reminder -gt $Now -and $reminder -lt (Read-Utc $State.NextNoticeUtc)) { $State.NextNoticeUtc=Get-UtcText $reminder }
            }
        }
        Defer {
            if (-not (Test-CanSchedule $State $Now)) { throw 'Deferral is no longer available. Safety checks still apply.' }
            # Defer hides a notice; it NEVER clears a selected schedule or moves the deadline.
            $State.NextNoticeUtc = Get-UtcText ($Now.AddHours($Policy.ReminderHours))
        }
        Schedule {
            if (-not (Test-CanSchedule $State $Now)) { throw 'Scheduling is closed; the update is due or preparation has begun.' }
            if (-not $Request.ContainsKey('Utc') -or $Request.Utc -isnot [string]) { throw 'Select a restart time.' }
            $chosen = Read-Utc $Request.Utc
            if ($chosen -lt $Now.AddMinutes(1) -or $chosen -gt (Read-Utc $State.DeadlineUtc)) { throw 'Choose a future time within the original deadline.' }
            $State.ScheduledUtc = Get-UtcText $chosen
            $State.NextAttemptUtc = ''
            Set-SchedulePhase $State Scheduled
            $State.NextNoticeUtc = Get-UtcText ($Now.AddHours($Policy.ReminderHours))
        }
        RestartNow {
            if ($State.Phase -ne 'RestartRequired') { throw 'The BIOS update is not ready to restart.' }
            # Explicit user action; broker still validates transaction, power and BitLocker.
            $State.RestartUtc = Get-UtcText $Now
            $State.NextAttemptUtc = ''
        }
        default { throw 'Unsupported action.' }
    }
    $State.LastObservedUtc = Get-UtcText $Now
}
function Get-ScheduleView($State, $Policy, [datetimeoffset]$Now) {
    $Now = Get-EffectiveNow $State $Now
    $overdue = [bool]($State.DeadlineUtc -and $Now -ge (Read-Utc $State.DeadlineUtc))
    $shouldShow = -not $State.NextNoticeUtc -or $Now -ge (Read-Utc $State.NextNoticeUtc)
    if ($State.Phase -eq 'VerifiedComplete' -and $State.CompletedNoticeShown) { $shouldShow = $false }
    @{
        Phase = $State.Phase; DeadlineUtc = $State.DeadlineUtc; ScheduledUtc = $State.ScheduledUtc
        RestartUtc = $State.RestartUtc; ServerUtc = Get-UtcText $Now
        WindowHours = $State.WindowHours; PreparationLeadMinutes = $Policy.PreparationLeadMinutes
        CanSchedule = [bool](Test-CanSchedule $State $Now); Overdue = $overdue
        ShouldShow = [bool]$shouldShow; Message = $State.LastError
        CanRestart = $State.Phase -eq 'RestartRequired' -and -not $State.LastError
    }
}
