# Dell BIOS deployment v2

A branded Windows interface and persistent scheduler (72 hours by default) for Intune + PSADT
4.1, with the existing guarded Dell BIOS installer underneath. This branch is
`v2`; [Main](https://github.com/cbankord/Dell-Bios-Update/tree/Main) retains v1.

**Implemented source; Windows pilot required before rollout.** No BIOS EXE,
PSADT distribution, real password or deployable `.intunewin` is included. The
repository's inherited SHA256 is **65 characters** and must be recalculated from
the approved EXE. The inherited configuration names **Dell Pro 14 Plus PB14250**,
`Dell_Pro_PA13250.exe`, target `2.1.1`; verify that exact Dell compatibility.
`PackageReviewed` remains false. Do not trim a hash or assume these values match
MC16250. Choose the approved EXE/model/version for each deployment.

## User experience

- A compact 600 x 560 WPF notice, fitted to the available work area at startup,
  with logo/banner slots, configurable colors and copy. Scrolling content sits
  above a fixed action bar so the buttons remain accessible.
- **Install Now** requests immediate guarded preparation after a save-work/power
  confirmation. SYSTEM retains every safety check and the final restart warning.
- **Schedule Install** opens the local date/time controls; click it again to save
  the selected restart time. Preparation may begin earlier by the configured lead.
- **Defer** hides the reminder while preserving the original deadline and any
  selected time or Install Now request. An expired deadline removes deferral and
  rescheduling. After staging, **Restart Now** replaces pre-install actions.
- A local date picker and 24-hour time selectors. Local times are converted to UTC;
  nonexistent/ambiguous daylight-saving times are rejected explicitly.
- A fixed deadline (72 hours by default) starts when the UI acknowledges its first rendered
  notice on an available desktop. Enrollment itself does not start the clock.
- Unlimited reminder deferrals and rescheduling before preparation begins, while
  the deadline remains open. A reminder normally appears at most every four hours.
- Closing the window hides it to the notification area. It never clears the
  schedule, deadline or SYSTEM task. Double-click the tray icon to reopen it.
- A selected restart permits preparation up to 30 minutes beforehand. The UI
  explains this; scheduling is locked once preparation begins. No selection means
  preparation becomes mandatory at the original deadline, with a warning first.
- Successful staging produces the requested restart-required message, the planned
  restart time and a **Restart now** button with a save-work confirmation.
- The scheduler provides at least 15 minutes after staging before automatic
  restart, plus a reminder at five minutes. The actual restart may be later than
  the requested time if preparation, sleep or safety checks take longer.
- Only the actual firmware version and acceptable BitLocker state produce
  **Verified complete**. Enrollment and successful staging are separate states.

The default post-staging message is:

> Your BIOS update is ready. A restart is required to finish installing it. Save
> your work, keep your computer plugged into power, and do not turn it off until
> the update has finished and Windows returns.

## Architecture and authority

PSADT installs the durable controller; it no longer waits days for an update or
owns a restart timer. A SYSTEM scheduled task runs the controller at startup and
relaunches it every five minutes if it exits. A separate task launches the WPF
client with a signed-in user's limited token at logon and periodically. PSADT
also tries an immediate `Start-ADTProcessAsUser -NoWait` launch.

The UI sends only `Status`, `NoticeShown`, `Defer`, `Schedule`, `InstallNow` and `RestartNow`
requests over a local named pipe. The controller authenticates an interactive
client in an active session and validates each action/time. It rejects network
access, unknown actions, extra fields, oversized frames and out-of-window dates.
The UI checks that the pipe owner is SYSTEM. No user-supplied file paths or
commands are executed. Users do not write privileged schedule state directly.

| Location | Purpose / access |
|---|---|
| `%ProgramData%\ManagedDellBIOS\Schedule-v2.json` | Authoritative schedule and fixed deadline; SYSTEM/Administrators only |
| `%ProgramData%\ManagedDellBIOS\Enrollment-v2.json` | Missing-state recovery guard |
| `%ProgramData%\ManagedDellBIOS\Runtime-v2` | Durable privileged scripts, config, approved EXE and required secret |
| `%ProgramFiles%\ManagedDellBIOS-v2` | UI and branding; Users read/execute, SYSTEM/Administrators write |
| `HKLM\SOFTWARE\ManagedDellBIOS` | Existing firmware transaction and suspension ownership |
| `ManagedDellBIOS-v2-Controller` | SYSTEM orchestration task |
| `ManagedDellBIOS-v2-UserUI` | Limited-token interactive client task |
| `ManagedDellBIOS-VerifyAndResume` | Existing post-boot verification/recovery task |

State writes use a same-directory atomic replacement. Same-package reenrollment
preserves the state and repairs task registration; it does not grant more time.
A different package is blocked until the previous v2 deployment is verified.
Missing/corrupt state or an ambiguous firmware transaction stops for IT review.
The controller never terminates a firmware process or automatically reflashes an
unresolved update. See [OPERATIONS.md](OPERATIONS.md) for failure behavior.

## Build with the wizard

Open **`Builder/Start-PackageBuilder.cmd`** on your Windows packaging computer.
Select your approved BIOS EXE and custom PSADT 4.1.x template ZIP, enter the model,
version, password and deployment settings, and build. The wizard calculates and
pins the SHA256, validates Dell signing, integrates the deployment functions,
applies branding, and generates the Intune requirement/detection/audit scripts.
Select your official `IntuneWinAppUtil.exe` to also produce `.intunewin`.

[Builder instructions, settings and output](Builder/README.md) cover reusable
nonsecret presets, optional battery runtime checks and Windows pilot requirements.
Built packages use your selected inputs; they do not use the inherited example
hash/model/version below. Output is protected and kept outside this repository.

## Configure and build manually

1. Put the approved Dell BIOS EXE in `Files`. Review its release notes, prerequisite
   versions, supported models, `/s`, `/p=` and return codes on a pilot. The package
   uses exact Dell manufacturer/model matching, numeric version comparison, no
   downgrades, a pinned SHA256 and valid Dell Authenticode signature.
2. Update `Files/BIOS-Config.psd1`. Retain `MinimumBatteryPercent = 51` or higher
   for laptops, and use the correct escrow destination and prerequisite version.
   Set `PackageReviewed = $true` only after review. The current hash is invalid.
3. For the shared BIOS administrator password, copy
   `Files/BIOS-Password.example.psd1` to **local** `Files/BIOS-Password.psd1` and
   populate it in your secured packaging workspace. This filename is Git-ignored.
   Single-quoted PowerShell strings preserve `$`; double any embedded apostrophe.
   Explicitly set `BiosPasswordRequired = $false` only for an approved fleet that
   has no BIOS password.
4. Customize `Files/UI/Branding.psd1`, and place local PNG/JPG artwork in
   `Files/UI/Assets`. Change company name, title, purpose, support text, logo,
   banner, colors and messages without editing scheduler logic. Empty image
   paths use the built-in vector mark. Keep accessibility contrast when rebranding.
5. Review `Files/Scheduler/Policy.psd1`: the window defaults to 72 hours and can
   be set to 1-168 hours for new enrollments. The original window is persisted;
   policy changes never extend an existing deadline. Reminder, preparation, final
   warning and retry intervals are also configurable. The UI displays the actual
   configured preparation lead and persisted window.
6. Copy `Files` into your approved stock PSADT **4.1.x** template. Replace ONLY
   `Install-ADTDeployment` in `Invoke-AppDeployToolkit.ps1` with
   `PSADT-Install-Function.ps1`. Keep the stock bootstrap/session handling. Set
   app metadata for this deployment. Uninstall/repair should fail explicitly;
   do not implement a generic BIOS downgrade or clear state during repair.
7. Run `Build-IntuneScripts.ps1` on your Windows packaging machine after every
   model/version/hash change. It validates the reviewed configuration and payload
   and generates the standalone scripts in `Intune`. Sign completed scripts if
   required by your organization's policy. Build a fresh `.intunewin` using the
   stock `Invoke-AppDeployToolkit.exe` as the setup file. Keep output outside the
   source folder.

```powershell
Get-FileHash '.\Files\YOUR_APPROVED_BIOS.exe' -Algorithm SHA256
Get-AuthenticodeSignature '.\Files\YOUR_APPROVED_BIOS.exe' |
    Select-Object Status, @{n='Publisher';e={$_.SignerCertificate.Subject}}
.\Build-IntuneScripts.ps1
```

Preview the real interface without enrollment, credentials, staging or restart
on a Windows machine with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo
```

Demo scheduling changes only in-memory sample state. Install Now in preview
moves to a simulated Preparing state and never launches firmware. Preview uses
its own instance and can run alongside the installed UI. Close exits the preview.
Defer still hides preview to the tray. For enrolled pilots, see
[updating the notice and actions](OPERATIONS.md#updating-the-compact-notice-and-install-now-action).

Open the **live installed** interface in the signed-in user's Windows PowerShell
session (not SYSTEM):

```powershell
powershell.exe -NoProfile -STA -File "$env:ProgramFiles\ManagedDellBIOS-v2\Show-BiosUI.ps1"
```

A manual launch opens the window even when a reminder was deferred. A second
manual launch signals the existing window to open. Without enrollment, live
mode shows a service-unavailable message and disables actions; use `-Demo` for
a standalone preview. Automatic PSADT/task launches pass `-Background` to honor
the reminder cooldown. Running the toolkit again is not a forced UI preview.
See [no-window troubleshooting](OPERATIONS.md#when-no-window-appears), including
the required paired launcher update for already enrolled pilots.

## Intune settings: one restart owner

| Setting | v2 value |
|---|---|
| Install behavior | System; x64 Windows 11 |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Device restart behavior | **No specific action** |
| Return 0 | Success: controller enrolled, not proof of firmware completion |
| Return 1618 | Retry if used by your enrollment wrapper |
| Return 60001 / unexpected results | Failed |
| 3010 | Not emitted by the v2 wrapper; do not configure a competing hard-reboot policy |
| Requirement script | `Intune/Require-Model.ps1`, 64-bit, Boolean equals True |
| Detection script | `Intune/Detect-BIOS.ps1`, 64-bit |
| Firmware compliance | `Intune/Audit-BIOSAndBitLocker.ps1`, read-only Remediations detection or your inventory system |
| Assignment | Small device pilot first; remove overlapping v1/other BIOS assignments |

**Important change from v1:** no Intune 720-minute grace-period restart and no
PSADT restart prompt. The persistent v2 controller owns this app's restart. Its
background firmware child may return 3010 internally; that is consumed by the
controller and is not returned to Intune. Enrollment completes promptly.

Intune's Installed state means the controller is enrolled for this package (or
actual firmware already meets target). It does not assert firmware success. Use
the separate audit script to report actual BIOS and BitLocker compliance. A
controller in NeedsAttention can remain Installed; monitor Scheduler.log/state
and the audit result. Other Windows Update/application policies can still restart
Windows independently; coordinate them for the pilot and deployment ring.

## Safety boundaries

Before staging, the existing installer still checks the approved model, version,
signature/hash, AC/battery, disk, pending Windows restarts, recovery protector and
successful recovery-key backup. It suspends BitLocker only immediately around
staging with a finite reboot count. The SYSTEM scheduler rechecks AC, charge,
matching staged transaction and owned suspension before requesting restart.

No `/r`, force-flash or forced process termination is used by the Dell installer.
The controller requests Windows restart with `/t 0` and without `/f`, after its
own warning period, so it does not intentionally force-close unsaved applications.
An application can consequently block completion; monitor overdue systems.

A deadline never overrides a safety check. Physical power can change after the
last check, including during firmware boot. The software cannot guarantee power
continuity. BitLocker remains suspended while staged firmware awaits restart;
a power hold can extend that interval. Do not resume it over pending firmware.

The shared password is plaintext in your local package and protected runtime and
is supplied to Dell via its native command line. SYSTEM/local administrators and
privileged monitoring can recover it. It is never sent to the UI or deliberately
logged by these scripts. Review Dell logs/EDR in the pilot. This is not a vault
integration; substitute an approved secret provider if your policy requires one.

## Validation and sources

See [VALIDATION.txt](VALIDATION.txt), [OPERATIONS.md](OPERATIONS.md) and
[CHANGELOG.md](CHANGELOG.md). The Linux tests exercise parser, scheduling rules,
DST conversion, framed messages, argument quoting, power thresholds and mocked
controller transitions. They do **not** validate Windows WPF rendering, named-pipe
ACL/impersonation, Task Scheduler group activation, Intune or Dell hardware.

- [PSADT 4.1 Start-ADTProcessAsUser](https://psappdeploytoolkit.com/docs/4.1.x/reference/functions/Start-ADTProcessAsUser)
- [Microsoft scheduled task principals](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal)
- [Microsoft pipe permissions](https://learn.microsoft.com/en-us/dotnet/api/system.io.pipes.pipeaccessrights)
- [Dell BIOS update switches and exit codes](https://www.dell.com/support/kbdoc/en-ed/000148745/dup-bios-updates)
- [Microsoft Suspend-BitLocker](https://learn.microsoft.com/en-us/powershell/module/bitlocker/suspend-bitlocker)
- [Intune Win32 app configuration](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32)
