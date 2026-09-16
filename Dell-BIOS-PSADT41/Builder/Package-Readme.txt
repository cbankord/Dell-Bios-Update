DELL BIOS V2 - GENERATED PACKAGE

1. Source is the complete PSADT deployment folder. The builder preserved the
   selected 4.1.x framework, extensions and custom files, replaced the three
   deployment functions, and set the BIOS app metadata. OriginalTemplate holds
   the original bootstrap for review outside the deployable source tree.
   Custom top-level logic, extensions, framework settings and existing Files
   remain your responsibility. Review these for competing installers/restarts.
   Editing the bootstrap invalidates any existing script signature. Apply your
   approved signing process after reviewing the final files; if you sign/change
   Source after packaging, rebuild .intunewin from the updated Source.

2. BuildManifest.json records the copied BIOS hash, framework archive hash,
   settings and runtime hashes. It excludes the password and password-file hash.
   Settings.psd1 is a reusable NONSECRET preset, with review reset to false.
   Build notes do not prove that the BIOS supports a model or that a flash worked.

3. If Package contains .intunewin, that is the upload file. Otherwise select a
   valid Microsoft IntuneWinAppUtil.exe in the builder, or run your approved tool:
     IntuneWinAppUtil.exe -c "<build>\Source" -s Invoke-AppDeployToolkit.exe -o "<build>\Package" -q
   Package output must be outside Source. Do not upload Source as a ZIP to Intune.
   The builder does not create or modify an Intune app or upload credentials.

4. Intune Win32 app:
   Install behavior: System (64-bit Windows)
   Install: Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
   Uninstall: Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
     This intentionally fails with 60001. BIOS downgrade/uninstall is unsupported;
     do not assign an uninstall deployment as a way to roll back firmware.
   Device restart behavior: No specific action.
   Return code 0: Success; 60001/unexpected: Failed; 1618: Retry if applicable.
   V2 never passes internal 3010 to Intune. No Intune or PSADT restart timer.
   Requirement: Intune\Require-Model.ps1, 64-bit, Boolean equals True.
   Detection: Intune\Detect-BIOS.ps1, 64-bit.
   Compliance: Intune\Audit-BIOSAndBitLocker.ps1, read-only actual BIOS/BitLocker.
   Installed means enrolled (or BIOS already meets target), not flash success.
   Coordinate Windows Update and other assignments with this restart owner.

5. Pilot the selected model/version/password/PSADT ZIP on Windows before rollout.
   Verify Dell exit codes, prerequisite versions, AC and battery holds, optional
   runtime telemetry, recovery-key backup, finite BitLocker suspension/resume,
   normal-user UI and deadline persistence, sleep/offline cases, and actual BIOS
   version after restart. See the repository's OPERATIONS.md and Builder/README.md.
   StagedDetectionHours is retained for legacy config compatibility; v2 enrollment
   detection does not use it. It never changes the deadline or restart time.

6. Source\Files\BIOS-Password.psd1 and .intunewin contain the shared BIOS secret.
   Output ACLs allow the packaging user, SYSTEM and Administrators. Copying to
   another location may change those ACLs. Protect, retain and dispose of these
   artifacts under your organization's credential handling policy. Do not put
   them in Git, shared tickets or email. Interrupted builds may leave a protected
   partial directory: remove it before rebuilding; never deploy it.
