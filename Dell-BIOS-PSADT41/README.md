# Dell BIOS v2.2 — simple PSADT deployment

Build with `Builder/Start-PackageBuilder.cmd`, using your approved Dell BIOS EXE
and prepared PSADT 4.1.x ZIP. Review the generated `READ-ME-FIRST.txt` before upload.
The builder keeps your custom framework and generates BIOS settings, branding,
Intune scripts and a runtime integrity manifest. No BIOS/password is in Git.

## User experience

1. Intune runs the PSADT package as x64 SYSTEM. Files are validated and refreshed
   under `%ProgramData%\Medela\DellBIOS` (`C:\ProgramData\Medela\DellBIOS` normally).
2. The compact branded UI runs once in the signed-in standard user's session.
   **Install Now** starts preparation through SYSTEM after all safety checks.
   **Defer**, closing the window or timing out before the deadline returns a retry.
3. A fixed window (72 hours by default) is saved immediately before the first
   prompt launch into an active user session. This is a delivery-attempt timestamp,
   not proof the notice was read. Launch failures, crashes, sign-outs and retries
   retain it. No active user means no new deadline and no firmware staging.
4. After expiry, the installation prompt removes Defer, prevents normal closing,
   and visibly counts down its prompt timeout before requesting preparation.
   Power/model/hash/password/BitLocker/transaction checks still apply.
5. Successful staging displays the configured restart-required message with
   **Restart Now** and **Restart Later**. Restart Now is a request to SYSTEM,
   which rechecks power, transaction ownership and BitLocker before `/r /t 0`.
   There is no `/f`. Restart Later/closing/timeout does not request a restart.
6. A temporary SYSTEM verification task checks actual BIOS and restores/verifies
   owned BitLocker protection after reboot. It unregisters after a definitive
   result. Staging or accepting an install is never reported as completion.

**Intune owns later attempts.** The reminder interval is a minimum between
notices, not a scheduled trigger. There is no exact-date picker, resident service,
background UI, persistent forced-restart countdown or guaranteed 72-hour wall-clock
execution. After a deferral or safety hold, the next Intune attempt evaluates the
original deadline. If the user postpones restart, subsequent attempts offer it
again without reflashing; monitor outstanding staged updates and protection state.
An independent user/Windows restart is outside this package's power gate.

## Storage and automatic file refresh

| Location under `C:\ProgramData\Medela\DellBIOS` | Contents / access |
|---|---|
| `Runtime` | Versioned helper scripts and policy; SYSTEM/Administrators |
| `UI` | Prompt, branding and PNG/JPG assets; users read/execute only |
| `State` | Original deadlines, enrollment markers, manifest and locks; SYSTEM/Administrators |
| `Recovery` | Guarded firmware copy, post-boot scripts and logs; SYSTEM/Administrators |

No files are newly installed into Program Files. The parent `Medela` folder is
created if absent; an existing shared parent is checked for safe ownership/access
without changing other applications' ACLs. Users cannot write code executed as
SYSTEM. Credentials remain in the protected deployment package and are not copied
to the user-readable UI or version/hash manifest.

Managed PowerShell files start with:

```powershell
# MedelaBIOS-FileVersion: 2.2.0
```

XAML uses the same marker inside an XML comment. The build-generated
`Files/RuntimeManifest.json` records versions and SHA256 hashes; images use their
branding version in the manifest. Each deployment invocation validates source
files against the manifest and compares them with the installed copy:

| Installed condition | Action |
|---|---|
| Missing, unversioned or older | Copy the packaged file |
| Same version, different SHA256 | Repair from the trusted package |
| Same version and SHA256 | Leave the file untouched |
| Newer version | Stop the older package; no automatic downgrade/mixed release |
| Firmware unresolved and replacement needed | Hold until verification/recovery resolves it |

The marker is a version identifier; the hash detects drift. Neither authenticates
a publisher. Trust comes from the reviewed Intune package and your signing policy.
Dell Authenticode and the separately approved BIOS SHA256 remain mandatory.
State, firmware transactions and credentials are never replaced by this updater.
All required source files are verified before copying; staged copies are verified,
individual replacements are atomic, and the installed manifest is committed last.
A failed refresh does not run cached code. The next attempt repairs remaining files.
The collection of files is not one filesystem-wide atomic transaction.

For a code release, increment the tattoo in each changed managed source file.
Use the builder to regenerate the manifest. For approved edits or signing of an
already built Source folder, regenerate hashes **after** the final bytes change:

```powershell
# From the trusted repository's Dell-BIOS-PSADT41 folder:
. .\Files\Simple\Cache.ps1
Write-RuntimeManifest -Files 'C:\Path\To\Build\Source\Files'
.\Build-IntuneScripts.ps1 -PackageRoot 'C:\Path\To\Build\Source' -OutputDirectory 'C:\Path\To\Build\Intune'
```

Then sign the regenerated Intune scripts if required, rebuild `.intunewin`, and
replace Intune's detection script as well as its package content. Detection embeds
the approved runtime hashes so code/branding repairs are offered even when the
BIOS is already current. Never resolve a mismatch by disabling the check.
Replacing branding with the builder is supported; direct cached edits will be
repaired back to the packaged branding. Same-BIOS-version reinstallation now
refreshes code/branding safely; it does not grant a new deferral window.

## Intune configuration

Microsoft documents interactive Intune installations and forced user-session UI
as unsupported. This package uses PSADT's session helper for the requested prompt;
that does not make it an Intune-supported interactive installation. Validate the
actual tenant/framework/session behavior in a Windows pilot before rollout.
See [Microsoft's Win32 installation guidance](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-2-program).

| Setting | Value |
|---|---|
| Install behavior | System; x64 Windows PowerShell 5.1 |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Device restart behavior | **No specific action** |
| Installation time required | Cover up to three prompt timeouts plus measured staging time and margin; start the pilot at 120 minutes |
| Return code `0` | Success only after actual BIOS and protection checks |
| Return code `1618` | **Retry** — deferral, no user, staged pending restart or transient hold |
| Return code `60001` | Failed — review logs / unresolved error |
| Detection | Generated `Intune/Detect-BIOS.ps1`, 64-bit |
| Requirement | Generated `Intune/Require-Model.ps1`, 64-bit Boolean equals True |
| Compliance audit | Generated `Intune/Audit-BIOSAndBitLocker.ps1` |

Internal installer `3010` is consumed by the wrapper and never sent to Intune as
a competing reboot timer. Detection requires actual target-or-newer BIOS, stable
protection and a resolved transaction when one exists. It does not detect controller
enrollment or accept a staged capsule. It also checks the expected runtime hashes;
old/missing/modified helpers trigger safe repair without reflashing a current BIOS.
Intune retry/re-evaluation can show a pending
or failed application while awaiting user action; pilot your assignment cadence.
Microsoft describes Retry as three attempts five minutes apart and required-app
re-offering at approximately 24 hours. A four-hour reminder setting therefore
does not promise a four-hour notification. The install timeout includes time
spent waiting for user choices; never terminate a BIOS updater to meet a timer.
See [Microsoft's retry and detection rules](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32).
Updating package content alone does not replace an old tenant detection script:
replace the old enrollment-based detection with the generated detection above.

The selected custom framework may have its own bootstrap/extensions/restart
behavior. Review it. The builder preserves it rather than certifying arbitrary
code. BIOS downgrade/uninstall/repair entry points intentionally fail; do not use
an Intune uninstall assignment to reset deployment or firmware state.

## Preview and diagnostics

As a standard user, from a package or the repository folder:

```powershell
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo
powershell.exe -NoProfile -STA -File .\Files\UI\Show-BiosUI.ps1 -Demo -Mode Restart
```

Preview cannot stage/restart or change deployment state. Close exits the window;
there is no tray client. The installed UI is launched by PSADT with live context,
not used as a standalone installation entry point.

Administrator log location:

```powershell
Get-Content "$env:ProgramData\Medela\DellBIOS\Recovery\Deployment.log" -Tail 60
```

Also inspect PSADT logs for entry/launch errors and protected `Dell-*.log` output
for vendor results. Do not share passwords, recovery keys or generated credential
packages. See [OPERATIONS.md](OPERATIONS.md) for migration and Windows pilot gates.

Manual source packaging still requires valid reviewed BIOS config, the approved
EXE, a local ignored BIOS-Password.psd1 when required, the integrated PSADT install
function, runtime manifest and regenerated Intune scripts. The checked-in example
config is not approved: its SHA256/model/EXE combination must be corrected using
the real payload. Prefer the builder, which calculates the hash from copied bytes.
