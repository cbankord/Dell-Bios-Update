DELL BIOS V2.2 - GENERATED PACKAGE

1. Source is your complete customized PSADT 4.1.x deployment. Review preserved
   bootstrap/extensions for additional installs or competing restart behavior.
   OriginalTemplate contains the original script outside the deployment folder.
   Changes invalidate existing script signatures: sign final scripts under your
   policy, regenerate Files/RuntimeManifest.json AFTER signing, then repackage.
   Use Write-RuntimeManifest from the reviewed repository Files/Simple/Cache.ps1.
   Then rerun Build-IntuneScripts.ps1 against that Source, sign the resulting
   Intune scripts if required, and upload the new detection and package together.

2. BuildManifest.json records the BIOS/framework hashes and nonsecret settings.
   RuntimeManifest.json records managed file versions and hashes. File tattoos
   identify versions; they are not publisher signatures. The trusted package is
   the update source, and Dell Authenticode plus pinned BIOS SHA256 still apply.
   Never include BIOS-Password.psd1 or its hash in any manifest/preset.

3. If Package contains .intunewin, upload it. Otherwise run the official signed
   IntuneWinAppUtil.exe against Source with output outside Source, or rebuild
   using the wizard with the content prep utility selected.

4. Intune Win32 settings:
   Install behavior: System, x64 Windows PowerShell 5.1.
   Install: Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
   Device restart behavior: No specific action.
   Installation timeout: allow three prompt timeouts plus measured staging and
   margin; start the Windows pilot at 120 minutes. Never kill a BIOS updater.
   Return 0: success after actual BIOS/protection verification.
   Return 1618: RETRY (deferred, no user, pending restart or transient hold).
   Return 60001/unexpected: failed; inspect logs.
   Internal installer 3010 is consumed; no competing Intune/PSADT reboot timer.
   Requirement: Intune/Require-Model.ps1, 64-bit Boolean equals True.
   Detection: Intune/Detect-BIOS.ps1, 64-bit; BIOS/protection/transaction and
   packaged runtime hashes. Old files trigger repair even with a current BIOS.
   Audit: Intune/Audit-BIOSAndBitLocker.ps1.
   REPLACE OLD ENROLLMENT-BASED DETECTION as well as package content.
   Uninstall/repair intentionally fail; never use them to reset firmware state.

5. Install Now / Defer is a one-shot branded prompt. The original deferral window
   begins with the first active-user prompt launch attempt. It does not reset
   after reboot, retries or code updates. Intune owns later attempts; there is
   no guaranteed exact-time or 72-hour background execution. Overdue installation
   prompts remove Defer and request preparation after the visible timeout.
   Safety checks remain mandatory. Restart Now is explicit and rechecks safety;
   Restart Later/closing/timeout never forces a reboot. Monitor staged updates.

6. Managed files live under C:\ProgramData\Medela\DellBIOS (Runtime, UI, State,
   Recovery). Older/unversioned/missing files and same-version hash drift are
   repaired automatically when safe; newer cached versions block downgrade.
   State/deadlines/credentials are not overwritten. Pending firmware or recovery
   blocks code replacement. Standard users only read the public UI files.
   Only the temporary post-boot verification task remains after staging.

7. Existing v2 pilots: remove old competing assignments. The new package retires
   only its known Controller/UserUI tasks and old Program Files UI when firmware
   is safe, importing the original deadline. It holds if a BIOS transaction is
   unresolved. Do not delete state to force migration. Old protected ProgramData
   records remain for diagnosis. See OPERATIONS.md in the repository.

8. Pilot Windows PowerShell 5.1/WPF/session launch, protected ACLs, same-package
   code repair, legacy migration, Intune retry/detection, real Dell signature and
   password, power/space/model holds, escrow and post-boot BIOS/BitLocker recovery.
   Portable tests are not real firmware or Windows integration validation.
   Logs: C:\ProgramData\Medela\DellBIOS\Recovery\Deployment.log plus PSADT logs.
   Microsoft does not support interactive Intune installations or forced user
   session UI. This PSADT helper does not remove that platform limitation:
   https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program

9. Source/Files/BIOS-Password.psd1 and .intunewin contain the shared BIOS secret.
   Output is protected for the packaging user, SYSTEM and Administrators. Protect
   both artifacts; do not upload them to Git, tickets or email. The password is
   not copied into the user-readable Medela cache. Never deploy partial output.
