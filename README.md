# Dell BIOS deployment — v4

**Current patch: v4.0.1.** Fixes the Install Now parameter-set failure with PSADT
4.1.4-4.1.8. Rebuild with the updated builder and replace the complete package plus
matching Intune detection. See [the recovery/rebuild instructions](Dell-BIOS-PSADT41/OPERATIONS.md#install-now-fails-with-a-parameter-set-error-and-60001).

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
