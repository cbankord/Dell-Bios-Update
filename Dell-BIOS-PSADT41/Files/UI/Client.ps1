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
