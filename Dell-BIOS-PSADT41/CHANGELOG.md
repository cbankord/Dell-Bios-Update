# v4.0 configurable scheduling and custom window chrome - 2026-09-17

- Branch from v3 `243f384`; preserve Main, v2 and v3. Add the builder's
  **Allow schedule later** checkbox, enabled by default, and literal Boolean
  `AllowScheduleLater` across presets, generated policy, review and build records.
  Legacy presets/policies retain enabled behavior; reject string Boolean values.
- Before expiry, enabled packages show Install Now / Schedule Install / Defer;
  disabled packages show Install Now / Defer. The prompt adapter and privileged
  writer both reject disabled scheduling/rescheduling before creating state,
  source or tasks. Expiry always removes schedule/defer without bypassing safety.
  Deferrals, original deadline, 60-minute restart and 15-minute reminders persist.
- Honor accepted appointments independently of the flag. Preserve the existing
  package/firmware replacement guard: changed incoming code/policy waits until
  retained accepted work runs, verifies and cleans its source. Document when the
  new disabled policy activates and removal of competing older Intune assignments.
  Keep task repair/due execution for existing intent, even under disabled policy.
- Replace both standard title bars with WPF WindowChrome and branded icon/title,
  labeled minimize/maximize/restore/close controls, native caption/resize behavior,
  compact work-area bounds, scroll/wrap layout and shared focus/hover/high-contrast
  resources. Custom Close goes through existing Closing guards: immediate or
  post-cleanup builder exit, live update minimize, overdue close refusal.
- Add separate Theme.xaml, presentation-only WindowChrome.ps1 and builder
  Branding.psd1. Select a local PNG/ICO in the builder, preview it, validate decode,
  size/dimensions and package it with a manifest hash. Use a vector device icon
  when absent. Cache allowlist includes 15 core files plus approved brand assets;
  ICO drift is repaired like other assets. No Medela parent/sibling ACL changes.
- Extend preview with -DisableScheduling and combine with -Overdue; retain
  progress/restart demos with no system actions. Update full-package/detection
  rebuild, signing, preset, icon, migration and Windows pilot instructions.
- Pass 569 assertions across 12 isolated PowerShell 7.4.7/Linux suites, including
  complete inert builds for both flags and PNG/ICO packaging, byte-preserving
  migration holds, due accepted execution, caption dispatch and async cleanup.
  Add a separate Windows-only native WPF smoke script; it was NOT run here.
  Actual PS5.1, WPF/DPI/Narrator, icon decoding, NTFS, SYSTEM PSADT/Task Scheduler,
  Intune and Dell hardware pilots remain required. No endpoint update was run.

# v3.1 restore Schedule Install - 2026-09-17

- Restore the third action in the compact notice: Install Now / Schedule Install /
  Defer. Add an accessible local date picker and editable 24-hour time, selected
  time display, validation errors and confirmation. Preview exercises the picker
  without tasks/firmware. Overdue notices offer only Install Now.
- Persist the selected UTC instant alongside the existing fixed deadline using
  an additive state migration. Require a future selection within that deadline;
  reject malformed responses and skipped/repeated DST times. Deferring retains
  the appointment; rescheduling replaces it without granting another window.
- Retain a complete approved custom PSADT Source privately under
  Medela/DellBIOS/State/ScheduledPackage. Verify copied bytes and publish metadata
  last. Keep shared password data out of public UI, manifests and logs. Never
  change Medela parent/sibling permissions. No early BitLocker suspension.
- Register one temporary SYSTEM install task against that retained framework,
  with an absolute UTC start and 15-minute prerequisite retries. Repair missing
  or stale tasks from persisted intent, reject conflicting tasks/packages, and
  refuse runtime replacement while a retained appointment is unresolved. Missed
  times remain due; no active user or unsafe power means wait, retaining deadline.
- A due safe appointment starts visible preparation without a second consent
  prompt. Check power before launch and preserve the installer's full safety
  gates. Retire the install task after staging without stopping its process;
  the existing one-hour guarded restart warning remains the only restart timer.
- Extend the post-boot verifier to clean the private source after a definitive
  result using the package-then-firmware lock order. Keep identifying metadata
  until credential-source deletion succeeds; recover interrupted cleanup and
  retain verification retries on failure. Preserve firmware/recovery records.
- If retained code discovers an already-current healthy BIOS, retire its trigger
  but defer deletion of its running framework to Intune. Detection remains false
  while private scheduled source remains. Builder 3.1.0 includes the new helper;
  rebuild full content AND matching detection, not individual cached/UI files.
- Pass 465 portable assertions across 11 suites, including 69 schedule/package/UI
  assertions, 24 post-boot cleanup assertions and 42 deployment flow assertions.
  Real file IO/locks and generated packages are exercised; Windows task, trust,
  ACL, WPF, hardware and firmware boundaries remain mocked. Windows PowerShell
  5.1, custom PSADT 4.1, actual task launch/DPI/standard-user access and Dell
  firmware pilots are required. Main and v2 are unchanged.

# v3.0.1 preserve shared Medela permissions - 2026-09-17

- Never apply an explicit ACL or owner change to the shared Medela parent,
  including first install. Create it with normal inherited permissions if absent.
  Constrain every cache permission writer to DellBIOS and its contents; refuse
  sibling, prefix-lookalike and traversal paths before a native permission call.
- Fix the overly broad parent check: accept creation/write-attribute grants and
  ignore inherit-only entries. The protected DellBIOS child does not inherit them.
  Continue to reject untrusted parent ownership, null DACLs and allow entries
  permitting parent/child replacement, with SID/rights in the diagnostic and no
  request to rewrite shared application permissions. This remains a conservative
  allow-entry check, not effective-access evaluation of all domain memberships.
- Create new owned cache folders with a protected ACL immediately using the
  Windows PowerShell/.NET Framework directory creation overload.
- Bump Cache.ps1 and builder records to 3.0.1. Preserve state, recovery, firmware
  gates, UI/countdown behavior and the v2/Main branches. Rebuild package and
  matching detection so file tattoos/hash repair can deliver the change.
- Pass 52 new permission-boundary assertions, 30 real file/cache assertions and
  88 builder assertions on PowerShell 7.4.7/Linux. Windows ACL construction and
  writes are modeled; real NTFS/Windows PowerShell 5.1 checks remain required.

# v3.0 builder Close button - 2026-09-17

- Branch from v2.3; preserve the v2 and Main branches.
- Add a visible, keyboard-accessible Close button to the builder footer. Escape
  and the title-bar X use the same close path; idle exit returns control to the
  launching PowerShell session without Ctrl+C.
- During a build, queue one close request, show Closing..., and close after the
  worker completes or fails, finishes its existing partial-output cleanup, and
  releases its worker/password resources. Do not terminate packaging midway.
- Identify the builder window and build records as v3/3.0.0. The deployed BIOS
  workflow, runtime version tattoos, countdown and safety gates are unchanged.
- Document graceful close behavior and the remaining Windows UI pilot checks.
- Pass 88 existing builder assertions and 21 close/async-cleanup assertions on
  PowerShell 7.4.7 with inert workers and mocked WPF controls. Actual Windows
  PowerShell 5.1 and WPF button/keyboard/terminal behavior still need pilot checks.

# v2.3 progress and guarded restart warning - 2026-09-17

- Keep Install Now / Defer and explicitly show days/hours/minutes until Install
  Now becomes the only option. Explain the post-staging restart countdown before
  the user begins installation.
- Show a real activity indicator while the guarded installer runs asynchronously;
  do not fabricate firmware percentages or terminate a worker after UI loss.
  Support PSADT 4.1 LaunchInfo.Task and immediate ProcessResult outputs.
- After staging, show a movable/minimizable 60-minute restart warning. Restore,
  center and play the Windows alert every 15 minutes. Minimize/X does not cancel;
  Restart Now or expiry uses the same SYSTEM transaction/power/BitLocker gate.
- Keep one live SYSTEM countdown, with no restart task or future OS shutdown
  timer. Cancel on unsafe power, sleep/resume or monitoring/clock interruption,
  session loss/change, UI failure or restart refusal. Never force applications
  closed; Windows can block a requested restart.
- Remove only disposable UI status. Preserve the original deadline, staged
  firmware and BitLocker verifier until recovery is resolved. Clean crash/power
  loss leftovers after a definitive post-boot result (old-boot UI only) or on the
  next package run; never claim cleanup can run while off.
- Add versioned Live.ps1, bump changed managed files to 2.3.0, expose countdown
  settings in the builder, and update Intune timeout/pilot documentation.
- Add actual asynchronous Task/file-IO/countdown and UI callback regressions.
  Native Windows clocks, WPF sound/activation/DPI, ACLs, PSADT session launch and
  real firmware still require a Windows pilot.

# v2.2 simple deployment and Medela file refresh - 2026-09-17

- Replace the resident broker, recurring UI/controller tasks and calendar picker
  with one-shot branded Install Now / Defer and Restart Now / Restart Later.
  PSADT launches the standard-user prompt; SYSTEM alone stages/restarts. Intune
  supplies retries. Remove background forced-restart timers; retain guarded
  post-boot verification and BitLocker recovery.
- Keep managed runtime/UI/state/recovery under ProgramData\Medela\DellBIOS.
  Add first-line MedelaBIOS-FileVersion tattoos and generated SHA256 manifests.
  Refresh missing/unversioned/older/drifted files, skip exact matches, reject
  newer cached versions, validate before copying and commit the manifest last.
  Preserve state and repair interrupted refreshes on the next invocation.
- Hold code replacement during unresolved firmware/protection recovery. Retire
  known legacy tasks/UI only under transaction locks; migrate the original
  deadline, remove the old Program Files UI and retain protected legacy evidence.
- Change detection to actual BIOS/protection/resolved transaction. Return 1618
  for deferrals/no user/pending restart/holds; never pass internal 3010 to Intune.
  Include approved runtime hashes so Intune can request a file repair when the
  BIOS is already current. Regenerate detection after final runtime signing.
- Adapt the builder and presets to simple policy, generate the runtime manifest,
  preserve custom PSADT 4.1 framework files, and document signing order.
- Replace obsolete daemon tests with real cache IO/repair, state migration,
  one-shot flow and UI callback tests. Windows ACL/session/WPF/firmware integration
  remains a required pilot, not a portable-test claim.

# v2 visible manual launch and UI diagnostics - 2026-09-16

- Fix direct UI launches staying hidden behind the reminder cooldown or an
  unavailable controller. Show a connection explanation and disable stale
  actions until authenticated status recovers; retain automatic retry.
- Separate manual opening from `-Background` PSADT/task activation. Automatic
  retries continue to respect deferrals. A per-session event asks an existing
  corrected instance to open; older running instances receive actionable help.
- Give preview its own instance so it can run alongside the installed UI; Close
  exits preview. Reject unsupported hosts/session 0 with useful diagnostics.
- Move dependency loading and mutex startup inside error handling. Log launch
  mode/source, nested failures and recovery; show foreground fatal errors in the
  console/dialog. No BIOS configuration or credentials are read by diagnostics.
- Recheck visibility and the unlocked desktop when acknowledging rendering.
  Opening or reconnecting alone never creates another scheduling window.
- Document live/preview commands and paired cached-code/task/PSADT upgrades;
  same-version/hash reenrollment still preserves the live runtime and state.
- Add 30 assertions exercising actual UI functions against inert window/pipe/
  dispatcher boundaries, and capture both automatic launch paths. Actual
  Windows WPF, named-event activation and task integration still require pilot.

# v2 compact notice and explicit install choices - 2026-09-16

- Reduce the default notice from 780 x 760 to 600 x 560, fit its initial size to
  available desktop space, and keep the action bar outside scrolling content.
- Add clearly labeled Install Now, Schedule Install and Defer choices. Expand
  date/time controls only on request; confirm with Schedule Install. Show Restart
  Now after staging and remove deferral/rescheduling once the deadline expires.
- Add a validated InstallNow protocol action and persist its intent separately
  from the restart schedule. The controller retains safety/transaction gates,
  final restart warnings and the original deadline. Delayed immediate requests
  receive a fresh notice. Duplicate requests cannot reset a safety retry.
- Preserve earlier enrolled state and make a new UI connected to an old controller
  explain the required controller update. Document the paired runtime/UI upgrade
  for existing pilots; same version/hash reenrollment remains nondestructive.
- Add action visibility/layout, intent persistence, overdue/phase rejection,
  guarded launch, power holds, missed requests and post-staging warning tests.
  Windows WPF rendering and scaling still require the documented pilot.

# v2 Windows PowerShell 5.1 template integration fix - 2026-09-16

- Fix descending script-edit ordering: use an explicit numeric calculated
  property instead of Sort-Object's dictionary-key property lookup, which was
  introduced in PowerShell 6 and does not work on the required Windows PS 5.1.
- Reject overlapping or incorrectly ordered edits before writing. Keep the
  parser gate and provide sanitized parser IDs/positions for future failures.
- Add a regression that emulates PS5 dictionary sorting in the real template
  integration function. It reproduced the reported syntax-validation failure
  before the fix and passes afterward. Builder suite: 74 assertions on PS7/Linux;
  this is compatibility-boundary emulation, not a Windows 5.1 execution result.

# v2 builder authorization diagnostics - 2026-09-16

- Stop the background worker immediately if loading the builder engine fails.
- Recognize direct/wrapped PowerShell authorization failures in both the worker
  error stream and EndInvoke exceptions. Show download-marker/signing/policy
  troubleshooting without logging source lines or credential arguments.
- Document narrowly scoped Unblock-File for reviewed repository scripts and
  policy inspection. No execution policy, authorization manager, application
  control or signature requirement is weakened or automatically changed.
- Add four assertions using the real worker scriptblock in a separate runspace
  with an inert PSSecurityException. Windows authorization still requires local
  diagnosis; the Linux test verifies error handling, not the cause on the device.

# v2 packaging wizard - 2026-09-16

- Add a four-step Windows WPF package builder and a reusable PowerShell engine.
  Accept a Dell BIOS EXE and a custom prepared PSADT 4.1.x ZIP; preserve framework
  resources, use AST integration for standard functions/metadata, archive the
  original bootstrap, and generate deployment configuration and Intune scripts.
- Calculate SHA256 from copied firmware and require valid Dell Authenticode.
  Validate ZIP paths, links, collisions, sizes, layout and framework version;
  never execute selected BIOS or template code while building.
- Accept shared password via masked, confirmed input/SecureString. Create unique
  protected output outside the repository; exclude credentials from presets,
  manifests and logs; remove handled partial builds. Retain the existing local
  shared-password deployment support and document its plaintext boundary.
- Optionally invoke the supplied Microsoft-signed IntuneWinAppUtil.exe and report
  success only when a nonempty .intunewin is produced. Source-only builds remain
  explicit. Add reusable nonsecret presets, branding fields and detailed output
  notes with Intune restart ownership settings.
- Make the scheduling window configurable from 1-168 hours, default 72. Persist
  the original duration; migrate earlier state to 72 without changing deadlines.
  UI copy now uses the actual preparation lead and original duration.
- Add an optional minimum estimated battery runtime gate (0 disables) while
  retaining AC, minimum 51%, disk, model, hash, password, BitLocker and transaction
  protection. Expose StagedDetectionHours explicitly as legacy compatibility,
  unused by v2 enrollment detection.
- Add inert packaging, ZIP safety, AST, preset/secret, configurable-deadline and
  battery telemetry regression tests. Windows GUI/ACL, actual content preparation
  and hardware flash validation remain required pilot gates.

# Change notes

## 2026-09-16 — v2 branded scheduling workflow

This implementation is isolated on `v2`. Main remains at the previous release.

### Scheduling and user experience

- Replace the three-deferral/12-hour wrapper with a durable SYSTEM controller and
  standard-user WPF client. PSADT enrolls the controller and exits promptly.
- Add logo/banner slots, configurable colors and copy, date/time selection,
  status cards, keyboard labels, scrolling, tray reopening and a harmless Demo mode.
- Start exactly 72 hours from first acknowledged rendered notice. Store UTC state
  with atomic replacement; repeated notices/retries cannot extend the deadline.
- Permit unlimited deferrals and rescheduling inside the window until preparation
  starts. No chosen time falls back to mandatory preparation at the deadline.
- Stage near the chosen time; retain power/prerequisite holds without clearing an
  overdue deadline. Give a fresh warning after missed times, sleep, broker recovery
  or restoration of restart safety. Show the requested restart-required wording.
- Separate enrollment, preparation, restart-required, verification and completion.
  Final success requires actual firmware and healthy BitLocker verification.

### Privilege and safety

- Keep credentials and writable state in the protected SYSTEM/Admin runtime;
  publish only read-only UI/branding to Program Files.
- Add a bounded local named-pipe protocol with active interactive peer checks,
  SYSTEM-owner validation, network denial and no arbitrary command/path requests.
  Use specific client access rights without granting pipe-instance creation.
- Recheck transaction, AC/battery and owned BitLocker suspension immediately before
  managed restart. Do not force-close applications, terminate firmware, bypass a
  safety gate, resume over pending firmware or reflash ambiguous transactions.
- Fix descendant directory ownership/ACLs as well as file ACLs to prevent replacing
  privileged scripts through a writable parent.
- Preserve the v1 firmware transaction/verification identities and refuse migration
  over unresolved firmware. Same-package reenrollment preserves deadlines and
  repairs task activation; missing state fails closed.

### Packaging and operations

- Intune now uses **No specific action** for restart behavior. Remove the v1 hard
  reboot mapping/grace timer and PSADT restart prompt. The controller is the sole
  restart owner for this app; internal Dell 0/2 -> 3010 never reaches Intune.
- Detection reports controller enrollment; the existing separate audit reports
  actual firmware/BitLocker compliance. Installed does not imply a successful flash.
- Add operations, migration/recovery guidance, Windows UI Demo and pilot matrix.
- Preserve inherited model/version/EXE values and PackageReviewed=false. The
  65-character hash still requires recalculation from an approved executable.

### Validation

See VALIDATION.txt for current counts and exact scope. Parser, pure scheduling,
DST, framing, native declaration compilation, real file replacement and mocked
firmware/restart guards ran on Linux. Windows UI, pipe ACL/impersonation, task
principals, actual Dell firmware and Intune remain unverified pilot gates.

---


## 2026-09-16 — Registry repair and managed BIOS update notices

### Why

The original registry writer recreated the transaction key with `-Force` on every
value write. On Windows this could erase earlier fields and leave only
`SuspendedByUs`, causing the missing `Status` failures seen during deployment.
The initial wrapper also lacked the agreed password, deferral and restart UI.

### Changes

- Create the transaction key only when absent; preserve values on later writes.
- Validate required state fields and fail with actionable recovery guidance.
  Preserve pre-existing damaged transactions; cleanup only applies to state
  created by the current attempt. Never reset a damaged fleet key automatically.
- Add shared BIOS administrator password support via a local, Git-ignored
  `Files/BIOS-Password.psd1`. Commit only the example placeholder. Validate before
  suspension; escape native arguments and suppress secret-bearing parse errors.
- Keep Dell return codes 0/2 mapped to 3010 and explicitly log successful staging
  versus actual firmware verification after reboot.
- Require AC and at least 51% battery (strictly above 50%). Preserve the existing
  model, target, executable, hash, escrow policy and unreviewed status.
- Add PSADT 4.1 welcome notice, three deferrals and a 12-hour minimum cooldown,
  including after the third deferral. Once exhausted, show a final 10-minute
  notice before continuing through the existing installer checks.
- Return Retry without staging when there is no active user or the wrapper is
  running silently. Already compliant devices skip the UI and updater.
- Add a 12-hour restart countdown calculated from StagedUtc, with the final
  15 minutes visible. Preserve 3010 if UI fails. Document Intune's 720-minute
  restart grace period, Interactive mode and Retry return-code mappings.
- Document log locations, manual damaged-state recovery, password exposure,
  logoff/restart limits and deployment/pilot steps.
- Add a reproducible regression harness with optional isolated Windows HKCU
  integration coverage for the registry writer.

### Validation and limits

45 parser/mocked regression assertions passed on PowerShell 7.6.6/Linux.
`git diff --check` passed. No firmware updater or restart was executed. The
optional Windows registry test, Windows PowerShell 5.1, PSADT UI, real password
acceptance, BitLocker and Intune timing remain pilot requirements. See
`VALIDATION.txt` for scope and commands.

### Required before packaging

The inherited SHA256 has **65 characters**. Recalculate the 64-character SHA256
from the approved executable; do not trim or guess it. The inherited configuration
names `Dell Pro 14 Plus PB14250` and `Dell_Pro_PA13250.exe` at version `2.1.1`.
Confirm that the executable actually supports that exact model. These identifiers
were preserved, not silently changed to MC16250. `PackageReviewed` remains false.
No approved BIOS EXE, real password or generated Intune scripts are committed.

Populate the local password file, correct/review the BIOS configuration, replace
the function in the stock PSADT 4.1 template, regenerate Intune scripts and build
a fresh package. Apply the documented Intune settings and pilot before rollout.
A source commit does not alter existing Intune assignments or cached endpoints.
