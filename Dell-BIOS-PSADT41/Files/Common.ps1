# Windows PowerShell 5.1; deliberately rejects legacy Axx version strings.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$script:StateKey = 'HKLM:\SOFTWARE\ManagedDellBIOS'
$script:WorkDir = Join-Path $env:ProgramData 'ManagedDellBIOS'
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
    if ($Config.RequireBattery -isnot [bool]) { throw 'RequireBattery must be Boolean.' }
    if ($Config.MinimumBatteryPercent -lt 50 -or $Config.MinimumBatteryPercent -gt 100) { throw 'Battery threshold must be 50-100.' }
    if ($Config.MinimumFreeSpaceGB -lt 1) { throw 'At least 1 GB free space is required.' }
    if ($Config.BitLockerRebootCount -lt 1 -or $Config.BitLockerRebootCount -gt 3) { throw 'Use a finite reboot count from 1 to 3.' }
    if ($Config.EscrowDestination -notin @('EntraID','ADDS')) { throw 'Choose EntraID or ADDS escrow.' }
    if ($Config.StagedDetectionHours -lt 1 -or $Config.StagedDetectionHours -gt 24) { throw 'Staged detection lifetime must be 1-24 hours.' }
}
function Get-BootId {
    return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks.ToString()
}
function Get-State {
    if (Test-Path -LiteralPath $script:StateKey) { return Get-ItemProperty -LiteralPath $script:StateKey }
    return $null
}
function Set-StateValue([string]$Name, $Value) {
    $null = New-Item -Path $script:StateKey -Force
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
        # Reset file ACLs to the protected parent, removing explicit user permissions.
        if (-not $item.PSIsContainer) {
            $fileAcl = New-Object System.Security.AccessControl.FileSecurity
            $fileAcl.SetAccessRuleProtection($false, $false)
            Set-Acl -LiteralPath $item.FullName -AclObject $fileAcl
        }
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
    if (-not [ManagedDellBios.NativePower]::GetSystemPowerStatus([ref]$power)) { throw 'Cannot determine AC power.' }
    if ($power.ACLineStatus -ne 1) { throw 'Retry: AC power is disconnected or unknown.' }
    if ($Config.RequireBattery) {
        if (($power.BatteryFlag -band 128) -or $power.BatteryFlag -eq 255 -or $power.BatteryLifePercent -eq 255) { throw 'Retry: battery is absent or unknown.' }
        if ($power.BatteryLifePercent -lt $Config.MinimumBatteryPercent) { throw 'Retry: battery charge is below the configured threshold.' }
        $batteries = @(Get-CimInstance Win32_Battery)
        if (-not $batteries.Count) { throw 'Retry: no battery telemetry available.' }
        foreach ($battery in $batteries) {
            if ($null -eq $battery.EstimatedChargeRemaining -or $battery.EstimatedChargeRemaining -gt 100 -or $battery.EstimatedChargeRemaining -lt $Config.MinimumBatteryPercent) { throw 'Retry: a battery is below threshold or unknown.' }
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
