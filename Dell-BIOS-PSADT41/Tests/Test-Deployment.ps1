# Harmless regression harness. Mocks Windows/PSADT; never executes a BIOS binary.
# Run with pwsh -NoProfile -File ./Tests/Test-Deployment.ps1
# Optional Windows-only test uses an isolated HKCU key, never production HKLM.
param([switch]$WindowsRegistryIntegration)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = @()
$count = 0
function Assert($Condition, [string]$Name) {
    $script:count++
    if (-not $Condition) { throw "FAIL: $Name" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert ($message -like $Pattern) $Name
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('DellBiosTests-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $fixture
$oldProgramData = $env:ProgramData
$oldSystemRoot = $env:SystemRoot
if (-not $env:ProgramData) { $env:ProgramData = $fixture }
try {
    Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psd1') } | ForEach-Object {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "Parser: $($_.Name)"
    }
    . "$root/Files/Common.ps1"
    if ($WindowsRegistryIntegration) {
        if ($env:OS -ne 'Windows_NT') { throw 'Windows registry integration requires Windows.' }
        $script:StateKey = 'HKCU:\Software\DellBiosTests-' + [guid]::NewGuid()
        try {
            Set-StateValue Status Preparing
            Set-StateValue TargetVersion '2.1.1'
            Set-StateValue SuspendedByUs 0
            $actual = Get-ItemProperty -LiteralPath $script:StateKey
            Assert ($actual.Status -eq 'Preparing' -and $actual.TargetVersion -eq '2.1.1' -and $actual.SuspendedByUs -eq '0') 'Real registry writes preserve earlier fields'
        } finally { Remove-Item -LiteralPath $script:StateKey -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $script:record = $null
    $script:creates = 0
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -eq $script:StateKey) { return $null -ne $script:record }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $(if ($PathType) { $PathType } else { 'Any' })
    }
    function Get-ItemProperty { param($LiteralPath) return $script:record }
    function New-Item {
        param($Path, [switch]$Force)
        Assert (-not $Force) 'Registry creation never uses Force'
        $script:creates++; $script:record = [pscustomobject]@{}
    }
    function New-ItemProperty {
        param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force)
        $script:record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    Set-StateValue Status Preparing
    Set-StateValue TargetVersion '2.1.1'
    Set-StateValue SuspendedByUs 0
    Assert ($script:creates -eq 1 -and $script:record.Status -eq 'Preparing') 'Repeated writes retain transaction fields'
    $script:record = [pscustomobject]@{ SuspendedByUs = '0' }
    Assert-Throws { Get-State } '*missing Status*' 'Damaged old state has actionable error'
    $script:record = $null
    Assert ($null -eq (Get-State)) 'Absent state returns null'
    $config = Import-PowerShellDataFile "$root/Files/BIOS-Config.psd1"
    $originalHash = $config.SHA256
    $config.SHA256 = 'A' * 64 # Inert fixture; the repository hash still needs administrator review.
    $config.PackageReviewed = $true
    Assert-Config $config
    $config.MinimumBatteryPercent = 50
    Assert-Throws { Assert-Config $config } '*51-100*' 'Reject exactly 50 percent configuration'
    $config.MinimumBatteryPercent = 51
    Assert-Throws { Get-BiosPassword $config $fixture } '*missing*' 'Missing required secret blocks'
    Copy-Item "$root/Files/BIOS-Password.example.psd1" "$fixture/BIOS-Password.psd1"
    Assert-Throws { Get-BiosPassword $config $fixture } '*configured*' 'Placeholder secret blocks'
    [IO.File]::WriteAllText("$fixture/BIOS-Password.psd1", "@{ Password = 'inert-test-value' }")
    Assert ((Get-BiosPassword $config $fixture) -eq 'inert-test-value') 'Read local password'
    [IO.File]::WriteAllText("$fixture/BIOS-Password.psd1", "@{ Password = 'inert-test-value }")
    Assert-Throws { Get-BiosPassword $config $fixture } 'Cannot read BIOS-Password.psd1. Check its data-file syntax locally.' 'Parse error does not expose secret source'
    $config.BiosPasswordRequired = $false
    Assert ($null -eq (Get-BiosPassword $config $fixture)) 'No-password model omits password'
    Assert ((ConvertTo-WindowsQuotedArgument 'abc$ !') -ceq '"abc$ !"') 'Quote spaces and shell metacharacters literally'
    Assert ((ConvertTo-WindowsQuotedArgument 'abc\') -ceq '"abc\\"') 'Escape trailing backslash'
    Assert ((ConvertTo-WindowsQuotedArgument 'ab"cd') -ceq '"ab\"cd"') 'Escape embedded quote'
    Assert ((ConvertTo-WindowsQuotedArgument 'ab\"cd') -ceq '"ab\\\"cd"') 'Escape backslash before quote'

    # Stub native telemetry without loading/calling kernel32 on the test host.
    Add-Type @'
namespace ManagedDellBios {
 public static class NativePower {
  public struct Status { public byte ACLineStatus, BatteryFlag, BatteryLifePercent; }
  public static byte AC = 1, Percent = 51;
  public static bool GetSystemPowerStatus(out Status status) {
   status = new Status { ACLineStatus = AC, BatteryFlag = 0, BatteryLifePercent = Percent };
   return true;
  }
 }
}
'@
    function Get-CimInstance { [pscustomobject]@{ EstimatedChargeRemaining = [ManagedDellBios.NativePower]::Percent } }
    $config.RequireBattery = $true
    Assert-Power $config
    Assert $true '51 percent on AC passes power gate'
    [ManagedDellBios.NativePower]::Percent = 50
    Assert-Throws { Assert-Power $config } 'Retry:*' 'Exactly 50 percent blocks launch'
    [ManagedDellBios.NativePower]::Percent = 51
    [ManagedDellBios.NativePower]::AC = 0
    Assert-Throws { Assert-Power $config } 'Retry:*' 'Unplugged AC blocks launch'
    [ManagedDellBios.NativePower]::AC = 255
    Assert-Throws { Assert-Power $config } 'Retry:*' 'Unknown AC blocks launch'

    [ManagedDellBios.NativePower]::AC = 1
    $config.MinimumBatteryRuntimeMinutes = 20
    Assert-Throws { Assert-Power $config } 'Retry: battery runtime estimate is unavailable*' 'Missing optional runtime telemetry fails safely'
    $script:runtimeMinutes=19
    function Get-CimInstance { [pscustomobject]@{EstimatedChargeRemaining=51; EstimatedRunTime=$script:runtimeMinutes} }
    Assert-Throws { Assert-Power $config } 'Retry: estimated battery runtime*' 'Insufficient estimated runtime blocks'
    $script:runtimeMinutes=20
    Assert-Power $config
    Assert $true 'Runtime equal to configured minimum passes'
    $script:runtimeMinutes=71582788
    Assert-Throws { Assert-Power $config } 'Retry: battery runtime estimate is unavailable*' 'Implausible runtime sentinel blocks'
    $script:runtimeMinutes=0
    Assert-Throws { Assert-Power $config } 'Retry: battery runtime estimate is unavailable*' 'Zero runtime is unknown'
    $config.MinimumBatteryRuntimeMinutes=0
    Assert-Power $config
    Assert $true 'Disabled optional estimate does not block otherwise safe power'
    $config.Remove('MinimumBatteryRuntimeMinutes')
    Assert-Config $config; Assert-Power $config
    Assert $true 'Existing configurations without new optional key remain supported'

    Write-Output "PASS: $count base safety assertions. WindowsRegistryIntegration=$WindowsRegistryIntegration"
} finally {
    $env:ProgramData = $oldProgramData
    $env:SystemRoot = $oldSystemRoot
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
