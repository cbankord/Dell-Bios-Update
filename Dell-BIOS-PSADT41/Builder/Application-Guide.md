# Application packaging in v4.3

Application source preservation described here applies to the default **PSADT**
view. v4.3 can optionally replace sections in **Editor**; see
[the section editor guide](Servicing-and-Editor-Guide.md). Legacy 3.x remains
unchanged packaging only.

Select **Application** in the Files tab's **Deployment type** list, choose your
complete PSADT application ZIP, and optionally select a custom Intune detection
script and Microsoft `IntuneWinAppUtil.exe`. On Deployment, enter app name/version
and choose **System** or **User** install behavior. On Build, choose the output
folder, review the settings, and click **Build package**.

This mode packages an **already configured application**. Install, uninstall,
repair, extensions, payloads and branding are copied unchanged into Source.
Name/version identify build records; they do not rewrite product metadata or
generate install logic for a bare MSI. No supplied script or payload runs while
building. Configure the app's UI, deferrals and restart behavior in the ZIP.
Application mode adds no BIOS password, Dell checks, battery gate, BitLocker
operation, Medela cache, scheduled task, managed BIOS UI or restart countdown.

## Supported ZIPs

| Layout | Required contents together in one deployment folder |
|---|---|
| PSADT 4.x | `Invoke-AppDeployToolkit.ps1`, `Invoke-AppDeployToolkit.exe`, `PSAppDeployToolkit/PSAppDeployToolkit.psd1` declaring a 4.x version, its named `.psm1`, and app resources/payloads |
| Legacy PSADT 3.x | `Deploy-Application.ps1`, `AppDeployToolkit/AppDeployToolkitMain.ps1`, `AppDeployToolkit/AppDeployToolkitConfig.xml`, app resources/payloads and optionally `Deploy-Application.exe` |

Legacy entry points follow the official
[PSADT 3.10.2 template](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/3.10.2/Toolkit/Deploy-Application.ps1).
Recognition records `3.x (legacy layout)`, not a certified patch version. All
PowerShell must parse on the Windows PowerShell 5.1 packaging host. Packages
requiring newer language syntax are not supported here; native runtime
compatibility remains an application pilot requirement.

One enclosing folder is supported. Dependencies must be inside the recognized
deployment folder. Multiple deployments, missing framework files and upstream
source-code archives are rejected. Existing limits remain: 20,000 ZIP entries,
2 GB per file and 4 GB total extracted. Traversal, links, invalid Windows names
and case collisions are rejected. `BIOS-Password.psd1` remains forbidden in ZIPs;
use the BIOS mode password field for managed BIOS deployments.

## Output and Intune

| Output | Purpose |
|---|---|
| `Source/` | Application deployment copied without script or branding changes |
| `Intune/Install-Commands.txt` | Install/uninstall commands, System/User behavior and setup notes |
| `Intune/Detect-Application.ps1` | Exact copy of your detection script, only when selected |
| `Package/*.intunewin` | Optional output of the selected, Microsoft-signed content prep tool |
| `BuildManifest.json` / `Build.log` | Builder 4.3.0, Application mode, app metadata, ZIP hash, output and detection records |
| `Settings.psd1` | Reusable mode/app/path settings, without a BIOS password |
| `READ-ME-FIRST.txt` | Application setup and pilot instructions |

Each build uses a new protected `PSADT-App-<name>-<timestamp>-<id>` child of your
chosen output folder. Parent permissions, unrelated siblings and previous builds
remain intact. Handled failure removes only the new partial build. Scripts and
existing signatures retain their bytes; the builder does not certify their trust.

Generated commands use the detected launcher and `-DeployMode Silent`. The legacy
script-only case uses `powershell.exe -NoProfile -File Deploy-Application.ps1`;
review host architecture because Intune can launch 32-bit PowerShell this way.
Check the app's requirements, uninstall support, return codes and restart policy.
BIOS return-code mappings do not apply to applications.

**Detection is app-specific.** Supply a reviewed script or configure an MSI/file/
registry/custom rule in Intune before assignment. No always-successful detection
script is generated; an output folder is not installation evidence. For scripts,
Intune requires a successful exit and detection output; test installed, absent
and wrong-version cases. Follow [Microsoft's Win32 app guidance](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32).

## Presets, scripts and pilot

Old presets without `PackageType` open in BIOS mode. New presets remember either
mode. Loading or switching clears BIOS passwords and review approval. Inactive
fields are excluded from the form's build settings. `New-DellBiosPackage` remains
BIOS-only; use `New-DeploymentPackage` to select either path.

```powershell
. .\Builder\Build-Package.ps1
$settings = New-PackageBuildSettings
$settings.PackageType = 'Application'
$settings.ApplicationName = 'Example App'
$settings.ApplicationVersion = '1.2.3'
$settings.ApplicationContext = 'System'
$settings.FrameworkZip = 'C:\Packaging\Example-App.zip'
$settings.OutputRoot = 'C:\Packaging\Output'
# Optional: ApplicationDetectionScript and ContentPrepTool.
$settings.PackageReviewed = $true # After reviewing this application and its ZIP.
New-DeploymentPackage -Settings $settings
```

Pilot actual install/uninstall, upgrade, detection, context, architecture,
unattended behavior and restarts on Windows. Validate both builder modes, old
presets, password clearing, output selection and Close during an app build with
no secret. Test native dialogs/caption at 100/150/200% scaling and keyboard/
screen-reader access. Portable tests use real package IO and inert callbacks;
they do not execute PSADT/apps, native content prep, WPF or NTFS ACL operations.
