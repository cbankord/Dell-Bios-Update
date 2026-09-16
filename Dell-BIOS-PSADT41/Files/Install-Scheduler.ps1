#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Scheduler\Core.ps1"
. "$PSScriptRoot\Scheduler\Windows.ps1"
$setupLock = $null
try {
    if (-not [Environment]::Is64BitProcess -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'Run under SYSTEM in 64-bit Windows PowerShell.' }
    Initialize-SecureDirectory
    $setupLock = [IO.File]::Open((Join-Path $script:WorkDir 'Setup-v2.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $config = Import-PowerShellDataFile "$PSScriptRoot\BIOS-Config.psd1"
    $policy = Import-PowerShellDataFile "$PSScriptRoot\Scheduler\Policy.psd1"
    Assert-Config $config; Assert-Model $config; Assert-SchedulerPolicy $policy
    Assert-Payload (Join-Path $PSScriptRoot $config.FileName) $config
    $null = Get-BiosPassword $config $PSScriptRoot
    $packageId = Get-PackageId $config
    $statePath = Join-Path $script:WorkDir 'Schedule-v2.json'
    $runtime = Join-Path $script:WorkDir 'Runtime-v2'
    $uiRoot = Join-Path $env:ProgramFiles 'ManagedDellBIOS-v2'
    $enrollmentPath = Join-Path $script:WorkDir 'Enrollment-v2.json'
    if ((Test-Path -LiteralPath $enrollmentPath) -and -not (Test-Path -LiteralPath $statePath)) {
        throw 'An enrolled scheduler has lost its state. Manual recovery is required; its deadline cannot be recreated.'
    }
    $existing = $null
    if (Test-Path -LiteralPath $statePath) {
        $existing = Read-ScheduleFile $statePath
        Assert-ScheduleState $existing $existing.PackageId
        if ($existing.PackageId -eq $packageId) {
            # Same package: preserve state and live files. Repair task activation only.
            if (-not (Test-Path -LiteralPath "$runtime\Scheduler\Start-Broker.ps1") -or -not (Test-Path -LiteralPath "$uiRoot\Show-BiosUI.ps1")) { throw 'Enrolled runtime is incomplete. Manual repair is required.' }
            Register-V2Tasks $runtime $uiRoot
            Start-ScheduledTask -TaskName 'ManagedDellBIOS-v2-Controller'
            Start-ScheduledTask -TaskName 'ManagedDellBIOS-v2-UserUI' -ErrorAction SilentlyContinue
            Write-SchedulerLog 'Same deployment already enrolled; original deadline and schedule preserved.'
            exit 0
        }
        if ($existing.Phase -ne 'VerifiedComplete') { throw 'A different v2 deployment is unresolved. Complete it before enrolling another package.' }
        Stop-ScheduledTask -TaskName 'ManagedDellBIOS-v2-Controller' -ErrorAction Stop
        Stop-ScheduledTask -TaskName 'ManagedDellBIOS-v2-UserUI' -ErrorAction SilentlyContinue
    }
    $snapshot = Get-TransactionSnapshot
    if ($snapshot.Busy -or ($null -ne $snapshot.Transaction -and $snapshot.Transaction.Status -ne 'Verified')) {
        throw 'An existing firmware transaction must finish or be investigated before v2 enrollment.'
    }
    if ($null -ne $existing) {
        Copy-Item -LiteralPath $statePath -Destination ($statePath + '.' + (Get-Date -Format 'yyyyMMddHHmmss') + '.archive')
    }
    # SYSTEM/Admin-only durable execution tree; no dependency on Intune cache lifetime.
    $null = New-Item -ItemType Directory -Path $runtime -Force
    foreach ($name in @('Common.ps1','BIOS-Config.psd1','Install-DellBIOS.ps1','Verify-AfterReboot.ps1',$config.FileName)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $runtime -Force
    }
    if ($config.BiosPasswordRequired) { Copy-Item -LiteralPath "$PSScriptRoot\BIOS-Password.psd1" -Destination $runtime -Force }
    elseif (Test-Path -LiteralPath "$runtime\BIOS-Password.psd1") { Remove-Item -LiteralPath "$runtime\BIOS-Password.psd1" -Force }
    $null = New-Item -ItemType Directory -Path "$runtime\Scheduler" -Force
    Copy-Item -Path "$PSScriptRoot\Scheduler\*" -Destination "$runtime\Scheduler" -Recurse -Force
    Assert-Payload (Join-Path $runtime $config.FileName) $config

    # UI assets are readable/executable by users, never writable by standard users.
    if (Test-Path -LiteralPath $uiRoot) {
        foreach ($item in @((Get-Item -LiteralPath $uiRoot -Force)) + @(Get-ChildItem -LiteralPath $uiRoot -Force -Recurse)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in UI deployment path.' }
        }
    } else { $null = New-Item -ItemType Directory -Path $uiRoot }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
    Set-Acl -LiteralPath $uiRoot -AclObject $acl
    Copy-Item -Path "$PSScriptRoot\UI\*" -Destination $uiRoot -Recurse -Force
    Copy-Item -LiteralPath "$PSScriptRoot\Scheduler\Transport.ps1" -Destination $uiRoot -Force
    # Force descendants to inherit the protected parent; strip explicit write grants.
    foreach ($item in Get-ChildItem -LiteralPath $uiRoot -Force -Recurse) {
        $childAcl = if ($item.PSIsContainer) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $childAcl.SetAccessRuleProtection($false, $false)
        $childAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
        Set-Acl -LiteralPath $item.FullName -AclObject $childAcl
    }
    Save-ScheduleFile (New-ScheduleState $packageId ([datetimeoffset]::UtcNow)) $statePath
    Save-ScheduleFile @{ PackageId=$packageId; Schema=2 } $enrollmentPath
    Register-V2Tasks $runtime $uiRoot
    Write-SchedulerLog "Enrolled $packageId. Deadline will start on the first delivered notice."
    Start-ScheduledTask -TaskName 'ManagedDellBIOS-v2-Controller'
    # If no user is logged on, the logon/repetition triggers deliver the UI later.
    Start-ScheduledTask -TaskName 'ManagedDellBIOS-v2-UserUI' -ErrorAction SilentlyContinue
    exit 0
} catch {
    try { Write-SchedulerLog ('Enrollment failed: ' + $_.Exception.Message) } catch { }
    exit 60001
} finally {
    if ($null -ne $setupLock) { $setupLock.Dispose() }
}
