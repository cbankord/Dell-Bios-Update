# v2 operations and Windows pilot

## Behavior under interruption

| Event | Behavior |
|---|---|
| Enrolled, no user/notice yet | No deadline clock or suspension. User logon delivers notice. Monitor machines that never receive one. |
| User closes the notice or chooses Defer | UI hides; selected time, immediate-install intent and deadline remain. SYSTEM enforcement continues. |
| User never chooses a time | The original deadline is the fallback. A catch-up warning precedes mandatory preparation. |
| User chooses Install Now | Records immediate intent, then checks power, transaction state and installer prerequisites. No UI-initiated firmware or restart. Successful staging still gets the configured final restart warning. |
| User reschedules | Only before preparation, to a future instant within the original deadline. |
| User logs off | Controller continues. A selected time or delivered-notice deadline remains binding even without a user present. |
| Computer is asleep/offline | Nothing flashes while off. Task resumes when Windows runs; a missed time receives a fresh warning, not another deferral window. No wake timer is created. |
| AC disconnected or charge low | No staging/restart. Explanation is shown, overdue status persists, and checks retry every five minutes by default. |
| Power lost after staging | Firmware is not staged again. Suspension remains owned; restart waits for safety and then a fresh warning. |
| Another Windows restart pending | Pre-staging hold. This installer does not clear pending flags or restart to bypass them. |
| Controller crashes before staging result | Firmware lock/transaction are inspected; a known staged transaction is adopted, ambiguous preparation stops for IT. No process is killed. |
| Controller restarts with firmware staged | Original deadline remains. A new final warning protects against an immediate catch-up restart. |
| Independent restart occurs | Existing verifier checks actual firmware and resumes owned BitLocker suspension after Windows returns. |
| Flash fails after reboot | NeedsAttention; automatic reflashing is blocked. |
| State missing/corrupt | Fail closed; enrollment guard prevents silently starting a new deadline. |
| Clock/time zone changes | UTC deadline is persisted; displayed time follows local zone. Observed time never moves backward in state. Large clock corrections require IT review. |
| Unsaved application blocks restart | No `/f` is used. Controller retries with another warning interval; monitor and assist. |
| Another user signs in | The schedule is device-wide. Any authenticated active interactive user can act within the same original window. Pilot shared/RDP devices separately. |

The first-notice acknowledgement is an operational delivery signal, not proof
that a human read it. Standard users can terminate their own UI; the periodic
user task relaunches it, and a deadline already delivered is enforced by SYSTEM.
A user who prevents all first notices from rendering leaves the device unarmed;
monitor AwaitingNotice rather than assuming every enrollment has a deadline.
This tool does not attempt to defend against a malicious local administrator.

## Logs and diagnosis

- `C:\ProgramData\ManagedDellBIOS\Scheduler.log`: enrollment, accepted actions,
  transitions, safety holds and restart requests. No raw request bodies/passwords.
- `Deployment.log`: existing guarded installer detail.
- `Dell-*.log`: Dell updater output; verify secret handling with the selected EXE.
- PSADT log: enrollment and immediate UI launch results.
- `%LocalAppData%\ManagedDellBIOS-v2\UI.log`: per-user startup mode/source/host,
  duplicate-instance handling, startup failures, connection/render failures and
  recovery. Repeated identical polling failures are logged once until recovery.
- `Schedule-v2.json`: phase, first delivered notice, immutable deadline, schedule,
  heartbeat and last error. Read as administrator; do not edit to grant more time.
- `HKLM:\SOFTWARE\ManagedDellBIOS`: actual firmware transaction, ownership and
  post-boot verification; this is separate from schedule state.

```powershell
Get-ScheduledTask -TaskName 'ManagedDellBIOS*' | Select-Object TaskName, State
Get-Content "$env:ProgramData\ManagedDellBIOS\Schedule-v2.json" -Raw
Get-Content "$env:ProgramData\ManagedDellBIOS\Scheduler.log" -Tail 50
Get-BitLockerVolume -MountPoint $env:SystemDrive |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus
Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion
```

Do not export whole BitLocker objects to logs: they can contain recovery material.
Check a controller heartbeat older than ten minutes while the device is awake.
NeedsAttention deliberately remains until IT resolves the underlying condition;
clearing a flag alone does not repair firmware or BitLocker.

## When no window appears

Run a fresh **Windows PowerShell 5.1** process (`powershell.exe`, with `-STA`) as
the signed-in standard user. A SYSTEM/session-0 process cannot display this UI
on that user's desktop. Do not run it inside an existing WPF host such as ISE.

To test the downloaded/built UI without a controller, from the package folder:

```powershell
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo
```

Preview uses no enrollment, password, firmware, BitLocker or restart operations.
Its separate instance can run alongside the live UI, and Close exits preview.
Keep the entire UI folder and its Transport.ps1 dependency together.

To open the enrolled interface, independently of the reminder cooldown:

```powershell
powershell.exe -NoProfile -STA -File "$env:ProgramFiles\ManagedDellBIOS-v2\Show-BiosUI.ps1"
Get-Content "$env:LOCALAPPDATA\ManagedDellBIOS-v2\UI.log" -Tail 50
```

Manual launch shows connection failures even before any status is received;
all actions remain disabled until an authenticated status can be rendered.
It retries automatically. A manual launch against the corrected running client
opens/restores that window within the next activation poll (normally one second).
It does not reset the deadline, cancel a selection or request installation.
An older running client cannot receive the new signal; use its Device care tray
icon and follow the paired upgrade below. Closing a live window still only hides
it. Never delete scheduling state or terminate an updater to make a notice appear.

The toolkit enrolls/repairs the controller under SYSTEM. Its user launch and the
periodic task pass `-Background`, so a prior deferral legitimately suppresses a
new notice. A toolkit exit of 0 means enrollment succeeded, not that a window
was displayed or the BIOS was updated. When there is no active user, delivery
waits for user logon. Examine PSADT and Scheduler.log if enrollment failed.

If preview fails, inspect the console/error dialog and **that same user's**
UI.log. The log identifies the script source path, PowerShell version and nested
error messages without recording credentials or request bodies. If Windows
blocks the entry script before it executes (for example signing policy or a
download marker), there may be no new UI.log entry: the foreground command's
PowerShell error is the diagnostic. Review/sign or unblock only the reviewed
download according to your organization's policy; do not relax fleet policy.

For an administrator investigating the installed deployment:

```powershell
Get-ScheduledTask -TaskName 'ManagedDellBIOS-v2-*' | Select-Object TaskName, State
(Get-ScheduledTask -TaskName 'ManagedDellBIOS-v2-UserUI').Actions |
    Select-Object Execute, Arguments
Get-Content "$env:ProgramData\ManagedDellBIOS\Scheduler.log" -Tail 50
```

After upgrading the cached UI, the user task arguments must end in
`Show-BiosUI.ps1" -Background`. The exact quoting may vary; the switch must be
after the script path. An old task without this switch would reopen the new UI
every five minutes. Update the cached files **and** task/PSADT launchers together.

## Migration, updates and recovery

Finish and verify a v1 staged update before enrolling v2. Remove the old Intune
assignment/reboot policy; the v2 package cannot change tenant assignments for you.
Keep the existing firmware key/task identity so unresolved work is visible.

For the next BIOS, change the approved EXE, version/hash/model settings and PSADT
metadata, regenerate scripts, then build a new app. The previous v2 deployment
must be VerifiedComplete before a different package can replace its runtime.

Reinstalling the same version/hash repairs task definitions and activation but
intentionally leaves live runtime files and the deadline untouched. For a code
or branding update to an already enrolled package, IT must first verify no
firmware operation is running/pending, stop the controller/UI tasks, back up
state, and replace the reviewed runtime/UI files while preserving their ACLs and
Schedule-v2.json. Restart tasks and verify the unchanged deadline. Do not attempt
in-place script replacement during Preparing or RestartRequired.

For the old missing-Status defect, archive the registry key and logs before any
recovery. A key containing only SuspendedByUs does not prove no firmware is pending.
Verify actual firmware, protection, no active updater and no pending firmware.
Only then may an administrator remove stale transaction/task state and retry.
Existing cached v1 verification scripts do not update merely because Git changes.

Do not forcibly terminate an updater, clear an unresolved transaction to cause
reflashing, or resume BitLocker over staged firmware. Use Dell's model-specific
recovery procedure for firmware failures. No generic downgrade/uninstall exists.

## Required pilot gates

1. Run `powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo`
   as a standard user. Check logo/banner replacements, text wrapping, keyboard-only
   navigation, screen-reader labels, 100/150/200% scaling and a small laptop display.
2. Run the base tests with `-WindowsRegistryIntegration` in Windows PowerShell 5.1.
   This uses a disposable HKCU key and never changes deployment state.
3. Correct configuration/hash, supply the approved EXE and local password, and
   run the original `Install-DellBIOS.ps1 -PreflightOnly` as SYSTEM. Confirm it
   does not escrow/suspend/flash. Verify recovery-key retrieval independently.
4. Enroll through Intune SYSTEM while a standard user is signed in. Confirm the
   UI launches without UAC, IPC succeeds, both task principals are correct and
   standard users cannot modify runtime/state/branding. Confirm local network
   clients and disconnected sessions cannot submit requests. Test a locked screen
   before first delivery; the deadline must not start until the notice is rendered.
5. Test all phase/time transitions. Repeat installation, sign out/in, restart,
   kill only the UI, sleep past a chosen time, and inspect the unchanged deadline.
   In an isolated lab you can seed an earlier first-notice/deadline pair with IT
   controls; never introduce a production bypass flag or shorten safety warnings.
6. Confirm no selection reaches its original deadline, removes deferral and starts
   a final warning. Confirm no active user still honors a previously established
   schedule. Do not enroll critical unattended workstations without an operating
   plan for that behavior.
7. On real Dell hardware, test 50% vs 51%, disconnected AC, unknown battery,
   pending Windows restart, wrong model, altered EXE and missing/wrong password.
   Failures must not force a flash or expose secrets. Interrupt only simulated
   workers in tests; never kill a live updater to exercise crash paths.
8. Confirm signed/hash-approved staging, correct code 2 -> internal 3010, the exact
   restart notice and selected/final times. Ensure Intune does not create another
   restart timer. Test a real power hold before restart and verify owned suspension.
9. Restart, wait for the verifier (startup delay five minutes), confirm actual
   BIOS meets target, BitLocker On if encrypted, and UI says Verified complete.
   Confirm a failed firmware result becomes NeedsAttention without a reflash.
10. Review Dell log/EDR command-line exposure and protect package access. Validate
    task recovery, IPC impersonation and all WPF behavior on your managed Windows
    image, not only an administrator's test desktop.

Windows WPF/pipe/task integration and real firmware behavior were not executable
on the Linux authoring host. These are unverified gates, not claimed passes.

## Builder and configurable policy update

The package builder is an offline packaging tool. Use
[Builder/README.md](Builder/README.md) for its input requirements, credential
handling and additional Windows GUI/packaging pilot gates. It never enrolls the
packaging machine or flashes a BIOS.

New state records its original `WindowHours` at enrollment. First delivered
notice starts that duration; deferrals, sign-outs, restarts and retries retain
it. Old schema-2 state without the field adopts 72 hours, preserving its prior
meaning. Editing Policy.psd1 cannot extend an existing deadline. Do not delete
schedule/enrollment state to change the window. Same version/hash reenrollment
also retains existing runtime/branding; a rebuilt package is not a live updater.

`MinimumBatteryRuntimeMinutes` is optional and defaults to 0 (off). When enabled,
missing or implausible CIM runtime telemetry blocks both preparation and managed
restart. The state stays overdue when applicable. Validate support per model;
do not enable it fleet-wide based on an estimate from one machine. AC and the
configured percentage remain required regardless of that optional setting.


## Updating the compact notice and Install Now action

A newly built package includes the smaller notice and updated controller.
**Reinstalling the same BIOS version/hash on an already enrolled pilot preserves
its cached runtime.** It does not automatically install these code changes.
Updating only the XAML changes the size but cannot add a working Install Now
request to an older controller. The new UI explicitly reports an older controller
and disables that unsupported action.

Use the maintenance procedure above to update both sides together. These are the
specific source-to-installed mappings for this change:

| Repository source | Installed destination |
|---|---|
| `Files/UI/Window.xaml` | `%ProgramFiles%\ManagedDellBIOS-v2\Window.xaml` |
| `Files/UI/Show-BiosUI.ps1` | `%ProgramFiles%\ManagedDellBIOS-v2\Show-BiosUI.ps1` |
| `Files/UI/Client.ps1` | `%ProgramFiles%\ManagedDellBIOS-v2\Client.ps1` |
| `Files/Scheduler/Core.ps1` | `%ProgramData%\ManagedDellBIOS\Runtime-v2\Scheduler\Core.ps1` |
| `Files/Scheduler/Engine.ps1` | `%ProgramData%\ManagedDellBIOS\Runtime-v2\Scheduler\Engine.ps1` |
| `Files/Scheduler/Start-Broker.ps1` | `%ProgramData%\ManagedDellBIOS\Runtime-v2\Scheduler\Start-Broker.ps1` |
| `Files/Scheduler/Windows.ps1` | `%ProgramData%\ManagedDellBIOS\Runtime-v2\Scheduler\Windows.ps1` |

Do this only during an IT maintenance session with no running/pending firmware
operation. Preparing, RestartRequired, Verifying, NeedsAttention or an unresolved
firmware transaction requires resolution before runtime replacement. Prevent
staging during the maintenance window; do not update at a selected preparation
time or after the deadline where enforcement may be due. If the deadline is
already due, let the existing guarded deployment finish before code maintenance.

Back up schedule/enrollment state and code, record the original deadline, and
stop the controller and user UI tasks before copying. The immediate UI launched
by PSADT may not belong to the scheduled task: close that application's process
too. Target only the PowerShell process whose command line runs the exact
installed `ManagedDellBIOS-v2\Show-BiosUI.ps1` path; never stop every PowerShell
process or any firmware/verification worker. Closing the notice with its Close
button only hides it and does not unload its scripts.

Copy the seven reviewed files above using your approved administrator/SYSTEM
maintenance process, preserve their protected ownership/ACLs and your branding,
and leave `Schedule-v2.json`, `Enrollment-v2.json`, policy, BIOS config, payload,
password and firmware registry state unchanged. Before restarting, re-register
the paired task definitions from the reviewed updated Windows.ps1, under your
approved administrator/SYSTEM maintenance context:

```powershell
. "$env:ProgramData\ManagedDellBIOS\Runtime-v2\Scheduler\Windows.ps1"
Register-V2Tasks -Runtime "$env:ProgramData\ManagedDellBIOS\Runtime-v2" `
    -UiRoot "$env:ProgramFiles\ManagedDellBIOS-v2"
```

Also rebuild the PSADT package with the current `PSADT-Install-Function.ps1` so
future Intune retries use `-Background`. Do not run an old toolkit launcher
against the new UI. Confirm the user task arguments contain `-Background`.
Same-version/hash reenrollment using the rebuilt package can repair task
definitions, but it still will not replace the cached scripts for you.

Restart the tasks after maintenance and confirm
the original deadline and selected time remain. The controller migrates the new
optional `InstallRequestedUtc` field to an empty value for older state; it never
fabricates an Install Now request or starts a new deferral window.

Pilot the first notice with all three choices visible, the date-picker expand/
confirm/cancel flow, an overdue notice without Defer, and the post-staging
Restart Now action. Check 100/150/200% scaling, short screens, long company text
and a banner: the action bar must remain visible while the content scrolls.
Install Now older than two minutes at the first eligible tick (for example after
sleep or a safety hold) gets a fresh preparation notice. Every restart still
requires its own safety check and final warning; an explicit Restart Now remains
available once staging succeeds.

For the launch fix, also pilot direct live opening after Defer, a second manual
launch, preview alongside live UI, recovery from a stopped/unavailable broker,
locked desktop before first notice and lock/close before acknowledgement. Verify
no deadline starts while locked or disconnected, and background task/PSADT
retries do not repeatedly bring a deferred notice to the foreground. Check a
missing/invalid branding or XAML file in an isolated preview copy: it must report
a startup error in the console/dialog and UI.log. Windows named events, WPF
dispatch/activation, PSADT user launch and actual task integration require this
pilot; the portable regression harness mocks those boundaries.
