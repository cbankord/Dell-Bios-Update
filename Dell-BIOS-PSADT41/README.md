# Dell BIOS v3.1 — scheduled installation and guarded restart

Build with `Builder/Start-PackageBuilder.cmd`, using your approved Dell BIOS EXE
and prepared PSADT 4.1.x ZIP. Review the generated `READ-ME-FIRST.txt` before upload.
The builder keeps your custom framework and generates BIOS settings, branding,
Intune scripts and a runtime integrity manifest. No BIOS/password is in Git.

## User experience

1. Intune runs the PSADT package as x64 SYSTEM. Files are validated and refreshed
   under `%ProgramData%\Medela\DellBIOS` (`C:\ProgramData\Medela\DellBIOS` normally).
2. The compact branded UI runs once in the signed-in standard user's session.
   **Install Now** starts preparation through SYSTEM after all safety checks.
   **Schedule Install** opens a local date/time picker within the original window.
   **Defer**, closing the window or timing out before the deadline returns a retry,
   keeping any existing appointment. The schedule can be changed before expiry.
   The notice shows days/hours/minutes until Install Now becomes the only option.
3. A fixed window (72 hours by default) is saved immediately before the first
   prompt launch into an active user session. This is a delivery-attempt timestamp,
   not proof the notice was read. Launch failures, crashes, sign-outs and retries
   retain it. No active user means no new deadline and no firmware staging.
4. After expiry, the installation prompt removes Schedule Install and Defer,
   prevents normal closing, and visibly counts down its prompt timeout before requesting preparation.
   Power/model/hash/password/BitLocker/transaction checks still apply.
5. During preparation an animated progress bar shows activity. It does not invent
   a Dell percentage or claim firmware is complete. Closing this window minimizes
   it; losing the window never terminates a running BIOS updater.
6. After successful staging, a movable/minimizable restart warning shows the
   required message, local restart time and **60-minute countdown**. **Restart Now**
   requests an earlier restart; **Minimize** or the window's X minimizes without
   cancelling. At 15/30/45 minutes it restores, centers on its monitor and plays
   the Windows alert sound. SYSTEM requests restart when the countdown expires,
   after checking power, transaction ownership, BitLocker and session continuity.
7. A temporary SYSTEM verification task checks actual BIOS and restores/verifies
   owned BitLocker protection after reboot. It unregisters after a definitive
   result. Staging or accepting an install is never reported as completion.

The restart countdown exists only in the current SYSTEM deployment process;
there is no future shutdown timer or restart task. It cancels on unsafe/unknown
power, detected sleep/resume or monitoring/clock interruption, session change,
or UI failure. The prompt retires and its temporary status files are removed.
After a crash or total power loss, cleanup waits until the post-boot verifier can
remove its old-boot status files, or the next package invocation removes leftovers.
The original install deadline, staged transaction, recovery files and verification
task remain. Deleting those before verification would break the recovery workflow.

**A selected installation time uses one temporary task.** SYSTEM retains a
complete approved copy of your custom framework and package in private
`State/ScheduledPackage`, then registers `ManagedDellBIOS-ScheduledInstall`.
The picker requires at least five minutes' notice. Dates appear in local time;
state and the task boundary pin the UTC instant. Skipped/repeated daylight-saving
times are rejected. Changing time zones changes the display, not the appointment.
A saved reschedule replaces the same task and preserves the original deadline.
Rescheduling is available when a deployment attempt offers the notice; there is
no persistent tray or standalone scheduling entry point.

At the selected time, preparation begins without a second consent prompt, with
visible progress and all safety gates. The device must be awake, have an active
user session and meet the configured power requirements. If asleep/offline or
signed out, the appointment remains due: the local task starts when available
and retries every 15 minutes. It does not wake the computer, require network
connectivity for launch, or bypass escrow/other checks that may need connectivity.
Power holds are explained at the reminder interval instead of every task retry.
The task has no execution timeout and never stops a running updater on AC loss.
See Microsoft's [repetition rules](https://learn.microsoft.com/en-us/windows/win32/taskschd/repetitionpattern-duration)
and [execution limit](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-executiontimelimit).

After staging, the install task is retired before the existing restart countdown.
It never schedules a restart. The post-boot verifier removes the protected package
copy after a definitive result; unresolved transactions and their recovery remain.
If the task discovers an already-current healthy BIOS, it retires its trigger but
leaves its own running framework for a subsequent Intune invocation to clean.
Detection remains pending while that private copy remains. Do not replace pending
scheduled runtime with another release/package; finish or review that work first.

**Without a selected time, Intune owns later attempts.** Deferral reminder hours
are a cooldown, not a trigger or guaranteed 72-hour execution. After a cancelled
restart countdown, the next Intune attempt checks the original deadline and gives
an already-staged update a fresh full warning without reflashing. Monitor staged
updates and owned BitLocker suspension.
An independent user/Windows restart is outside this package's power gate. The
managed restart uses `/r /t 0` without `/f`; applications may block it. No Windows
countdown is armed, since a nonzero shutdown timeout implies forced app closure.
See [Microsoft's shutdown options](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown).

## Storage and automatic file refresh

| Location under `C:\ProgramData\Medela\DellBIOS` | Contents / access |
|---|---|
| `Runtime` | Versioned helper scripts and policy; SYSTEM/Administrators |
| `UI` | Prompt, branding and PNG/JPG assets; users read/execute only |
| `State` | Original deadlines, selected install time, enrollment, manifest and locks; SYSTEM/Administrators |
| `State/ScheduledPackage` | Temporary complete source, including credential file when required; SYSTEM/Administrators only |
| `Recovery` | Guarded firmware copy, post-boot scripts and logs; SYSTEM/Administrators |

`UI/Live/<session-id>/Status.json` is a temporary SYSTEM-written, user-readable
display feed. It contains phase/countdown/heartbeat only, never credentials.
Users cannot change the deadline or send privileged commands through this file.
The UI closes if the file disappears or its heartbeat becomes stale.

No files are newly installed into Program Files. **The shared `Medela` parent's
permissions and owner are never changed.** If absent, it is created with normal
inherited permissions. Only `DellBIOS` and its contents receive explicit cache
ACLs, enforced by a path boundary in the permission helpers. New owned directories
are created with protected ACLs immediately; they do not briefly inherit broad
shared-folder grants. Private and user-readable child folders keep their separate
permissions. Sibling application permissions and contents are untouched.

The read-only parent check accepts ordinary create-file/create-folder/write
grants and skips inherit-only entries; `DellBIOS` disables inheritance. It still
blocks untrusted parent ownership, an unrestricted DACL, or nonadmin grants that
apply to the parent and permit deletion, child deletion, permission changes or
ownership changes. These can undermine a protected child's path. The diagnostic
identifies the offending SID/rights instead of requesting a shared-folder reset.
See [shared-folder troubleshooting](OPERATIONS.md#shared-medela-folder-permissions).
Credentials remain in the protected deployment package and private scheduled copy, never the
user-readable UI or version/hash manifest.

Each managed PowerShell file has its own version marker, for example:

```powershell
# MedelaBIOS-FileVersion: 3.1.0
```

XAML uses the same marker inside an XML comment. The build-generated
`Files/RuntimeManifest.json` records versions and SHA256 hashes; images use their
branding version in the manifest. Each deployment invocation validates source
files against the manifest and compares them with the installed copy:

| Installed condition | Action |
|---|---|
| Missing, unversioned or older | Copy the packaged file |
| Same version, different SHA256 | Repair from the trusted package |
| Same version and SHA256 | Leave the file untouched |
| Newer version | Stop the older package; no automatic downgrade/mixed release |
| Firmware unresolved or a retained schedule pending and replacement needed | Hold until verification/recovery and private source cleanup resolve it |

The marker is a version identifier; the hash detects drift. Neither authenticates
a publisher. Trust comes from the reviewed Intune package and your signing policy.
Dell Authenticode and the separately approved BIOS SHA256 remain mandatory.
State, firmware transactions and credentials are never replaced by this updater.
All required source files are verified before copying; staged copies are verified,
individual replacements are atomic, and the installed manifest is committed last.
A failed refresh does not run cached code. The next attempt repairs remaining files.
The collection of files is not one filesystem-wide atomic transaction.

For a code release, increment the tattoo in each changed managed source file.
Use the builder to regenerate the manifest. For approved edits or signing of an
already built Source folder, regenerate hashes **after** the final bytes change:

```powershell
# From the trusted repository's Dell-BIOS-PSADT41 folder:
. .\Files\Simple\Cache.ps1
Write-RuntimeManifest -Files 'C:\Path\To\Build\Source\Files'
.\Build-IntuneScripts.ps1 -PackageRoot 'C:\Path\To\Build\Source' -OutputDirectory 'C:\Path\To\Build\Intune'
```

Then sign the regenerated Intune scripts if required, rebuild `.intunewin`, and
replace Intune's detection script as well as its package content. Detection embeds
the approved runtime hashes so code/branding repairs are offered even when the
BIOS is already current. Never resolve a mismatch by disabling the check.
Replacing branding with the builder is supported; direct cached edits will be
repaired back to the packaged branding. Same-BIOS-version reinstallation now
refreshes code/branding safely; it does not grant a new deferral window.

## Intune configuration

Microsoft documents interactive Intune installations and forced user-session UI
as unsupported. This package uses PSADT's session helper for the requested prompt;
that does not make it an Intune-supported interactive installation. Validate the
actual tenant/framework/session behavior in a Windows pilot before rollout.
See [Microsoft's Win32 installation guidance](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program).

| Setting | Value |
|---|---|
| Install behavior | System; x64 Windows PowerShell 5.1 |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Device restart behavior | **No specific action** |
| Installation time required | Cover the install prompt, full restart countdown, measured staging time and margin; start the pilot at 180 minutes |
| Return code `0` | Success only after actual BIOS and protection checks |
| Return code `1618` | **Retry** — deferral, no user, staged pending restart or transient hold |
| Return code `60001` | Failed — review logs / unresolved error |
| Detection | Generated `Intune/Detect-BIOS.ps1`, 64-bit |
| Requirement | Generated `Intune/Require-Model.ps1`, 64-bit Boolean equals True |
| Compliance audit | Generated `Intune/Audit-BIOSAndBitLocker.ps1` |

Internal installer `3010` is consumed by the wrapper and never sent to Intune as
a competing reboot timer. Detection requires actual target-or-newer BIOS, stable
protection and a resolved transaction when one exists. It does not detect controller
enrollment or accept a staged capsule. It also checks the expected runtime hashes;
old/missing/modified helpers trigger safe repair without reflashing a current BIOS.
Retained scheduled source must also be cleaned before detection reports success.
Intune retry/re-evaluation can show a pending
or failed application while awaiting user action; pilot your assignment cadence.
Microsoft describes Retry as three attempts five minutes apart and required-app
re-offering at approximately 24 hours. A four-hour reminder setting therefore
does not promise a four-hour notification. The install timeout includes time
spent waiting for user choices; never terminate a BIOS updater to meet a timer.
See [Microsoft's retry and detection rules](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32).
Updating package content alone does not replace an old tenant detection script:
replace the old enrollment-based detection with the generated detection above.

The selected custom framework may have its own bootstrap/extensions/restart
behavior. Review it. The builder preserves it rather than certifying arbitrary
code. BIOS downgrade/uninstall/repair entry points intentionally fail; do not use
an Intune uninstall assignment to reset deployment or firmware state.

## Preview and diagnostics

As a standard user, from a package or the repository folder:

```powershell
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo -Mode Progress
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo -Mode Restart
```

Preview includes the Schedule Install picker and cannot create a task, stage/restart,
or change deployment state. The restart preview
counts down and demonstrates reminders, then closes without restarting. For a
shorter UI pilot use `-Demo -Mode Restart -RestartMinutes 15 -RestartReminderMinutes 1`.
This is a display simulation, not the privileged safety monitor. Close exits;
there is no tray client. The installed UI is launched by PSADT with live context,
not used as a standalone installation entry point.

Administrator log location:

```powershell
Get-Content "$env:ProgramData\Medela\DellBIOS\Recovery\Deployment.log" -Tail 60
```

Also inspect PSADT logs for entry/launch errors and protected `Dell-*.log` output
for vendor results. Do not share passwords, recovery keys or generated credential
packages. See [OPERATIONS.md](OPERATIONS.md) for migration and Windows pilot gates.

Manual source packaging still requires valid reviewed BIOS config, the approved
EXE, a local ignored BIOS-Password.psd1 when required, the integrated PSADT install
function, runtime manifest and regenerated Intune scripts. The checked-in example
config is not approved: its SHA256/model/EXE combination must be corrected using
the real payload. Prefer the builder, which calculates the hash from copied bytes.
