#requires -Version 5.1
[CmdletBinding()]
param()
. "$PSScriptRoot\Files\Common.ps1"
$config = Import-PowerShellDataFile "$PSScriptRoot\Files\BIOS-Config.psd1"
Assert-Config $config
Assert-Payload (Join-Path "$PSScriptRoot\Files" $config.FileName) $config
$json = ($config | ConvertTo-Json -Depth 5 -Compress).Replace("'", "''")
$header = @'
# Generated from BIOS-Config.psd1. Regenerate for EVERY model/version/hash change.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$config = '__CONFIG_JSON__' | ConvertFrom-Json
function Convert-BiosVersion([string]$Text) {
    if ($Text -notmatch '^\d+\.\d+(\.\d+){0,2}$') { throw 'Unsupported version.' }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts -join '.')
}
'@
$header = $header.Replace('__CONFIG_JSON__', $json)
$model = @'
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit script execution.' }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.Manufacturer.Trim() -notmatch '^Dell( Inc\.?| Computer Corporation)?$' -or $cs.Model.Trim() -notin @($config.Models)) { throw 'Model not applicable.' }
'@
$detect = @'
    $current = Convert-BiosVersion (Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion.Trim()
    if ($current -ge (Convert-BiosVersion $config.TargetVersion)) { Write-Output "BIOS verified: $current"; exit 0 }
    $state = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\ManagedDellBIOS' -ErrorAction Stop
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks.ToString()
    $age = [datetime]::UtcNow - [datetime]::Parse($state.StagedUtc).ToUniversalTime()
    if ($state.Status -eq 'Staged' -and $state.BootId -eq $boot -and $state.TargetVersion -eq $config.TargetVersion -and $state.PayloadHash -eq $config.SHA256 -and $age.TotalHours -ge 0 -and $age.TotalHours -lt $config.StagedDetectionHours) {
        Write-Output 'BIOS payload staged; restart and firmware verification pending.'
        exit 0
    }
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
$out = Join-Path $PSScriptRoot 'Intune'
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
