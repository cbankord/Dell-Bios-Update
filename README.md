# Dell BIOS deployment — v3

V3.1 restores **Install Now / Schedule Install / Defer**. Users choose an
installation date and local time within the original deferral window (72 hours
by default). Rescheduling never extends that deadline. After expiry, only
Install Now is offered. Scheduling chooses when preparation starts; the existing
60-minute restart warning begins only after successful staging.

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

Main remains the original version; v2 remains at v2.3. Older scheduler code
remains available in Git history. Windows pilot validation is required before
fleet deployment.
