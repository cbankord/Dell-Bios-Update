function Send-BiosRequest($Request) {
    # Specific access rights avoid GENERIC_WRITE, which also requests CreateNewInstance.
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', 'ManagedDellBIOS-v2', [IO.Pipes.PipeAccessRights]::ReadWrite, 'Asynchronous', 'Identification', 'None')
    try {
        $pipe.Connect(1200)
        # Do not trust a user-created server with the same name.
        $owner = $pipe.GetAccessControl().GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne 'S-1-5-18') { throw 'The update controller could not be authenticated.' }
        Write-PipeMessage $pipe $Request
        $response = ConvertFrom-SchedulerJson (Read-PipeMessage $pipe)
        if (-not $response.Ok) { throw $response.Error }
        return $response.State
    } finally { $pipe.Dispose() }
}
function Convert-LocalSelectionToUtc([datetime]$Day, [int]$Hour, [int]$Minute, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    $local = [datetime]::SpecifyKind($Day.Date.AddHours($Hour).AddMinutes($Minute), [DateTimeKind]::Unspecified)
    if ($Zone.IsInvalidTime($local)) { throw 'That time does not exist because the clocks change. Select another time.' }
    if ($Zone.IsAmbiguousTime($local)) { throw 'That time occurs twice because the clocks change. Select another time.' }
    [TimeZoneInfo]::ConvertTimeToUtc($local, $Zone).ToString('o')
}
function Get-LocalTimeLabel([string]$Utc) {
    if (-not $Utc) { return 'Not selected' }
    ([datetimeoffset]::Parse($Utc)).ToLocalTime().ToString('ddd, MMM d, yyyy h:mm tt zzz')
}
function Get-BiosViewValue($View, [string]$Name, $Default) {
    if ($View -is [System.Collections.IDictionary]) {
        if ($View.Contains($Name)) { return $View[$Name] }
    } elseif ($null -ne $View -and $null -ne $View.PSObject.Properties[$Name]) { return $View.$Name }
    return $Default
}
function Get-NoticeActions($View) {
    # Choices are visible on the first rendered notice, even while awaiting
    # acknowledgement; enabling them still requires the controller's permission.
    $choicePhase=$View.Phase -in @('AwaitingNotice','Pending','Scheduled','Blocked')
    @{
        ShowInstall=$choicePhase
        ShowSchedule=$choicePhase -and -not $View.Overdue
        ShowDefer=$choicePhase -and -not $View.Overdue
        EnableInstall=[bool](Get-BiosViewValue $View 'CanInstallNow' $false)
        EnableSchedule=[bool]$View.CanSchedule
        EnableDefer=[bool]$View.CanSchedule
        ShowRestart=$View.Phase -eq 'RestartRequired'
        EnableRestart=[bool]$View.CanRestart
    }
}
