V4.3 APPLICATION / WINDOWS UPDATE / DELL DRIVER OUTPUT

For generated servicing or edited apps, read BuildManifest.json and the exact
Source/Invoke-AppDeployToolkit.ps1 before deployment. SourcePreserved=false means
sections or servicing payload were added. Sections.psadt.json is a reusable
section-only snapshot; it is not a full deployment. Never store credentials in it.
WindowsUpdate/Driver require SYSTEM, the configured Windows build, and tested
installed-state detection. Driver also requires an approved Dell model. Default
servicing uses DISM or PnPUtil without requesting a restart, returns 3010 when
required, and has no default uninstall/repair. Configure one Intune restart policy.
Editor changes can alter those defaults and must be piloted. BIOS controls do not
apply to these modes. See Builder/Servicing-and-Editor-Guide.md in the repository.

APPLICATION WITH DEFAULT PSADT VIEW ONLY - V4.3
The following source-preservation notes apply when PackageType=Application
and SourcePreserved=true. Generated servicing and edited packages use the notes above.

Source contains your existing application's scripts, payloads, framework and
branding. The builder does not rewrite install/uninstall/repair logic, metadata,
prompts, deferrals or restarts. It does not execute the application while building.
Name/version entered in the builder label build records; they do not change the
application's original deployment metadata or installed product version.

Review Intune/Install-Commands.txt for entry-point commands and selected System
or User install behavior. Confirm your package supports these standard PSADT
parameters and that uninstall is implemented before offering it to users.
Set architecture, OS requirements, timeout, return-code mappings and restart
behavior to match the app. Intune commands use Silent mode; configure application
branding/experience in the original ZIP. No Medela BIOS UI or timer is injected.

If you selected a detection script, Intune/Detect-Application.ps1 is its unchanged
copy. Upload it as custom detection and test installed/absent/version cases using
the correct architecture and execution context. The builder parses but never
executes or certifies the script. Without one, configure app-specific detection
in Intune before assignment. A successful build does not mean an app is installed.

Package/*.intunewin is present only if the Microsoft content prep tool was
selected. Otherwise package Source yourself with the setup file named in the
commands record. BuildManifest.json records mode, ZIP hash, version and output;
Settings.psd1 remembers builder choices without a BIOS password. Source and optional
.intunewin are in a unique protected child of your selected output folder.

Supported layouts: a complete PSADT 4.x deployment with Invoke-AppDeployToolkit.exe,
Invoke-AppDeployToolkit.ps1 and PSAppDeployToolkit manifest/root module, or the
legacy 3.x Deploy-Application.ps1 plus AppDeployToolkitMain.ps1/config XML layout.
One enclosing folder is allowed. Multiple applications/source-code archives are
rejected. Legacy layout recognition does not certify its exact framework patch.
All source PowerShell must parse on the packaging host (Windows PowerShell 5.1).

Keep sensitive application data out of Git and protect generated packages. No
BIOS password, Dell payload checks, BitLocker changes, Medela cache or scheduled
tasks are added by Application mode. Review the supplied app's own privileged
operations, credentials, signing, dependencies and hardware requirements.
Archive limits and safe-path restrictions still apply; BIOS-Password.psd1 must
not be present in an input ZIP. Use BIOS mode for the managed Dell BIOS workflow.

Pilot the real application on Windows, including install/uninstall, detection,
upgrade, reboot behavior and your chosen Intune context. Portable tests do not
execute application code, native content prep, WPF or Windows ACLs.
