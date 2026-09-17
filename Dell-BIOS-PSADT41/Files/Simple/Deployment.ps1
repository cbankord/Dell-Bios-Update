# MedelaBIOS-FileVersion: 2.2.0
# One PSADT invocation owns this flow. No resident broker, pipe or UI task.
function Assert-MedelaHost {
    if (-not [Environment]::Is64BitProcess -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Run the deployment as SYSTEM in x64 Windows PowerShell.' }
}
function Enter-LegacyRetirement([string]$Root,$Config,[string]$StatePath,$Policy) {
    $old=Join-Path $env:ProgramData 'ManagedDellBIOS'
    $marker=Join-Path $Root 'State/LegacyRetired.json'
    $tasks=@(Get-ScheduledTask -TaskName 'ManagedDellBIOS-v2-Controller','ManagedDellBIOS-v2-UserUI' -ErrorAction SilentlyContinue)
    if ((Test-Path -LiteralPath $marker) -and $tasks.Count) { throw 'An old package recreated the legacy tasks. Remove its assignment before continuing.' }
    if (Test-Path -LiteralPath $marker) { return @() }
    $held=New-Object 'Collections.Generic.List[IDisposable]'
    try {
        if (Test-Path -LiteralPath $old) {
            Assert-NoCacheLinks $old
            foreach ($name in @('Setup-v2.lock','Deployment.lock')) {
                $held.Add([IO.File]::Open((Join-Path $old $name),'OpenOrCreate','ReadWrite','None'))
            }
        }
        $transaction=Get-State
        Assert-CacheRefreshSafe $transaction $true
        $legacyPath=Join-Path $old 'Schedule-v2.json'
        if ((Test-Path -LiteralPath (Join-Path $old 'Enrollment-v2.json')) -and -not (Test-Path -LiteralPath $legacyPath)) { throw 'Legacy enrollment has lost its schedule. Resolve it before migration.' }
        if (Test-Path -LiteralPath $legacyPath) {
            $legacy=Read-ScheduleFile $legacyPath
            if ($legacy.Phase -notin @('AwaitingNotice','Pending','Scheduled','Blocked','VerifiedComplete')) { throw 'Legacy firmware operation requires resolution before migration.' }
            $imported=Import-LegacyDeadline $legacy (Get-PackageId $Config) $Policy.WindowHours
        } else { $imported=$null }
        # Only retire this application's known tasks. Hold the old firmware lock
        # throughout, so no old worker can enter staging during the transition.
        foreach ($task in $tasks) {
            $expected=if ($task.TaskName -like '*Controller') { Join-Path $old 'Runtime-v2\Scheduler\Start-Broker.ps1' } else { Join-Path $env:ProgramFiles 'ManagedDellBIOS-v2\Show-BiosUI.ps1' }
            if (@($task.Actions | Where-Object { $_.Arguments -like ('*'+$expected+'*') }).Count -ne 1) { throw 'Legacy task action is unexpected. Manual review required.' }
        }
        foreach ($task in $tasks) { $null=Disable-ScheduledTask -InputObject $task; Stop-ScheduledTask -InputObject $task; Unregister-ScheduledTask -InputObject $task -Confirm:$false }
        if (Test-Path -LiteralPath $legacyPath) {
            $legacy=Read-ScheduleFile $legacyPath
            if ($legacy.Phase -notin @('AwaitingNotice','Pending','Scheduled','Blocked','VerifiedComplete')) { throw 'Legacy phase changed during migration; inspect state before retry.' }
            $imported=Import-LegacyDeadline $legacy (Get-PackageId $Config) $Policy.WindowHours
        }
        if ($null -ne $imported -and -not (Test-Path -LiteralPath $StatePath)) { Save-ScheduleFile $imported $StatePath }
        $oldUI=Join-Path $env:ProgramFiles 'ManagedDellBIOS-v2'
        $oldScript=Join-Path $oldUI 'Show-BiosUI.ps1'
        $pattern='(?i)-File\s+"?'+[regex]::Escape($oldScript)+'"?(?:\s|$)'
        foreach ($process in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
            if ($process.CommandLine -match $pattern) { Stop-Process -Id $process.ProcessId -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $oldUI) {
            Assert-NoCacheLinks $oldUI
            foreach ($item in Get-ChildItem -LiteralPath $oldUI -Recurse -Force) { Assert-NoCacheLinks $item.FullName }
            Remove-Item -LiteralPath $oldUI -Recurse -Force
        }
        Save-ScheduleFile @{Schema=1;RetiredUtc=[datetimeoffset]::UtcNow.ToString('o')} $marker
        Write-BiosLog 'Legacy controller/UI retired. Original deadline preserved where present; old protected data retained for diagnosis.'
        return ,$held.ToArray()
    } catch {
        foreach ($guard in $held) { $guard.Dispose() }
        throw
    }
}
function Invoke-MedelaPrompt([string]$Root,[string]$Mode,[string]$Deadline,[int]$Minutes,[string]$Message='', [switch]$Overdue) {
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $ui=Join-Path $Root 'UI\Show-BiosUI.ps1'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))
    $arguments='-NoProfile -STA -File "{0}" -Mode {1} -DeadlineUtc "{2}" -TimeoutMinutes {3}' -f $ui,$Mode,$Deadline,$Minutes
    if ($encoded) { $arguments+=' -Message64 '+$encoded }
    if ($Overdue) { $arguments+=' -Overdue' }
    $result=Start-ADTProcessAsUser -FilePath $ps -ArgumentList $arguments -CreateNoWindow -NoStreamLogging -PassThru -IgnoreExitCodes '*'
    if ($null -eq $result -or $result.ExitCode -notin @(10,11,12,13,14)) {
        if ($null -ne $result -and $result.StdErr) { Write-BiosLog ('UI error: '+$result.StdErr) }
        throw 'The user prompt did not complete. Test Files\UI\Show-BiosUI.ps1 -Demo in the signed-in user session.'
    }
    return [int]$result.ExitCode
}
function Invoke-MedelaInstaller([string]$Root,[string]$Files,[switch]$PreflightOnly) {
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments='-NoProfile -NonInteractive -File "{0}" -PackageFiles "{1}"' -f (Join-Path $Root 'Runtime\Install-DellBIOS.ps1'),$Files
    if ($PreflightOnly) { $arguments+=' -PreflightOnly' }
    $result=Start-ADTProcess -FilePath $ps -ArgumentList $arguments -WindowStyle Hidden -PassThru -IgnoreExitCodes '*'
    if ($null -eq $result) { throw 'BIOS installer returned no process result.' }
    return [int]$result.ExitCode
}
function Invoke-MedelaRestart($Config) {
    $guard=[IO.File]::Open((Join-Path $script:WorkDir 'Deployment.lock'),'OpenOrCreate','ReadWrite','None')
    try {
        Assert-RestartSafe $Config (Get-State) (Get-BootId)
        # Only this path requests a restart, immediately after its safety checks.
        # No future Windows/Intune/PSADT countdown and no forced app termination.
        & "$env:SystemRoot\System32\shutdown.exe" /r /t 0 /d p:2:17 /c 'Dell BIOS update. Keep AC power connected.' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Windows did not accept the restart request.' }
        Write-BiosLog 'User-confirmed managed restart requested without forcing applications closed.'
    } finally { $guard.Dispose() }
}
function Invoke-MedelaDeployment([string]$Files) {
    $held=@(); $packageLock=$null; $firmwareLock=$null
    try {
        Assert-MedelaHost
        $config=Import-PowerShellDataFile (Join-Path $Files 'BIOS-Config.psd1')
        $policy=Import-PowerShellDataFile (Join-Path $Files 'Simple\Policy.psd1')
        Assert-Config $config; Assert-Model $config; Assert-SimplePolicy $policy
        Assert-Payload (Join-Path $Files $config.FileName) $config
        $null=Get-BiosPassword $config $Files
        $root=Get-MedelaRoot
        Initialize-MedelaCache $root
        $packageLock=[IO.File]::Open((Join-Path $root 'State\Package.lock'),'OpenOrCreate','ReadWrite','None')
        $firmwareLock=[IO.File]::Open((Join-Path $script:WorkDir 'Deployment.lock'),'OpenOrCreate','ReadWrite','None')
        $statePath=Join-Path $root ('State\'+(Get-PackageId $config)+'.json')
        $plan=Get-CacheUpdatePlan $Files $root
        Assert-CacheRefreshSafe (Get-State) (@($plan | Where-Object Reason -ne 'Current').Count -gt 0)
        $held=Enter-LegacyRetirement $root $config $statePath $policy
        Update-MedelaCache $Files $root $plan {param($Message) Write-BiosLog $Message}
        $firmwareLock.Dispose(); $firmwareLock=$null
        $enrollment=$statePath+'.enrolled'
        if ((Test-Path -LiteralPath $enrollment) -and -not (Test-Path -LiteralPath $statePath)) { throw 'Deployment state is missing. Restore it; do not create another deferral window.' }
        $state=if (Test-Path -LiteralPath $statePath) { Read-ScheduleFile $statePath } else { New-SimpleState (Get-PackageId $config) $policy.WindowHours }
        Assert-SimpleState $state (Get-PackageId $config)
        if (-not (Test-Path -LiteralPath $enrollment)) { Save-ScheduleFile @{Schema=3;PackageId=(Get-PackageId $config)} $enrollment }
        $now=Get-SimpleNow $state
        Save-ScheduleFile $state $statePath
        $snapshot=Get-TransactionSnapshot
        if ($snapshot.Busy) { Write-BiosLog 'Retry: another installer/verifier is active.'; return 1618 }
        $txn=$snapshot.Transaction
        if ($null -ne $txn -and $txn.Status -eq 'Verified' -and $txn.SuspendedByUs -ne '0') { throw 'Retry: firmware is verified but protection recovery is still unresolved.' }
        $staged=$null -ne $txn -and $txn.Status -eq 'Staged' -and $txn.BootId -eq (Get-BootId) -and $txn.TargetVersion -eq $config.TargetVersion -and $txn.PayloadHash -eq $config.SHA256
        if ($null -ne $txn -and $txn.Status -eq 'Staged' -and $txn.BootId -ne (Get-BootId)) { Write-BiosLog 'Retry: post-boot verification is pending.'; return 1618 }
        if ($null -ne $txn -and $txn.Status -ne 'Verified' -and -not $staged) { throw 'An earlier BIOS transaction needs verification or recovery. No automatic reflash.' }
        if (-not $staged -and (Convert-BiosVersion (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion.Trim()) -ge (Convert-BiosVersion $config.TargetVersion)) {
            Assert-PostBootHealth $config
            $state.Phase='VerifiedComplete'; Save-ScheduleFile $state $statePath
            Write-BiosLog 'Verified complete: actual BIOS and BitLocker health checked.'; return 0
        }
        $active=Get-ADTLoggedOnUser | Where-Object IsActiveUserSession | Select-Object -First 1
        if (-not $active) { Write-BiosLog 'Retry: no active user. No firmware staging or deadline creation.'; return 1618 }
        if ($state.NextNoticeUtc -and $now -lt [datetimeoffset]::Parse($state.NextNoticeUtc) -and (-not $state.DeadlineUtc -or $now -lt [datetimeoffset]::Parse($state.DeadlineUtc))) { Write-BiosLog 'Retry: reminder cooldown remains in effect.'; return 1618 }
        if (-not $staged) {
            Start-SimpleNotice $state $now
            Save-ScheduleFile $state $statePath
            $choice=Invoke-MedelaPrompt $root Install $state.DeadlineUtc $policy.PromptTimeoutMinutes -Overdue:($now -ge [datetimeoffset]::Parse($state.DeadlineUtc))
            $now=Get-SimpleNow $state
            if ($choice -ne 10) {
                $state.NextNoticeUtc=$now.AddHours($policy.ReminderHours).ToString('o'); Save-ScheduleFile $state $statePath
                Write-BiosLog 'User deferred/closed the notice. Original deadline retained; Intune owns the next attempt.'; return 1618
            }
            $code=Invoke-MedelaInstaller $root $Files
            Write-BiosLog "Installer returned $code."
            if ($code -ne 3010) {
                if ($code -eq 0) { Assert-PostBootHealth $config; $state.Phase='VerifiedComplete'; Save-ScheduleFile $state $statePath; return 0 }
                $null=Invoke-MedelaPrompt $root Info $state.DeadlineUtc $policy.PromptTimeoutMinutes 'The update could not be prepared. Connect AC power, check battery charge and contact IT if the issue continues. IT can inspect Deployment.log. No restart is requested by this prompt.'
                return $code
            }
            $state.Phase='RestartRequired'; $state.NextNoticeUtc=''; Save-ScheduleFile $state $statePath
        }
        $choice=Invoke-MedelaPrompt $root Restart $state.DeadlineUtc $policy.PromptTimeoutMinutes
        if ($choice -eq 12) {
            try { Invoke-MedelaRestart $config }
            catch {
                Write-BiosLog ('Restart safety hold: '+$_.Exception.Message)
                $null=Invoke-MedelaPrompt $root Info $state.DeadlineUtc $policy.PromptTimeoutMinutes 'Restart is waiting for a safety requirement. Connect AC power and charge the battery. Contact IT if this continues. The BIOS will not be staged again.'
            }
        }
        $state.NextNoticeUtc=([datetimeoffset]::UtcNow).AddHours($policy.ReminderHours).ToString('o'); Save-ScheduleFile $state $statePath
        # 3010 never becomes an Intune timer. Staging is not detection/completion.
        # A future Intune invocation offers the restart again without reflashing.
        return 1618
    } catch {
        try { Write-BiosLog $_.Exception.Message } catch { }
        Write-ADTLogEntry -Message ('Medela BIOS deployment stopped: '+$_.Exception.Message) -Severity 3
        if ($_.Exception.Message.StartsWith('Retry:') -or $_.Exception -is [IO.IOException]) { return 1618 }
        return 60001
    } finally {
        if ($null -ne $firmwareLock) { $firmwareLock.Dispose() }
        foreach ($guard in $held) { $guard.Dispose() }
        if ($null -ne $packageLock) { $packageLock.Dispose() }
    }
}
