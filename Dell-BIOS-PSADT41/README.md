# Dell BIOS deployment through Intune and PSADT 4.1

Reusable deployment source for Dell Pro Max 16 MC16250 and other approved Dell
client models using the same documented Windows BIOS EXE interface. One approved
EXE/target version per package; multiple exact model names are allowed only when
that same Dell EXE supports all of them. No wildcard model matching.

**This is a deployment template, not a hardware-validated production package.**
You must supply your approved BIOS EXE and PSADT 4.1.x distribution. The default
configuration deliberately cannot flash anything. No BIOS release has been
selected for you. Script checks reduce risk; they cannot guarantee a firmware
update will succeed or prevent someone disconnecting power during reboot.

## Behavior

1. Run as LocalSystem in 64-bit Windows PowerShell 5.1 through PSADT 4.1.
2. Match the exact Dell model; compare numeric BIOS versions; skip equal/newer
   firmware and reject a version below your configured prerequisite.
3. Validate the EXE's pinned SHA256 and a valid Dell Authenticode signature.
4. Require known AC power, a battery with at least 50% charge on laptops, at least
   1 GB free space, no CBS/Windows Update restart flag and no pending file renames.
   These are common reboot checks, not an exhaustive detector of all firmware or
   management products. Coordinate Windows Update, Dell Command Update and other
   BIOS deployments so they cannot stage another update concurrently.
5. For encrypted OS volumes, require protection On, stable encryption state and
   an existing recovery-password protector. Back up all recovery protectors to
   Entra ID (default) or AD DS and require each backup command to succeed. The
   scripts never print key material. A successful backup command is not a separate
   server-side retrieval test: verify recovery-key retrieval in your pilot.
6. Cache the EXE and verification scripts in a SYSTEM/Administrators-only
   directory, register a SYSTEM verification task, then suspend BitLocker for a
   finite number of reboots (default 1). Check power again before launching.
7. Execute `BIOS.exe /s /l="..."`. No immediate reboot and no force switches.
   Dell codes 0 and 2 become 3010. All other codes are failures, including an
   unexpected 6 (the updater is rebooting despite this package omitting `/r`).
8. Intune manages restart timing. Firmware progress will still be visible during
   boot. After Windows returns, the task checks BitLocker protection and actual
   BIOS version. It resumes protection only when this package owned suspension.
   It runs at startup after 5 minutes and every 30 minutes until verification can
   finish. Failed protection recovery retains the task for another attempt.

If a documented updater failure occurs, the package restores its own suspension.
If execution becomes ambiguous, it retains the transaction and finite suspension
for the next reboot. It never kills a running BIOS updater or automatically
reflashes an unresolved transaction. A failed post-boot firmware check is logged
and blocks further automatic attempts until investigated.

## 1. Select and configure the BIOS

Obtain the EXE from Dell Support for your service tag/model. Read its release
notes, prerequisite versions, downgrade restrictions and `EXE /?` help on a pilot
Windows device. Confirm `/s` stages silently without reboot and that its return
codes match the supported interface. Do not simply deploy whichever EXE is newest
at endpoint runtime.

Gather the actual inventory strings:

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion
```

Put the approved EXE into `Files`. Edit `Files\BIOS-Config.psd1`:

| Setting | What to put there |
|---|---|
| Models | Exact `Win32_ComputerSystem.Model` values supported by this EXE |
| TargetVersion | Approved BIOS version from Dell, e.g. numeric `1.x.y` |
| MinimumCurrentVersion | Dell prerequisite version; `0.0.0` only when no intermediate BIOS is required |
| FileName | Exact EXE filename in Files |
| SHA256 | Hash of that approved EXE, checked against Dell's published hash where available |
| RequireBattery | True for MC16250; false only for a validated desktop package |
| BitLockerRebootCount | 1 by default; validate the complete firmware boot sequence before changing |
| EscrowDestination | EntraID or ADDS, matching your recovery-key storage |
| PackageReviewed | True after completing this configuration review |

```powershell
Get-FileHash '.\Files\YOUR_APPROVED_BIOS.exe' -Algorithm SHA256
Get-AuthenticodeSignature '.\Files\YOUR_APPROVED_BIOS.exe' |
    Select-Object Status, @{n='Publisher';e={$_.SignerCertificate.Subject}}
.\Build-IntuneScripts.ps1
```

The builder validates the configuration and EXE and generates standalone Intune
scripts. They embed the same configuration, so they do not depend on the Intune
content cache at detection time. Re-run the builder after **every** configuration
change. Treat the packaged files as immutable after building. If your organization
signs scripts, sign them after all edits/generation and before packaging.

This version supports numeric BIOS versions only, not legacy `Axx` releases.
Interchangeable configuration does not mean every historical Dell updater has the
same switches, prerequisites or boot behavior.

## 2. Integrate with your stock PSADT 4.1 template

Use your approved PSADT 4.1.x distribution. Copy this package's Files contents into
its Files directory. In `Invoke-AppDeployToolkit.ps1`, replace the entire
`Install-ADTDeployment` function with the function in `PSADT-Install-Function.ps1`.
Keep PSADT's stock bootstrap/import/session handling. Set AppVendor, AppName and
AppVersion to identify this Dell BIOS package. Do not add welcome dialogs, app
closure, reboot prompts or the old v3 `Execute-Process` syntax.

Replace `Uninstall-ADTDeployment` and `Repair-ADTDeployment` with explicit failure
functions; BIOS uninstall/repair is not a safe generic operation:

```powershell
function Uninstall-ADTDeployment { Close-ADTSession -ExitCode 60001 }
function Repair-ADTDeployment { Close-ADTSession -ExitCode 60001 }
```

The resulting source root contains the stock Invoke-AppDeployToolkit EXE and PS1,
PSAppDeployToolkit module directory and the populated Files directory. The helper
calls `Start-ADTProcess -PassThru -IgnoreExitCodes '*'` so it can explicitly pass
the child's exit code to `Close-ADTSession`. This is supported in PSADT 4.1.0.
Do not use `-SuppressRebootPassThru` or a process-killing timeout.

Package the completed source folder with Microsoft's Win32 Content Prep Tool:

```powershell
.\IntuneWinAppUtil.exe -c 'C:\Packaging\Dell-BIOS' `
    -s 'Invoke-AppDeployToolkit.exe' -o 'C:\Packaging\Output' -q
```

Keep Output outside the source directory. The ZIP supplied here is source, not an
`.intunewin`, and does not include Dell's EXE or the PSADT distribution.

## 3. Intune configuration

| Setting | Value |
|---|---|
| App type | Windows app (Win32) |
| Install behavior | System |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` (deliberately fails) |
| Allow available uninstall | No; do not assign uninstall |
| Installation time required | 120 minutes; this is an outer limit, not permission to interrupt flashing |
| Architecture | x64 |
| OS requirement | Your supported Windows 11 baseline |
| Additional requirement | Upload Intune\Require-Model.ps1; Boolean equals True |
| Requirement execution | 64-bit; no logged-on user context |
| Detection | Upload Intune\Detect-BIOS.ps1; run as 32-bit = No |
| Return 0 | Success |
| Return 3010 | Hard reboot for an enforced Intune restart with grace period (see below) |
| Return 1618 | Retry |
| Return 60001 / other errors | Failed |
| Device restart behavior | Determine behavior based on return codes |
| Assignment | Required, device group, small pilot ring first |
| Restart grace period | For example 60 minutes, countdown 15 minutes; pilot the actual behavior |

The 3010-to-Hard-reboot mapping is **intentional**: the wrapper reports that a
restart is required and Intune enforces it using its grace-period controls. It
does not mean the Dell process already restarted. Leave the script's code at 3010;
change the mapping in this app's return-code table. Microsoft's current guidance
says Soft reboot only notifies and does not apply restart grace-period settings.
If you leave 3010 as Soft reboot, supply another reliable restart mechanism or the
BIOS can remain staged indefinitely. Do not report a fully automated rollout as
complete if no restart is enforced.

Keep restart notifications enabled on user workstations. Silent installation does
not require a surprise reboot. For unattended machines, coordinate the assignment
and enforced restart with the operating schedule. Intune availability/deadlines
alone are not a precise firmware maintenance-window guarantee.

Configure retries for temporary power/reboot/space conditions. Intune Retry uses
three attempts with five-minute waits; it is not a continuously running power
monitor. Devices that miss these attempts need later Intune reevaluation or an
admin retry after the cause is resolved. Pending Windows updates are not forcibly
rebooted by this installer before flashing.

## Detection and verification are different

Before reboot, the old BIOS version is still expected. Detect-BIOS accepts a
successful staging marker only for the matching target/hash, the same Windows
boot and less than 24 hours. This lets Intune complete installation processing
and apply its restart policy. Intune may briefly label the app Installed while
firmware is still pending. This is **staging success**, not proof of BIOS success.

After a real Windows restart, that marker no longer passes detection. The actual
BIOS must be at least the target. There is no permanent marker that conceals a
failed flash. Intune reporting refresh is asynchronous; it may not update at boot.
Deploy the generated Audit-BIOSAndBitLocker.ps1 as a read-only Intune Remediations
detection script, or use it in your existing inventory/audit process, to monitor
both actual BIOS and protection state. Scope it only to the intended model group.
It never treats staging as compliance and does not enforce encryption on a fully
decrypted device; use your existing encryption policy for that.

## BIOS administrator passwords

Password support is intentionally absent because your password-management method
is unknown. Confirm that your target devices do not require a password for BIOS
updates before using this version. Dell documents `/p=...` for password-protected
updates and exit code 7 for missing/incorrect passwords. A password-protected
machine should fail silently instead of prompting under `/s`; verify this with
your exact EXE. Do not put a shared BIOS password in this configuration, PSADT
script, Intune command, EXE filename or package. If passwords are configured, adapt
the execution step to your approved per-device secret delivery method before
deployment. Hiding a PSADT argument from its log does not remove process command
line exposure. No password is bypassed or guessed by this package.

## Pilot and operational checks

Run `Files\Install-DellBIOS.ps1 -PreflightOnly` under SYSTEM in 64-bit Windows
PowerShell on a pilot. It writes local logs/creates the protected working
directory, but does not back up keys, suspend protection, register tasks or run
the BIOS EXE. It does not prove a password, capsule staging, escrow connectivity or
post-boot firmware behavior. Then test the complete PSADT package through Intune.

Validate the following before expanding the ring:

- Wrong model and tampered/unsigned EXE never launch.
- Battery disconnected/low and unknown telemetry return Retry without suspension.
- Equal/newer BIOS does not run the updater or downgrade.
- Recovery key is retrievable and failed backup prevents suspension/flashing.
- Actual accepted Dell return code, successful silent staging and Intune restart
  grace-period behavior match expectations under SYSTEM.
- The firmware finishes with AC connected, returns to Windows and reports the
  target version with BitLocker protection On, without recovery prompts.
- A failed update is detected after reboot and is not repeatedly reflashed.

Keep AC connected through the entire restart/update. Finite reboot count is not a
wall-clock suspension timeout: a device that never restarts can remain suspended.
Enforce the restart promptly and monitor delayed/rejected restart cases. The
post-boot task assumes that firmware work has finished when Windows returns; each
new model/version must be piloted for this sequence. No automated downgrade or
firmware rollback is attempted; use Dell's model-specific recovery procedure.

## Logs and recovery

On each device:

```powershell
Get-Content "$env:ProgramData\ManagedDellBIOS\Deployment.log"
Get-ChildItem "$env:ProgramData\ManagedDellBIOS\Dell-*.log"
Get-ItemProperty 'HKLM:\SOFTWARE\ManagedDellBIOS'
Get-BitLockerVolume -MountPoint $env:SystemDrive |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus
Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion
```

PSADT also writes its normal deployment log. A successful update keeps its
verification state and logs. A failed or ambiguous transaction is deliberately
not erased by reinstalling or changing package versions. Inspect Dell logs and
the actual BIOS/BitLocker state first. After a completed reboot, you can rerun the
registered task with `Start-ScheduledTask -TaskName 'ManagedDellBIOS-VerifyAndResume'`.
If it has already completed and unregistered, its verification script remains in
the protected working directory for an administrator to run as SYSTEM.

Only after confirming no firmware operation is running or pending, resolving the
cause and verifying protection, may an administrator archive the logs and clear
the `HKLM:\SOFTWARE\ManagedDellBIOS` transaction key to allow a fresh attempt.
Do not clear this key merely to make Intune retry. Do not forcibly terminate a
stuck BIOS process or resume BitLocker over a pending firmware update.

## Reuse for the next BIOS or another model

Clone the completed package source, replace the EXE, update the configuration and
PSADT AppVersion, regenerate the three Intune scripts, and create a new Win32 app.
Keep the transaction key/task identity consistent so packages can see unresolved
updates. Remove overlapping required assignments to older versions or use
supersedence without uninstalling the older firmware. For intermediate-version
requirements, deploy and verify the prerequisite with a real restart before the
next package. The minimum-version gate prevents skipping the prerequisite.

## Sources and validation

- [Dell BIOS command switches](https://www.dell.com/support/kbdoc/en-us/000136752/command-line-switches-for-dell-bios-updates)
- [Dell DUP options and exit codes](https://www.dell.com/support/kbdoc/en-ed/000148745/dup-bios-updates)
- [MC16250 supported BIOS package example; not a selected release](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=v0c19)
- [Microsoft Suspend-BitLocker](https://learn.microsoft.com/en-us/powershell/module/bitlocker/suspend-bitlocker)
- [Microsoft BitLocker cmdlets](https://learn.microsoft.com/en-us/powershell/module/bitlocker/)
- [Intune Win32 app configuration and detection](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32)
- [Intune restart grace-period behavior](https://learn.microsoft.com/en-us/intune/app-management/deployment/win32)
- [PSADT 4.1.0 Start-ADTProcess source](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/4.1.0/src/PSAppDeployToolkit/Public/Start-ADTProcess.ps1)

See VALIDATION.txt for checks performed on these source files. Windows, Intune,
Dell hardware and real BitLocker/Task Scheduler integration require your pilot.
