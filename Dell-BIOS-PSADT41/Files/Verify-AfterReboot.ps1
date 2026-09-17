# MedelaBIOS-FileVersion: 3.1.0
#requires -Version 5.1
#requires -RunAsAdministrator
. "$PSScriptRoot\Common.ps1"
function Remove-MedelaVerifiedUI([string]$WorkDir,[string]$OldBoot,[string]$CurrentBoot) {
    if ($OldBoot -eq $CurrentBoot) { return }
    $live=Join-Path (Split-Path $WorkDir -Parent) 'UI/Live'
    if (-not (Test-Path -LiteralPath $live)) { return }
    # Do not touch a current-boot prompt or any firmware/recovery state. Only
    # known status files belonging to the verified transaction's old boot qualify.
    $ancestor=[IO.Path]::GetFullPath($live)
    while ($ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in UI cleanup path.' }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    foreach ($folder in Get-ChildItem -LiteralPath $live -Directory -Force) {
        if ($folder.Name -notmatch '^[a-f0-9]{32}$' -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $items=@(Get-ChildItem -LiteralPath $folder.FullName -Force)
        if (@($items | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin @('Status.json','Status.json.new') }).Count) { continue }
        $statusPath=Join-Path $folder.FullName 'Status.json'
        if (-not (Test-Path -LiteralPath $statusPath)) { continue }
        $data=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($data.Schema -eq 1 -and $data.Session -eq $folder.Name -and $null -ne $data.PSObject.Properties['BootId'] -and [string]$data.BootId -eq $OldBoot) {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force
        }
    }
}
$lock = $null; $packageLock = $null
try {
    $root=Split-Path $script:WorkDir -Parent
    $scheduled=Test-Path -LiteralPath (Join-Path $root 'State/ScheduledPackage')
    if ($scheduled) {
        # Same lock order as the deployment, so cleanup cannot race a reschedule,
        # runtime replacement or a running retained PSADT framework.
        $packageLock=[IO.File]::Open((Join-Path $root 'State/Package.lock'),'OpenOrCreate','ReadWrite','None')
        foreach ($name in @('Cache.ps1','State.ps1','Scheduling.ps1')) { . (Join-Path $root ('Runtime/'+$name)) }
    }
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
    try { Remove-MedelaVerifiedUI $script:WorkDir $state.BootId (Get-BootId) }
    catch { Write-BiosLog ('Transient UI cleanup needs a later package attempt: '+$_.Exception.Message) }
    if ($scheduled) {
        $packageId=Get-PackageId @{TargetVersion=$state.TargetVersion;SHA256=$state.PayloadHash}
        Clear-MedelaScheduledPackage $root $packageId
    }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
} catch {
    try { Write-BiosLog ('Verification requires attention: ' + $_.Exception.Message) } catch { }
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if ($null -ne $packageLock) { $packageLock.Dispose() }
}
