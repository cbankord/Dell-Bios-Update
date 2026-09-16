# Windows-only privileged integration. Never dot-source this into the user UI.
. "$PSScriptRoot\Transport.ps1"
function Get-PackageId($Config) { 'v2-' + $Config.TargetVersion + '-' + $Config.SHA256.ToLowerInvariant() }
function Write-SchedulerLog([string]$Message) {
    Add-Content -LiteralPath (Join-Path $script:WorkDir 'Scheduler.log') -Encoding UTF8 -Value (([datetime]::UtcNow.ToString('o')) + ' ' + $Message)
}
function Read-ScheduleFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Scheduler state is missing. Do not recreate the deadline automatically.' }
    ConvertTo-PlainHashtable (ConvertFrom-SchedulerJson (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop))
}
function Save-ScheduleFile($State, [string]$Path) {
    $temp = $Path + '.new'
    [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}
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
function Initialize-PipeNative {
    if ('ManagedBiosV2.Peer' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ManagedBiosV2 {
 public static class Peer {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
  [DllImport("wtsapi32.dll", SetLastError=true)]
  static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr data, out int size);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr data);
  public static bool IsActive(SafePipeHandle pipe) {
   uint pid; if (!GetNamedPipeClientProcessId(pipe, out pid)) return false;
   int session;
   using (var p = Process.GetProcessById((int)pid)) { session = p.SessionId; }
   if (session == 0) return false;
   IntPtr data; int size;
   if (!WTSQuerySessionInformation(IntPtr.Zero, session, 8, out data, out size)) return false;
   try { return size >= 4 && Marshal.ReadInt32(data) == 0; }
   finally { WTSFreeMemory(data); }
  }
 }
}
'@
}
function New-SchedulerPipe {
    $acl = New-Object IO.Pipes.PipeSecurity
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($system)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object IO.Pipes.PipeAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-2')), 'FullControl', 'Deny'))) # Network
    $acl.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($system, 'FullControl', 'Allow')))
    $interactive = New-Object Security.Principal.SecurityIdentifier('S-1-5-4')
    # Exclude CreateNewInstance: users must not host a fake privileged server.
    $acl.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($interactive, 'ReadWrite,ReadPermissions', 'Allow')))
    New-Object IO.Pipes.NamedPipeServerStream('ManagedDellBIOS-v2', 'InOut', 1, 'Byte', 'Asynchronous', 4096, 4096, $acl)
}
function Get-AuthenticatedPipeUser($Pipe) {
    if (-not [ManagedBiosV2.Peer]::IsActive($Pipe.SafePipeHandle)) { throw 'An active interactive session is required.' }
    $identityResult = @{ Sid = '' }
    $Pipe.RunAsClient([IO.Pipes.PipeStreamImpersonationWorker]{
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if (-not $identity.IsAuthenticated -or -not (@($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-4')) { throw 'Interactive identity required.' }
            $identityResult.Sid = $identity.User.Value
        } finally { $identity.Dispose() }
    })
    return $identityResult.Sid
}

function Register-V2Tasks([string]$Runtime, [string]$UiRoot) {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\Scheduler\Start-Broker.ps1"' -f $runtime)
    $null = Register-ScheduledTask -TaskName 'ManagedDellBIOS-v2-Controller' -Action $action -Trigger @((New-ScheduledTaskTrigger -AtStartup),$repeat) -Principal $system -Settings $settings -Force
    # Group activation runs with a logged-on user's limited token. No stored user password.
    $users = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    # Parallel permits fast-user-switch logons; a per-session UI mutex rejects duplicates.
    $uiSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit ([timespan]::Zero)
    # Repeated/logon activation respects deferrals; manual script launches open
    # the window. Keep this flag paired with the installed UI when upgrading.
    $uiAction = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}\Show-BiosUI.ps1" -Background' -f $uiRoot)
    $null = Register-ScheduledTask -TaskName 'ManagedDellBIOS-v2-UserUI' -Action $uiAction -Trigger @((New-ScheduledTaskTrigger -AtLogOn),$repeat) -Principal $users -Settings $uiSettings -Force
}
