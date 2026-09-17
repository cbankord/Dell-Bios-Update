# MedelaBIOS-FileVersion: 4.0.0
# Called only by the trusted SYSTEM deployment while it holds Package.lock.
function Get-MedelaScheduledPackagePath([string]$Root) { Join-Path $Root 'State/ScheduledPackage' }
function Get-MedelaScheduledPackage([string]$Root) {
    $path=Join-Path (Get-MedelaScheduledPackagePath $Root) 'Ready.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Assert-NoCacheLinks $path
    $record=Read-ScheduleFile $path
    if ($record.Schema -ne 1 -or $record.PackageId -notmatch '^v2-\d+(?:\.\d+){1,3}-[a-f0-9]{64}$') { throw 'Invalid retained schedule package metadata. Preserve it for IT review.' }
    return $record
}
function Get-MedelaInstallTask([string]$Root) {
    $task=Get-ScheduledTask -TaskName 'ManagedDellBIOS-ScheduledInstall' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    $exe=Join-Path (Join-Path (Get-MedelaScheduledPackagePath $Root) 'Source') 'Invoke-AppDeployToolkit.exe'
    if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $exe -or
        $task.Actions[0].Arguments -cne '-DeploymentType Install -DeployMode Silent' -or
        $task.Principal.UserId -notin @('SYSTEM','S-1-5-18')) { throw 'The scheduled-install task has an unexpected action or owner. It was not changed.' }
    return $task
}
function Remove-MedelaInstallTask([string]$Root) {
    $task=Get-MedelaInstallTask $Root
    if ($null -ne $task) {
        # Unregister future triggers; never Stop-ScheduledTask/kill a live updater.
        Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop
        Write-BiosLog 'Temporary scheduled-install task retired; any running firmware process is left alone.'
    }
}
function Register-MedelaInstallTask([string]$Root,[datetimeoffset]$When) {
    $null=Get-MedelaInstallTask $Root # Reject a conflicting task before mutation.
    if ($null -eq (Get-MedelaScheduledPackage $Root)) { throw 'A complete protected package is required before scheduling.' }
    $source=Join-Path (Get-MedelaScheduledPackagePath $Root) 'Source'
    $action=New-ScheduledTaskAction -Execute (Join-Path $source 'Invoke-AppDeployToolkit.exe') -Argument '-DeploymentType Install -DeployMode Silent' -WorkingDirectory $source
    $trigger=New-ScheduledTaskTrigger -Once -At $When.LocalDateTime -RepetitionInterval ([timespan]::FromMinutes(15))
    # Pin an instant, independent of subsequent time-zone/DST changes.
    $trigger.StartBoundary=$When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $null=Register-ScheduledTask -TaskName 'ManagedDellBIOS-ScheduledInstall' -TaskPath '\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop
    Write-BiosLog ('Installation scheduled at {0}; temporary task retries unmet prerequisites every 15 minutes.' -f $When.ToUniversalTime().ToString('o'))
}
function Sync-MedelaInstallTask([string]$Root,$State) {
    if (-not $State.ScheduledInstallUtc) { return }
    $retained=Get-MedelaScheduledPackage $Root
    if ($null -eq $retained -or $retained.PackageId -ne $State.PackageId) { throw 'Scheduled installation has lost its protected package. Preserve the original deadline and investigate.' }
    $task=Get-MedelaInstallTask $Root
    $when=[datetimeoffset]::Parse($State.ScheduledInstallUtc)
    $matches=$false
    if ($null -ne $task -and @($task.Triggers).Count -eq 1) {
        try { $matches=[datetimeoffset]::Parse($task.Triggers[0].StartBoundary) -eq $when } catch { $matches=$false }
    }
    if (-not $matches) { Register-MedelaInstallTask $Root $when }
}
function Assert-MedelaScheduleChoice([string]$Text,$State,[datetimeoffset]$Now) {
    if ($Text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$' -or -not $State.DeadlineUtc) { throw 'Invalid installation schedule response.' }
    $when=[datetimeoffset]::Parse($Text)
    if ($Now -ge [datetimeoffset]::Parse($State.DeadlineUtc) -or $when -le $Now -or $when -gt [datetimeoffset]::Parse($State.DeadlineUtc)) { throw 'Installation time must be in the future and within the original deadline.' }
    return $when
}
function New-MedelaScheduledPackage([string]$Root,[string]$Files,$Config) {
    $slot=Get-MedelaScheduledPackagePath $Root
    $existing=Get-MedelaScheduledPackage $Root
    $id=Get-PackageId $Config
    if ($null -ne $existing) {
        if ($existing.PackageId -ne $id) { throw 'Another BIOS package already owns the pending installation schedule.' }
        return
    }
    $source=[IO.Path]::GetFullPath((Split-Path $Files -Parent)).TrimEnd('\','/')
    $slotFull=[IO.Path]::GetFullPath($slot).TrimEnd('\','/')
    if ($source.Equals($slotFull,[StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($slotFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        $slotFull.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Scheduled-package source and destination overlap. Preserve them for IT review.' }
    if ($null -ne (Get-MedelaInstallTask $Root)) { throw 'A task exists without complete scheduled-package metadata. Preserve it for IT review.' }
    if (Test-Path -LiteralPath $slot) {
        Assert-NoCacheLinks $slot
        foreach ($item in Get-ChildItem -LiteralPath $slot -Recurse -Force) { Assert-NoCacheLinks $item.FullName }
        Remove-Item -LiteralPath $slot -Recurse -Force # Interrupted, unpublished copy only.
    }
    foreach ($name in @('Invoke-AppDeployToolkit.exe','Invoke-AppDeployToolkit.ps1','PSAppDeployToolkit/PSAppDeployToolkit.psd1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw 'Scheduling requires the complete generated PSADT Source package.' }
    }
    Assert-NoCacheLinks $source
    $items=@(Get-ChildItem -LiteralPath $source -Recurse -Force)
    foreach ($item in $items) { Assert-NoCacheLinks $item.FullName }
    $bytes=($items|Where-Object {-not $_.PSIsContainer}|Measure-Object Length -Sum).Sum
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Root))
    if ($drive.AvailableFreeSpace -lt ($bytes+[long]$Config.MinimumFreeSpaceGB*1GB)) { throw 'Retry: insufficient space to retain the scheduled package safely.' }
    Protect-MedelaDirectory $slot
    $destination=Join-Path $slot 'Source'; Protect-MedelaDirectory $destination
    $ready=$false
    try {
        Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
        foreach ($item in Get-ChildItem -LiteralPath $destination -Recurse -Force) { Assert-NoCacheLinks $item.FullName }
        Protect-MedelaDirectory $destination
        # Compare copied bytes, without writing password contents or its hash to
        # a manifest/log. The entire retained package is SYSTEM/Admin only.
        foreach ($file in $items|Where-Object {-not $_.PSIsContainer}) {
            $relative=$file.FullName.Substring($source.TrimEnd('\','/').Length+1)
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $destination $relative) -Algorithm SHA256).Hash) { throw 'Retained package copy did not verify.' }
        }
        $copiedFiles=Join-Path $destination 'Files'
        $null=Read-ApprovedRuntimeManifest $copiedFiles
        Assert-Payload (Join-Path $copiedFiles $Config.FileName) $Config
        Save-ScheduleFile @{Schema=1;PackageId=$id;CreatedUtc=[datetimeoffset]::UtcNow.ToString('o')} (Join-Path $slot 'Ready.json')
        $ready=$true
        Write-BiosLog 'Complete approved PSADT package retained privately for scheduled installation; no firmware staging or BitLocker suspension performed.'
    } finally { if (-not $ready -and (Test-Path -LiteralPath $slot)) { Remove-Item -LiteralPath $slot -Recurse -Force } }
}
function Save-MedelaInstallSchedule([string]$Root,[string]$Files,$Config,$Policy,$State,[string]$StatePath,[string]$RequestedUtc) {
    if (-not (Get-AllowScheduleLater $Policy)) { throw 'Installation scheduling is disabled for this package. Existing appointments and the original deadline remain unchanged.' }
    $null=Assert-MedelaScheduleChoice $RequestedUtc $State (Get-SimpleNow $State)
    New-MedelaScheduledPackage $Root $Files $Config
    $when=Assert-MedelaScheduleChoice $RequestedUtc $State (Get-SimpleNow $State)
    $State.ScheduledInstallUtc=$when.ToUniversalTime().ToString('o')
    $State.Phase='Scheduled'; $State.NextNoticeUtc=([datetimeoffset]::UtcNow).AddHours($Policy.ReminderHours).ToString('o')
    # Persist intent before registering. A retry repairs missing/stale task timing;
    # the task always rechecks this state before doing any firmware work.
    Save-ScheduleFile $State $StatePath
    Register-MedelaInstallTask $Root $when
}
function Clear-MedelaScheduledPackage([string]$Root,[string]$PackageId,[string]$RunningFiles='') {
    $slot=Get-MedelaScheduledPackagePath $Root
    $retained=Get-MedelaScheduledPackage $Root
    if ($null -eq $retained) {
        if (Test-Path -LiteralPath $slot) {
            Assert-MedelaOwnedPath $slot; Assert-NoCacheLinks $slot
            # Finish a cleanup interrupted after its final metadata deletion.
            # Missing metadata with any remaining data is not safe to infer.
            if (@(Get-ChildItem -LiteralPath $slot -Force).Count) { throw 'Retained package metadata is missing; preserve remaining files for IT review.' }
            Remove-Item -LiteralPath $slot -Force -ErrorAction Stop
        }
        return
    }
    if ($retained.PackageId -ne $PackageId) { throw 'Scheduled package belongs to another deployment; it was preserved.' }
    Remove-MedelaInstallTask $Root
    # A task can discover that firmware was updated independently. Do not delete
    # its own running framework. Detection requests later Intune cleanup instead.
    if ($RunningFiles -and [IO.Path]::GetFullPath($RunningFiles).StartsWith([IO.Path]::GetFullPath($slot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return }
    Assert-MedelaOwnedPath $slot; Assert-NoCacheLinks $slot
    foreach ($item in Get-ChildItem -LiteralPath $slot -Recurse -Force) { Assert-NoCacheLinks $item.FullName }
    if (@(Get-ChildItem -LiteralPath $slot -Force | Where-Object Name -notin @('Source','Ready.json','Ready.json.new')).Count) { throw 'Unexpected retained package contents; preserve for IT review.' }
    # Delete the identifying marker last. If a file is locked during cleanup,
    # the next verifier can still recognize and remove remaining credentials.
    $source=Join-Path $slot Source
    if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction Stop }
    $pending=Join-Path $slot 'Ready.json.new'
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction Stop }
    Remove-Item -LiteralPath (Join-Path $slot 'Ready.json') -Force -ErrorAction Stop
    Remove-Item -LiteralPath $slot -Force -ErrorAction Stop
    Write-BiosLog 'Retained scheduled package removed after definitive verification; original deadline and firmware recovery records preserved.'
}
