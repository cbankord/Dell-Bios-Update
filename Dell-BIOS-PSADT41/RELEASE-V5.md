# v5.0.0 — Package upgrade assistant and local test actions

This release starts a separate `v5` branch from v4.5 commit
`d01753155c4b18f36145974ec76f2c39503623fe`. Main/v2/v3/v4 are preserved.

## Why

Updating a packaged application previously required manually replacing payloads,
editing installer references, reviewing MSI identities/transforms and launching
separate test commands. v5 brings those authoring steps into the existing builder
while preserving source packages and keeping actual execution explicit.

## Changes

- Editor **Replace install file...** snapshots the complete ZIP or PS1 package
  folder, including unsaved editor changes, into the chosen output location.
- An asynchronous review dialog maps filename, transform and exact MSI
  product-code literals using PowerShell syntax. It preserves intentional old
  product removal by leaving pre-install edits unselected. Users review each edit.
- Keep-name replacement supports calculated references. MSI AppVersion changes
  only when a literal metadata value matches the old MSI version. Original source
  files and unrelated framework/payload content remain intact.
- Supported Property-only MST changes can be migrated to the new MSI family.
  Generated transforms have strict identity/version validation. Complex MSTs
  need a reviewed replacement; transform chains and external MSI media require
  complete-package authoring. No installer runs during inspection or packaging.
- Upgraded ZIPs reopen in Editor. Stale selected detection is cleared; reports
  retain hashes, product identity and edit locations without logging script
  arguments or transform values. Builds record the upgrade report hash.
- **Local tests** adds Install/Repair/Uninstall and a verified SYSTEM context
  selector. Tests execute the full reviewed package snapshot in a separate
  process, record actual account/SID/session/exit code, and never infer detection
  success from a process exit code.
- SYSTEM uses the user's Microsoft-signed PsExec, explicit EULA selection and
  normal UAC. Each run stages protected code below Medela\DellBIOS. Shared Medela
  and sibling ACLs remain unchanged. No test scheduler or persistent broker is
  added. The editor stays in its user session; SYSTEM tests run Silent in session 0.
- Close waits for active operations; a close during preparation prevents a new
  test launching. Completed SYSTEM payload copies are removed, evidence retained;
  interrupted or uncertain runs retain their working files for investigation.
- Existing BIOS validation, credentials, BitLocker, locks, countdown/reminders
  and post-reboot verification remain in their unchanged runtime files.

## Validation and limits

The Linux/PowerShell 7.4.7 run passed 743 assertions in 16 isolated suites,
including 67 new upgrade/test/dialog assertions. Counts include parser/fixture
assertions, not independent end-to-end scenarios. Native boundaries are mocked.
The new Windows workflow parses with Windows PowerShell 5.1, runs the three v5
suites, then exercises real Windows Installer COM using inert databases. Workflow
results must be checked separately; adding the workflow is not a passing result.

Native WPF, UAC, PsExec, NTFS permissions, real app install/repair/uninstall and
BIOS/Intune behavior still require the documented Windows pilot. Tests are not a
sandbox. No arbitrary MST or vendor installer is guaranteed compatible after
replacement. Source packages, generated transforms and test logs may contain
app-supplied sensitive information; keep them out of Git and protect their output.

See [Upgrade and testing guide](Builder/Upgrade-and-Testing-Guide.md) and
[validation record](VALIDATION.txt) for precise workflows and evidence.
