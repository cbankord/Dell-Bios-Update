# MedelaBIOS-FileVersion: 4.0.0
function ConvertFrom-StateJson([string]$Json) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { ConvertFrom-Json -InputObject $Json -DateKind String }
    else { ConvertFrom-Json -InputObject $Json }
}
function Read-ScheduleFile([string]$Path) {
    $object=ConvertFrom-StateJson (Get-Content -LiteralPath $Path -Raw)
    $state=@{}
    foreach ($property in $object.PSObject.Properties) {
        $value=$property.Value
        # Older ConvertFrom-Json versions can eagerly materialize ISO strings
        # as DateTime in the local zone. Normalize only known timestamp fields;
        # reject unspecified instants instead of inferring a time zone.
        if ($property.Name.EndsWith('Utc') -and $value -is [datetime]) {
            if ($value.Kind -eq [DateTimeKind]::Unspecified) { throw 'Unzoned deployment timestamp.' }
            $value=$value.ToUniversalTime().ToString('o')
        } elseif ($property.Name.EndsWith('Utc') -and $value -is [datetimeoffset]) { $value=$value.ToUniversalTime().ToString('o') }
        $state[$property.Name]=$value
    }
    $state
}
function Save-ScheduleFile($State,[string]$Path) {
    [IO.File]::WriteAllText(($Path+'.new'),($State|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace(($Path+'.new'),$Path,[NullString]::Value) }
    else { [IO.File]::Move(($Path+'.new'),$Path) }
}
function Get-PackageId($Config) { 'v2-'+$Config.TargetVersion+'-'+$Config.SHA256.ToLowerInvariant() }
function Get-AllowScheduleLater($Policy) {
    # Old v3 policy/presets omit this field and retain their enabled behavior.
    if (-not $Policy.ContainsKey('AllowScheduleLater')) { return $true }
    if ($Policy.AllowScheduleLater -isnot [bool]) { throw 'AllowScheduleLater must be Boolean.' }
    return $Policy.AllowScheduleLater
}
function Assert-SimplePolicy($Policy) {
    $null=Get-AllowScheduleLater $Policy
    foreach ($name in @('WindowHours','ReminderHours','PromptTimeoutMinutes','RestartCountdownMinutes','RestartReminderMinutes')) { if ($Policy[$name] -isnot [int]) { throw "Invalid $name." } }
    if ($Policy.Schema -ne 3 -or $Policy.WindowHours -lt 1 -or $Policy.WindowHours -gt 168 -or $Policy.ReminderHours -lt 1 -or $Policy.ReminderHours -gt 12 -or $Policy.PromptTimeoutMinutes -lt 1 -or $Policy.PromptTimeoutMinutes -gt 30) { throw 'Invalid simple deployment policy.' }
    if ($Policy.RestartCountdownMinutes -lt 15 -or $Policy.RestartCountdownMinutes -gt 120 -or $Policy.RestartReminderMinutes -lt 1 -or $Policy.RestartReminderMinutes -gt 30 -or $Policy.RestartReminderMinutes -ge $Policy.RestartCountdownMinutes) { throw 'Invalid restart countdown/reminder policy.' }
}
function New-SimpleState([string]$PackageId,[int]$WindowHours) {
    @{Schema=3;PackageId=$PackageId;WindowHours=$WindowHours;FirstNoticeUtc='';DeadlineUtc='';NextNoticeUtc='';LastObservedUtc='';Phase='Pending'}
}
function Assert-SimpleState($State,[string]$PackageId) {
    foreach ($key in (New-SimpleState $PackageId 72).Keys) { if (-not $State.ContainsKey($key)) { throw 'Incomplete deployment state; do not reset the deadline.' } }
    if ($State.Schema -ne 3 -or $State.PackageId -ne $PackageId -or $State.WindowHours -lt 1 -or $State.WindowHours -gt 168) { throw 'Invalid deployment state.' }
    if ([bool]$State.FirstNoticeUtc -ne [bool]$State.DeadlineUtc) { throw 'Incomplete deadline.' }
    foreach ($name in @('FirstNoticeUtc','DeadlineUtc','NextNoticeUtc','LastObservedUtc')) {
        if ($State[$name]) {
            if ($State[$name] -notmatch '(Z|\+00:00)$') { throw 'UTC deployment state required.' }
            $null=[datetimeoffset]::Parse($State[$name])
        }
    }
    if ($State.DeadlineUtc -and [datetimeoffset]::Parse($State.DeadlineUtc) -ne [datetimeoffset]::Parse($State.FirstNoticeUtc).AddHours($State.WindowHours)) { throw 'Original deadline has changed.' }
    # Additive migration: existing v2/v3 deadlines remain byte-for-byte intact.
    if (-not $State.ContainsKey('ScheduledInstallUtc')) { $State.ScheduledInstallUtc='' }
    if ($State.ScheduledInstallUtc) {
        if (-not $State.DeadlineUtc -or $State.ScheduledInstallUtc -notmatch '(Z|\+00:00)$') { throw 'Scheduled installation requires the original UTC deadline.' }
        $scheduled=[datetimeoffset]::Parse($State.ScheduledInstallUtc)
        if ($scheduled -gt [datetimeoffset]::Parse($State.DeadlineUtc) -or $scheduled -lt [datetimeoffset]::Parse($State.FirstNoticeUtc)) { throw 'Scheduled installation is outside the original window.' }
    }
}
function Get-SimpleNow($State) {
    $now=[datetimeoffset]::UtcNow
    if ($State.LastObservedUtc -and [datetimeoffset]::Parse($State.LastObservedUtc) -gt $now) { $now=[datetimeoffset]::Parse($State.LastObservedUtc) }
    $State.LastObservedUtc=$now.ToString('o'); $now
}
function Start-SimpleNotice($State,[datetimeoffset]$Now) {
    # Persist immediately before launching into the active user's session. This
    # is a delivery-attempt timestamp, not proof of reading. A launch failure or
    # power loss must never silently grant another window on the next attempt.
    if (-not $State.FirstNoticeUtc) { $State.FirstNoticeUtc=$Now.ToString('o'); $State.DeadlineUtc=$Now.AddHours($State.WindowHours).ToString('o') }
}
function Assert-CacheRefreshSafe($Transaction,[bool]$ChangesNeeded) {
    if ($ChangesNeeded -and $null -ne $Transaction -and ($Transaction.Status -ne 'Verified' -or $Transaction.SuspendedByUs -ne '0')) { throw 'Retry: runtime refresh is blocked while a BIOS transaction or protection recovery is unresolved.' }
}
function Import-LegacyDeadline($Legacy,[string]$PackageId,[int]$WindowHours) {
    if ($Legacy.PackageId -ne $PackageId -and $Legacy.Phase -ne 'VerifiedComplete') { throw 'Another legacy BIOS deployment remains unresolved.' }
    $state=New-SimpleState $PackageId $WindowHours
    if ($Legacy.PackageId -eq $PackageId) {
        if ($Legacy.ContainsKey('WindowHours')) { $state.WindowHours=[int]$Legacy.WindowHours } else { $state.WindowHours=72 }
        $state.FirstNoticeUtc=$Legacy.FirstNotifiedUtc; $state.DeadlineUtc=$Legacy.DeadlineUtc
        $state.NextNoticeUtc=$Legacy.NextNoticeUtc; $state.LastObservedUtc=$Legacy.LastObservedUtc
        # Honor prior immediate intent/selected times by making the next Intune
        # attempt due, not by introducing a second restart schedule.
        if ($Legacy.ScheduledUtc -or ($Legacy.ContainsKey('InstallRequestedUtc') -and $Legacy.InstallRequestedUtc)) { $state.NextNoticeUtc='' }
    }
    Assert-SimpleState $state $PackageId; $state
}
