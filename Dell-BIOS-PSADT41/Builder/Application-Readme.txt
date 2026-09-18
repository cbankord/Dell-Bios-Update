PSADT APPLICATION - V4.2 GENERATED PACKAGE

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
