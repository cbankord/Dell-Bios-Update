# v4.5 Windows Update, Dell Driver and inline editor

Run `Start-PackageBuilder.cmd` on an x64 Windows packaging computer using Windows
PowerShell 5.1. The deployment list has four choices. The packaging view starts as **PSADT**. **Open ZIP** and **Load selected ZIP**
automatically enter **Editor**; there is no need to change the dropdown first.

| Deployment type | PSADT ZIP | Additional input | Default behavior |
|---|---|---|---|
| BIOS update | Your reviewed PSADT 4.1.x template | Approved Dell BIOS EXE and existing BIOS settings | Existing managed BIOS workflow, protected from section replacement |
| Application | Complete PSADT 4.x or legacy 3.x application | Name/version/context; optional detection | Original source preserved unless Editor is enabled |
| Windows Update | Reviewed PSADT 4.1.x template | One standalone MSU/CAB, approved Windows build, tested detection script | Generates DISM installation steps with no installer-initiated restart |
| Dell Driver | Reviewed PSADT 4.1.x template | Extracted INF driver ZIP, exact Dell models, approved Windows build, tested detection script | Generates PnPUtil installation steps for matching hardware |

Use a clean, reviewed framework template for generated servicing. Its nine phase
sections and custom/functions block are replaced with the servicing defaults;
bootstrap, module, configuration, extensions and other files remain from your ZIP.
The new servicing package name/version are applied to existing `adtSession`
metadata fields. Application mode preserves its original metadata unless explicitly
edited. In ZIP Editor, Metadata and Custom settings can override those values.
Custom bootstrap or extension code still runs on the endpoint: review it.

## Windows Update

1. Select **Windows Update**, your PSADT 4.1.x template ZIP, and an approved `.msu`
   or `.cab` in **Deployment → Update or driver payload**.
2. Enter the package name/version and exact Windows client build number, such as
   `26100`. Use the actual approved target; the example is not an update recommendation.
3. Supply a tested Intune detection script for the specific installed update.
4. Choose **5 Build → Output folder**, review, approve and build.

The endpoint must be Dell, run the configured Windows client build and run the
installer as SYSTEM in a 64-bit Windows host. Every copied payload has a pinned
SHA256 checked again immediately before servicing. Native Windows servicing owns
package validation; build-time hashing does not certify that a CAB/MSU is a valid
Microsoft update. Approval must include the source, architecture, edition, KB,
prerequisite servicing packages, disk space and restart impact.

Generated commands use DISM `/Online /Add-Package /Quiet /NoRestart /PreventPending`.
Online MSU installation requires Windows 11; the builder rejects older build
numbers for MSUs. Applicability checks are retained. This release accepts a single
update payload: install any required checkpoint/prerequisite updates first, or
prepare and test a full multi-package deployment in Application mode. It does not
scan Windows Update, download KBs or change update rings. See Microsoft's
[DISM package servicing documentation](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options?view=windows-11).

## Dell Driver

Select **Dell Driver** and a ZIP containing the extracted, approved INF driver
package. Keep the original CAT, SYS, DLL and other supporting files and directory
layout. A Dell driver-pack CAB or self-extracting EXE must be extracted using its
supported procedure before zipping the driver files. Raw EXE/CAB installers are
not accepted by Driver mode; an existing PSADT package wrapping such an installer
can still be packaged as Application.

Enter the exact values from `Win32_ComputerSystem.Model` for the approved models,
and one Windows client build. All machines being Dell does not make drivers
interchangeable across models. A version-specific detection script is mandatory;
check the installed device driver, not merely that files exist in the driver store.

The endpoint rechecks the Dell manufacturer, exact model, Windows build and every
payload hash. Firmware-class INF packages are rejected at build and runtime. No
BIOS password, BitLocker changes, firmware cache or managed BIOS countdown is
added. PnPUtil uses `/add-driver "...\*.inf" /subdirs /install` without `/reboot`.
Windows enforces driver signing and matching/ranking; adding a package does not
prove the intended device adopted that driver. See Microsoft's
[PnPUtil command reference](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax).

## Intune detection, restarts and servicing failures

Windows Update and Driver defaults are SYSTEM-only. They serialize this builder's
servicing processes with a named mutex; Windows also has its own servicing locks.
They do not coordinate schedules with Windows Update rings, third-party servicing,
or the separate BIOS transaction. Assign compatible maintenance windows and avoid
concurrent firmware/driver/OS changes during the pilot and rollout.

Only process results `0` and `3010` are accepted. `3010` is passed to PSADT/Intune as
restart required. Configure one Intune restart policy, its soft-reboot mapping and
its installation timeout. The defaults do not add a restart timer. The existing
one-hour BIOS countdown and 15-minute reminders remain BIOS-only.

Errors, applicability failures, changed payloads, wrong models/builds and concurrent
servicing fail the deployment; they never create a fake installed result. Intune
must evaluate the supplied detection rule, including after reboot. The default
servicing templates deliberately fail Uninstall and Repair: author and test an
approved rollback separately before assigning either action. Review PSADT logs,
Windows DISM/CBS logs for updates, and SetupAPI device logs for drivers.

## Inline PSADT section editor

For direct **Open PS1 → EDIT**, common metadata fields and custom settings, see
[the v4.5 direct editor guide](Direct-Script-Editor-Guide.md). No ZIP is required
for that workflow. The steps below describe ZIP authoring.

1. Click **Open ZIP** in **4 PSADT / Editor** to load the original deployment as
   Application authoring, without completing build settings.
2. Alternatively choose the deployment type and PSADT ZIP on **Files**. Entering
   an empty Editor tab loads that ZIP automatically.
3. **Load selected ZIP** reloads on request and selects Editor automatically. For Application, all supported sections are loaded
   from its actual deployment script. For Windows Update/Driver, the editor shows
   the generated servicing defaults that the build would use.
4. Choose a section in the left list and edit its PowerShell text:
   **Custom / functions**, **Pre install**, **Install**, **Post install**,
   **Pre uninstall**, **Uninstall**, **Post uninstall**, **Pre repair**,
   **Repair**, **Post repair**.
5. **Check syntax** validates the ten buffers and their integration into the PSADT
   entry script. Syntax highlighting uses the PowerShell tokenizer; it does not
   evaluate commands. Ctrl+Tab inserts four spaces; Tab moves between controls.
6. **Save template** writes a `.psadt.json` containing just those ten sections and
   the template format/schema. It does not save a full deployment, payload,
   framework, build settings, password field or BIOS state. Code typed into the
   editor is saved literally: never put credentials in it.
7. **Load template** applies a saved section document to the currently selected ZIP.
   Review the replacement sections. Switching ZIPs/types or loading another
   document asks before replacing unsaved editor buffers; save first to retain your work.
8. Build while **Editor** is selected to apply the current in-memory buffers,
   including unsaved changes. With no live buffer, an explicit reusable template
   path can be used instead. Selecting **PSADT** ignores old editor buffers and
   restores the mode's default packaging behavior.

The builder passes a detached snapshot to its background worker. If the ZIP's hash
has changed since it was loaded, the build stops and asks you to reload. Saving a
section template never modifies the original ZIP or deployment script. Settings
presets remember `UseEditor` and `SectionTemplatePath`, not unsaved section text.
Every generated or mapped-section build includes `Sections.psadt.json` outside Source and its
SHA256 in `BuildManifest.json`, together with payload/ZIP hashes, mode and whether
source was preserved. EntryScriptSHA256 also covers metadata edits in the resulting
entry script; section templates exclude metadata. A no-op Application editor build
keeps the original entry bytes and records SourcePreserved=true. Build logs contain
the decision and hashes, not section text. Full script builds record
EditorLayout=FullScript and omit the section-only snapshot.

For approved scripts that need signing, edit an unsigned authoring copy. The editor
refuses to replace sections in a signed deployment script. Sign the generated entry
script under your organization policy, then content-prepare the signed Source.
Leave `IntuneWinAppUtil.exe` blank during that source build. Signing changes bytes:
retain the signing/final-content-prep records alongside the original build manifest.
Neither the builder nor the editor bypasses execution policy or application control.

### Supported editor layouts

The editor supports the PSADT 4.x `Install-ADTDeployment`, `Uninstall-ADTDeployment`
and `Repair-ADTDeployment` functions with three direct `adtSession.InstallPhase`
assignments per function in Pre/main/Post order, each on its own line. It preserves
function scaffolding, phase assignments and bootstrap outside the editable ranges.
The metadata table changes only when explicitly edited. Nested braces, here-strings and comments are parsed as PowerShell.

Custom functions must be one contiguous block before the deployment functions, or
inside the editor's `BuilderCustomFunctions` region before them. Unrelated top-level
initialization and imported helper files are not automatically captured. This is a
section/metadata editor; it does not edit imported modules or extensions. Ambiguous boundaries or extra/missing phase assignments fall back to full script
editing when the script is valid. Invalid PowerShell still fails before saving.
Input text must be UTF-8 (with or without BOM) or BOM-marked Unicode; convert
legacy ANSI authoring files first. Standard PSADT 3.x phase blocks and metadata
variables are also supported. Unknown valid layouts open in Full script without
guessing boundaries; section-template actions are disabled there. Calculated
metadata stays intact while mapped phases remain editable. BIOS package generation
still protects its managed functions. See the direct editor guide for ZIP and
legacy behavior; editing never upgrades a framework or translates its APIs.

Changing generated servicing code is an authoring action: your edited sections own
its endpoint behavior. Removing the generated install call or adding restart code
changes the defaults described above. The builder cannot certify arbitrary custom
PowerShell. Review the complete resulting entry script and detection before approval.

## Windows pilot checklist

Automated Linux/PowerShell checks are listed separately in `../VALIDATION.txt`.
Before deployment, validate on Windows PowerShell 5.1 with your exact PSADT 4.1.x ZIP:

- All four package types, old presets, both PSADT/Editor views, ZIP reload and stale
  buffer rejection, templates saved/reopened, and original ZIP remaining unchanged.
- All ten sections filled correctly for a real application; text entry, selection,
  paste, undo/redo, caret/scroll position while highlighting and syntax error recovery.
- WPF/WinForms editor interaction with Narrator, keyboard-only navigation, high
  contrast, small screens, and 100%, 150%, 200% scaling. The existing inert
  `Tests/V4/Test-WindowsUI.ps1` smoke check now attaches a native editor host too.
- Builder X/Close/Escape while idle and during successful/failed extraction or
  content prep: active work finishes cleanup before exit. Idle Close exits
  immediately; save editor text before closing. Minimize must preserve the worker.
- Real SYSTEM trust/signature, model/build, MSU/CAB dependency, driver applicability,
  device version, actual 0/3010/error codes, Intune detection absent/present/post-boot,
  and one restart policy. Include a nonmatching device and an already-installed case.
- Native ACL enforcement on only the newly created output child; no permissions
  changes to shared `C:\ProgramData\Medela` or siblings. BIOS runtime and its
  unresolved transaction protections remain unchanged in this release.
