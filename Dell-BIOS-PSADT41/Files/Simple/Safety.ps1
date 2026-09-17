# MedelaBIOS-FileVersion: 2.2.0
function Get-TransactionSnapshot {
    # The installer and verifier hold this lock through all multi-value writes.
    try { $guard = [IO.File]::Open((Join-Path $script:WorkDir 'Deployment.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { return @{ Busy = $true; Transaction = $null } }
    try { return @{ Busy = $false; Transaction = Get-State } }
    finally { $guard.Dispose() }
}
function Assert-PostBootHealth($Config) {
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    if ($current -lt (Convert-BiosVersion $Config.TargetVersion)) { throw 'Actual BIOS is below target.' }
    Import-Module BitLocker -ErrorAction Stop
    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($volume.VolumeStatus -notin @('FullyEncrypted','FullyDecrypted')) { throw 'Encryption is not stable.' }
    if ($volume.VolumeStatus -eq 'FullyEncrypted' -and $volume.ProtectionStatus -ne 'On') { throw 'BitLocker protection must be On.' }
}
function Assert-RestartSafe($Config, $Transaction, [string]$Boot) {
    if ($null -eq $Transaction -or $Transaction.Status -ne 'Staged' -or
        $Transaction.TargetVersion -ne $Config.TargetVersion -or $Transaction.PayloadHash -ne $Config.SHA256 -or
        $Transaction.BootId -ne $Boot) { throw 'Restart blocked: staged transaction does not match this boot and package.' }
    Assert-Model $Config
    Assert-Power $Config
    Import-Module BitLocker -ErrorAction Stop
    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($volume.LockStatus -ne 'Unlocked') { throw 'Restart blocked: OS volume is not unlocked.' }
    if ($volume.VolumeStatus -eq 'FullyEncrypted') {
        if ($Transaction.SuspendedByUs -ne '1' -or $volume.ProtectionStatus -ne 'Off') {
            throw 'Restart blocked: expected owned BitLocker suspension is not present. Contact IT.'
        }
    } elseif ($volume.VolumeStatus -ne 'FullyDecrypted' -or $Transaction.SuspendedByUs -ne '0') { throw 'Restart blocked: unexpected BitLocker state.' }
}
