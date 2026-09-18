# Dell BIOS package builder v4.1

Launch **Start-PackageBuilder.cmd** on your Windows packaging computer. The wizard
builds a fresh deployment from your approved Dell BIOS executable and your own
prepared **PSADT 4.1.x template ZIP**. You do not need to edit the deployment
functions or calculate/paste a SHA256.

**Builder 4.1.0 includes the v4.0.1 Install Now launch fix for PSADT 4.1.4-4.1.8.**
If an older package reports a parameter-set error and exits 60001, restart this
builder from the updated v4 copy and rebuild with your existing approved settings
and custom ZIP. Replace the complete package and its generated Intune detection;
do not delete endpoint state. See [the troubleshooting steps](../OPERATIONS.md#install-now-fails-with-a-parameter-set-error-and-60001).

Use 64-bit **Windows PowerShell 5.1** on x64 Windows. The GUI uses WPF and runs as
the packaging user; elevation is not required. Use an existing local NTFS output
folder outside this repository, with a short path and sufficient free space for
the extracted framework, BIOS and package. Your organization's script execution
and signing policy still applies; the launcher does not override that policy.

The compact window has a custom title bar, replaceable icon and labeled native
minimize/maximize/restore controls. Drag its caption or resize its edges. Colors
and the builder title/default icon are in `Branding.psd1`; the shared visual theme
is `../Files/UI/Theme.xaml`. This presentation code does not perform firmware work.

Use **Close** in the bottom-right corner, **Escape**, or the custom title-bar **X** to
exit. When idle, the window closes immediately and the script returns to your
existing PowerShell prompt; you do not need Ctrl+C. A console created by the CMD
launcher exits when its PowerShell process returns normally.

If a build is running, Close changes to **Closing...**. The builder finishes the
current build (or handles its failure and removes partial output), disposes its
background worker and password, then closes automatically. This is a graceful
exit, not a force-terminate control; a hung external packaging tool can still
delay it. Completed output is kept in your selected output folder. The Close
button does not cancel an endpoint BIOS update or change the deployment UI.

## The four steps

1. **Files:** choose the BIOS EXE and custom PSADT ZIP. Optionally
   choose your official `IntuneWinAppUtil.exe` to produce `.intunewin` in the same
   build. Without it, the result is complete deployment source plus Intune scripts.
2. **Deployment:** enter exact CIM model names, target/prerequisite BIOS versions,
   shared administrator password twice, power/disk thresholds and recovery settings.
3. **Experience:** set the deferral window, reminder cooldown, install prompt
   timeout, restart countdown and sound/recenter interval. Set **Allow schedule
   later** (enabled by default). Enter company text, colors, optional logo/banner
   images and a title-bar PNG/ICO icon. The selected icon previews immediately.
4. **Build:** choose **Output folder → Choose folder** or type the destination.
   Review its path and the settings, confirm that you reviewed the approved
   firmware and trusted template, then build. The GUI remains responsive during
   packaging. Select **Open output** and follow the generated `READ-ME-FIRST.txt`.

Save a preset to reuse the same settings for the next model or version. Presets
contain **no password**; loading one clears the password boxes and the prior
review. Change the BIOS, target and model as appropriate and enter the password
again. Old presets without `AllowScheduleLater` load as enabled, and missing
`IconPath` selects the default icon. Explicit `$false` survives save/load/build;
quoted Boolean strings are rejected. The wizard starts with empty model/version fields instead of assuming that
the repository's old example values are approved for your devices.

Obtain the content prep utility through the
[official Microsoft repository](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool).
It requires .NET Framework 4.7.2. The builder checks its Microsoft signature and
invokes `-c Source -s Invoke-AppDeployToolkit.exe -o Package -q` with quoted paths.
The utility is optional, is not bundled, and is never downloaded silently.

## Settings and their actual behavior

| Field | Default / allowed | Effect |
|---|---|---|
| Models | Required; 1-50 exact names | Exact Dell model allowlist; one EXE must support every listed model |
| Expected version | Required numeric version | Actual post-restart BIOS must meet or exceed this target; no downgrade |
| Minimum existing version | `0.0.0` | Dell prerequisite version gate |
| BIOS password required | Enabled | Requires a locally entered shared password; clear only for approved password-free systems |
| Require battery | Enabled | Laptop battery checks; clear only for approved desktops; AC remains mandatory |
| Minimum battery percent | `51`; 51-100 | Charge must meet or exceed the value at staging and managed restart |
| Minimum estimated runtime | `0`; 0-240 minutes | Optional runtime gate; 0 disables it |
| Minimum free space | `1`; 1-1024 GB | Free space required on the Windows volume before staging |
| BitLocker reboot count | `1`; 1-3 | Finite suspension around staging; recovery workflow still verifies/resumes |
| Recovery key escrow | `EntraID` or `ADDS` | Successful backup required before suspension |
| StagedDetectionHours | `24`; legacy preset/config field | Hidden in the wizard; actual-BIOS detection does not use it |
| Allow schedule later | Enabled; literal Boolean | Offer installation scheduling before expiry; does not control deferrals or restart countdown |
| Title-bar icon | Built-in device icon; optional PNG/ICO | Local image, at most 1 MB / 1024x1024 pixels; previewed and automatically packaged |
| Deferral window | `72`; 1-168 hours | Fixed window from first active-user prompt launch attempt; retained across retries |
| Reminder interval | `4`; 1-12 hours | Minimum between notices; Intune or the selected-install task supplies retries |
| Install prompt timeout | `10`; 1-30 minutes | Defer before deadline; request preparation after an overdue notice |
| Restart countdown | `60`; 15-120 minutes | SYSTEM requests a guarded automatic restart after staging; unsafe power/sleep/session interruption cancels it |
| Restart reminder interval | `15`; 1-30 minutes, below countdown | Restore/recenter the movable window and play Windows alert sound; minimize/X keeps the countdown running |

“Battery time” means the **estimated remaining runtime in minutes**, not a sleep,
charging delay or BIOS execution timeout. It uses
[Win32_Battery.EstimatedRunTime](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-battery).
Many devices report unknown or implausible telemetry on AC. When enabled, missing,
zero or values over 1,440 minutes fail safely and retain the waiting/overdue state.
The upper bound is a conservative application rule, not a Windows guarantee.
Validate telemetry on each model before enabling this gate. The native
[BatteryLifeTime field](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-system_power_status)
is not used because it can be unknown on AC. No estimate guarantees physical
battery life or substitutes for AC and percentage checks.

Changing policy cannot extend an existing deployment's original deadline. Same
BIOS/hash reinstallation now refreshes older, missing or drifted runtime files
under `C:\ProgramData\Medela\DellBIOS` using version tattoos and a SHA256 manifest.
It does not overwrite newer code or pending firmware recovery. There is no
Program Files installation or recurring controller/UI task. Old presets may
contain PreparationLeadMinutes, FinalWarningMinutes or SafetyRetryMinutes;
import drops these retired scheduler settings. Review the new experience before
building. See [OPERATIONS.md](../OPERATIONS.md) for automatic legacy retirement.

V3.0.1 changes permissions only within `Medela\DellBIOS`. It leaves the shared
`Medela` parent and other application folders untouched, accepts ordinary
creation/inherit-only grants, and diagnoses parent-replacement grants without
rewriting them. See [shared-folder permissions](../OPERATIONS.md#shared-medela-folder-permissions).
Rebuild the package and use its matching new detection script for this cache fix.

With scheduling enabled, the notice offers **Install Now / Schedule Install / Defer**, with
remaining days/hours/minutes until Install Now is the only option. Schedule Install
selects a local preparation time within the unchanged deferral window, at least
five minutes ahead. SYSTEM retains the complete generated Source privately under
`State/ScheduledPackage` and creates one temporary scheduled-install task with
15-minute prerequisite retries. Rescheduling replaces that appointment; Defer
keeps it. After staging the task is retired, and post-boot verification cleans the
private source (including its credential file). Clearing **Allow schedule later**
offers **Install Now / Defer** and blocks new scheduling/rescheduling in SYSTEM
code; a fresh disabled deployment creates no installation task. Expiry always
leaves only Install Now. Existing appointments remain accepted; a changed incoming
package holds until their retained source/firmware work is resolved before its
new policy activates. Remove competing old Intune assignments, not accepted tasks
or state. See [v3 migration](../OPERATIONS.md#moving-from-v3-to-v4).
Rebuild the entire package and matching detection to deliver v4; copying only UI
files is insufficient. During preparation, an animated bar indicates activity without
claiming a firmware percentage. The restart window shows the local restart time
and remaining countdown. Cancellation cleans only temporary UI status; the
firmware transaction and BitLocker verification task remain until resolved.
No recurring restart task or future Windows shutdown timer is created.

The icon is copied to `Source/Files/UI/Assets/app-icon.png` or `.ico`; generated
`Branding.psd1` points to it and `RuntimeManifest.json` records its hash. If none
is selected, `Theme.xaml` supplies the built-in vector icon. Source assets may be
removed from the packaging computer after build; endpoints use packaged assets.
Presets retain the source path, so a future rebuild needs that file again. To
rebrand the builder's own default, set `Builder/Branding.psd1` to a local
`Assets/name.png` or `.ico` placed under Builder; selecting a package icon overrides
its preview. No remote URLs, executable icons or new runtime dependencies are used.

## What the ZIP must contain

Supply a **prepared deployment template**, with these together in one directory:

- `Invoke-AppDeployToolkit.exe`
- `Invoke-AppDeployToolkit.ps1`
- `PSAppDeployToolkit/PSAppDeployToolkit.psd1`, declaring version 4.1.x
- The manifest's `.psm1` root module and its required framework resources
- Your framework configuration, extensions and custom files

An enclosing folder is supported. Multiple complete templates, incomplete
releases, PSADT 3/4.0/4.2+, or a GitHub source-code archive are rejected. Remove
`BIOS-Password.psd1` from the ZIP and enter the current password in the wizard.
The ZIP is checked for traversal, rooted paths, alternate streams, case-colliding
entries, links, Windows reserved names and size limits (20,000 entries, 2 GB per
entry and 4 GB extracted). No input template script or module is executed during
the build; data manifests are read through `Import-PowerShellDataFile`.

The builder parses the deployment script with PowerShell's AST. It requires one
top-level function for each standard Install/Uninstall/Repair entry point and one
top-level literal `$adtSession` metadata table. It inserts the BIOS installer,
makes uninstall/repair fail explicitly, and sets app vendor/name/version/x64,
success/reboot codes, processes-to-close and admin/title metadata. It preserves
the rest of your bootstrap, module, extensions and files. The original script is
archived outside Source. This was checked against the official
[PSADT 4.1.0 frontend](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/4.1.0/src/PSAppDeployToolkit/Frontend/v4/Invoke-AppDeployToolkit.ps1).

Custom top-level code or extensions can still install other software, launch
prompts or request restarts. Review your framework for these behaviors; the
builder cannot certify arbitrary customization. Its BIOS runtime files, config,
policy, UI files and `Files/ApprovedBIOS.exe` replace matching paths in the copied
framework. Original ZIP and repository files are not changed. Existing signatures
on edited scripts are invalidated; re-sign final scripts if your policy requires
it, regenerate RuntimeManifest.json and the Intune scripts after signing, and
then rebuild `.intunewin` from that signed Source. Upload the matching detection
script with the package. See [the refresh/signing procedure](../README.md#storage-and-automatic-file-refresh).

## Output

V4.1 places the destination picker directly on the **Build** tab. New sessions
start with a blank Output folder instead of defaulting to Documents. Type an
existing local absolute path, or use **Choose folder** to select/create a folder.
The picker opens at the current valid selection, is owned by the builder window,
and leaves the prior selection intact on Cancel. If the picker cannot open, use
the editable path field. Old and new presets retain `OutputRoot`; review it when
moving a preset to another packaging computer.

The selected folder must be outside the repository, on a local ACL-capable disk.
Existing UNC/junction/symlink restrictions remain. The GUI validates the path
before starting a worker; the worker validates it again. An empty/invalid choice
does not silently fall back to Documents. Spaces and square brackets in local
paths are handled literally; a drive root remains absolute.

Every build creates `DellBIOS-<target-version>-<timestamp>-<id>` beneath the chosen
folder. This contains **all** output in the table below, including the optional
`Package/*.intunewin`. The new build directory receives the existing protected
permissions; the selected parent and unrelated files are not changed. A handled
failure removes only that build's partial directory, preserving previous builds.
Changing destination invalidates the review; it is locked while a build is active.

Review text, progress, `Build.log` and `BuildManifest.json` identify the destination.
The manifest records `BuilderVersion = 4.1.0`, `OutputRoot` and `OutputDirectory`.
`Settings.psd1` saves your selection for another build; **Open output** opens the
completed build folder. These paths describe the build computer, not an endpoint
cache location: endpoint files still use `C:\ProgramData\Medela\DellBIOS`.

| Item | Use |
|---|---|
| `Source/` | Complete customized PSADT package with approved BIOS and generated runtime settings |
| `Intune/Require-Model.ps1` | Standalone x64 requirement; Boolean equals True |
| `Intune/Detect-BIOS.ps1` | Actual target BIOS, protection, resolved transaction and expected runtime hashes |
| `Intune/Audit-BIOSAndBitLocker.ps1` | Actual firmware and protection compliance |
| `Package/*.intunewin` | Upload artifact, only when the content prep tool was selected and succeeded |
| `Settings.psd1` | Nonsecret reusable preset including AllowScheduleLater and icon source path; review reset |
| `Source/Files/RuntimeManifest.json` | Per-file versions and SHA256 for runtime repair; no credentials |
| `BuildManifest.json`, `Build.log` | Versions, payload/framework hashes, policy and build records; no secret or password-file hash |
| `OriginalTemplate/` | Original deployment script for local review, outside the deployable source |
| `READ-ME-FIRST.txt` | Exact Intune commands, restart policy, credential and pilot instructions |

The BIOS gets a stable `ApprovedBIOS.exe` filename inside the package; its bytes
are unchanged. Its copied bytes are hashed and checked for valid Dell Authenticode
before configuration and detection are generated. Each build gets a new unique
output directory. Partial output is removed on a handled failure. If the builder
is terminated or Windows shuts down mid-build, a protected partial directory may
remain; remove it and rebuild. Only a completed result is deployable.

Output access is restricted to the packaging account, SYSTEM and Administrators
before any secret is written. The shared password is plaintext in the generated
local data file, as in the existing deployment. It is never saved in presets,
review text, build logs or manifests. Do not enable PowerShell transcription while
entering secrets via scripts; use `Read-Host -AsSecureString` or the GUI. SYSTEM,
local administrators and privileged monitoring can still recover the password
from the package/Dell command line. `.intunewin` is not a credential vault.
Moving output can change its permissions; protect and dispose of it accordingly.

The builder uses a fixed runtime file allowlist from the repository and never
copies a local password or arbitrary BIOS binary from the repository. Output
inside this repository is refused. Password files and `.intunewin` are also
Git-ignored. No Intune app, assignment, firmware update or restart is triggered by
building the package.

## Scripted reuse

Run from the `Dell-BIOS-PSADT41` directory in Windows PowerShell 5.1. All final
settings remain available through the same engine as the GUI:

```powershell
. .\Builder\Build-Package.ps1
$settings = Import-PackagePreset 'C:\SecurePackaging\DellBIOS-settings.psd1'
$settings.BiosPath = 'C:\ApprovedFirmware\YOUR_APPROVED_BIOS.exe'
$settings.FrameworkZip = 'C:\SecurePackaging\Our-PSADT-4.1.zip'
$settings.OutputRoot = 'C:\SecurePackaging\Output' # Existing folder, outside checkout
$settings.Models = @('Dell Pro Max 16 MC16250')      # Verify exact model/EXE support
$settings.TargetVersion = '2.1.1'                    # Example; use the approved version
$settings.AllowScheduleLater = $false               # Install Now / Defer; restart countdown unchanged
$settings.IconPath = 'C:\Branding\device-care.ico'     # Optional; use '' for the default
$settings.PackageReviewed = $true                  # After reviewing these inputs
$password = Read-Host 'Shared BIOS administrator password' -AsSecureString
try {
    New-DellBiosPackage -Settings $settings -BiosPassword $password -Progress {
        param($message)
        Write-Host $message
    }
} finally {
    $password.Dispose()
}
```

Use `New-PackageBuildSettings` instead of importing a preset to start with safe
defaults. The engine accepts the password only through a separate SecureString
parameter; do not add one to the settings hashtable.

## Troubleshooting and Windows pilot

The requested user prompt uses PSADT's session helper. Microsoft does not support
interactive Intune installs or user-session UI workarounds; the helper does not
remove that limitation. Review [the Intune guidance](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program)
and [package configuration](../README.md#intune-configuration), including an install
timeout that allows the full restart countdown, prompts and staging to finish,
before deployment. Start the default Windows pilot with 180 minutes and adjust
to measured staging time and any longer configured countdown.

Build errors identify the phase without echoing file contents or password parse
errors. Invalid settings are reported before extraction. For extraction failures,
check the ZIP layout, version, entry restrictions and free space. For template
integration failures, start with the standard 4.1.x metadata/functions and move
custom behavior into supported extensions. For Dell validation failures, inspect
the approved EXE's Authenticode status and certificate chain on the packaging
computer; do not disable the signature check. For content prep failures, use the
official signed utility, verify .NET 4.7.2 and sufficient space, and inspect local
tool output. No partial build is ready for upload.

Before deployment, validate the GUI at 100/150/200% scaling, keyboard navigation,
password mismatch/clear behavior, browse/preset flows, async build completion and
output permissions as a nonadmin user. Check Close, Escape and X while idle,
after success/failure, and while a build is running: the last case must finish
cleanup before exiting without Ctrl+C. Build with your real ZIP and EXE, verify
custom framework resources, create an actual `.intunewin`, and run the existing
[Windows firmware pilot](../OPERATIONS.md). Test both the optional runtime gate
and configured thresholds immediately before staging and managed restart. The
Linux regression suite uses inert fixtures and mocks Windows trust/ACL boundaries;
it is not proof of WPF rendering, Windows permissions or a successful flash.

Run `Tests/V4/Test-WindowsUI.ps1` with Windows PowerShell 5.1 `-STA` for an inert
native XAML/icon/caption smoke check, optionally `-IconPath C:\Branding\device-care.ico`.
It briefly opens windows but does not load deployment logic. Then run both checkbox
states through a real build, save/load old and new presets, preview enabled,
disabled and overdue notices, and test the live guard semantics on pilot hardware.
Use keyboard-only navigation and Narrator, minimize/restore, drag between monitors,
high contrast and a 1366x768 display at 100/150/200%. Verify all controls remain
reachable, including the footer when content scrolls. See `../VALIDATION.txt` for
which automated checks were actually run.


### AuthorizationManager check failed

This is a PowerShell script authorization failure, not a Dell BIOS return code
or evidence of an incorrect BIOS password. The GUI loads its engine again in a
background PowerShell session when Build is clicked. A downloaded-file marker,
signing requirement, publisher prompt or application-control rule can block that
load. The short error alone does not identify which one applies.

Close the wizard. In **Windows PowerShell 5.1**, inspect:

```powershell
Get-ExecutionPolicy -List
Get-ExecutionPolicy
```

If you downloaded the repository from GitHub, review/trust that specific source,
then remove the downloaded-file marker from its scripts. Replace the path below
with your extracted `Dell-BIOS-PSADT41` folder; do not point it at a drive root or
all of Downloads:

```powershell
$repoFolder = 'C:\Path\To\Dell-BIOS-PSADT41'
Get-ChildItem -LiteralPath $repoFolder -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') } |
    Unblock-File

& "$repoFolder\Builder\Start-PackageBuilder.cmd"
```

[Unblock-File](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file)
removes the download marker; it does not change execution policy. Alternatively,
unblock the trusted repository ZIP in its Windows Properties before extracting a
fresh copy. Unblocking does not satisfy `AllSigned`, `Restricted`, or an enforced
application-control rule. Use your organization's signing/approved packaging
process for those cases; the builder does not override them. If the failure
persists, collect the two policy outputs above, how you launched the wizard, and
its build-status text. Do not include the BIOS password or generated password file.

The builder now stops on a denied engine load and recognizes authorization errors
wrapped by the background worker. Its diagnostic omits raw script lines and
arguments. This error-handling change improves diagnosis; it does not prove that
Windows authorization on a particular packaging computer has been resolved.


### Generated deployment script did not pass syntax validation

Early builder revisions used `Sort-Object Start -Descending` on a list of edit
hashtables. Named-property sorting by dictionary keys is supported only from
PowerShell 6 onward, so Windows PowerShell 5.1 could apply replacements in the
wrong order and generate invalid syntax even from a valid template. This was a
builder compatibility defect. The corrected builder uses an explicit numeric
calculated property and rejects overlapping/out-of-order edits before writing.
See [Microsoft's Sort-Object documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/sort-object#example-11-sort-hashtables-by-key-value).

Update the builder on v4, close the existing wizard, and launch it again with the
same approved template and settings. Syntax validation remains mandatory. If a
new build still fails, its error now includes parser IDs and line/column positions
without disclosing custom source text. Share those diagnostics and the PSADT
module version; do not share passwords or a credential-bearing package.
