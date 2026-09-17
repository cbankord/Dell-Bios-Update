#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [string]$OutputDirectory = (Join-Path $PackageRoot 'Intune')
)
. "$PSScriptRoot\Files\Common.ps1"
. "$PSScriptRoot\Files\Simple\Cache.ps1"
$config = Import-PowerShellDataFile (Join-Path $PackageRoot 'Files/BIOS-Config.psd1')
Assert-Config $config
Assert-Payload (Join-Path (Join-Path $PackageRoot 'Files') $config.FileName) $config
$json = ($config | ConvertTo-Json -Depth 5 -Compress).Replace("'", "''")
$runtimeJson = ((Read-ApprovedRuntimeManifest (Join-Path $PackageRoot 'Files')) | ConvertTo-Json -Depth 5 -Compress).Replace("'", "''")
$header = @'
# Generated from BIOS-Config.psd1. Regenerate for EVERY model/version/hash change.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$config = '__CONFIG_JSON__' | ConvertFrom-Json
$runtime = '__RUNTIME_JSON__' | ConvertFrom-Json
function Convert-BiosVersion([string]$Text) {
    if ($Text -notmatch '^\d+\.\d+(\.\d+){0,2}$') { throw 'Unsupported version.' }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts -join '.')
}
'@
$header = $header.Replace('__CONFIG_JSON__', $json)
$header = $header.Replace('__RUNTIME_JSON__', $runtimeJson)
$model = @'
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit script execution.' }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.Manufacturer.Trim() -notmatch '^Dell( Inc\.?| Computer Corporation)?$' -or $cs.Model.Trim() -notin @($config.Models)) { throw 'Model not applicable.' }
'@
$detect = @'
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    if ($current -ge (Convert-BiosVersion $config.TargetVersion)) {
        Import-Module BitLocker -ErrorAction Stop
        $volume=Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($volume.VolumeStatus -notin @('FullyEncrypted','FullyDecrypted') -or ($volume.VolumeStatus -eq 'FullyEncrypted' -and $volume.ProtectionStatus -ne 'On')) { exit 1 }
        $key='HKLM:\SOFTWARE\ManagedDellBIOS'
        if (Test-Path -LiteralPath $key) {
            $txn=Get-ItemProperty -LiteralPath $key
            if ($txn.Status -ne 'Verified' -or $txn.SuspendedByUs -ne '0') { exit 1 }
        }
        # Same-BIOS package updates must still refresh old/missing/drifted code.
        # Read-only detection: all repair remains in the SYSTEM installer.
        $cache=Join-Path $env:ProgramData 'Medela\DellBIOS'
        foreach ($file in $runtime.Files) {
            $path=Join-Path $cache $file.Destination
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $file.SHA256) { exit 1 }
        }
        Write-Output "BIOS verified: $current; drive protection checked."; exit 0
    }
    # Deferred or staged is not complete. Intune must attempt the package again.
    exit 1
} catch { exit 1 }
'@
$require = @'
    Write-Output 'True'
    exit 0
} catch { Write-Output 'False'; exit 0 }
'@
$audit = @'
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    if ($current -lt (Convert-BiosVersion $config.TargetVersion)) { throw "BIOS $current is below target." }
    Import-Module BitLocker -ErrorAction Stop
    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($volume.VolumeStatus -notin @('FullyEncrypted','FullyDecrypted')) { throw 'Encryption state needs review.' }
    if ($volume.VolumeStatus -eq 'FullyEncrypted' -and $volume.ProtectionStatus -ne 'On') { throw 'BitLocker protection is suspended.' }
    Write-Output "Verified BIOS $current; BitLocker state acceptable."
    exit 0
} catch { Write-Output ('Needs attention: ' + $_.Exception.Message); exit 1 }
'@
$out = $OutputDirectory
$null = New-Item -ItemType Directory -Path $out -Force
$utf8 = New-Object System.Text.UTF8Encoding($true)
foreach ($entry in @(
    @{ Name = 'Detect-BIOS.ps1'; Body = $detect },
    @{ Name = 'Require-Model.ps1'; Body = $require },
    @{ Name = 'Audit-BIOSAndBitLocker.ps1'; Body = $audit }
)) {
    $content = $header + "`r`ntry {`r`n" + $model + "`r`n" + $entry.Body
    [IO.File]::WriteAllText((Join-Path $out $entry.Name), $content, $utf8)
}
Write-Output "Generated detection, requirement and audit scripts in $out"
