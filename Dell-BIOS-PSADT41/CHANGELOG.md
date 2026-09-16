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
