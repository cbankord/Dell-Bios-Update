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
