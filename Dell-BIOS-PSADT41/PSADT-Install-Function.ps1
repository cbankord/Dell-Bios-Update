# Replace ONLY Install-ADTDeployment in the stock Invoke-AppDeployToolkit.ps1.
# Keep the bootstrap/session handling. Intune must use -DeployMode Interactive.
function Install-ADTDeployment {
    $adtSession.InstallPhase = 'Pre-Installation'
    . (Join-Path $adtSession.DirFiles 'Common.ps1')
    $config = Import-PowerShellDataFile (Join-Path $adtSession.DirFiles 'BIOS-Config.psd1')
    Assert-Config $config
    Assert-Model $config
    $state = Get-State
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    $unresolved = $null -ne $state -and $state.Status -ne 'Verified'
    if (-not $unresolved -and $current -ge (Convert-BiosVersion $config.TargetVersion)) {
        Write-ADTLogEntry -Message 'BIOS already meets the target. No prompt or flash required.'
        Close-ADTSession -ExitCode 0
        return
    }

    # Existing transactions go straight to the guarded installer: no new deferrals.
    if (-not $unresolved) {
        $activeUser = Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession } | Select-Object -First 1
        if (-not $activeUser -or $adtSession.IsSilent() -or $adtSession.IsNonInteractive()) {
            Write-ADTLogEntry -Message 'Retry: an active user and Interactive deployment mode are required for the BIOS notice.'
            Close-ADTSession -ExitCode 1618
            return
        }
        $history = Get-ADTDeferHistory
        $lastDeferral = $history | Select-Object -ExpandProperty DeferRunIntervalLastTime -ErrorAction Ignore
        # PSADT 4.1 only checks its interval while deferrals remain. Enforce the
        # cooldown after the THIRD deferral too, without consuming another deferral.
        if ($null -ne $lastDeferral) {
            $nextPrompt = ([datetime]$lastDeferral).ToUniversalTime().AddHours(12)
            if ([datetime]::UtcNow -lt $nextPrompt) {
                Write-ADTLogEntry -Message "Retry: BIOS notice cooldown ends at $($nextPrompt.ToString('o'))."
                Close-ADTSession -ExitCode 1618
                return
            }
        }
        $strings = Get-ADTStringTable
        $originalMessage = $strings.CloseAppsPrompt.CustomMessage
        $strings.CloseAppsPrompt.CustomMessage = @"
A Dell BIOS update needs to be installed.

Before continuing, connect AC power and charge the battery to at least $($config.MinimumBatteryPercent)% (above 50%). These requirements are checked before installation.

You may defer up to three times, with at least 12 hours between prompts after each deferral.

After the update is prepared, you have 12 hours to restart. Save your work and keep AC power connected throughout the restart and BIOS update.
"@
        $welcome = @{
            Title = 'Dell BIOS update'
            Subtitle = 'Please review the power and restart requirements.'
            AllowDefer = $true
            DeferTimes = 3
            DeferRunInterval = New-TimeSpan -Hours 12
            CustomText = $true
        }
        $remaining = $history | Select-Object -ExpandProperty DeferTimesRemaining -ErrorAction Ignore
        if ($null -ne $remaining -and [int]$remaining -le 0) {
            # Final 10-minute notice; Continue still runs every installer safety gate.
            $welcome.ForceCountdown = 600
        }
        try { Show-ADTInstallationWelcome @welcome }
        finally { $strings.CloseAppsPrompt.CustomMessage = $originalMessage }
    }

    $adtSession.InstallPhase = 'Installation'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not [Environment]::Is64BitProcess) {
        $powerShell = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $adtSession.DirFiles 'Install-DellBIOS.ps1')
    $result = Start-ADTProcess -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -IgnoreExitCodes '*'
    if ($null -eq $result) { throw 'BIOS deployment returned no process result.' }

    if ($result.ExitCode -eq 3010) {
        $adtSession.InstallPhase = 'Post-Installation'
        # A notification failure must not hide successful staging from Intune.
        try {
            $state = Get-State
            if ($null -eq $state -or $state.Status -ne 'Staged' -or $state.BootId -ne (Get-BootId) -or
                $state.TargetVersion -ne $config.TargetVersion -or $state.PayloadHash -ne $config.SHA256) {
                throw 'No matching staged transaction for the restart prompt.'
            }
            $staged = [datetimeoffset]::Parse($state.StagedUtc)
            if ($staged -gt [datetimeoffset]::UtcNow) { throw 'Staging timestamp is in the future; check the device clock.' }
            $seconds = [uint32][Math]::Max(1, [Math]::Min(43200, [Math]::Ceiling(($staged.AddHours(12) - [datetimeoffset]::UtcNow).TotalSeconds)))
            $activeUser = Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession } | Select-Object -First 1
            if ($activeUser -and -not $adtSession.IsSilent() -and -not $adtSession.IsNonInteractive()) {
                Show-ADTInstallationRestartPrompt -Title 'Restart required for Dell BIOS update' `
                    -Subtitle 'Save your work and keep AC power connected. Restart occurs when the countdown expires.' `
                    -CountdownSeconds $seconds -CountdownNoHideSeconds ([uint32][Math]::Min(900, $seconds))
            } else {
                Write-ADTLogEntry -Message 'Restart UI unavailable; Intune must enforce the configured 720-minute restart grace period.'
            }
        } catch {
            Write-ADTLogEntry -Message ('Restart prompt unavailable; preserving 3010 for Intune restart enforcement. ' + $_.Exception.Message) -Severity 2
        }
    }
    Close-ADTSession -ExitCode $result.ExitCode
}
