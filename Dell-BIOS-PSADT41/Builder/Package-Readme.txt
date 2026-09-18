DELL BIOS V4.1 - GENERATED PACKAGE

This build was saved beneath the output folder selected on the builder's Build
tab. BuildManifest.json and Build.log record the chosen parent and unique build
directory. Source, Intune scripts and optional Package/.intunewin are grouped in
this directory. Settings.psd1 remembers the output folder for future builds.

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
   Installation timeout: allow install prompt + full restart countdown + measured
   staging and margin; start at 180 minutes, raising it for longer settings.
   Never kill a BIOS updater to meet an installation timeout.
   Return 0: success after actual BIOS/protection verification.
   Return 1618: RETRY (deferred, no user, pending restart or transient hold).
   Return 60001/unexpected: failed; inspect logs.
   Internal installer 3010 is consumed; no competing Intune/PSADT reboot timer.
   Requirement: Intune/Require-Model.ps1, 64-bit Boolean equals True.
   Detection: Intune/Detect-BIOS.ps1, 64-bit; BIOS/protection/transaction and
   packaged runtime hashes and cleanup of retained scheduled source. Old files
   trigger repair even with a current BIOS.
   Audit: Intune/Audit-BIOSAndBitLocker.ps1.
   REPLACE OLD ENROLLMENT-BASED DETECTION as well as package content.
   Uninstall/repair intentionally fail; never use them to reset firmware state.

5. AllowScheduleLater in Source/Files/Simple/Policy.psd1 controls installation
   scheduling, not deferrals or the post-install restart countdown. Enabled
   (default): Install Now / Schedule Install / Defer. Disabled: Install Now / Defer;
   SYSTEM rejects new/rescheduled appointments and no fresh install task is made.
   Existing accepted appointments are honored. Settings.psd1, BuildManifest.json
   and Build.log record the setting. Old presets without it default to enabled.
   The fixed window
   begins with the first active-user prompt launch attempt; retries/code updates
   never reset it. Schedule Install picks a local time at least five minutes ahead
   within that window. Defer/X/timeout keeps any saved appointment. After expiry,
   only Install Now remains and preparation follows the visible prompt timeout.
   SYSTEM retains your complete Source privately in State/ScheduledPackage, then
   creates ManagedDellBIOS-ScheduledInstall. It runs at the chosen UTC instant and
   retries missing user/power prerequisites every 15 minutes without waking the PC
   or extending the deadline. No BitLocker suspension occurs during scheduling.
   Changing the time replaces the same task. The task is retired after staging;
   it never owns a restart timer. Without a selected time, Intune supplies retries.
   No execution while powered off or exact 72-hour enforcement is guaranteed.
   Preparation shows an animated progress bar without inventing a percentage.
   After staging, a movable/minimizable warning counts down 60 minutes by default,
   with a sound and restore/recenter every 15 minutes. Minimize/X keeps counting;
   Restart Now or expiry requests a SYSTEM restart after safety checks. Windows
   apps may block it: no forced closing of unsaved applications.
   Unsafe power, detected sleep/monitoring interruption, clock change, lost user
   session or UI failure cancels the countdown and cleans temporary prompt data.
   Retain BIOS/BitLocker recovery and original deadline; never delete all tasks.
   A later Intune attempt gives staged firmware a fresh warning without reflashing.
   No code runs while powered off; the post-boot verifier cleans its old-boot
   prompt data, and later package attempts also remove stale prompt folders.

6. Managed files live under C:\ProgramData\Medela\DellBIOS (Runtime, UI, State,
   Recovery). Older/unversioned/missing files and same-version hash drift are
   repaired automatically when safe; newer cached versions block downgrade.
   State/deadlines/credentials are not overwritten. Pending firmware or recovery
   or retained scheduled source blocks code replacement. Standard users only read
   the public UI files. The private full source is removed after definitive
   verification; never delete firmware/recovery state to force its cleanup.
   Only the temporary post-boot verification task remains after staging.

7. V3 or existing v4 appointments: remove competing older Intune assignments but
   preserve the accepted local task and protected package. An incoming changed
   package returns retry until accepted work runs, is verified and its private
   source cleaned. Its disabled policy/runtime then activates. It never cancels
   an appointment, replaces unresolved firmware or grants a new deferral window.
   A disabled policy can still repair/honor existing accepted intent.
   Existing v2 pilots: remove old competing assignments. The new package retires
   only its known Controller/UserUI tasks and old Program Files UI when firmware
   is safe, importing the original deadline. It holds if a BIOS transaction is
   unresolved. Do not delete state to force migration. Old protected ProgramData
   records remain for diagnosis. See OPERATIONS.md in the repository.

8. Pilot Windows PowerShell 5.1/WPF/session launch, protected ACLs, same-package
   code repair, legacy migration, Intune retry/detection, real Dell signature and
   password, power/space/model holds, escrow and post-boot BIOS/BitLocker recovery.
   Verify the local schedule picker, reschedule, original deadline, missed times,
   task launch from the retained framework, safe retries and private source cleanup.
   Test both Allow schedule later states, old presets and accepted-work migration.
   Verify custom caption dragging, resize, minimize/maximize/restore, keyboard and
   screen-reader labels at 100/150/200% DPI, small screens and high contrast.
   Live progress/restart Close minimizes; overdue Close cannot defer. Builder
   Close is immediate while idle or waits for active-build cleanup. Icons are
   local PNG/ICO assets; a vector device icon is used when no icon is selected.
   Preview: Files/UI/Show-BiosUI.ps1 -Demo [-DisableScheduling] [-Overdue].
   Verify progress, minimize/X, 15-minute sound/recenter, one-hour expiry, sleep /
   Modern Standby, 50% vs 51%, AC loss, UI/host loss and application-blocked restart.
   Portable tests are not real firmware or Windows integration validation.
   Logs: C:\ProgramData\Medela\DellBIOS\Recovery\Deployment.log plus PSADT logs.
   Microsoft does not support interactive Intune installations or forced user
   session UI. This PSADT helper does not remove that platform limitation:
   https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program

9. Source/Files/BIOS-Password.psd1 and .intunewin contain the shared BIOS secret.
   Output is protected for the packaging user, SYSTEM and Administrators. Protect
   both artifacts; do not upload them to Git, tickets or email. The password is
   retained only in the private scheduled source, never the user-readable UI.
   Medela parent and sibling permissions are unchanged. Never deploy partial output.
