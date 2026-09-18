# v4.5 ZIP and PS1 editor

Open the builder on Windows and choose **4 PSADT / Editor → Open ZIP**. Select the
entire PSADT framework or app ZIP. The loader finds `Deploy-Application.ps1` or
`Invoke-AppDeployToolkit.ps1`, selects **Editor**, and opens the original script
for authoring automatically. No separate dropdown selection or Open PS1 step is
required. A single enclosing folder (or deeper wrapper) is supported.

If you already chose a ZIP on Files, entering an empty Editor tab loads it.
**Load selected ZIP** reloads it explicitly; existing documents are not overwritten
just by changing tabs. Open ZIP always authors the original app. For generated
Windows Update/Driver defaults, choose that mode on Files, select the framework ZIP
there and use Load selected ZIP instead. Successful ZIP loads populate available
literal app name/version values. A failed load retains the current document.

**Open PS1** remains available for an individual script; click **EDIT** to unlock
that read-only preview. No output folder, BIOS executable, password or completed
package settings are needed to open a ZIP or PS1.
Opening and checking a script only parses its text; imported app code never runs.

You can also drag a ZIP or PS1 onto `Start-PackageBuilder.cmd`, or launch explicitly:

```powershell
powershell.exe -NoProfile -STA -File .\Builder\Start-PackageBuilder.ps1 -EditScript 'C:\Packaging\Example-App\Invoke-AppDeployToolkit.ps1'
```

Use Windows PowerShell 5.1 on an x64 Windows packaging computer. The launcher does
not register a file association or replace Windows' normal PS1 Open action.
PS1 opening starts in read-only preview. ZIP opening enters Editor immediately;
signed scripts remain read-only. **EDIT** unlocks an unsigned standalone PS1.
The currently selected BIOS/Application/Windows Update/Driver build mode does not
affect standalone editing. Managed BIOS package generation remains protected.

## What you can edit

| Page | Contents |
|---|---|
| Metadata | App name, publisher/vendor, app version, script author/version/date, architecture, language, revision, install name and install title |
| Custom settings | The literal `$adtSession = @{ ... }` table for 4.x, or the original legacy metadata variable declarations; includes nested values and calculated expressions |
| Custom / functions | The supported custom helper block before the deployment functions |
| Pre install / Install / Post install | The three `Install-ADTDeployment` phases |
| Pre uninstall / Uninstall / Post uninstall | The three `Uninstall-ADTDeployment` phases |
| Pre repair / Repair / Post repair | The three `Repair-ADTDeployment` phases |

The common form edits literal text values. Quotes and `$` characters are saved as
text. A calculated value is shown read-only in the form: edit its expression in
Custom settings when needed. Expressions are never evaluated to populate fields.
Metadata is PSADT deployment metadata; changing AppVersion does not change the
installer payload or prove a different product version is installed.

Code pages use PowerShell syntax colors with a high-contrast fallback. Tab moves
between controls; Ctrl+Tab inserts four spaces. Paste imports plain text. Coloring
is debounced and skipped when the text is unchanged, with a native Rich Edit scope
to preserve scroll and keep formatting out of text undo history. That native
behavior needs the Windows validation below.

## Save choices

| Action | Result |
|---|---|
| Check syntax | Parses metadata, individual sections and the reconstructed full script. It does not run or certify the app. |
| Save PS1 | Saves metadata, settings and all sections to the opened file after validation and a changed-on-disk check. |
| Save as new PS1 | Writes a new `.ps1` filename. It does not overwrite an unrelated existing file. |
| Save template | Writes the existing `PSADT-Sections`, schema 1, `.psadt.json` format with exactly ten code sections. Metadata is excluded. |
| Load template | Replaces the ten sections in the open document; retains its metadata. Save PS1 writes the combined result. |
| Close document | Closes this document without exiting the builder. Asks before discarding unsaved changes. |

For a loaded ZIP, **Save as new PS1** exports the edited entry script and keeps
the ZIP document open. **Build package** applies edits to a new complete Source
package. The original ZIP is never rewritten. A ZIP with one deployment PS1 can
be opened even before its framework is complete; Build still requires a complete,
valid app ZIP. Archives with multiple deployment scripts are rejected explicitly
instead of choosing one silently. Open the intended PS1 or ZIP its app separately.

Saving over the opened file checks its SHA256 against the snapshot read at open,
then checks again just before replacement. If another editor changed the file,
reopen it or use Save as new PS1 to retain your buffer separately. A per-file mutex
also prevents competing saves by builder instances in the same Windows session.

An unchanged save does not write or create a backup, preserving the original bytes
and encoding. A changed save writes validated UTF-8 with BOM for Windows PowerShell
5.1 in a temporary protected child of the destination folder. It uses
[File.Replace](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace?view=netframework-4.8.1)
to replace the existing script and keep its previous bytes in a unique adjacent
`filename.ps1.<timestamp>-<id>.bak`. Metadata/permission merge errors are not ignored.
The temporary child is removed after the operation. Destination parent and sibling
permissions are never rewritten. Retain or remove backups according to your normal
authoring process; they contain the previous script, not an encrypted archive.

Save to a local ACL-capable disk. UNC destinations, reparse-point paths and saves
inside the live `%ProgramData%\Medela\DellBIOS` runtime cache are refused. Work on
an authoring copy with normal file permissions. Signed scripts open for review;
create an unsigned authoring copy using your approved process to make changes,
then sign the final script. The editor does not remove signatures or bypass policy.

Opening another document or loading a preset asks before replacing unsaved work.
The builder's existing **Close / X / Escape exits immediately while idle**; save
before exiting. During an active load/build, Close waits for worker cleanup.
There is no autosave or recovery journal, and no app updater runs inside the editor.

## Build the edited app

A saved PS1 is an authoring file, not a complete Intune deployment. Save it with the
app's framework, extensions, configuration and payloads, then ZIP that complete
deployment. Choose **Close document**, select **Application** and the ZIP, choose the
output folder, and build in the default **PSADT** view to preserve the saved app.
Use a standard entry filename in the final package. Renaming an authoring copy to
`.edited.ps1` does not change what the PSADT launcher executes.

Alternatively, load a complete ZIP in **Editor**. The Metadata and Custom settings
pages are also available there, and Build uses a detached snapshot of sections and
metadata. Windows Update/Driver load generated identity and servicing defaults;
explicit editor metadata takes precedence. For Application, the separate package
name/version fields label build records and do not overwrite script metadata.

Section templates and settings presets remain compatible. They do not store new
metadata buffers: save the PS1/full ZIP to reuse those values. A CLI build using
only `SectionTemplatePath` applies sections only. `BuildManifest.json` records
BuilderVersion `4.5.0` and `EntryScriptSHA256` for the resulting application or
servicing entry script, covering metadata as well as code. A no-op Application
editor build keeps its original bytes and records `SourcePreserved=true` even
though `EditorApplied=true`. Review the complete Source and detection before use.

## Supported layouts and limits

Mapped section editing supports the standard PSADT 4.x Install, Uninstall and
Repair functions and the standard legacy 3.x dispatcher with all nine phase
assignments. Legacy metadata uses `$appName`, `$appVersion`, `$appScriptAuthor`
and the other original variables, rather than a fabricated `adtSession` table.
Typed/script-scoped literal tables and tables in a script-level try block are
recognized. `[ordered]` tables and nested values remain supported.

A missing or calculated metadata table no longer blocks opening. If deployment
phases can be mapped, those remain editable and original metadata is preserved;
unavailable metadata pages are omitted. If section boundaries cannot be mapped
reliably, the editor opens **Full script** with the entire source intact. This
includes older/custom legacy layouts with missing repair phases. Syntax checking,
signed-source guards, changed-on-disk checks and backups still apply. Full script
editing disables section-template actions and records `EditorLayout=FullScript`
in app builds; review Source instead of expecting a Sections.psadt.json snapshot.

Custom functions must form one contiguous block before the deployment functions,
or be inside the `BuilderCustomFunctions` region there. Mixed helper locations
use Full script; invalid PowerShell is rejected. With mapped sections, other
bootstrap code and imported modules remain outside the editable ranges. This
editor does not assemble a framework, translate 3.x commands into 4.x APIs, or
make section templates automatically compatible across toolkit generations.

Input must be UTF-8 or BOM-marked Unicode. File reading is bounded to 8 MB, parsed
scripts to 2 million characters, each section to 100,000 characters and the custom
settings table to 100,000 characters. Full scripts above 100,000 characters use
plain text display to avoid excessive coloring work. Convert legacy ANSI authoring copies first.
No credentials are inserted into metadata, presets or logs by this feature; text
you type is saved literally. Keep passwords out of scripts and section templates.

## Required Windows pilot

Portable automated results are recorded separately in `../VALIDATION.txt`.
The following native checks have not been run in this development environment:

- In Windows PowerShell 5.1 `-STA`, run `Tests/V4/Test-WindowsUI.ps1` as a standard
  user. It opens inert windows and checks caption controls, editor attachment and
  native coloring/scroll/undo/redo behavior. It never installs an app or firmware.
- Open your actual PSADT PS1 from the button, CMD drag/drop and
  `-EditScript`. Verify read-only preview, EDIT, all metadata/custom settings and
  all nine phases. Verify Ctrl+Tab, paste, undo/redo, long-section scrolling and
  syntax-error recovery; repeated highlighting must not alter source text.
- Open actual 3.x and 4.x ZIPs with Open ZIP, the Files shortcut, selected-ZIP
  tab loading and CMD drag/drop. Verify automatic Editor selection, entry filename,
  standard metadata/phase mapping, calculated metadata and Full script fallback.
  Reject ambiguous archives with a readable error while keeping the prior buffer.
- Save unchanged and changed scripts; check the exact backup, UTF-8 BOM and NTFS
  permissions. Include a read-only destination, changed-on-disk source, Save as,
  signed input and denied permissions. Parent and sibling ACLs must remain intact.
- Save/reload old section templates and presets, close/reopen documents, switch
  between direct PS1 and ZIP editing, and test Close during successful/failed work.
- Check keyboard-only navigation, Narrator, high contrast, small displays and
  100%, 150%, 200% scaling; all metadata fields and action buttons must be reachable.
- Build and pilot the complete app in its intended Intune context, including
  install/uninstall/repair, detection, return codes and restart policy. Syntax and
  source-preservation checks do not validate arbitrary deployment behavior.

The existing BIOS model/trust/hash/password/power checks, transaction protection,
BitLocker recovery, fixed deadlines, accepted appointments, ProgramData child
storage, progress, guarded one-hour restart and 15-minute reminders are unchanged.
