# v4.4 direct PSADT script editor

Open the builder on Windows, choose **4 PSADT / Editor → Open PS1**, select your
PSADT `Invoke-AppDeployToolkit.ps1`, then click **EDIT**. No ZIP, output folder,
BIOS executable, password or completed package settings are needed to edit a PS1.
Opening and checking a script only parses its text; imported app code never runs.

You can also drag the PS1 onto `Start-PackageBuilder.cmd`, or launch explicitly:

```powershell
powershell.exe -NoProfile -STA -File .\Builder\Start-PackageBuilder.ps1 -EditScript 'C:\Packaging\Example-App\Invoke-AppDeployToolkit.ps1'
```

Use Windows PowerShell 5.1 on an x64 Windows packaging computer. The launcher does
not register a file association or replace Windows' normal PS1 Open action.
Opening starts in read-only preview. **EDIT** enables the form and code buffers.
The currently selected BIOS/Application/Windows Update/Driver build mode does not
affect standalone editing. Managed BIOS package generation remains protected.

## What you can edit

| Page | Contents |
|---|---|
| Metadata | App name, publisher/vendor, app version, script author/version/date, architecture, language, revision, install name and install title |
| Custom settings | The complete literal `$adtSession = @{ ... }` table, including custom keys, flags, arrays, nested process lists and calculated expressions |
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
| Close PS1 | Closes this document and restores ZIP authoring without exiting the builder. Asks before discarding unsaved changes. |

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
deployment. Choose **Close PS1**, select **Application** and the ZIP, choose the
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
BuilderVersion `4.4.0` and `EntryScriptSHA256` for the resulting application or
servicing entry script, covering metadata as well as code. A no-op Application
editor build keeps its original bytes and records `SourcePreserved=true` even
though `EditorApplied=true`. Review the complete Source and detection before use.

## Supported layouts and limits

Direct editing requires the standard PSADT 4.x top-level Install, Uninstall and
Repair functions with Pre/main/Post phase assignments, and one literal top-level
`adtSession` metadata table. `[ordered]` tables and nested table values are supported.
Scripts that calculate the entire table cannot use direct metadata editing;
unchanged Application packaging and supported ZIP section editing remain available.
Legacy 3.x packages retain unchanged packaging support, without this inline editor.

Custom functions must form one contiguous block before the deployment functions,
or be inside the `BuilderCustomFunctions` region there. Mixed helper locations,
ambiguous phase boundaries and invalid PowerShell fail without guessing. Other
bootstrap code and imported modules remain outside the editable ranges. The editor
does not assemble arbitrary functions into a PSADT template automatically.

Input must be UTF-8 or BOM-marked Unicode. File reading is bounded to 8 MB, parsed
scripts to 2 million characters, each section to 100,000 characters and the custom
settings table to 100,000 characters. Convert legacy ANSI authoring copies first.
No credentials are inserted into metadata, presets or logs by this feature; text
you type is saved literally. Keep passwords out of scripts and section templates.

## Required Windows pilot

Portable automated results are recorded separately in `../VALIDATION.txt`.
The following native checks have not been run in this development environment:

- In Windows PowerShell 5.1 `-STA`, run `Tests/V4/Test-WindowsUI.ps1` as a standard
  user. It opens inert windows and checks caption controls, editor attachment and
  native coloring/scroll/undo/redo behavior. It never installs an app or firmware.
- Open your actual PSADT PS1 from the button, Files shortcut, CMD drag/drop and
  `-EditScript`. Verify read-only preview, EDIT, all metadata/custom settings and
  all nine phases. Verify Ctrl+Tab, paste, undo/redo, long-section scrolling and
  syntax-error recovery; repeated highlighting must not alter source text.
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
