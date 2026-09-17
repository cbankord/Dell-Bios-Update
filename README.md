# Dell BIOS deployment — v2.2

A PSADT 4.1 + Intune deployment with a compact branded **Install Now / Defer**
prompt, a **Restart Now / Restart Later** prompt, and protected versioned files
under `C:\ProgramData\Medela\DellBIOS`. No resident controller, named-pipe broker,
Program Files installation or recurring UI task.

Open `Dell-BIOS-PSADT41/Builder/Start-PackageBuilder.cmd` on Windows. Select the
approved Dell EXE and your prepared PSADT 4.1.x ZIP; enter model/version, password,
safety settings and branding. The builder creates a new deployment and, optionally,
`.intunewin`. It also generates the SHA256 runtime manifest used for file refresh.

[Packaging](Dell-BIOS-PSADT41/README.md) ·
[Operations and migration](Dell-BIOS-PSADT41/OPERATIONS.md) ·
[Builder](Dell-BIOS-PSADT41/Builder/README.md) ·
[Changes](Dell-BIOS-PSADT41/CHANGELOG.md)

Main remains the original version. Older v2 scheduler code remains available in
Git history. Windows pilot validation is required before fleet deployment.
