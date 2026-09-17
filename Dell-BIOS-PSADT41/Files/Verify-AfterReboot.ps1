# MedelaBIOS-FileVersion: 2.2.0
#requires -Version 5.1
#requires -RunAsAdministrator
. "$PSScriptRoot\Common.ps1"
$lock = $null
try {
    $lock = [IO.File]::Open((Join-Path $script:WorkDir 'Deployment.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $state = Get-State
    if ($null -eq $state) { exit 0 }
    # Do not resume protection over a capsule staged for the next restart.
    if ($state.BootId -eq (Get-BootId)) { exit 0 }
    if ($state.SuspendedByUs -eq '1') {
        Import-Module BitLocker
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
        if ($volume.VolumeStatus -ne 'FullyEncrypted') { throw 'Unexpected OS volume encryption state.' }
        if ($volume.ProtectionStatus -ne 'On') { $null = Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop }
        if ((Get-BitLockerVolume -MountPoint $env:SystemDrive).ProtectionStatus -ne 'On') { throw 'BitLocker protection did not resume.' }
        Set-StateValue 'SuspendedByUs' '0'
        Write-BiosLog 'BitLocker protection verified On after restart.'
    }
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion.Trim()
    if ($current -ge (Convert-BiosVersion $state.TargetVersion)) {
        Set-StateValue 'Status' 'Verified'
        Set-StateValue 'Verification' "Passed: BIOS $current"
        Write-BiosLog "Post-boot verification passed: BIOS $current."
    } else {
        Set-StateValue 'Status' 'FailedAfterReboot'
        Set-StateValue 'Verification' "Failed: BIOS $current; expected $($state.TargetVersion)"
        Write-BiosLog "POST-BOOT FAILURE: BIOS $current; expected $($state.TargetVersion). Automatic reflashing blocked."
    }
    Set-StateValue 'VerifiedUtc' ([datetime]::UtcNow.ToString('o'))
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
} catch {
    try { Write-BiosLog ('Verification requires attention: ' + $_.Exception.Message) } catch { }
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
