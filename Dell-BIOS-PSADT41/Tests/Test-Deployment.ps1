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

    # Use real wrapper and Common code with mocked registry/CIM/PSADT boundaries.
    Copy-Item "$root/Files/Common.ps1" "$fixture/Common.ps1"
    $data = (Get-Content "$root/Files/BIOS-Config.psd1" -Raw).Replace('PackageReviewed = $false','PackageReviewed = $true').Replace($originalHash, $config.SHA256)
    [IO.File]::WriteAllText("$fixture/BIOS-Config.psd1", $data)
    $script:model = $config.Models[0]
    $script:target = $config.TargetVersion
    $script:hash = $config.SHA256
    $script:bootDate = [datetime]::UtcNow.AddDays(-1)
    $script:current = '0.0.0'
    $script:active = $true; $script:silent = $false
    $script:history = $null; $script:welcome = $null; $script:restart = $null
    $script:launches = 0; $script:failPrompt = $false
    $script:stageAge = 0; $script:childCode = 3010
    $script:strings = @{ CloseAppsPrompt = @{ CustomMessage = 'original' } }
    $adtSession = [pscustomobject]@{ DirFiles = $fixture; InstallPhase = '' }
    $adtSession | Add-Member ScriptMethod IsSilent { return $script:silent }
    $adtSession | Add-Member ScriptMethod IsNonInteractive { return $false }
    function Get-CimInstance {
        param($ClassName)
        switch ($ClassName) {
            Win32_ComputerSystem { [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = $script:model } }
            Win32_BIOS { [pscustomobject]@{ SMBIOSBIOSVersion = $script:current } }
            Win32_OperatingSystem { [pscustomobject]@{ LastBootUpTime = $script:bootDate } }
        }
    }
    function Get-ADTLoggedOnUser { if ($script:active) { [pscustomobject]@{ IsActiveUserSession = $true } } }
    function Get-ADTDeferHistory { return $script:history }
    function Get-ADTStringTable { return $script:strings }
    function Write-ADTLogEntry { param($Message,$Severity) }
    function Close-ADTSession { param($ExitCode) throw "ADT_EXIT_$ExitCode" }
    function Show-ADTInstallationWelcome { $script:welcome = $args }
    function Start-ADTProcess {
        $script:launches++
        if ($script:childCode -eq 3010) {
            $script:record = [pscustomobject]@{
                Status = 'Staged'; TargetVersion = $script:target; PayloadHash = $script:hash
                BootId = $script:bootDate.ToUniversalTime().Ticks.ToString(); SuspendedByUs = '1'
                StagedUtc = [datetimeoffset]::UtcNow.AddHours(-$script:stageAge).ToString('o')
            }
        }
        return [pscustomobject]@{ ExitCode = $script:childCode }
    }
    function Show-ADTInstallationRestartPrompt {
        [CmdletBinding(DefaultParameterSetName = 'Countdown')]
        param($Title,$Subtitle,
            [Parameter(ParameterSetName = 'Countdown')]$CountdownSeconds,
            [Parameter(ParameterSetName = 'Countdown')]$CountdownNoHideSeconds,
            [Parameter(ParameterSetName = 'SilentRestart')]$SilentCountdownSeconds)
        if ($script:failPrompt) { throw 'Simulated UI failure' }
        $script:restart = @($CountdownSeconds,$CountdownNoHideSeconds)
    }
    . "$root/PSADT-Install-Function.ps1"
    $env:SystemRoot = $fixture
    $script:active = $false
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_1618' 'No active user retries'
    Assert ($script:launches -eq 0) 'No-user case never launches'
    $script:active = $true; $script:silent = $true
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_1618' 'Silent mode cannot bypass notice'
    $script:silent = $false
    $script:history = [pscustomobject]@{ DeferRunIntervalLastTime = [datetime]::Now.AddHours(-1); DeferTimesRemaining = 0 }
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_1618' 'Cooldown enforced after third deferral'
    Assert ($null -eq $script:welcome -and $script:launches -eq 0) 'Cooldown neither prompts nor launches'
    $script:history.DeferRunIntervalLastTime = [datetime]::Now.AddHours(-13)
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_3010' 'Expired cooldown permits staging'
    Assert ($script:welcome -contains '-ForceCountdown:' -or $script:welcome -contains '-ForceCountdown') 'Final notice has countdown'
    Assert ($script:restart[0] -gt 43190 -and $script:restart[0] -le 43200) 'New staging gets 12 hours'
    Assert ($script:restart[1] -eq 900) 'Final 15 minutes cannot be hidden'
    Assert ($script:strings.CloseAppsPrompt.CustomMessage -eq 'original') 'Restore PSADT shared message'
    $script:stageAge = 8; $script:welcome = $null
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_3010' 'Already staged retains restart result'
    Assert ($script:restart[0] -gt 14390 -and $script:restart[0] -le 14400) 'Repeat uses four remaining hours'
    Assert ($null -eq $script:welcome) 'Existing transaction skips deferrals'
    $script:failPrompt = $true
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_3010' 'UI failure preserves Intune reboot code'
    $script:failPrompt = $false; $script:active = $false; $script:restart = $null
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_3010' 'No-user staged transaction passes reboot code'
    Assert ($null -eq $script:restart) 'No-user case skips restart prompt'
    $script:record = $null; $script:current = $script:target
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_0' 'Compliant BIOS succeeds without user'
    $script:active = $true; $script:current = '0.0.0'; $script:history = $null; $script:childCode = 1618
    Assert-Throws { Install-ADTDeployment } 'ADT_EXIT_1618' 'Child power/prerequisite retry passes through'
    Assert ($null -eq $script:restart) 'Failed prerequisites never request restart'
    Write-Output "PASS: $count regression assertions. WindowsRegistryIntegration=$WindowsRegistryIntegration"
} finally {
    $env:ProgramData = $oldProgramData
    $env:SystemRoot = $oldSystemRoot
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
