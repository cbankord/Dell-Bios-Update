# MedelaBIOS-FileVersion: 2.2.0
# Windows PowerShell 5.1; deliberately rejects legacy Axx version strings.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$script:StateKey = 'HKLM:\SOFTWARE\ManagedDellBIOS'
$script:WorkDir = Join-Path $env:ProgramData 'Medela\DellBIOS\Recovery'
$script:TaskName = 'ManagedDellBIOS-VerifyAndResume'

function Convert-BiosVersion([string]$Text) {
    if ($Text -notmatch '^\d+\.\d+(\.\d+){0,2}$') { throw "Unsupported BIOS version format: $Text" }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts -join '.')
}
function Assert-Config($Config) {
    if ($Config.PackageReviewed -ne $true) { throw 'Review BIOS-Config.psd1 and set PackageReviewed to true.' }
    $null = Convert-BiosVersion $Config.TargetVersion
    if ((Convert-BiosVersion $Config.MinimumCurrentVersion) -gt (Convert-BiosVersion $Config.TargetVersion)) { throw 'Invalid minimum version.' }
    if (@($Config.Models).Count -eq 0 -or @($Config.Models | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'Exact model list required.' }
    if ($Config.FileName -notmatch '^[a-zA-Z0-9_. -]+\.exe$') { throw 'Use a BIOS EXE filename without a directory.' }
    if ($Config.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'A pinned SHA256 hash is required.' }
    if ($Config.BiosPasswordRequired -isnot [bool]) { throw 'BiosPasswordRequired must be Boolean.' }
    if ($Config.RequireBattery -isnot [bool]) { throw 'RequireBattery must be Boolean.' }
    if ($Config.ContainsKey('MinimumBatteryRuntimeMinutes')) {
        if ($Config.MinimumBatteryRuntimeMinutes -isnot [int] -or $Config.MinimumBatteryRuntimeMinutes -lt 0 -or $Config.MinimumBatteryRuntimeMinutes -gt 240) { throw 'MinimumBatteryRuntimeMinutes must be 0-240; 0 disables the optional estimate check.' }
        if ($Config.MinimumBatteryRuntimeMinutes -gt 0 -and -not $Config.RequireBattery) { throw 'Battery runtime requires RequireBattery.' }
    }
    if ($Config.MinimumBatteryPercent -lt 51 -or $Config.MinimumBatteryPercent -gt 100) { throw 'Battery threshold must be 51-100 (above 50%).' }
    if ($Config.MinimumFreeSpaceGB -lt 1) { throw 'At least 1 GB free space is required.' }
    if ($Config.BitLockerRebootCount -lt 1 -or $Config.BitLockerRebootCount -gt 3) { throw 'Use a finite reboot count from 1 to 3.' }
    if ($Config.EscrowDestination -notin @('EntraID','ADDS')) { throw 'Choose EntraID or ADDS escrow.' }
    if ($Config.StagedDetectionHours -lt 1 -or $Config.StagedDetectionHours -gt 24) { throw 'Staged detection lifetime must be 1-24 hours.' }
}
function Get-BootId {
    return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks.ToString()
}
function Get-State {
    if (Test-Path -LiteralPath $script:StateKey) {
        $state = Get-ItemProperty -LiteralPath $script:StateKey -ErrorAction Stop
        foreach ($name in @('Status','TargetVersion','BootId','PayloadHash','SuspendedByUs')) {
            if ($null -eq $state.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$state.$name)) {
                throw "Incomplete BIOS transaction state: missing $name. Preserve the key and inspect logs, pending firmware and BitLocker before manual recovery."
            }
        }
        if ($state.Status -notin @('Preparing','Launching','Staged','Verified','FailedOrAmbiguous','FailedAfterReboot') -or $state.SuspendedByUs -notin @('0','1')) {
            throw 'Invalid BIOS transaction state. Manual investigation is required; automatic reflashing is blocked.'
        }
        if ($state.Status -eq 'Staged' -and ($null -eq $state.PSObject.Properties['StagedUtc'] -or [string]::IsNullOrWhiteSpace([string]$state.StagedUtc))) {
            throw 'Incomplete BIOS transaction state: missing StagedUtc. Manual investigation is required.'
        }
        return $state
    }
    return $null
}
function Set-StateValue([string]$Name, $Value) {
    # Registry New-Item -Force can erase existing values. Create this key only once.
    if (-not (Test-Path -LiteralPath $script:StateKey)) {
        $null = New-Item -Path $script:StateKey -ErrorAction Stop
    }
    $null = New-ItemProperty -LiteralPath $script:StateKey -Name $Name -Value ([string]$Value) -PropertyType String -Force
}
function Write-BiosLog([string]$Message) {
    $line = '{0} {1}' -f [datetime]::UtcNow.ToString('o'), $Message
    Add-Content -LiteralPath (Join-Path $script:WorkDir 'Deployment.log') -Value $line -Encoding UTF8
}
function Initialize-SecureDirectory {
    if (Test-Path -LiteralPath $script:WorkDir) {
        if ((Get-Item -LiteralPath $script:WorkDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Working directory cannot be a reparse point.' }
    } else { $null = New-Item -ItemType Directory -Path $script:WorkDir }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')))
    Set-Acl -LiteralPath $script:WorkDir -AclObject $acl
    # Reject pre-existing reparse points before writing privileged files.
    foreach ($item in @(Get-ChildItem -LiteralPath $script:WorkDir -Force -Recurse)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in working directory.' }
        # Lock down directories as well as files: a writable parent lets a user
        # replace a privileged script even when that script's own ACL is protected.
        $itemAcl = if ($item.PSIsContainer) {
            New-Object System.Security.AccessControl.DirectorySecurity
        } else { New-Object System.Security.AccessControl.FileSecurity }
        $itemAcl.SetAccessRuleProtection($false, $false)
        $itemAcl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')))
        Set-Acl -LiteralPath $item.FullName -AclObject $itemAcl
    }
}
function Assert-Model($Config) {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer.Trim() -notmatch '^Dell( Inc\.?| Computer Corporation)?$') { throw 'Not a Dell computer.' }
    if ($cs.Model.Trim() -notin @($Config.Models)) { throw "Model is not approved: $($cs.Model)" }
}
function Assert-Payload([string]$Path, $Config) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Config.SHA256) { throw 'BIOS executable SHA256 mismatch.' }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) { throw 'BIOS Authenticode signature is not valid.' }
    if ($sig.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?Dell (?:Inc\.?|Technologies Inc\.?)"?(?:,|$)') { throw 'The BIOS publisher is not recognized as Dell.' }
}
function Assert-Power($Config) {
    if (-not ('ManagedDellBios.NativePower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ManagedDellBios {
  public static class NativePower {
    [StructLayout(LayoutKind.Sequential)]
    public struct Status {
      public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
      public int BatteryLifeTime, BatteryFullLifeTime;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemPowerStatus(out Status status);
  }
}
'@
    }
    $power = New-Object ManagedDellBios.NativePower+Status
    if (-not [ManagedDellBios.NativePower]::GetSystemPowerStatus([ref]$power)) { throw 'Retry: cannot determine AC power.' }
    if ($power.ACLineStatus -ne 1) { throw 'Retry: AC power is disconnected or unknown.' }
    if ($Config.RequireBattery) {
        if (($power.BatteryFlag -band 128) -or $power.BatteryFlag -eq 255 -or $power.BatteryLifePercent -eq 255) { throw 'Retry: battery is absent or unknown.' }
        if ($power.BatteryLifePercent -lt $Config.MinimumBatteryPercent) { throw 'Retry: battery charge is below the configured threshold.' }
        $batteries = @(Get-CimInstance Win32_Battery)
        if (-not $batteries.Count) { throw 'Retry: no battery telemetry available.' }
        foreach ($battery in $batteries) {
            if ($null -eq $battery.EstimatedChargeRemaining -or $battery.EstimatedChargeRemaining -gt 100 -or $battery.EstimatedChargeRemaining -lt $Config.MinimumBatteryPercent) { throw 'Retry: a battery is below threshold or unknown.' }
            if ($Config.ContainsKey('MinimumBatteryRuntimeMinutes') -and $Config.MinimumBatteryRuntimeMinutes -gt 0) {
                # Optional CIM estimate; Win32 API BatteryLifeTime is unknown on AC.
                # Values over one day are treated as implausible/unknown, not safe.
                $estimate = $battery.PSObject.Properties['EstimatedRunTime']
                if ($null -eq $estimate -or $null -eq $estimate.Value -or $estimate.Value -lt 1 -or $estimate.Value -gt 1440) { throw 'Retry: battery runtime estimate is unavailable. Contact IT if this persists.' }
                if ($estimate.Value -lt $Config.MinimumBatteryRuntimeMinutes) { throw 'Retry: estimated battery runtime is below the configured minimum.' }
            }
        }
    }
}
function Assert-NoPendingReboot {
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) { if (Test-Path $key) { throw 'Retry: Windows already requires a restart.' } }
    $manager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    foreach ($name in @('PendingFileRenameOperations','PendingFileRenameOperations2')) {
        if ($manager.PSObject.Properties[$name] -and @($manager.$name | Where-Object { $_ }).Count) { throw 'Retry: pending file rename operations require review/restart.' }
    }
}

function Get-BiosPassword($Config, [string]$Directory) {
    if (-not $Config.BiosPasswordRequired) { return $null }
    $path = Join-Path $Directory 'BIOS-Password.psd1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Required local BIOS-Password.psd1 is missing. See the password setup instructions.'
    }
    # Do not propagate a data-file parse error: it could include a secret source line.
    try { $secret = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop }
    catch { throw 'Cannot read BIOS-Password.psd1. Check its data-file syntax locally.' }
    if (-not $secret.ContainsKey('Password') -or $secret.Password -isnot [string] -or
        [string]::IsNullOrWhiteSpace($secret.Password) -or $secret.Password -eq 'REPLACE_LOCALLY' -or
        $secret.Password -match '[\x00\r\n]') {
        throw 'BIOS-Password.psd1 must contain a configured, single-line Password string.'
    }
    return $secret.Password
}
function ConvertTo-WindowsQuotedArgument([string]$Value) {
    # Windows native argv escaping: double backslashes before quotes and at the end.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
