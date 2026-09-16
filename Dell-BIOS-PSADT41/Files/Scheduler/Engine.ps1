# State transitions are independent of the UI. All OS operations are in named helpers.
function Start-FirmwareWorker {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process -FilePath $ps -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:RuntimeDir 'Install-DellBIOS.ps1')) -WindowStyle Hidden -PassThru
}
function Invoke-ManagedRestart {
    # /t 0 does not imply /f. Never force-kill unsaved applications.
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /d p:2:17 /c 'Scheduled Dell BIOS update. Keep AC power connected.' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows rejected the restart request.' }
}
function Save-EngineState { Save-ScheduleFile $script:schedule $script:StatePath }
function Set-EngineBlocked([string]$Reason, [datetimeoffset]$Now) {
    Set-SchedulePhase $script:schedule Blocked $Reason
    $script:schedule.NextAttemptUtc = Get-UtcText ($Now.AddMinutes($script:policy.SafetyRetryMinutes))
}
function Invoke-SchedulerTick([datetimeoffset]$Now) {
    $s = $script:schedule
    $Now = Get-EffectiveNow $s $Now
    $s.LastObservedUtc = Get-UtcText $Now
    $s.HeartbeatUtc = Get-UtcText $Now
    if ($s.Phase -eq 'NeedsAttention' -or $s.Phase -eq 'VerifiedComplete') { return }
    $boot = Get-BootId
    $childCode = $null
    if ($null -ne $script:worker) {
        if (-not $script:worker.HasExited) { return }
        $childCode = $script:worker.ExitCode
        $script:worker.Dispose(); $script:worker = $null
        $s.WorkerPid = 0
        Write-SchedulerLog "Installer completed with code $childCode."
    }
    $snapshot = Get-TransactionSnapshot
    if ($snapshot.Busy) { return } # Never inspect partially written registry state.
    $txn = $snapshot.Transaction
    $matches = $null -ne $txn -and $txn.TargetVersion -eq $script:config.TargetVersion -and $txn.PayloadHash -eq $script:config.SHA256
    if ($null -ne $txn -and $txn.Status -ne 'Verified' -and -not $matches) {
        Set-SchedulePhase $s NeedsAttention 'Another BIOS transaction is unresolved. Contact IT.'; return
    }
    if ($matches -and $txn.Status -in @('FailedAfterReboot','FailedOrAmbiguous','Launching','Preparing')) {
        Set-SchedulePhase $s NeedsAttention 'The prior update needs investigation. Automatic reflashing is blocked. Contact IT.'; return
    }
    if ($matches -and $txn.Status -eq 'Staged') {
        if ($txn.BootId -ne $boot) {
            Set-SchedulePhase $s Verifying 'Windows has restarted. Firmware and BitLocker verification is pending.'
            return # Existing SYSTEM verification task runs after boot and owns recovery.
        }
        if ($s.Phase -ne 'RestartRequired') {
            Set-SchedulePhase $s RestartRequired
            $minimum = (Read-Utc $txn.StagedUtc).AddMinutes($script:policy.FinalWarningMinutes)
            # A recovered broker or missed schedule always provides a fresh warning.
            if ($minimum -lt $Now.AddMinutes($script:policy.FinalWarningMinutes)) { $minimum = $Now.AddMinutes($script:policy.FinalWarningMinutes) }
            $chosen = Get-MaintenanceTime $s
            if ($null -ne $chosen -and $chosen -gt $minimum) { $minimum = $chosen }
            $s.RestartUtc = Get-UtcText $minimum
            $s.NextAttemptUtc = ''
            Write-SchedulerLog "Firmware staged; managed restart is planned for $($s.RestartUtc)."
        }
        if ($s.NextAttemptUtc -and $Now -lt (Read-Utc $s.NextAttemptUtc)) { return }
        try { Assert-RestartSafe $script:config $txn $boot }
        catch {
            # Never resume over staged firmware and never restage to repair a power failure.
            if ($s.LastError -ne $_.Exception.Message) { $s.NextNoticeUtc = '' }
            $s.LastError = $_.Exception.Message
            $s.NextAttemptUtc = Get-UtcText ($Now.AddMinutes($script:policy.SafetyRetryMinutes))
            Write-SchedulerLog ('Restart safety hold: ' + $s.LastError)
            return
        }
        if ($s.LastError) {
            $s.LastError = ''; $s.NextNoticeUtc = ''; $s.NextAttemptUtc = ''
            $s.RestartUtc = Get-UtcText ($Now.AddMinutes($script:policy.FinalWarningMinutes))
            Write-SchedulerLog 'Power/safety restored. Starting a fresh final warning.'
        }
        # A long sleep/offline interval must not cause an immediate unattended catch-up restart.
        if ($script:lastTick -and ($Now - $script:lastTick).TotalMinutes -gt 2 -and $Now -ge (Read-Utc $s.RestartUtc)) {
            $s.RestartUtc = Get-UtcText ($Now.AddMinutes($script:policy.FinalWarningMinutes))
            $s.NextNoticeUtc = ''
            Write-SchedulerLog 'Missed restart after sleep/offline interval; fresh warning started.'
        }
        if ($Now -ge (Read-Utc $s.RestartUtc)) {
            # Record before requesting restart. A crash will not generate repeated immediate attempts.
            $s.LastRestartAttemptUtc = Get-UtcText $Now
            $s.NextAttemptUtc = Get-UtcText ($Now.AddMinutes($script:policy.FinalWarningMinutes))
            $s.RestartUtc = $s.NextAttemptUtc
            Save-EngineState
            try { Assert-RestartSafe $script:config $txn $boot }
            catch {
                $s.LastError=$_.Exception.Message; $s.NextNoticeUtc=''
                $s.NextAttemptUtc=Get-UtcText ($Now.AddMinutes($script:policy.SafetyRetryMinutes))
                Write-SchedulerLog ('Last-moment restart safety hold: ' + $s.LastError)
                return
            }
            Invoke-ManagedRestart
            Write-SchedulerLog 'Windows restart requested without forced application closure.'
        }
        return
    }
    if ($matches -and $txn.Status -eq 'Verified') {
        Assert-PostBootHealth $script:config
        Set-SchedulePhase $s VerifiedComplete
        Write-SchedulerLog 'Verified complete: actual firmware meets target and BitLocker is healthy.'
        return
    }
    if ($s.Phase -in @('RestartRequired','Verifying')) {
        Set-SchedulePhase $s NeedsAttention 'Expected firmware transaction is missing. Contact IT.'; return
    }
    if ($s.Phase -eq 'Preparing') {
        if ($null -ne $childCode -and $childCode -eq 1618) {
            Set-EngineBlocked 'A prerequisite is not ready. Connect AC, charge above 50%, and resolve pending Windows restarts. IT can check Deployment.log.' $Now
            return
        }
        if ($null -ne $childCode -and $childCode -eq 0) {
            Assert-PostBootHealth $script:config
            Set-SchedulePhase $s VerifiedComplete; return
        }
        Set-SchedulePhase $s NeedsAttention 'Preparation stopped without confirmed staging. Contact IT; automatic reflashing is blocked.'; return
    }
    # Firmware may have been upgraded externally before we started.
    $actual = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    if ($actual -ge (Convert-BiosVersion $script:config.TargetVersion)) {
        Assert-PostBootHealth $script:config
        Set-SchedulePhase $s VerifiedComplete; return
    }
    $due = Get-MaintenanceTime $s
    if ($null -eq $due) { return } # fixed clock begins only on delivered notice.
    if ($s.NextAttemptUtc -and $Now -lt (Read-Utc $s.NextAttemptUtc)) { return }
    $lead = if ($s.ScheduledUtc -and -not $s.InstallRequestedUtc) { $script:policy.PreparationLeadMinutes } else { 0 }
    if ($Now -lt $due.AddMinutes(-$lead)) { return }
    # If we missed a selected time/deadline, announce a fresh warning BEFORE staging.
    $recentInstallRequest = $s.InstallRequestedUtc -and ($Now - (Read-Utc $s.InstallRequestedUtc)).TotalMinutes -le 2
    if ($Now -ge $due -and -not $s.WorkerStartedUtc -and -not $recentInstallRequest) {
        $s.WorkerStartedUtc = Get-UtcText $Now # catch-up-warning marker, replaced on actual start
        $s.NextAttemptUtc = Get-UtcText ($Now.AddMinutes($script:policy.FinalWarningMinutes))
        $s.NextNoticeUtc = ''
        $s.LastError = 'The scheduled time was missed. Preparation will begin after a {0}-minute notice, once safety checks pass.' -f $script:policy.FinalWarningMinutes
        return
    }
    try {
        Assert-Model $script:config
        Assert-Power $script:config
        Assert-NoPendingReboot
        Assert-Payload (Join-Path $script:RuntimeDir $script:config.FileName) $script:config
    } catch {
        if ($_.Exception.Message.StartsWith('Retry:')) { Set-EngineBlocked $_.Exception.Message $Now; return }
        throw
    }
    Set-SchedulePhase $s Preparing
    $s.WorkerBoot = $boot
    $s.WorkerStartedUtc = Get-UtcText $Now
    Save-EngineState # persist intent before a process could ever launch
    $script:worker = Start-FirmwareWorker
    $s.WorkerPid = $script:worker.Id
    Save-EngineState
    Write-SchedulerLog 'Beginning guarded BIOS preparation near the scheduled restart.'
}
