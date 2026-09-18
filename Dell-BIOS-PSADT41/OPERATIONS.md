# Medela BIOS operations and Windows pilot

For direct PS1 metadata/section authoring and safe saves, see the
[direct editor guide](Builder/Direct-Script-Editor-Guide.md). This changes authoring
files only; it does not execute an app or modify an endpoint cache.

For Windows Update, Dell Driver and PSADT section templates, use the
[servicing/editor guide](Builder/Servicing-and-Editor-Guide.md). Those generated
modes use Intune restart handling, require tested detection, and do not use BIOS
state or the BIOS countdown. The remaining BIOS operations below still apply.

## V4.4 package modes

The latest v4 builder is **PSADT Deployment Builder v4.4**. Choose **BIOS update**
**Application**, **Windows Update** or **Dell Driver** on Files. Old presets default to BIOS; switching/loading clears
the password and review. Application mode preserves a complete supplied PSADT
4.x or legacy 3.x deployment and its experience in the default PSADT view.
Editor can replace supported PSADT 4.x sections. It packages app metadata,
optional detection and Intune instructions without adding managed BIOS behavior.
See [the application guide](Builder/Application-Guide.md).

Check `BuildManifest.json`: `BuilderVersion` must be `4.4.0`; `PackageType` must
match the selected `BIOS`, `Application`, `WindowsUpdate` or `Driver` path. Use the README and Intune files
from that build. Do not use BIOS detection/requirements or BIOS return-code
mappings for software applications. An app without a supplied detection script
requires app-specific detection configured in Intune before assignment.

This release changes the builder, not existing endpoint BIOS runtime logic.
Application source owns its install/uninstall, branding, prompts and restart
behavior; the builder never runs it. Existing BIOS schedules, state, recovery,
power/BitLocker guards and Medela parent/sibling permissions remain intact.
Pilot the selected modes, saved/legacy presets, password clearing and app Close with no
secret, plus actual application install/uninstall/detection and the selected
Intune context. Windows native dialogs and app execution were not tested here.

## Output selection introduced in v4.1

Use the latest v4 branch and launch its `Builder/Start-PackageBuilder.cmd`; the
caption reads **PSADT Deployment Builder v4.4**. On **5 Build**, select **Output
folder → Choose folder** or enter an existing local destination. New sessions
have no default output path; existing presets keep their saved `OutputRoot`.
Confirm `BuildManifest.json` records `BuilderVersion` `4.4.0` and the expected
`OutputRoot` / unique `OutputDirectory`. The chosen parent contains Source,
Intune scripts and optional Package/.intunewin under one new protected build folder.

Rebuild the full package and matching detection to deliver the literal-path cache
helper fix (`Cache.ps1` tattoo 4.1.0); other runtime files keep their own versions.
The v4.0.1 PSADT launch fix is included. Existing replacement holds, appointments,
deadlines, recovery and Medela parent/sibling permission boundaries still apply.

Windows pilot for this change: choose/create a folder in the native picker, cancel
with and without a prior selection, type another local drive/path, load an older
preset and build with a destination containing spaces and brackets. Check owner/
focus behavior with the custom caption at 100/150/200% scaling, verify the displayed
and actual paths match, and confirm the selected parent/siblings retain their
permissions and contents. Test Open output and graceful Close during a build.
Native folder dialogs, Windows ACLs and Microsoft content-prep execution are not
proved by the portable tests. Continue the deployment/hardware pilot below.

## Moving from v3 to v4

V4 branches from latest v3 (`243f384`) and keeps the existing package identity,
deadline state and firmware recovery workflow. Main/v2/v3 remain unchanged.
Rebuild with the v4 builder and deploy the **complete package and matching new
Intune detection**. New presentation helpers and policy cannot be delivered by
copying only `Show-BiosUI.ps1`. V4 presentation files use 4.0.0 tattoos; the
v4.0.1 launch fix uses 4.0.1 on `Deployment.ps1` and `Live.ps1`, and the v4.1
literal-path fix uses 4.1.0 on `Cache.ps1`. Other files
retain their own versions. There are 15 core managed files plus brand assets.

**Allow schedule later** defaults to enabled, including imported v3 presets
without that field. `$false` removes Schedule Install and prevents new/rescheduled
appointments in privileged code, while preserving deferrals, the fixed deadline
and the post-install restart countdown. Use literal Booleans, not quoted strings.

| Existing work | V4 migration behavior |
|---|---|
| No accepted appointment or unresolved firmware | Apply verified runtime/policy safely; preserve any enrolled original deadline |
| Accepted appointment with retained package | Changed incoming package logs a hold and returns 1618 before cache/state replacement or a new notice |
| Accepted work reaches its chosen time | Original retained source/task runs with all safety checks and visible progress, without another scheduling notice |
| Staged/ambiguous firmware or protection recovery pending | Preserve runtime/transaction/recovery until definitively resolved |
| Accepted work verified and private source cleaned | Apply incoming runtime/policy on the next attempt; no fresh deadline |
| Existing accepted state already belongs to the running disabled policy | Keep/repair its task and honor it when due; reject all new schedules/reschedules |

This is a hand-off, not an immediate rewrite of an accepted v3 package. Remove
competing older Intune assignments when rolling out v4 so an older package cannot
independently display its enabled scheduling policy. Leave its accepted local
task/private source intact. The incoming disabled package never offers scheduling;
its new runtime/settings take effect after the retained work resolves. A different
BIOS package also waits. Never edit private state, remove recovery tasks or delete
`State/ScheduledPackage` to force the transition. A persistent failure requires IT
review using the retained logs and original recovery workflow.

## V4 window and policy pilot

Portable regressions exercise real decision code with inert Windows boundaries.
They do not validate actual WPF rendering, Windows PowerShell 5.1 or firmware.
Run the native smoke check as a signed-in standard user from the repository:

```powershell
powershell.exe -NoProfile -STA -File .\Tests\V4\Test-WindowsUI.ps1
# Optional: also exercise decoding your actual branding file.
powershell.exe -NoProfile -STA -File .\Tests\V4\Test-WindowsUI.ps1 -IconPath C:\Branding\device-care.ico
```

It loads both real XAML windows, theme/icon and caption handlers with an inert
Closing guard. It does not load deployment logic, create tasks or flash/restart.
Then complete these manual checks in addition to the firmware pilot below:

- Build and save/reload both checkbox states. Import an old preset with no flag;
  verify enabled. Check policy, Settings.psd1, BuildManifest.json and Build.log.
- Preview `-Demo`, `-Demo -DisableScheduling`, and each with `-Overdue`. Confirm
  three/two/one installation actions respectively. Preview Progress and Restart;
  preview Close exits without real work. Test the packaged icon on the caption
  and taskbar, the default icon, and rejected invalid image input.
- At 100%, 150% and 200%, on a small display and between mixed-DPI monitors, drag,
  resize, maximize/restore and minimize both apps. All fields/actions must remain
  reachable with scrolling/wrapping. Test high contrast, Tab/Shift+Tab, access keys,
  Enter/Space, Alt+F4, visible focus/hover and Narrator labels/status announcements.
- Test the builder caption/footer Close and Escape while idle, building, handling
  failure and after completion. A queued close must wait for cleanup/disposal,
  leave completed output intact and return to the launching terminal without Ctrl+C.
- Under real PSADT SYSTEM launch, test live progress/restart caption Close and
  Minimize: neither terminates firmware nor cancels the countdown. Test overdue
  Close/Alt+F4 and a stale Defer click. Test reminders after dragging/minimizing.
- With a fresh disabled deployment, verify no `ManagedDellBIOS-ScheduledInstall`
  task/source snapshot is created; Defer still retains the original deadline.
  Create an enabled appointment, then deliver a disabled v4 package. Confirm the
  migration hold, accepted task execution, retained deadline and later activation.
  Repeat with missed time, sign-out, unsafe power and unresolved staged firmware.
- Confirm ordinary Medela parent/sibling ACLs and application access are unchanged.
  Pilot your custom PSADT 4.1 bootstrap, Intune retry/detection and the existing
  60-minute/15-minute guarded restart behavior. Keep Intune on No specific action.

## Moving from the older v2 scheduler

Rebuild with the current builder and replace both the Intune package and its
old enrollment-based detection script. Use the generated actual-BIOS detection.
Replace detection on every subsequent code/branding package update too; it embeds
the runtime hashes that request file repair even on an already-current BIOS.
Remove the older package assignment so it cannot recreate the retired tasks.
Run the updated package as SYSTEM; no manual Program Files editing is required.

When safe, the updated deployment automatically:

1. Acquires its package lock and the legacy setup/firmware locks.
2. Rejects running, staged, failed/ambiguous or recovery-pending firmware.
   A legacy Preparing/RestartRequired/Verifying/NeedsAttention phase also blocks.
3. Validates and retires only `ManagedDellBIOS-v2-Controller` and
   `ManagedDellBIOS-v2-UserUI`. It does not terminate a BIOS or verifier process.
4. Imports the matching original deadline/window into protected Medela state.
   Old selected times/immediate intent become due for a new package prompt;
   the retired v2 restart appointment is not reinterpreted as a v3 installation
   appointment. The user may select a new installation time only within the
   original remaining window. No new three-day window is granted.
5. Stops only processes whose `-File` argument identifies the exact old UI,
   removes `C:\Program Files\ManagedDellBIOS-v2`, and records retirement.
6. Installs/refreshes the reviewed versioned files under
   `C:\ProgramData\Medela\DellBIOS`.

Old protected `C:\ProgramData\ManagedDellBIOS` data is left inert for diagnosis;
the new package does not run its controller or use it as an active cache. The
firmware transaction registry identity `HKLM:\SOFTWARE\ManagedDellBIOS` and
`ManagedDellBIOS-VerifyAndResume` task identity are retained so unresolved work
cannot be hidden by a folder change. Do not delete them to force a retry.
If the old BIOS is staged, complete and verify it using the existing guarded
workflow first. The updater will deliberately refuse to replace its recovery code.

If legacy tasks reappear after retirement, an old assignment is still running.
The new package stops for review; it does not race a second controller. If an
upgrade fails after safe task retirement, rerun the corrected package. Deadline
state is preserved and interrupted file replacement is repaired from source.

## Shared Medela folder permissions

`C:\ProgramData\Medela` is shared with other applications. The deployment does
**not** change its owner, remove inheritance, replace its ACL, or recurse through
sibling applications. It applies permissions only to `Medela\DellBIOS` and owned
contents. Cache ACL helpers refuse the shared parent, sibling paths, prefix
lookalikes and `..` escapes. Reparse paths remain rejected.

Versions before 3.0.1 rejected all nonadmin Write entries, including inherit-only
rules. V3.0.1 accepts ordinary file/folder creation and write-attribute grants on
the shared parent and skips entries that apply only to descendants. The owned
DellBIOS root has inheritance disabled, so it does not adopt those grants. New
owned directories receive their protected ACL in the .NET Framework directory
creation call, before they become accessible under inherited permissions.
See [Microsoft's inheritance rules](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules)
and [directory creation with security](https://learn.microsoft.com/en-us/dotnet/api/system.io.directory.createdirectory?view=netframework-4.8.1#system-io-directory-createdirectory(system-string-system-security-accesscontrol-directorysecurity)).

The shared-parent check remains read-only and conservative. An allow entry for
Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership or generic
FullControl applying to the parent can allow replacing the protected path.
Windows can authorize deletion/renaming through either the object or its parent;
[child permissions alone do not eliminate a parent delete-child grant](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-deletefilew).
Untrusted ownership and an unrestricted/null DACL also stop caching. This checker
does not calculate effective access for every domain group or subtract deny ACEs;
it reports a potentially dangerous allow entry for review and never rewrites it.

If the revised check still stops, collect the SID/rights in the new error and
these read-only results:

```powershell
(Get-Acl -LiteralPath 'C:\ProgramData\Medela').Owner
icacls.exe 'C:\ProgramData\Medela'
```

Keep the shared folder's permissions as required by its applications. If its
parent-replacement rights are required, review a separate protected cache design
with IT; this release does not silently relocate the cache or offer a safety
bypass. Do not remove this check, reset the shared ACL, or delete firmware state
to make an unsafe location pass.

Rebuild with the updated v4 builder and replace both the Intune package and its
generated detection script. Managed files retain individual version tattoos;
the v4.0.1 launch fix updates `Deployment.ps1` and `Live.ps1` to 4.0.1.
Never edit just a cached script or reuse the old
runtime manifest/detection hashes. Pending firmware recovery still blocks code
replacement until that transaction is resolved.

On Windows, compare the parent and sibling owner/DACL before and after initial
deployment and a repeat. Validate that a standard user can access the other
applications normally, can read the BIOS UI, and cannot modify, rename, delete or
replace the BIOS root/private code. Exercise both allowed create/inherit-only
grants and blocked parent-replacement grants in an isolated test directory.
The portable regression models Windows ACL APIs; it does not prove NTFS access.

## What persists

The active cache is limited to `Medela\DellBIOS`. UI files are read-only for users;
private runtime, state, firmware/recovery files and logs are SYSTEM/Admin only.
The shared BIOS password stays in the deployment package and, after scheduling,
its private `State/ScheduledPackage/Source` copy. The snapshot is removed after
definitive verification; it must never become readable to standard users. Intune and your PSADT
framework may maintain their own caches/logs outside this application folder.
The package does not relocate or delete those platform-owned directories.

A first prompt launch attempt starts a durable deadline. No signed-in active
user means retry with no new deadline. Once started, exceptions, deferrals, code
refresh, sign-out, reboot and reinstallation cannot reset it. Missing enrolled
state and corrupt/extended deadlines fail closed. Existing pending deadlines
retain their original duration even if future policy chooses another value.

Before the deadline, the notice offers Install Now and Defer, plus Schedule
Install when AllowScheduleLater is enabled.
Schedule Install uses a local date picker and editable 24-hour HH:mm time, at least
five minutes ahead and no later than the original deadline. Defer/X/timeout keeps
any saved appointment. A skipped/repeated DST time is rejected. A reschedule
updates the same UTC appointment, never the deadline. After expiry the prompt
removes schedule/defer and requests preparation after its visible timeout.

Scheduling copies the complete generated PSADT Source into private
`State/ScheduledPackage`, verifies copied bytes, and commits Ready.json last.
It then saves the appointment and registers the SYSTEM task
`ManagedDellBIOS-ScheduledInstall`. No BitLocker suspension occurs here. The task
uses the retained EXE with a fixed working directory and silent Install arguments,
so Intune's temporary content need not survive. Its sole UTC trigger begins at
the selected instant and repeats every 15 minutes until staging or a transaction
requiring recovery retires it. A registration interruption retains saved intent;
the next invocation repairs a missing/stale task from that state. A different
package or changed runtime cannot replace an unresolved retained appointment.

The task starts when available, does not wake the device, and has no battery-stop,
execution-timeout or parallel-instance policy that can terminate an updater.
At a due appointment SYSTEM checks for an active user and rechecks prerequisites.
It starts visible preparation without a second consent prompt only when safe.
Signed-out/sleeping/offline devices retain the due time and overdue status; local
launch does not need Intune connectivity, while escrow may still need network.
Power holds show an explanation at the reminder interval. Other prerequisite
holds/errors are logged; the original firmware/recovery guards remain in force.

Without a selected appointment, Intune supplies retry/re-evaluation timing. The
reminder setting limits interruptions and does not create a reminder task or
promise exact deadline execution. Killing the UI never erases the fixed window.
After staging, the temporary install task is removed without stopping its current
process. The post-boot verifier acquires the package lock before the firmware lock
and removes the retained source after a definitive result. Cleanup failures retain
the verifier for retry. An already-current healthy BIOS discovered by the retained
framework removes its trigger and waits for a later Intune invocation to delete
that framework; detection refuses success until this private copy is gone.

After staging, SYSTEM runs a 60-minute countdown (configurable) in the current
deployment process. Restart Now requests an earlier restart. Minimize/X keeps the
countdown running; every 15 minutes the prompt restores, centers on its monitor
and plays the Windows alert sound. Audio follows Windows mute/volume settings;
foreground activation, lock-screen behavior and multi-monitor DPI need piloting.
Only an animated activity bar is shown during preparation; there is no fabricated
firmware percentage and completion still requires actual post-boot verification.

Every countdown poll checks power and the same active user session. Before restart,
the full model/power/transaction/BitLocker guard runs under the firmware lock. A
sleep/resume indication (elapsed-vs-awake clock bias above two seconds), monitoring
gap over 30 seconds, clock adjustment over 30 seconds, unsafe power, lost session
or unexpected UI exit cancels the countdown. A cancelled prompt shows a brief
explanation and closes. Windows sleep detection uses GetTickCount64 and
[QueryUnbiasedInterruptTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttime);
Modern Standby/hibernate behavior must be verified on each pilot model.

There is no restart scheduled task and no future OS shutdown timer to cancel.
The request is `/r /t 0` without `/f`; applications can block the restart. The
package never calls a global shutdown abort that could cancel another updater's
restart. Keep Intune on No specific action and review other tenant restart rules.
No code can clean files while a device is powered off: the next invocation removes
stale `UI/Live` status folders under the package lock. The UI also closes on a
missing/stale SYSTEM heartbeat, without issuing any restart itself.
After a definitive post-boot result, the verifier removes only UI status from
the transaction's previous boot before retiring its task. It leaves current-boot
UI sessions alone. Thus a successful detected BIOS need not wait for another
Intune install just to remove its interrupted prompt files.

Cleanup deliberately retains the staged transaction, original deferral deadline,
firmware/recovery files and verifier task until the outcome is resolved. Never
delete all scheduled tasks or resume BitLocker over a staged capsule just because
power became unsafe. The existing verifier handles owned protection after reboot.
The next Intune attempt gives staged firmware a fresh full warning without flashing
again; monitor outstanding suspension and failed transactions. Independent Windows
or user restarts cannot be power-gated by this script. Do not interrupt a running
Dell updater because its progress window closes or power becomes unsafe.

The verification task is temporary, runs as SYSTEM after boot (five-minute delay)
and on recovery retries, verifies actual BIOS and owned drive protection, and
unregisters after a definitive result. A failed BIOS result remains recorded and
blocks automatic reflashing. No reboot count of zero, forced flash, forced process
kill or bypass of model/power/signature/hash/escrow checks is introduced.

## Troubleshooting

### Install Now fails with a parameter-set error and 60001

V4.0.1 fixes a reproduced PSADT compatibility defect in the progress-window and
BIOS-worker launches. PSADT 4.1.4-4.1.8 reject `-IgnoreExitCodes '*'` together
with `-NoWait`; passing `-NoWait:$false` also binds the incompatible parameter.
See the official
[4.1.4 worker function](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/4.1.4/src/PSAppDeployToolkit/Public/Start-ADTProcess.ps1)
and [user-process function](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/4.1.4/src/PSAppDeployToolkit/Public/Start-ADTProcessAsUser.ps1).
`60001` here is the deployment wrapper's failure code, not a Dell BIOS return code.
The failing progress-launch call precedes worker launch; the generic error alone
does not prove whether a previous attempt staged firmware.

1. Download the latest **v4** repository content. Close the old builder and launch
   `Builder/Start-PackageBuilder.cmd` from the updated copy.
2. Load your preset and use the same approved BIOS, settings and prepared PSADT
   4.1 ZIP. Re-enter the password locally if required. Build a fresh complete
   package; there is no need to downgrade the framework for this correction.
3. Confirm `BuildManifest.json` has `BuilderVersion` equal to `4.4.0` (current), and generated
   `Source/Files/Simple/Deployment.ps1` and `Live.ps1` start with version `4.0.1`.
   Follow the existing final-signing/manifest regeneration instructions if applicable.
4. Replace the Intune package **and its matching generated detection script**, or
   run the newly generated complete Source through the existing SYSTEM pilot
   method. Do not deploy an older build or edit cached files independently.

Normal cache refresh replaces the corrected helpers while preserving the fixed
deadline and state. Do not delete `C:\ProgramData\Medela\DellBIOS`, reset its
state, or remove recovery tasks. Accepted appointments and unresolved firmware
still block replacement; a retained older package that keeps failing requires
IT review of its logs and transaction status, not a forced cache reset.

The new log entries distinguish `Starting progress UI through PSADT` from
`Starting BIOS preparation worker through PSADT`. If the error persists after
rebuilding, collect the surrounding Deployment.log and PSADT log lines plus the
module version from your selected template's `PSAppDeployToolkit.psd1`. Other
custom-framework parameter conflicts can produce the same generic message.

### Missing actions or UI diagnostics

If only Install Now and Defer appear, check AllowScheduleLater first: this is the
intended v4 disabled state. A prompt older than v3.1 also lacks scheduling.
To enable it, rebuild with the v4 checkbox selected and deploy the entire new
Source/package plus matching detection, subject to accepted-work migration holds.
Do not copy only XAML or a cached script: scheduling also needs the new helper,
state integration and manifest. Confirm the first-line tattoo in the package and
cached `UI/Show-BiosUI.ps1` is 4.0.0. If firmware is already current, use preview;
a healthy target-or-newer BIOS intentionally skips the live install notice.

Use the latest package's `Files\UI\Show-BiosUI.ps1 -Demo` in fresh Windows
PowerShell 5.1 with `-STA`. It runs independently of enrollment and reports startup
errors in the console/dialog. A standard user does not write SYSTEM runtime logs.
Live UI errors are captured by the PSADT parent into Deployment.log where possible;
a launch error before the parent can log is available in the PSADT log.

```powershell
# Administrator / SYSTEM diagnosis; do not export full BitLocker protector objects.
Get-Content "$env:ProgramData\Medela\DellBIOS\Recovery\Deployment.log" -Tail 60
Get-ScheduledTask -TaskName 'ManagedDellBIOS*' | Select-Object TaskName, State
Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion
Get-BitLockerVolume -MountPoint $env:SystemDrive |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus
Get-Content "$env:ProgramData\Medela\DellBIOS\State\InstalledFiles.json" -Raw
```

`Cache refreshed` logs name the file, version and reason. Current files are not
rewritten. Incoming manifest failures mean rebuild/sign first and regenerate the
manifest; do not edit the installed marker. A newer cached tattoo means the old
package must not overwrite it. A transaction safety hold means resolve the BIOS
operation first. Neither case should be addressed by deleting state.

## Required Windows pilot

Microsoft does not support interactive Intune installations, including techniques
that launch UI into a user's session. The PSADT helper is used for the requested
experience, but this remains a platform support limitation, even after a successful
pilot. See [Microsoft's guidance](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program).
Set the Intune installation timeout above the install prompt plus full restart
countdown, measured staging time and margin (180 minutes is a starting pilot
value). Raise it further for a longer configured countdown or slower tested EXE.
Never shorten this budget by killing an updater.

- Windows PowerShell 5.1, PSADT 4.1.x custom framework: standard-user prompt via
  SYSTEM, no console flash/UAC, no competing custom bootstrap or restart timer.
- Preview/install/progress/restart/info modes, logo/banner changes, keyboard/screen-reader
  labels, 100/150/200% scaling, small displays, long company text and timeout.
- Fresh install under Medela, no Program Files creation or recurring controller/UI
  tasks. Verify parent/child ownership and ACLs, including a pre-existing Medela
  folder shared with another app and rejection of writable parents/reparse points.
- Same BIOS/hash rebuild: older/missing/drifted files repaired, newer files refused,
  current files left alone, unchanged deadline/state, no secret in public assets.
- Legacy migration: pending/overdue states, active transaction holds, exact old
  tasks/process retirement, recovery continuity, old assignment removed.
- Schedule picker in preview and live mode, past/out-of-window/ambiguous DST input,
  reschedule within the unchanged deadline, Defer keeping the appointment, expiry
  leaving only Install Now, local time-zone changes preserving the UTC instant.
- The scheduled task launches your full custom framework as SYSTEM with its fixed
  working directory after Intune content removal; standard-user progress appears.
  Test signed-out, locked, asleep, powered-off and offline appointments; safe retry
  without a new window; repeated unsafe-power attempts without repeated prompts.
- Registration failure before/after state persistence, missing/stale task repair,
  package/task conflict, concurrent Intune/task attempts, retained-source ACLs and
  insufficient disk space. Use inert payloads for interruption tests. Verify task
  retirement after staging, post-boot credential-source cleanup, cleanup retries,
  and already-current firmware cleanup without deleting a running framework.
- Real selected Dell EXE/model/password and Authenticode; 50% vs 51%, missing AC,
  optional runtime threshold, free space, pending Windows restart and encryption
  transitions. Check the safe hold and user explanation in each failure case.
- Recovery-key backup/retrieval and finite BitLocker suspension immediately around
  staging; 60-minute expiry, 15/30/45-minute sound/recenter, minimizing/X, Restart
  Now safety checks, sleep/hibernate/Modern Standby, AC loss and 50% vs 51% during
  the countdown, session changes, host/UI failure, application-blocked restart,
  independent restart and actual post-boot BIOS/protection verification.
- Intune retry/detection behavior: no staged/enrollment success, no automatic
  Intune restart, no-user/sign-out/locked-screen cases, sleep/offline and repeated
  deferrals. The first attempt is a delivery signal, not proof of user attention.
  Verify code/branding repair is requested on a device whose BIOS is already at
  target, and that completing this repair does not launch the Dell updater.
- Interrupted cache copying, power loss before/after staging using mocks first;
  never interrupt real firmware as a test. Never terminate an updater or clear an
  unresolved transaction to make another flash run.

Portable tests use inert files and mocked Windows boundaries. WPF, actual ACLs,
Intune delivery, PSADT session launching and real firmware are not validated on
this Linux authoring host. See VALIDATION.txt for the reproducible checks.
