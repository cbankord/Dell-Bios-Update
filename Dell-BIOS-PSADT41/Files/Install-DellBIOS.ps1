#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$PreflightOnly)

. "$PSScriptRoot\Common.ps1"
$exitCode = 60001
$lock = $null
$ownedSuspension = $false
$launched = $false
$knownFailure = $false
$createdTransaction = $false
$biosPassword = $null
try {
    if (-not [Environment]::Is64BitProcess) { throw '64-bit Windows PowerShell is required.' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Run as LocalSystem, including pilot tests.' }
    $config = Import-PowerShellDataFile "$PSScriptRoot\BIOS-Config.psd1"
    Initialize-SecureDirectory
    Assert-Config $config
    Assert-Model $config
    try { $lock = [IO.File]::Open((Join-Path $script:WorkDir 'Deployment.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Retry: another deployment or verification is running.' }
    $boot = Get-BootId
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion.Trim()
    $target = Convert-BiosVersion $config.TargetVersion
    $state = Get-State
    # Never replace an unresolved transaction, even when deploying a newer package.
    if ($state -and $state.Status -ne 'Verified') {
        if ($current -ge (Convert-BiosVersion $state.TargetVersion)) {
            throw 'Previous transaction needs verification. Run the registered verification task, then retry.'
        }
        if ($state.Status -eq 'Staged' -and $state.BootId -eq $boot -and $state.PayloadHash -eq $config.SHA256 -and $state.TargetVersion -eq $config.TargetVersion) {
            Write-BiosLog 'Previously staged during this boot; updater will not run again. Restart is still required.'
            $exitCode = 3010
            return
        }
        throw "Unresolved BIOS transaction ($($state.Status)). Inspect logs before any further flash attempt."
    }
    if ($current -ge $target) {
        Write-BiosLog "Already compliant: current=$current target=$target. No downgrade."
        $exitCode = 0
        return
    }
    if ($current -lt (Convert-BiosVersion $config.MinimumCurrentVersion)) { throw 'Install the Dell prerequisite BIOS version first.' }
    $biosPassword = Get-BiosPassword $config $PSScriptRoot
    $payload = Join-Path $PSScriptRoot $config.FileName
    Assert-Payload $payload $config
    Assert-NoPendingReboot
    Assert-Power $config
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    if ($null -eq $disk -or $disk.FreeSpace -lt ($config.MinimumFreeSpaceGB * 1GB)) { throw 'Retry: insufficient free space on system volume.' }
    Import-Module BitLocker -ErrorAction Stop
    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ($volume.LockStatus -ne 'Unlocked') { throw 'OS volume is not unlocked.' }
    if ($volume.VolumeStatus -notin @('FullyEncrypted','FullyDecrypted')) { throw 'Retry: BitLocker encryption/decryption is in progress or paused.' }
    $encrypted = $volume.VolumeStatus -eq 'FullyEncrypted'
    $protectors = @()
    if ($encrypted) {
        if ($volume.ProtectionStatus -ne 'On') { throw 'BitLocker was already suspended. Resolve that condition before deployment.' }
        $protectors = @($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        if (-not $protectors.Count) { throw 'No recovery-password protector exists. Remediate encryption policy first.' }
        $backupCommand = if ($config.EscrowDestination -eq 'EntraID') { 'BackupToAAD-BitLockerKeyProtector' } else { 'Backup-BitLockerKeyProtector' }
        $null = Get-Command $backupCommand -ErrorAction Stop
    }
    if ($PreflightOnly) {
        Write-BiosLog "Preflight passed for $current -> $target. No escrow, suspension, task registration or flash performed."
        $exitCode = 0
        return
    }
    # Make a protected, durable copy before changing BitLocker or invoking firmware.
    $cachedExe = Join-Path $script:WorkDir $config.FileName
    Copy-Item -LiteralPath $payload -Destination $cachedExe -Force
    foreach ($file in @('Common.ps1','Verify-AfterReboot.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $script:WorkDir -Force
    }
    Assert-Payload $cachedExe $config
    if ($encrypted) {
        foreach ($protector in $protectors) {
            # Suppress returned volume objects: they can contain recovery passwords.
            $null = & $backupCommand -MountPoint $env:SystemDrive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
        }
        Write-BiosLog "Recovery-key backup command succeeded for $($config.EscrowDestination)."
    }
    $values = @{
        Status = 'Preparing'; TargetVersion = $config.TargetVersion; PreviousVersion = $current.ToString()
        PayloadHash = $config.SHA256; BootId = $boot; StartedUtc = [datetime]::UtcNow.ToString('o')
        StagedUtc = ''; SuspendedByUs = '0'; LastDellExitCode = ''; Verification = 'Pending'
    }
    $createdTransaction = $true
    foreach ($name in $values.Keys) { Set-StateValue $name $values[$name] }
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:WorkDir 'Verify-AfterReboot.ps1')
    $action = New-ScheduledTaskAction -Execute $ps -Argument $taskArgs
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT5M'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 30)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger @($startup,$repeat) -Settings $settings -Principal $principal -Force
    Assert-NoPendingReboot
    Assert-Power $config
    if ($encrypted) {
        # Record intent before suspension so a crash cannot lose ownership tracking.
        Set-StateValue 'SuspendedByUs' '1'
        $ownedSuspension = $true
        $null = Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount $config.BitLockerRebootCount -ErrorAction Stop
        if ((Get-BitLockerVolume -MountPoint $env:SystemDrive).ProtectionStatus -ne 'Off') { throw 'BitLocker did not suspend.' }
    }
    Assert-Power $config
    Set-StateValue 'Status' 'Launching'
    $dellLog = Join-Path $script:WorkDir ('Dell-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-BiosLog "Launching approved Dell BIOS $current -> $target. Reboot is managed by Intune."
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $cachedExe
    $startInfo.Arguments = '/s /l="{0}"' -f $dellLog
    if ($config.BiosPasswordRequired) {
        $startInfo.Arguments += ' /p=' + (ConvertTo-WindowsQuotedArgument $biosPassword)
    }
    $startInfo.WorkingDirectory = $script:WorkDir
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    # No /r, /f, /forceit, /bls, process timeout or forced termination. Never log arguments.
    # Once launch is attempted, treat an exception as potentially staged firmware.
    $launched = $true
    if (-not $process.Start()) { throw 'Dell process did not start.' }
    $process.WaitForExit()
    $dellCode = $process.ExitCode
    $process.Dispose()
    Set-StateValue 'LastDellExitCode' $dellCode
    Write-BiosLog "Dell updater returned $dellCode."
    if ($dellCode -in @(0,2)) {
        Set-StateValue 'StagedUtc' ([datetime]::UtcNow.ToString('o'))
        Set-StateValue 'Status' 'Staged'
        Write-BiosLog 'BIOS update staged successfully; restart required (3010). Actual firmware will be verified after boot.'
        $exitCode = 3010
    } else {
        $knownFailure = $dellCode -in @(1,3,4,5,7,8,9,10)
        Set-StateValue 'Status' 'FailedOrAmbiguous'
        throw "Dell update failed or returned an unexpected code: $dellCode. See Dell log."
    }
} catch {
    $message = $_.Exception.Message
    if ($message.StartsWith('Retry:') -and -not $launched) { $exitCode = 1618 } else { $exitCode = 60001 }
    if (Test-Path -LiteralPath $script:WorkDir) {
        try { Write-BiosLog $message } catch { }
    }
    # A successful staging operation must stay suspended until its reboot.
    # Unknown results stay guarded; the post-boot task handles protection recovery.
    if ($ownedSuspension -and ((-not $launched) -or $knownFailure)) {
        try {
            $null = Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop
            if ((Get-BitLockerVolume -MountPoint $env:SystemDrive).ProtectionStatus -ne 'On') { throw 'Protection is not On.' }
            Set-StateValue 'SuspendedByUs' '0'
            Write-BiosLog 'Restored BitLocker after a pre-launch or documented updater failure.'
        } catch {
            $exitCode = 60001
            try { Write-BiosLog 'BitLocker recovery needs attention; verification task retained.' } catch { }
        }
    }
    # A transient check failed after task/state creation, before launch: safe retry.
    if ($createdTransaction -and -not $launched -and $null -ne $lock -and (Test-Path $script:StateKey)) {
        # Read defensively here so a damaged key cannot mask the original error.
        $saved = Get-ItemProperty -LiteralPath $script:StateKey -ErrorAction SilentlyContinue
        if ($null -ne $saved -and $null -ne $saved.PSObject.Properties['Status'] -and
            $null -ne $saved.PSObject.Properties['SuspendedByUs'] -and $saved.Status -eq 'Preparing' -and $saved.SuspendedByUs -eq '0') {
            Remove-Item -LiteralPath $script:StateKey -Recurse -Force
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
} finally {
    $biosPassword = $null
    if ($null -ne $lock) { $lock.Dispose() }
    exit $exitCode
}
