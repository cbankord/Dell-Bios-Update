# Dell BIOS deployment — v3

V3 adds a visible **Close** button to the package builder. Close, Escape and the
title-bar X exit immediately when idle. During a build, they request automatic
exit after the build finishes and cleanup completes. V3.0.1 also confines cache
permission changes to `Medela\DellBIOS`, leaving the shared `Medela` parent and
other applications' permissions alone. Firmware and restart behavior retain v2.3.

A PSADT 4.1 + Intune deployment with a compact branded **Install Now / Defer**
prompt with days remaining, an animated preparation indicator, and a movable,
minimizable **Restart Now** warning with a 60-minute automatic restart countdown.
The warning sounds and recenters every 15 minutes. Protected versioned files stay
under `C:\ProgramData\Medela\DellBIOS`. No resident controller, named-pipe broker,
Program Files installation or recurring UI/restart task. Unsafe power or an
interrupted countdown cancels automatic restart while preserving firmware recovery.

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
