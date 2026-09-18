#requires -Version 5.1
# Reusable build engine. Dot-source, then call New-DeploymentPackage.
# Never executes the BIOS, imported template scripts, or a secret from a preset.
Set-StrictMode -Version 3
$script:BuilderSource = Split-Path $PSScriptRoot -Parent
. "$script:BuilderSource/Files/Common.ps1"
. "$script:BuilderSource/Files/Simple/State.ps1"
. "$script:BuilderSource/Files/Simple/Cache.ps1"
. "$script:BuilderSource/Files/UI/WindowChrome.ps1"
. "$PSScriptRoot/Application-Package.ps1"
. "$PSScriptRoot/Section-Editor.ps1"
. "$PSScriptRoot/Maintenance-Package.ps1"

function Get-BuilderFailureMessage([Management.Automation.ErrorRecord]$Record) {
    # EndInvoke can wrap a PSSecurityException. Never print script source or
    # invocation arguments: a build may have a credential in memory.
    $exception=$Record.Exception
    $authorizationFailure=$Record.CategoryInfo.Category -eq 'SecurityError'
    while ($null -ne $exception) {
        if ($exception -is [Management.Automation.PSSecurityException] -or $exception.Message -match 'AuthorizationManager check failed') { $authorizationFailure=$true }
        $exception=$exception.InnerException
    }
    if ($authorizationFailure) {
        return 'PowerShell blocked a builder script before it could run. A downloaded-file block, script signing/execution policy, or application control can cause this. Close the wizard, review Get-ExecutionPolicy -List in Windows PowerShell 5.1, and check whether the trusted repository scripts are marked as downloaded. See Builder/README.md: AuthorizationManager check failed. No BIOS executable was launched by this build. Do not change organization-enforced policy.'
    }
    return $Record.Exception.Message
}

function Stop-BuilderValidation([string]$Message) {
    # Only call with our own safe diagnostic text, never a caught exception or
    # data-file source. This allows useful errors without exposing secret lines.
    $exception=New-Object IO.InvalidDataException($Message)
    $exception.Data['BuilderSafeMessage']=$Message
    throw $exception
}
function New-PackageBuildSettings {
    @{
        PackageType='BIOS'; ApplicationName=''; ApplicationVersion=''
        ApplicationContext='System'; ApplicationDetectionScript=''
        UseEditor=$false; SectionTemplatePath=''
        MaintenancePayload=''; WindowsBuild=''; DriverModels=@()
        BiosPath=''; FrameworkZip=''; OutputRoot=''; ContentPrepTool=''
        Models=@(); TargetVersion=''; MinimumCurrentVersion='0.0.0'
        BiosPasswordRequired=$true; RequireBattery=$true
        MinimumBatteryPercent=51; MinimumBatteryRuntimeMinutes=0
        MinimumFreeSpaceGB=1; BitLockerRebootCount=1; EscrowDestination='EntraID'
        StagedDetectionHours=24; WindowHours=72; ReminderHours=4; PromptTimeoutMinutes=10
        AllowScheduleLater=$true; RestartCountdownMinutes=60; RestartReminderMinutes=15
        CompanyName='Your company'; AppTitle='Device care'
        Heading='A little maintenance. A stronger device.'
        Purpose='An approved BIOS update will improve the security and reliability of your Dell computer.'
        SupportText='Need help? Contact your IT service desk.'
        LogoPath=''; BannerPath=''; IconPath=''; AccentColor='#2457D6'; BackgroundColor='#F3F5FA'
        SurfaceColor='#FFFFFF'; TextColor='#14213D'; MutedColor='#475569'
        ReadyMessage='Your BIOS update is ready. A restart is required to finish installing it. Save your work, keep your computer plugged into power, and do not turn it off until the update has finished and Windows returns.'
        PackageReviewed=$false
    }
}
function Write-BuilderData([string]$Path, [System.Collections.IDictionary]$Data) {
    # Data-only PSD1: quoting is literal, including apostrophes, $, backticks and Unicode.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# MedelaBIOS-FileVersion: 4.0.0')
    $lines.Add('@{')
    foreach ($key in $Data.Keys) {
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'Invalid data field name.' }
        $value=$Data[$key]
        if ($value -is [bool]) { $literal=if ($value) { '$true' } else { '$false' } }
        elseif ($value -is [int]) { $literal=$value.ToString([Globalization.CultureInfo]::InvariantCulture) }
        elseif ($value -is [string]) { $literal="'" + $value.Replace("'", "''") + "'" }
        elseif ($value -is [array]) {
            $quoted=@(foreach ($entry in $value) {
                if ($entry -isnot [string]) { throw 'Only string lists are supported.' }
                "'" + $entry.Replace("'", "''") + "'"
            })
            $literal='@(' + ($quoted -join ', ') + ')'
        } else { throw 'Unsupported data value.' }
        $lines.Add(('    {0} = {1}' -f $key,$literal))
    }
    $lines.Add('}')
    [IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
}
function Export-PackagePreset([hashtable]$Settings, [string]$Path) {
    $safe=New-PackageBuildSettings
    foreach ($key in @($safe.Keys)) { if ($Settings.ContainsKey($key)) { $safe[$key]=$Settings[$key] } }
    # A previous review is not an approval for the next EXE or template.
    $safe.PackageReviewed=$false
    Write-BuilderData $Path $safe
}
function Import-PackagePreset([string]$Path) {
    $data=Import-PowerShellDataFile -LiteralPath $Path
    $settings=New-PackageBuildSettings
    foreach ($key in $data.Keys) {
        if ($key -in @('PreparationLeadMinutes','FinalWarningMinutes','SafetyRetryMinutes')) { continue }
        if (-not $settings.ContainsKey($key)) { throw 'Preset contains an unknown field. Passwords must never be stored in presets.' }
        if ($key -in @('AllowScheduleLater','BiosPasswordRequired','RequireBattery','PackageReviewed','UseEditor') -and $data[$key] -isnot [bool]) { throw 'Preset Boolean settings must use literal $true or $false.' }
        $settings[$key]=$data[$key]
    }
    $settings.PackageReviewed=$false
    return $settings
}
function Assert-BuilderHost {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') {
        throw 'Build on x64 Windows using 64-bit Windows PowerShell 5.1.'
    }
}
function Assert-BuilderPath([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build inputs and output folders must not use junctions or symbolic links.' }
        $item=if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Resolve-BuilderOutputRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Choose an Output folder on the Build tab before building.' }
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or
        ([IO.Path]::DirectorySeparatorChar -eq '\' -and $Path -notmatch '^[A-Za-z]:[\\/]')) {
        throw 'Choose a local absolute output folder on an ACL-capable disk.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'Create or select an existing output folder using Choose folder on the Build tab.' }
    Assert-BuilderPath $Path
    $full=[IO.Path]::GetFullPath($Path)
    # Keep a drive root such as D:\ absolute; trimming it to D: is drive-relative.
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) }
    $repo=[IO.Path]::GetFullPath((Split-Path $script:BuilderSource -Parent)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($full -eq $repo -or $full.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Choose an output folder outside this repository.' }
    return $full
}
function Protect-BuilderDirectory([string]$Path) {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($sid)
    foreach ($identity in @($sid.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($identity)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
function Assert-BuilderIcon([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -notin @('.png','.ico') -or (Get-Item -LiteralPath $Path).Length -gt 1MB) { throw 'Choose a PNG or ICO title-bar icon no larger than 1 MB.' }
    try { Add-Type -AssemblyName PresentationCore; $null=Read-BiosWindowIcon ([IO.Path]::GetFullPath($Path)) }
    catch { Stop-BuilderValidation 'The title-bar icon could not be decoded. Choose a valid local PNG/ICO up to 1024 by 1024 and 1 MB.' }
}
function Assert-BuilderSettings([hashtable]$Settings) {
    $defaults=New-PackageBuildSettings
    foreach ($key in $defaults.Keys) { if (-not $Settings.ContainsKey($key)) { throw "Missing setting: $key." } }
    foreach ($key in $Settings.Keys) { if (-not $defaults.ContainsKey($key)) { throw 'Unknown build setting. Supply the password separately as a SecureString.' } }
    if ($Settings.PackageType -notin @('BIOS','Application','WindowsUpdate','Driver')) { throw 'Choose BIOS update, Application, Windows Update or Dell Driver.' }
    if ($Settings.UseEditor -isnot [bool]) { throw 'UseEditor must be Boolean.' }
    if ($Settings.PackageType -eq 'BIOS' -and $Settings.UseEditor) { throw 'The managed BIOS workflow cannot be replaced by editor sections.' }
    if ($Settings.PackageType -ne 'BIOS') {
        Assert-ApplicationBuildSettings $Settings
        if ($Settings.PackageType -in @('WindowsUpdate','Driver')) { Assert-MaintenanceSettings $Settings }
        return
    }
    foreach ($key in @('BiosPasswordRequired','RequireBattery','PackageReviewed','AllowScheduleLater')) {
        if ($Settings[$key] -isnot [bool]) { throw "$key must be Boolean." }
    }
    foreach ($key in @('MinimumBatteryPercent','MinimumBatteryRuntimeMinutes','MinimumFreeSpaceGB','BitLockerRebootCount','StagedDetectionHours','WindowHours','ReminderHours','PromptTimeoutMinutes','RestartCountdownMinutes','RestartReminderMinutes')) {
        if ($Settings[$key] -isnot [int]) { throw "$key must be a whole number." }
    }
    if ($Settings.MinimumFreeSpaceGB -gt 1024) { throw 'Minimum free space must be 1-1024 GB.' }
    foreach ($key in @('BiosPath','FrameworkZip','OutputRoot')) {
        if ([string]::IsNullOrWhiteSpace($Settings[$key])) { throw "Choose $key." }
    }
    foreach ($key in @('BiosPath','FrameworkZip','ContentPrepTool','LogoPath','BannerPath','IconPath')) {
        if ($Settings[$key]) {
            if (-not (Test-Path -LiteralPath $Settings[$key] -PathType Leaf)) { throw "Selected $key file does not exist." }
            Assert-BuilderPath $Settings[$key]
        }
    }
    if ([IO.Path]::GetExtension($Settings.FrameworkZip) -ne '.zip') { throw 'Select a ZIP containing one prepared PSADT template.' }
    if ([IO.Path]::GetExtension($Settings.BiosPath) -ne '.exe') { throw 'Select a Dell BIOS EXE.' }
    if ($Settings.ContentPrepTool -and [IO.Path]::GetFileName($Settings.ContentPrepTool) -ine 'IntuneWinAppUtil.exe') { throw 'Select the official IntuneWinAppUtil.exe content prep tool.' }
    if ($Settings.Models -isnot [array] -or @($Settings.Models).Count -gt 50) { throw 'Supply 1-50 exact model names.' }
    foreach ($model in $Settings.Models) {
        if ($model -isnot [string] -or $model -ne $model.Trim() -or $model -match '[\x00-\x1f]' -or $model.Length -gt 150) { throw 'Model names must be plain text, without leading/trailing spaces.' }
    }
    foreach ($key in @('CompanyName','AppTitle','Heading','Purpose','SupportText','ReadyMessage')) {
        if ($Settings[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings[$key]) -or $Settings[$key].Length -gt 2000 -or $Settings[$key] -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { throw "Enter valid text for $key (1-2000 characters)." }
    }
    foreach ($key in @('AccentColor','BackgroundColor','SurfaceColor','TextColor','MutedColor')) {
        if ($Settings[$key] -notmatch '^#[0-9a-fA-F]{6}$') { throw "$key must use #RRGGBB." }
    }
    foreach ($key in @('LogoPath','BannerPath')) {
        if ($Settings[$key] -and ([IO.Path]::GetExtension($Settings[$key]) -notin @('.png','.jpg','.jpeg') -or (Get-Item -LiteralPath $Settings[$key]).Length -gt 10MB)) { throw 'Brand images must be PNG/JPG files no larger than 10 MB.' }
    }
    if ($Settings.IconPath) { Assert-BuilderIcon $Settings.IconPath }
    $config=Get-BuilderConfig $Settings ('A'*64)
    Assert-Config $config
    Assert-SimplePolicy (Get-BuilderPolicy $Settings)
}
function Get-BuilderConfig([hashtable]$Settings, [string]$Hash) {
    $config=@{FileName='ApprovedBIOS.exe'; SHA256=$Hash}
    foreach ($key in @('Models','TargetVersion','MinimumCurrentVersion','BiosPasswordRequired','RequireBattery','MinimumBatteryPercent','MinimumBatteryRuntimeMinutes','MinimumFreeSpaceGB','BitLockerRebootCount','EscrowDestination','StagedDetectionHours','PackageReviewed')) { $config[$key]=$Settings[$key] }
    return $config
}
function Get-BuilderPolicy([hashtable]$Settings) {
    $policy=@{Schema=3}
    foreach ($key in @('WindowHours','ReminderHours','PromptTimeoutMinutes','RestartCountdownMinutes','RestartReminderMinutes','AllowScheduleLater')) { $policy[$key]=$Settings[$key] }
    return $policy
}
function Expand-BuilderZip([string]$ZipPath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Stop-BuilderValidation 'ZIP destination must be new.' }
    $archive=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 20000) { Stop-BuilderValidation 'ZIP is empty or contains too many entries.' }
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total=0
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if ($name.StartsWith('/') -or $name -match '[\x00-\x1f:*?"<>|]' -or $name -match '//') { Stop-BuilderValidation 'Unsafe path in framework ZIP.' }
            $parts=$name.TrimEnd('/').Split('/')
            foreach ($part in $parts) {
                if ($part -in @('','.','..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { Stop-BuilderValidation 'Unsafe Windows filename in framework ZIP.' }
            }
            if (-not $seen.Add($name.TrimEnd('/'))) { Stop-BuilderValidation 'Duplicate/case-colliding path in framework ZIP.' }
            $unixType=($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -notin @(0,0x8000,0x4000) -or ($entry.ExternalAttributes -band 0x400)) { Stop-BuilderValidation 'Links and special files are not allowed in framework ZIPs.' }
            if ($entry.Length -gt 2GB -or $entry.Length -lt 0) { Stop-BuilderValidation 'A framework ZIP entry is too large.' }
            $total+=$entry.Length
            if ($total -gt 4GB) { Stop-BuilderValidation 'Framework ZIP exceeds the 4 GB extracted limit.' }
            if ($parts[-1] -ieq 'BIOS-Password.psd1') { Stop-BuilderValidation 'Remove BIOS-Password.psd1 from the input ZIP. Managed BIOS deployments accept the secret locally in BIOS mode.' }
        }
        $null=[IO.Directory]::CreateDirectory($Destination)
        $prefix=[IO.Path]::GetFullPath($Destination) + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/'); $target=[IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Stop-BuilderValidation 'ZIP path escaped destination.' }
            if ($name.EndsWith('/')) { $null=[IO.Directory]::CreateDirectory($target); continue }
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $zipStream=$entry.Open(); $output=$null
            try {
                $output=[IO.File]::Open($target,'CreateNew','Write','None')
                $buffer=New-Object byte[] 81920; [long]$written=0
                while (($read=$zipStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $written+=$read
                    if ($written -gt $entry.Length) { Stop-BuilderValidation 'ZIP entry exceeds its declared size.' }
                    $output.Write($buffer,0,$read)
                }
                if ($written -ne $entry.Length) { Stop-BuilderValidation 'Truncated framework ZIP entry.' }
            } finally { if ($null -ne $output) { $output.Dispose() }; $zipStream.Dispose() }
        }
    } finally { $archive.Dispose() }
}
function Get-BuilderFramework([string]$ExpandedRoot) {
    $candidates=@(Get-ChildItem -LiteralPath $ExpandedRoot -Filter 'Invoke-AppDeployToolkit.ps1' -File -Recurse | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'Invoke-AppDeployToolkit.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') -PathType Leaf)
    })
    if ($candidates.Count -ne 1) { Stop-BuilderValidation 'ZIP must contain exactly one prepared PSADT template with its launcher, script and PSAppDeployToolkit module. A source-code ZIP is not a deployment template.' }
    $root=$candidates[0].DirectoryName
    $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $root 'PSAppDeployToolkit/PSAppDeployToolkit.psd1')
    $version=[version]$manifest.ModuleVersion
    if ($version.Major -ne 4 -or $version.Minor -ne 1) { Stop-BuilderValidation 'This builder supports PSADT 4.1.x templates only.' }
    if (-not $manifest.RootModule -or $manifest.RootModule -notmatch '^[a-zA-Z0-9_.-]+\.psm1$' -or -not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'PSAppDeployToolkit') $manifest.RootModule) -PathType Leaf)) { Stop-BuilderValidation 'PSADT root module is missing or unsupported.' }
    return @{Root=$root; Version=$version.ToString()}
}
function Set-BuilderTemplate([string]$ScriptPath, [string]$TargetVersion) {
    $text=[IO.File]::ReadAllText($ScriptPath)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { Stop-BuilderValidation 'The custom deployment script has syntax errors.' }
    $edits=New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @('Install-ADTDeployment','Uninstall-ADTDeployment','Repair-ADTDeployment')) {
        $matches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        if ($matches.Count -ne 1 -or $matches[0].Parent -isnot [Management.Automation.Language.NamedBlockAst] -or $matches[0].Parent.Parent -ne $ast) { Stop-BuilderValidation "Template must contain one top-level $name function." }
        $replacement=if ($name -eq 'Install-ADTDeployment') { [IO.File]::ReadAllText((Join-Path $script:BuilderSource 'PSADT-Install-Function.ps1')) } else { "function $name {`r`n    Write-ADTLogEntry -Message 'Firmware uninstall/repair is unsupported. Use the documented recovery procedure.' -Severity 3`r`n    Close-ADTSession -ExitCode 60001`r`n}" }
        $edits.Add(@{Start=$matches[0].Extent.StartOffset; End=$matches[0].Extent.EndOffset; Text=$replacement})
    }
    # The stock bootstrap assigns adtSession again from Open-ADTSession. Select
    # only its one top-level literal metadata table; preserve later assignments.
    $sessions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'adtSession'},$true))
    $tables=@(foreach ($assignment in $sessions) {
        if ($assignment.Parent -isnot [Management.Automation.Language.NamedBlockAst] -or $assignment.Parent.Parent -ne $ast) { continue }
        $table=$assignment.Right.Find({param($node) $node -is [Management.Automation.Language.HashtableAst]},$false)
        if ($null -ne $table -and $table.Extent.StartOffset -eq $assignment.Right.Extent.StartOffset -and $table.Extent.EndOffset -eq $assignment.Right.Extent.EndOffset) { $table }
    })
    if ($tables.Count -ne 1) { Stop-BuilderValidation 'Template must have one top-level literal adtSession metadata table.' }
    $values=@{
        AppVendor="'Dell'"; AppName="'Managed Dell BIOS'"; AppVersion=("'"+$TargetVersion+"'")
        AppArch="'x64'"; AppSuccessExitCodes='@(0)'; AppRebootExitCodes='@()'
        AppProcessesToClose='@()'; RequireAdmin='$true'; InstallName="''"; InstallTitle="'Dell BIOS update'"
    }
    foreach ($key in $values.Keys) {
        $pairs=@($tables[0].KeyValuePairs | Where-Object { $_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Item1.Value -eq $key })
        if ($pairs.Count -ne 1) { Stop-BuilderValidation "Template adtSession is missing or duplicates $key." }
        $extent=$pairs[0].Item2.Extent
        $edits.Add(@{Start=$extent.StartOffset; End=$extent.EndOffset; Text=$values[$key]})
    }
    # Windows PowerShell 5.1 cannot sort hashtables by a key passed as a string
    # property name. Explicitly read the numeric key with a calculated property.
    # Descending offsets are mandatory: earlier edits must not move later ones.
    $previousStart=$text.Length
    foreach ($edit in $edits | Sort-Object -Property { [int]$_['Start'] } -Descending) {
        if ($edit.Start -lt 0 -or $edit.End -lt $edit.Start -or $edit.End -gt $previousStart) {
            Stop-BuilderValidation 'Deployment script edits overlap or are out of order. The source script was not changed.'
        }
        $text=$text.Substring(0,$edit.Start)+$edit.Text+$text.Substring($edit.End)
        $previousStart=$edit.Start
    }
    $null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {
        # Error IDs and positions are useful without exposing custom script text.
        $locations=@($errors | Select-Object -First 3 | ForEach-Object { 'line {0}, column {1}: {2}' -f $_.Extent.StartLineNumber,$_.Extent.StartColumnNumber,$_.ErrorId })
        Stop-BuilderValidation ('Generated deployment script did not pass syntax validation (' + ($locations -join '; ') + '). The source script was not changed.')
    }
    [IO.File]::WriteAllText($ScriptPath,$text,(New-Object Text.UTF8Encoding($true)))
}
function Invoke-BuilderContentPrep([string]$Tool, [string]$Source, [string]$Output, [string]$SetupFile='Invoke-AppDeployToolkit.exe') {
    if ($SetupFile -notin @('Invoke-AppDeployToolkit.exe','Deploy-Application.exe','Deploy-Application.ps1') -or -not (Test-Path -LiteralPath (Join-Path $Source $SetupFile) -PathType Leaf)) { Stop-BuilderValidation 'The selected PSADT setup entry point is missing or unsupported.' }
    $sig=Get-AuthenticodeSignature -LiteralPath $Tool
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?Microsoft Corporation"?(?:,|$)') { Stop-BuilderValidation 'The content prep tool must have a valid Microsoft signature.' }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Tool
    $info.Arguments='-c {0} -s {1} -o {2} -q' -f (ConvertTo-WindowsQuotedArgument $Source),(ConvertTo-WindowsQuotedArgument $SetupFile),(ConvertTo-WindowsQuotedArgument $Output)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); if ($process.ExitCode -ne 0) { Stop-BuilderValidation 'Microsoft content preparation failed. Inspect the local tool output.' } }
    finally { $process.Dispose() }
    $packages=@(Get-ChildItem -LiteralPath $Output -Filter '*.intunewin' -File)
    if ($packages.Count -ne 1 -or $packages[0].Length -eq 0) { Stop-BuilderValidation 'The content prep tool did not create one nonempty .intunewin.' }
    return $packages[0].FullName
}
function New-DellBiosPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings, [Security.SecureString]$BiosPassword, [scriptblock]$Progress = {})
    Assert-BuilderHost
    if ($Settings.PackageType -ne 'BIOS') { throw 'Use New-DeploymentPackage for Application mode; BIOS integration is not allowed.' }
    Assert-BuilderSettings $Settings
    if ($Settings.BiosPasswordRequired -and ($null -eq $BiosPassword -or $BiosPassword.Length -eq 0)) { throw 'Enter the shared BIOS administrator password.' }
    # Validate again in the worker; UI validation is not an authorization boundary.
    $outputParent=Resolve-BuilderOutputRoot $Settings.OutputRoot
    $build=Join-Path $outputParent ('DellBIOS-'+$Settings.TargetVersion+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=[IO.Directory]::CreateDirectory($build)
    $success=$false; $phase='securing the output directory'
    try {
        Protect-BuilderDirectory $build
        & $Progress ('Creating package in: '+$build)
        $work=Join-Path $build '.buildwork'; $null=[IO.Directory]::CreateDirectory($work)
        $phase='validating and extracting the framework'; & $Progress 'Checking the PSADT ZIP and preparing your custom framework...'
        $snapshot=Join-Path $work 'framework.zip'
        Copy-Item -LiteralPath $Settings.FrameworkZip -Destination $snapshot
        $frameworkHash=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
        $expanded=Join-Path $work 'Expanded'
        Expand-BuilderZip $snapshot $expanded
        $framework=Get-BuilderFramework $expanded
        $source=Join-Path $build 'Source'; $null=[IO.Directory]::CreateDirectory($source)
        Get-ChildItem -LiteralPath $framework.Root -Force | Copy-Item -Destination $source -Recurse -Force
        $original=Join-Path $build 'OriginalTemplate'; $null=[IO.Directory]::CreateDirectory($original)
        Copy-Item -LiteralPath (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Destination $original
        $phase='integrating the deployment functions'; & $Progress 'Inserting BIOS deployment functions and app metadata...'
        Set-BuilderTemplate (Join-Path $source 'Invoke-AppDeployToolkit.ps1') $Settings.TargetVersion
        $files=Join-Path $source 'Files'; $null=[IO.Directory]::CreateDirectory($files)
        # Copy a fixed runtime allowlist. Never copy local passwords, BIOS binaries,
        # generated packages or unrelated files from the builder checkout.
        foreach ($name in @('Common.ps1','Install-DellBIOS.ps1','Verify-AfterReboot.ps1')) {
            Copy-Item -LiteralPath (Join-Path "$script:BuilderSource/Files" $name) -Destination $files -Force
        }
        foreach ($relative in @('Simple/Cache.ps1','Simple/State.ps1','Simple/Safety.ps1','Simple/Scheduling.ps1','Simple/Live.ps1','Simple/Deployment.ps1','UI/Window.xaml','UI/WindowChrome.ps1','UI/Theme.xaml','UI/Show-BiosUI.ps1','UI/Assets/README.md')) {
            $dest=Join-Path $files $relative
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            Copy-Item -LiteralPath (Join-Path "$script:BuilderSource/Files" $relative) -Destination $dest -Force
        }
        $phase='validating the Dell executable'; & $Progress 'Calculating SHA256 and checking the copied BIOS Dell signature...'
        $payload=Join-Path $files 'ApprovedBIOS.exe'
        Copy-Item -LiteralPath $Settings.BiosPath -Destination $payload -Force
        $config=Get-BuilderConfig $Settings (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
        Assert-Config $config
        try { Assert-Payload $payload $config }
        catch { Stop-BuilderValidation 'The copied BIOS did not pass the SHA256 and Dell Authenticode checks. Verify the approved EXE and its certificate chain on this computer.' }
        Write-BuilderData (Join-Path $files 'BIOS-Config.psd1') $config
        $policy=Get-BuilderPolicy $Settings
        Write-BuilderData (Join-Path $files 'Simple/Policy.psd1') $policy
        $phase='writing local credentials'; & $Progress 'Writing protected package settings (credentials are excluded from build notes and presets)...'
        if ($Settings.BiosPasswordRequired) {
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($BiosPassword)
            try {
                $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                if ([string]::IsNullOrWhiteSpace($plain) -or $plain -match '[\x00-\x1f]' -or $plain -eq 'REPLACE_LOCALLY') { throw 'The BIOS password is empty, a placeholder or contains unsupported control characters.' }
                Write-BuilderData (Join-Path $files 'BIOS-Password.psd1') @{Password=$plain}
            } finally { $plain=$null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        }
        $phase='applying branding'
        $brand=Import-PowerShellDataFile -LiteralPath "$script:BuilderSource/Files/UI/Branding.psd1"
        foreach ($key in @('CompanyName','AppTitle','Heading','Purpose','SupportText','AccentColor','BackgroundColor','SurfaceColor','TextColor','MutedColor','ReadyMessage')) { $brand[$key]=$Settings[$key] }
        $brand.PowerMessage=if ($Settings.RequireBattery) { 'Connect AC power and charge the battery to at least {0}%. Keep the computer plugged in throughout the update.' -f $Settings.MinimumBatteryPercent } else { 'Keep the computer connected to AC power throughout the update.' }
        if ($Settings.MinimumBatteryRuntimeMinutes -gt 0) { $brand.PowerMessage+=' At least {0} minutes of estimated battery runtime is also required.' -f $Settings.MinimumBatteryRuntimeMinutes }
        foreach ($pair in @(@('LogoPath','LogoFile','company-logo'),@('BannerPath','BannerFile','company-banner'),@('IconPath','IconFile','app-icon'))) {
            if ($Settings[$pair[0]]) {
                $name=$pair[2]+[IO.Path]::GetExtension($Settings[$pair[0]]).ToLowerInvariant()
                Copy-Item -LiteralPath $Settings[$pair[0]] -Destination (Join-Path "$files/UI/Assets" $name) -Force
                $brand[$pair[1]]='Assets/'+$name
            } else { $brand[$pair[1]]='' }
        }
        Write-BuilderData (Join-Path $files 'UI/Branding.psd1') $brand
        Write-RuntimeManifest $files
        $phase='generating Intune scripts'; & $Progress 'Generating model requirements, actual BIOS detection and firmware audit scripts...'
        $null=& "$script:BuilderSource/Build-IntuneScripts.ps1" -PackageRoot $source -OutputDirectory (Join-Path $build 'Intune')
        $phase='checking generated scripts'
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object Extension -in @('.ps1','.psd1')) {
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw 'A generated or custom PowerShell file has syntax errors. Review your template.' }
        }
        $intuneWin=''
        if ($Settings.ContentPrepTool) {
            $phase='running Microsoft content preparation'; & $Progress 'Creating the .intunewin with your Microsoft content prep tool...'
            $output=Join-Path $build 'Package'; $null=[IO.Directory]::CreateDirectory($output)
            $intuneWin=Invoke-BuilderContentPrep $Settings.ContentPrepTool $source $output
        }
        $phase='writing build notes'
        $manifest=[ordered]@{
            BuilderVersion='4.3.0'; PackageType='BIOS'; BuiltUtc=[datetimeoffset]::UtcNow.ToString('o')
            FrameworkVersion=$framework.Version; FrameworkSHA256=$frameworkHash
            BIOS=$config; DeploymentPolicy=$policy; HasPassword=$Settings.BiosPasswordRequired
            OutputMode=$(if ($intuneWin) { 'IntuneWin' } else { 'SourceOnly' })
            OutputRoot=$outputParent; OutputDirectory=$build
            IntuneWinSHA256=$(if ($intuneWin) { (Get-FileHash -LiteralPath $intuneWin -Algorithm SHA256).Hash } else { '' })
            RuntimeFiles=@(Get-ChildItem -LiteralPath $files -File -Recurse | Where-Object { $_.Name -ne 'BIOS-Password.psd1' } | ForEach-Object {
                @{Path=$_.FullName.Substring($source.Length+1); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
            })
        }
        [IO.File]::WriteAllText((Join-Path $build 'BuildManifest.json'),($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllLines((Join-Path $build 'Build.log'),@(
            'Build completed at ' + $manifest.BuiltUtc
            'Builder version: ' + $manifest.BuilderVersion
            'Package type: BIOS'
            'PSADT module version: ' + $framework.Version
            'Framework ZIP SHA256: ' + $frameworkHash
            'Approved BIOS SHA256: ' + $config.SHA256
            'Output mode: ' + $manifest.OutputMode
            'Output folder: ' + $outputParent
            'Build directory: ' + $build
            'Allow schedule later: ' + $policy.AllowScheduleLater
            'Original deployment script archived. Three deployment functions and BIOS metadata replaced.'
            'Configuration, branding, deferral policy and Intune scripts generated.'
            'Local shared password included: ' + $Settings.BiosPasswordRequired
            'Password content and password-file hashes are deliberately excluded from these records.'
        ),(New-Object Text.UTF8Encoding($true)))
        Export-PackagePreset $Settings (Join-Path $build 'Settings.psd1')
        Copy-Item -LiteralPath "$PSScriptRoot/Package-Readme.txt" -Destination (Join-Path $build 'READ-ME-FIRST.txt')
        Remove-Item -LiteralPath $work -Recurse -Force
        $success=$true
        & $Progress 'Build complete. Use READ-ME-FIRST.txt for Intune settings and pilot checks.'
        return [pscustomobject]@{PackageType='BIOS';OutputDirectory=$build; SourcePath=$source; IntuneWinFile=$intuneWin; SHA256=$config.SHA256; FrameworkVersion=$framework.Version}
    } catch {
        # Never forward a parser error or native tool output that could contain a
        # line from the local password file. Keep diagnostics phase-specific.
        $detail='See the builder guide for this phase.'
        if ($_.Exception.Data.Contains('BuilderSafeMessage')) { $detail=[string]$_.Exception.Data['BuilderSafeMessage'] }
        throw "Build failed while $phase. $detail No package is ready; partial output will be removed."
    } finally {
        if (-not $success -and (Test-Path -LiteralPath $build)) { Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction Stop }
    }
}
