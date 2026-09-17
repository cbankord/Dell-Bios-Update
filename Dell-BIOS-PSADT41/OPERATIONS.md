# Medela BIOS operations and Windows pilot

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
   calendar scheduling has been removed. No new three-day window is granted.
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

## What persists

The active cache is limited to `Medela\DellBIOS`. UI files are read-only for users;
private runtime, state, firmware/recovery files and logs are SYSTEM/Admin only.
The shared BIOS password stays in the deployment package. Intune and your PSADT
framework may maintain their own caches/logs outside this application folder.
The package does not relocate or delete those platform-owned directories.

A first prompt launch attempt starts a durable deadline. No signed-in active
user means retry with no new deadline. Once started, exceptions, deferrals, code
refresh, sign-out, reboot and reinstallation cannot reset it. Missing enrolled
state and corrupt/extended deadlines fail closed. Existing pending deadlines
retain their original duration even if future policy chooses another value.

The reminder interval is only a cooldown between package invocations. Intune
supplies the retry/re-evaluation timing; there is no app-created reminder task.
If asleep/offline, enforcement waits for Windows and the next deployment attempt.
An overdue visible install prompt has no Defer and requests preparation after
its visible timeout. Killing the user UI or signing out is not treated as consent;
a later deployment attempt still sees the original expired deadline.

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
