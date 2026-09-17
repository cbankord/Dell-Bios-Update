# MedelaBIOS-FileVersion: 2.3.0
# Temporary UI status only. SYSTEM owns the deadline; no restart scheduled task
# or Windows shutdown timer is armed. UI files never contain credentials.
function Get-MedelaProcessResult($Handle) {
    if ($null -eq $Handle) { throw 'PSADT returned no asynchronous process handle.' }
    # PSADT 4.1.0 NoWait returns LaunchInfo(Task), or an immediate ProcessResult.
    if ($null -ne $Handle.PSObject.Properties['Task']) {
        if (-not $Handle.Task.IsCompleted) { return $null }
        $result=$Handle.Task.GetAwaiter().GetResult()
    } else { $result=$Handle }
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode']) { throw 'Unsupported PSADT process result. Use the reviewed 4.1.x framework.' }
    [int]$exitCode=0
    if ($null -eq $result.ExitCode -or -not [int]::TryParse([string]$result.ExitCode,[ref]$exitCode)) { throw 'PSADT did not return a valid process exit code.' }
    return $result
}
function Write-MedelaUIFailure($Result) {
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['StdErr'] -and $Result.StdErr) {
        $detail=[string]$Result.StdErr
        Write-BiosLog ('User UI error: '+$detail.Substring(0,[math]::Min(4096,$detail.Length)))
    }
}
function Get-MedelaRestartHoldMessage([string]$Reason) {
    if ($Reason -match 'AC |battery|power') { return 'Automatic restart has been cancelled because power requirements are not met. Plug your computer in and charge the battery. You will receive a fresh warning before another automatic restart. Contact IT if this continues.' }
    if ($Reason -match 'sleep/resume|monitoring gap|clock change') { return 'Automatic restart has been cancelled because the computer slept or the warning was interrupted. Keep your computer plugged in. You will receive a fresh warning before another automatic restart.' }
    return 'Automatic restart has been cancelled because a safety check could not be completed. Keep your computer plugged in and save your work. Contact IT if this continues. You will receive a fresh warning before another automatic restart.'
}
function Get-MedelaClock {
    if (-not ('MedelaBIOS.CountdownClock' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MedelaBIOS {
 public static class CountdownClock {
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool QueryUnbiasedInterruptTime(out ulong value);
 }
}
'@
    }
    [uint64]$awake=0
    if (-not [MedelaBIOS.CountdownClock]::QueryUnbiasedInterruptTime([ref]$awake)) { throw 'Cannot read the restart safety clock.' }
    @{Utc=[datetimeoffset]::UtcNow;Tick=[double][MedelaBIOS.CountdownClock]::GetTickCount64();Awake=([double]$awake/10000)}
}
function Get-MedelaSessionIdentity {
    $active=Get-ADTLoggedOnUser | Where-Object IsActiveUserSession | Select-Object -First 1
    if ($null -eq $active) { return '' }
    return ('{0}|{1}' -f $active.NTAccount,$active.SessionId)
}
function Assert-MedelaCountdown($Timer,[string]$Session) {
    $stamp=Get-MedelaClock
    $elapsed=($stamp.Tick-$Timer.Start.Tick)/1000
    $gap=$stamp.Tick-$Timer.LastTick
    $sleep=($stamp.Tick-$stamp.Awake)-($Timer.Start.Tick-$Timer.Start.Awake)
    if ($elapsed -lt 0 -or $gap -lt 0 -or $gap -gt 30000 -or $sleep -gt 2000 -or [math]::Abs(($stamp.Utc-$Timer.Start.Utc).TotalSeconds-$elapsed) -gt 30) {
        throw 'Restart countdown cancelled after sleep/resume, a monitoring gap, or a clock change. A fresh warning is required.'
    }
    if (-not $Session -or (Get-MedelaSessionIdentity) -ne $Session) { throw 'Restart countdown cancelled because the original active user session ended or changed.' }
    $Timer.LastTick=$stamp.Tick
    return [math]::Max(0,($Timer.DurationSeconds-$elapsed))
}
function Write-MedelaLiveStatus($Context,[string]$Phase,[string]$Message='',[int]$RemainingSeconds=0,[string]$DeadlineUtc='',[int]$Reminder=0) {
    $value=@{Schema=1;Session=$Context.Id;BootId=$Context.BootId;Phase=$Phase;Message=$Message;RemainingSeconds=$RemainingSeconds;DeadlineUtc=$DeadlineUtc;Reminder=$Reminder;HeartbeatUtc=[datetimeoffset]::UtcNow.ToString('o')}
    Save-ScheduleFile $value $Context.Path
}
function Remove-MedelaStaleUI([string]$Root) {
    # Caller holds Package.lock. These are only our disposable UI status folders,
    # never State/Recovery or registered tasks. An old UI closes on missing data.
    $live=Join-Path $Root 'UI/Live'
    if (-not (Test-Path -LiteralPath $live)) { return }
    Assert-NoCacheLinks $live
    foreach ($item in Get-ChildItem -LiteralPath $live -Directory -Force) {
        if ($item.Name -notmatch '^[a-f0-9]{32}$') { throw 'Unexpected UI session folder; inspect before cleanup.' }
        Assert-NoCacheLinks $item.FullName
        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Recurse -Force) { Assert-NoCacheLinks $child.FullName }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}
function Start-MedelaLiveUI([string]$Root,[string]$Phase) {
    $context=@{Id=[guid]::NewGuid().ToString('N');BootId=(Get-BootId);Path='';Handle=$null}
    $folder=Join-Path $Root ('UI/Live/'+$context.Id)
    Assert-NoCacheLinks $folder
    $null=[IO.Directory]::CreateDirectory($folder) # Inherit SYSTEM/Admin write, Users RX.
    $context.Path=Join-Path $folder 'Status.json'
    try {
        Write-MedelaLiveStatus $context $Phase
        $arguments='-NoProfile -STA -File "{0}" -Mode Live -StatusPath "{1}"' -f (Join-Path $Root 'UI/Show-BiosUI.ps1'),$context.Path
        $context.Handle=Start-ADTProcessAsUser -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -CreateNoWindow -NoStreamLogging -NoWait -PassThru -IgnoreExitCodes '*'
        $result=Get-MedelaProcessResult $context.Handle
        if ($null -ne $result) { Write-MedelaUIFailure $result;throw 'The progress/restart UI exited during launch.' }
        return $context
    } catch { Remove-Item -LiteralPath $folder -Recurse -Force; throw }
}
function Stop-MedelaLiveUI($Context) {
    if ($null -eq $Context) { return }
    # Missing status is also a close signal; no kill of the firmware worker.
    try { if (Test-Path -LiteralPath $Context.Path) { Write-MedelaLiveStatus $Context Closed } }
    finally {
        $folder=Split-Path $Context.Path -Parent
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    }
}
function Invoke-MedelaStaging([string]$Root,[string]$Files) {
    $ui=$null; $worker=$null; $uiLost=$false
    try {
        $ui=Start-MedelaLiveUI $Root Preparing
        # No timeout and no KillChildProcessesWithParent: never kill a firmware
        # worker because a window closes, the session ends, or power changes.
        $worker=Invoke-MedelaInstaller $Root $Files -NoWait
        while ($null -eq ($result=Get-MedelaProcessResult $worker)) {
            try {
                if (-not $uiLost) {
                    $uiResult=Get-MedelaProcessResult $ui.Handle
                    if ($null -ne $uiResult) { $uiLost=$true;Write-MedelaUIFailure $uiResult }
                }
                if (-not $uiLost) { Write-MedelaLiveStatus $ui Preparing }
            } catch { $uiLost=$true }
            Start-Sleep -Milliseconds 1000
        }
        if ($uiLost) { Write-BiosLog 'Progress UI ended; the firmware worker was allowed to finish. Transaction and recovery are retained.' }
        return [int]$result.ExitCode
    } finally {
        # Even a status/monitoring error must not abandon or terminate the worker.
        try {
            if ($null -ne $worker) {
                while ($null -eq (Get-MedelaProcessResult $worker)) { Start-Sleep -Milliseconds 1000 }
            }
        } finally { Stop-MedelaLiveUI $ui }
    }
}
function Invoke-MedelaRestartCountdown([string]$Root,$Config,$Policy,$State,[string]$StatePath) {
    $ui=$null; $disposition='Cancelled'; $reason=''; $timer=$null
    try {
        Assert-RestartSafe $Config (Get-State) (Get-BootId)
        $session=Get-MedelaSessionIdentity
        if (-not $session) { throw 'No active user for the restart warning.' }
        $ui=Start-MedelaLiveUI $Root StartingRestart
        $stamp=Get-MedelaClock
        $timer=@{Start=$stamp;LastTick=$stamp.Tick;DurationSeconds=($Policy.RestartCountdownMinutes*60)}
        $deadline=$stamp.Utc.AddSeconds($timer.DurationSeconds).ToString('o')
        $State.Phase='RestartRequired';$State.RestartSessionId=$ui.Id
        $State.RestartStartedUtc=$stamp.Utc.ToString('o');$State.RestartDeadlineUtc=$deadline
        $State.RestartDisposition='Active';$State.RestartCancelReason=''
        Save-ScheduleFile $State $StatePath
        Write-BiosLog ('Restart countdown started: deadline={0}; duration={1} minutes; reminder={2} minutes.' -f $deadline,$Policy.RestartCountdownMinutes,$Policy.RestartReminderMinutes)
        while ($true) {
            $remaining=Assert-MedelaCountdown $timer $session
            # Live power gate uses exactly the model's configured minimum (>=51)
            # and AC requirements. Full transaction/BitLocker guard runs at start
            # and immediately before the actual Windows restart request.
            Assert-Power $Config
            $remaining=Assert-MedelaCountdown $timer $session
            $result=Get-MedelaProcessResult $ui.Handle
            if ($null -ne $result -and $result.ExitCode -ne 12) { Write-MedelaUIFailure $result;throw 'Restart warning ended unexpectedly. No automatic restart will be requested.' }
            if ($remaining -le 0 -or $null -ne $result) {
                $reason=if ($null -ne $result) {'Restart Now selected'} else {'Configured restart warning elapsed'}
                Invoke-MedelaRestart $Config -Timer $timer -Session $session -Reason $reason
                $disposition='Requested'
                return 1618
            }
            $reminder=[int][math]::Floor(($timer.DurationSeconds-$remaining)/($Policy.RestartReminderMinutes*60))
            Write-MedelaLiveStatus $ui Restart -RemainingSeconds ([int][math]::Ceiling($remaining)) -DeadlineUtc $deadline -Reminder $reminder
            Start-Sleep -Milliseconds 5000
        }
    } catch {
        $reason=$_.Exception.Message
        Write-BiosLog ('Restart safety hold: '+$reason)
        # Explain briefly, then retire this mandatory prompt. Original deferral
        # deadline, staged transaction, verifier and owned suspension survive.
        if ($null -ne $ui) {
            try { Write-MedelaLiveStatus $ui Paused (Get-MedelaRestartHoldMessage $reason); Start-Sleep -Seconds 5 } catch { }
        }
        return 1618
    } finally {
        try {
            $State.RestartDisposition=$disposition;$State.RestartCancelReason=$reason
            $State.RestartDeadlineUtc='';$State.RestartSessionId=''
            if ($disposition -ne 'Requested') { $State.Phase='RestartPaused' }
            Save-ScheduleFile $State $StatePath
        } finally { Stop-MedelaLiveUI $ui }
    }
}
