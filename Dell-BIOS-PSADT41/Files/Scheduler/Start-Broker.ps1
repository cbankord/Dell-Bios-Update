#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Common.ps1"
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Windows.ps1"
. "$PSScriptRoot\Engine.ps1"
$script:RuntimeDir = Split-Path $PSScriptRoot -Parent
$script:StatePath = Join-Path $script:WorkDir 'Schedule-v2.json'
$runLock = $null; $pipe = $null; $script:worker = $null; $script:lastTick = $null
try {
    if (-not [Environment]::Is64BitProcess -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'SYSTEM x64 is required.' }
    $runLock = [IO.File]::Open((Join-Path $script:WorkDir 'Broker-v2.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $script:config = Import-PowerShellDataFile "$script:RuntimeDir\BIOS-Config.psd1"
    $script:policy = Import-PowerShellDataFile "$PSScriptRoot\Policy.psd1"
    Assert-Config $script:config; Assert-SchedulerPolicy $script:policy
    $script:schedule = Read-ScheduleFile $script:StatePath
    Assert-ScheduleState $script:schedule (Get-PackageId $script:config)
    Initialize-PipeNative
    # Existing RestartRequired state after broker restart receives a fresh warning;
    # it retains the original deadline and cannot be deferred or rescheduled.
    if ($script:schedule.Phase -eq 'RestartRequired') {
        $script:schedule.RestartUtc = Get-UtcText ([datetimeoffset]::UtcNow.AddMinutes($script:policy.FinalWarningMinutes))
        $script:schedule.NextNoticeUtc = ''
    }
    Write-SchedulerLog 'SYSTEM scheduler started.'
    $nextTick = [datetimeoffset]::MinValue
    $nextListen = [datetimeoffset]::MinValue
    while ($true) {
        if ($null -eq $pipe -and [datetimeoffset]::UtcNow -ge $nextListen) {
            try { $pipe = New-SchedulerPipe; $connection = $pipe.BeginWaitForConnection($null, $null) }
            catch {
                if ($null -ne $pipe) { $pipe.Dispose(); $pipe=$null }
                $nextListen = [datetimeoffset]::UtcNow.AddMinutes(1)
                Write-SchedulerLog 'Interactive channel unavailable; scheduler enforcement continues. Check for a conflicting pipe/server.'
            }
        }
        if ($null -ne $pipe -and $connection.IsCompleted) {
            try {
                $pipe.EndWaitForConnection($connection)
                # Impersonation identifies the last message read from this connection.
                $json = Read-PipeMessage $pipe
                $sid = Get-AuthenticatedPipeUser $pipe
                $object = ConvertFrom-SchedulerJson $json
                $request = ConvertTo-PlainHashtable $object
                $now = [datetimeoffset]::UtcNow
                Invoke-ScheduleRequest $script:schedule $script:policy $request $now
                if ($request.Action -ne 'Status') {
                    Save-EngineState
                    Write-SchedulerLog "Interactive request accepted: action=$($request.Action); sid=$sid; deadline=$($script:schedule.DeadlineUtc); selected=$($script:schedule.ScheduledUtc); installNow=$($script:schedule.InstallRequestedUtc)."
                }
                Write-PipeMessage $pipe @{ Ok = $true; State = Get-ScheduleView $script:schedule $script:policy $now }
            } catch {
                # Never reflect arbitrary request content or exception source lines to logs.
                try { Write-PipeMessage $pipe @{ Ok = $false; Error = 'Request rejected. Refresh the status and choose an available action.' } } catch { }
            } finally { $pipe.Dispose(); $pipe = $null }
        }
        $now = [datetimeoffset]::UtcNow
        if ($now -ge $nextTick) {
            $oldPhase = $script:schedule.Phase
            try { Invoke-SchedulerTick $now }
            catch {
                Set-SchedulePhase $script:schedule NeedsAttention 'A safety or state check failed. Contact IT and review Scheduler.log.'
                Write-SchedulerLog ('Scheduler safety stop: ' + $_.Exception.Message)
            }
            if ($oldPhase -ne $script:schedule.Phase) { Write-SchedulerLog "Phase changed: $oldPhase -> $($script:schedule.Phase)." }
            Save-EngineState
            $script:lastTick = $now
            $nextTick = $now.AddSeconds(5)
        }
        Start-Sleep -Milliseconds 100
    }
} catch {
    try { Write-SchedulerLog ('Scheduler stopped: ' + $_.Exception.Message) } catch { }
    exit 1
} finally {
    if ($null -ne $pipe) { $pipe.Dispose() }
    if ($null -ne $runLock) { $runLock.Dispose() }
    # Never terminate a firmware child when this controller exits.
}
