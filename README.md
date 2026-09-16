# Dell BIOS deployment — v2

This branch adds a branded Windows scheduling interface and persistent BIOS update
workflow (72 hours by default) to the Intune + PowerShell + PSADT 4.1 package.

**Package builder:** open `Dell-BIOS-PSADT41/Builder/Start-PackageBuilder.cmd`
on Windows. Select your BIOS EXE and custom PSADT ZIP, enter settings and branding,
and generate the complete package. Select `IntuneWinAppUtil.exe` to also build
`.intunewin`. [Wizard instructions](Dell-BIOS-PSADT41/Builder/README.md).

Start with [packaging and Intune instructions](Dell-BIOS-PSADT41/README.md),
[operations and pilot gates](Dell-BIOS-PSADT41/OPERATIONS.md), and
[change notes](Dell-BIOS-PSADT41/CHANGELOG.md).

The existing version remains on [Main](https://github.com/cbankord/Dell-Bios-Update/tree/Main).
This is source for a Windows pilot; an approved BIOS EXE, corrected configuration,
local password and PSADT distribution are required before packaging.
