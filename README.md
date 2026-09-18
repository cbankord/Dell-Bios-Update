# PSADT Deployment Builder — v5

**v5 adds Replace install file and local Install / Repair / Uninstall tests.**
Open an Application ZIP (or its entry PS1, then EDIT), review installer filename,
MSI product-code and supported MST changes, and create a new working ZIP.
The Local tests tab can run that edited package in the current user context or
verify and use SYSTEM through your selected Microsoft PsExec tool.
See [the v5 upgrade and testing guide](Dell-BIOS-PSADT41/Builder/Upgrade-and-Testing-Guide.md) for the workflow, limits and Windows pilot.

**v4.5: Open ZIP → Editor, with automatic deployment-script detection.**
Edit common app metadata, the full custom settings table, custom/functions and all
nine install/uninstall/repair phases. Load either Deploy-Application.ps1 or
Invoke-AppDeployToolkit.ps1 from a ZIP, or open a PS1 directly. Legacy metadata
variables and calculated metadata no longer prevent opening; custom layouts
use full script editing. No build settings are needed just to open a document.
[Direct editing and safe saves](Dell-BIOS-PSADT41/Builder/Direct-Script-Editor-Guide.md) explains backups, Save as, supported
layouts and the Windows pilot. The four packaging modes and ZIP editor remain.

**Current release: v5 (BuilderVersion 5.0.0), on the v5 branch.** Choose
**BIOS update**, **Application**, **Windows Update** or **Dell Driver** in the Files tab's **Deployment type** list.

| Mode | Input | Behavior |
|---|---|---|
| BIOS update | Approved Dell BIOS EXE plus PSADT 4.1.x template ZIP | Existing managed BIOS workflow with safety checks, custom UI, scheduling and guarded restart |
| Application | Complete PSADT 4.x or legacy 3.x app ZIP | Preserves the app in PSADT view; Editor supports mapped sections or full script editing |
| Windows Update | PSADT 4.1.x ZIP, standalone MSU/CAB and detection script | Generates Windows servicing steps for an approved Windows build |
| Dell Driver | PSADT 4.1.x ZIP, extracted INF driver ZIP and detection script | Generates installation for approved Dell models and Windows build |

Application mode asks for app name/version, System or User install behavior and
an optional detection script. Without a script, configure app-specific detection
in Intune. The app's existing code controls its prompts, deferrals and restarts;
no BIOS UI, power gates, password, BitLocker or scheduling code is added.
See [Application packaging](Dell-BIOS-PSADT41/Builder/Application-Guide.md).

Choose your
package destination on **5 Build → Output folder → Choose folder** or type its
path. New sessions start without a destination; presets remember your selection.
The review and build records show where output goes. Each build gets a new
protected subfolder containing Source, Intune scripts and optional .intunewin.

New presets remember the selected mode. Old presets default to BIOS. Neither
mode runs an installer while building. The details below describe **BIOS mode**.

Includes the v4.0.1 Install Now fix for PSADT 4.1.4-4.1.8. Rebuild with the updated
builder and replace the complete package plus matching Intune detection. See
[the recovery/rebuild instructions](Dell-BIOS-PSADT41/OPERATIONS.md#install-now-fails-with-a-parameter-set-error-and-60001).

V4 adds **Allow schedule later** to the package builder, enabled by default.
Enabled packages offer **Install Now / Schedule Install / Defer**; disabled
packages offer **Install Now / Defer** and reject scheduling in SYSTEM code too.
After the original deadline (72 hours by default), only Install Now remains.
The option controls installation time, independently of the existing 60-minute
post-staging restart countdown. Old presets retain scheduling by default.

Both windows use a custom title bar with a replaceable PNG/ICO icon, native
dragging/resizing, minimize/maximize/close controls and a shared accessible theme.
Branding remains separate from firmware logic. Preview supports both checkbox
states and overdue notices without changing the device.

One temporary SYSTEM task runs the retained approved package at the chosen time
and retries unmet prerequisites every 15 minutes. It retires after staging; the
post-boot verifier removes the protected package copy after a definitive result.
Files remain under `C:\ProgramData\Medela\DellBIOS`, with no permission changes
to the shared `Medela` parent or sibling applications. There is no resident
controller, Program Files installation, recurring UI task or restart task.

The compact branded UI shows days remaining, preparation activity and a movable,
minimizable restart warning. The warning sounds and recenters every 15 minutes.
Unsafe power or an interrupted countdown cancels automatic restart while
preserving firmware recovery. The builder retains its Close/Escape/X controls.

Open `Dell-BIOS-PSADT41/Builder/Start-PackageBuilder.cmd` on Windows. Select the
approved Dell EXE and your prepared PSADT 4.1.x ZIP; enter model/version, password,
safety settings and branding. The builder creates a new deployment and, optionally,
`.intunewin`. It also generates the SHA256 runtime manifest used for file refresh.

[Packaging](Dell-BIOS-PSADT41/README.md) ·
[Operations and migration](Dell-BIOS-PSADT41/OPERATIONS.md) ·
[Builder](Dell-BIOS-PSADT41/Builder/README.md) ·
[Changes](Dell-BIOS-PSADT41/CHANGELOG.md)

V4 branches from v3 commit `243f384`; Main, v2 and v3 are preserved. Accepted
appointments finish using their retained package before an incoming runtime or
disabled policy activates; no deadline or unresolved transaction is overwritten.
Retire competing old Intune assignments as described in Operations. See
[validation results](Dell-BIOS-PSADT41/VALIDATION.txt) for automated checks and the
remaining Windows PowerShell 5.1/WPF/PSADT/device pilot requirements.
