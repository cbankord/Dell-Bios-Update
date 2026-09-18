# v5 installer upgrades and local lifecycle tests

v5 branches from v4 commit `d01753155c4b18f36145974ec76f2c39503623fe`.
Main, v2, v3 and v4 remain separate. Existing BIOS runtime logic is unchanged.
Use x64 Windows PowerShell 5.1 and start `Builder/Start-PackageBuilder.cmd`.
Authoring does not require administrator rights. SYSTEM testing requires normal
Windows administrator elevation and a Microsoft-signed PsExec tool you supply.

## Replace an installer

1. Open a complete Application ZIP in **4 PSADT / Editor**, or open the standard
   entry PS1 in its complete package folder and click **EDIT**. Unsaved editor
   changes are included in the working copy. Signed scripts require an approved
   unsigned authoring copy; signatures are never stripped automatically.
2. Click **Replace install file...**. Choose a working/output folder outside the
   source package and repository if the Build tab does not already specify one.
3. Select the existing installer under `Files`, then the replacement MSI or EXE.
   The types must match. **Keep existing installer filename** supports calculated
   references and zero-configuration MSI packages without guessing variable values.
4. For a referenced MST, select its old file. Leave Replacement MST blank to
   attempt Property-only migration, or select a reviewed transform supplied for
   the new MSI. Click **Analyze replacement**.
5. Review the proposed string edits and MSI identity. Tick individual changes.
   Pre-install references are unselected by default: they may intentionally remove
   the old product. Uninstall/repair product-code literals normally target the
   replacement. The Context column distinguishes recognized process commands,
   assignments and other expressions. Assignments require explicit selection;
   changing a log message alone cannot satisfy an installation reference.
6. Acknowledge the review and click **Create upgraded ZIP**. The new complete ZIP
   opens automatically in Editor. No installer has run. Re-select a reviewed
   detection script, update calculated metadata/EXE version labels as needed, then
   use Build package or Local tests.

The assistant uses PowerShell AST string spans; it does not execute imported
scripts, globally replace GUIDs, evaluate calculated filenames, or guess EXE
switches. A calculated directory prefix such as `$($adtSession.DirFiles)` is
preserved when its filename is literal. Unknown filename expressions require
Keep existing filename or a manual edit. Comments and filename substrings are
not rewritten. A matching literal AppVersion is updated from old MSI version to
new MSI version; arbitrary version expressions and other labels are preserved.

Output is a protected `PSADT-Work-<id>/Upgraded-<id>` under your selected folder:

| File | Purpose |
|---|---|
| `Upgraded-Application.zip` | Complete edited app, ready to reopen or build |
| `Source/` | Reviewable upgraded package directory |
| `Source/PSADT-Upgrade.json` | Input/output hashes, identity, applied edit locations, transform mode and property names |

The original ZIP/PS1, original MSI/MST, framework and unrelated payloads remain
intact. The old installer is removed from the new copy only when its filename is
no longer referenced in the reconstructed script; otherwise it is retained.
Review retained files in zero-configuration/multiple-installer packages. The
existing detection selection is cleared on opening an upgraded ZIP; standalone
detection scripts, Intune detection rules, external configuration, hard-coded
hashes and dependency packages are not silently rewritten. The normal build
records `UpgradeRecordSHA256` when the input contains upgrade provenance.

Cancel/Close during an upgrade waits for copying/analysis/cleanup. Cancelled work
is removed. Applied output is retained; temporary input and analysis copies are
removed. Handled failures leave the source intact. After a host crash, an
unfinished `PSADT-Work-*` folder can be removed after confirming no builder/test
process uses it. It is never treated as a completed deployment automatically.

## What MST migration supports

MSIs and MSTs are inspected using the Windows Installer database API. Inspection
does not install a product or execute its custom actions. Automatic migration:

- Requires matching UpgradeCode, language and platform.
- Inspects `_TransformView`, then derives intentional Property-table differences
  by applying the old MST to a disposable copy of the old MSI.
- Refuses table/schema/custom-action changes and changes to product identity.
- Applies supported Property additions, changes and removals to a disposable
  copy of the new MSI using parameterized queries.
- Generates a new MST with ProductCode, full version equality, language and
  UpgradeCode validation, without suppressing transform errors.
- Rechecks applicability against the new MSI. Records property names, never
  property values or script command arguments in the upgrade report.

A supplied replacement MST can contain vendor-authored table changes, but must
pass summary/platform/version checks, apply without suppressed errors and retain
the new product identity. Database compatibility does not certify application
behavior. Review settings with the vendor and install/repair/uninstall on a VM.
Transforms may contain secrets; protect output and keep MSI/MST packages out of Git.

This release handles one transform per replacement. Multiple referenced MSTs,
embedded/calculated transform references, MSI external CAB/loose media, mixed
installer types, duplicate payload basenames and unrelated product-family
transform migration require editing the complete vendor package. No arbitrary
MST can be safely rewritten for every future release of an application.

Implementation references: [ApplyTransform](https://learn.microsoft.com/en-us/windows/win32/msi/database-applytransform),
[_TransformView](https://learn.microsoft.com/en-us/windows/win32/msi/-transformview-table),
[GenerateTransform](https://learn.microsoft.com/en-us/windows/win32/msi/database-generatetransform),
[CreateTransformSummaryInfo](https://learn.microsoft.com/en-us/windows/win32/msi/database-createtransformsummaryinfo),
[validation flags](https://learn.microsoft.com/en-us/windows/win32/msi/character-count-summary).

## Install, repair and uninstall locally

Open the application and select **6 Local tests**. The target shown is the open
document plus its current editor buffers. A full supported PSADT 3.x/4.x package
is required, even though a PS1 can be opened alone for editing.

Choose **Install**, **Repair**, or **Uninstall**. The confirmation identifies the
computer, action and context. These are real local changes, including any restart
your script requests. The builder does not invent repair or rollback behavior.
Entry scripts must expose DeploymentType/DeployMode; explicit ValidateSet limits
are checked before launch. Current-user tests can use Silent or Interactive mode.
Use current user does not remove elevation if you started the builder as admin.

Each test takes a separate private package snapshot and verifies all file hashes.
The selected launcher runs in a separate process with the package root as its
working directory. There is no execution-policy bypass, command injection through
the action selector, automatic retry or kill-on-timeout. One machine-wide mutex
prevents concurrent lifecycle tests started through this runner. Close/X/Escape
wait for a running test and cleanup; minimizing does not cancel it. A Close
request during preparation prevents the prepared deployment from starting.

## Test as SYSTEM

1. Select your approved Microsoft **PsExec.exe** or **PsExec64.exe**. The tool is
   not bundled or downloaded automatically. Review its license, then check the
   acceptance box. See [Microsoft PsExec](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec).
2. Click **Elevate tests to SYSTEM** and approve the normal Windows UAC request.
   A probe must report SID `S-1-5-18` before the UI selects SYSTEM. The probe does
   not run the app. The editor itself remains in your user session.
3. Click a lifecycle action. Each SYSTEM run can request UAC again; verification
   does not cache an elevated token or create a persistent privileged service.

SYSTEM runs use Silent mode in session 0, without `-i`. This checks SYSTEM
execution; it does not reproduce Intune downloading, detection, assignments,
restart policy, signed-in-user prompts or network authentication. Microsoft
specifies silent app installation in its [Intune Win32 guidance](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-add).
Test any separate user-session experience explicitly on pilot devices.

The elevated broker copies reviewed files to
`C:\ProgramData\Medela\DellBIOS\BuilderTest-<id>`, verifies their hashes and the
Microsoft PsExec signature again, then starts the SYSTEM worker there. Code and
payloads are writable only by Administrators/SYSTEM. The originating Windows or
Entra account can read its Evidence child, not modify SYSTEM code. The shared
Medela folder and siblings are never re-permissioned. If existing parent rights
allow non-admin replacement of the protected child, the test fails rather than
changing those permissions or running SYSTEM code there.

PsExec creates its normal temporary service with a unique test name. No test
scheduled task or permanent elevation broker is installed. Completed protected
code/payload copies are removed, retaining Evidence. Interrupted/unknown runs
retain their protected working files for investigation; do not remove them while
a deployment process might still be running. An administrator can remove only
completed `BuilderTest-<id>` folders after retaining required evidence. Do not
delete DellBIOS runtime, State or Recovery to clean test logs.

## Results and pilot requirements

Open test logs shows `TestResult.json`, redirected process output, and PsExec
diagnostics where applicable. The receipt records actual SID/account/session,
timestamps, action, raw exit code and outcome. Exit 0 is **ProcessSucceeded**;
3010/1641 is **RestartRequired**. These labels do not assert detection or BIOS
verification. Check actual installed state and PSADT logs. A reboot or lost runner
without a terminal receipt is an unknown result; the builder never declares it
complete or reruns it automatically. Test output may contain app-generated
sensitive text; it stays in protected local folders, outside Git.

Automated portable tests exercise real ZIP/file IO, AST rewriting, metadata,
review and async callbacks, hash guards, command construction and receipts.
Windows trust, identity, process execution and ACLs are mocked there.

Before distribution, run on x64 Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -STA -File .\Tests\V4\Test-WindowsUI.ps1
powershell.exe -NoProfile -File .\Tests\V5\Test-WindowsMsi.ps1
```

The MSI test creates inert databases and transforms and never installs them.
Also pilot the following; they were not executed in the Linux development host:

| Scenario | Verify |
|---|---|
| Actual 3.x and 4.x apps, MSI and EXE | Open, EDIT, replace, reopen upgraded ZIP, build and unchanged source bytes |
| Supported and unsupported MSTs | Correct settings/identity, native summary validation, clear refusal with vendor replacement option |
| Installer naming and version cases | Same name, spaces, variable filename, same/new product code, intentional old-product cleanup |
| Real app lifecycle on a disposable Windows VM | Install, installed-state detection, repair, uninstall and reboot codes |
| Standard user and admin; local/domain/Entra account | UAC consent/decline, actual SYSTEM SID, receipt readability and child-only permissions |
| Policy and interruptions | Blocked PsExec, execution policy/WDAC, missing files, changed ZIP, sleep/reboot, Close while running, concurrent tests |
| Native dialogs and accessibility | Upgrade grid editing, selection invalidation, minimize/restore/close, keyboard/Narrator and 100/150/200% scaling |
| Existing Dell BIOS deployment | Power/signature/hash/password/BitLocker/transaction/restart guards and post-reboot version verification remain intact |

Local package testing is an optional builder capability. Neither opening a ZIP,
analyzing an MSI/MST nor clicking Build package executes a deployment.
