# Cross-platform, inert packaging regression tests. No executable is ever run.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('DellBuilderTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($fixture)
$oldProgramData=$env:ProgramData
if (-not $env:ProgramData) { $env:ProgramData=$fixture }
$count=0
function Assert($Condition,[string]$Name) { $script:count++; if (-not $Condition) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Action,[string]$Name) { $rejected=$false; try { $null=& $Action } catch { $rejected=$true }; Assert $rejected $Name }
try {
    . "$root/Builder/Build-Package.ps1"
    # Exercise the actual GUI worker scriptblock without loading WPF. A denied
    # engine import must terminate the worker, preserve an actionable diagnosis,
    # and never attempt the build function or echo exception source/arguments.
    $tokens=$null; $errors=$null
    $guiAst=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$tokens,[ref]$errors)
    $workerCall=$guiAst.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'AddScript'},$true)
    $workerCode=$workerCall.Arguments[0].ScriptBlock.GetScriptBlock()
    $denied=Join-Path $fixture 'denied-engine.ps1'
    [IO.File]::WriteAllText($denied,"throw [System.Management.Automation.PSSecurityException]::new('inert-private-error-detail')")
    $background=[PowerShell]::Create()
    $events=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    try {
        $null=$background.AddScript($workerCode).AddArgument($denied).AddArgument(@{}).AddArgument($null).AddArgument($events)
        $handle=$background.BeginInvoke(); $record=$null
        try { $null=$background.EndInvoke($handle) } catch { $record=$_ }
        Assert ($null -ne $record) 'Worker stops immediately when loading its engine is denied'
        $diagnosis=Get-BuilderFailureMessage $record
        Assert ($diagnosis -match 'Get-ExecutionPolicy -List' -and $diagnosis -match 'downloaded') 'Wrapped authorization error has actionable guidance'
        Assert (-not $diagnosis.Contains('inert-private-error-detail')) 'Authorization diagnostics exclude private exception contents'
        Assert (-not (@($background.Streams.Error | Where-Object FullyQualifiedErrorId -match 'CommandNotFound').Count)) 'Denied import does not continue into missing build command'
    } finally { $background.Dispose() }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [xml]$ui=Get-Content -LiteralPath "$root/Builder/Window.xaml" -Raw
    Assert ($ui.DocumentElement.LocalName -eq 'Window') 'Builder XAML is well formed'
    # An intentionally inert template with custom module/config/extension files.
    $template=Join-Path $fixture 'Template'; $null=[IO.Directory]::CreateDirectory($template)
    $module=Join-Path $template 'PSAppDeployToolkit'; $null=[IO.Directory]::CreateDirectory($module)
    Write-BuilderData (Join-Path $module 'PSAppDeployToolkit.psd1') @{ModuleVersion='4.1.0';RootModule='PSAppDeployToolkit.psm1'}
    [IO.File]::WriteAllText((Join-Path $module 'PSAppDeployToolkit.psm1'),"throw 'The build must NEVER import this module'")
    [IO.File]::WriteAllText((Join-Path $template 'Invoke-AppDeployToolkit.exe'),'Inert launcher, not executable')
    $bootstrap=@'
# Preserve my framework customization.
param([string]$DeploymentType, [string]$DeployMode)
$adtSession = @{
    AppVendor='Custom'; AppName='Custom App'; AppVersion='1.0'; AppArch='x86'
    AppSuccessExitCodes=@(0); AppRebootExitCodes=@(3010,1641)
    AppProcessesToClose=@('outlook'); RequireAdmin=$false
    InstallName='Old'; InstallTitle='Old title'; CustomField='preserve $ and { braces }'
    CustomNested=@{Value='preserve nested data'}
}
function Install-ADTDeployment { Write-Output 'old install' }
function Uninstall-ADTDeployment { Write-Output 'old uninstall' }
function Repair-ADTDeployment { Write-Output 'old repair' }
# Custom bootstrap after functions remains intact.
$adtSession = Open-ADTSession @adtSession
throw 'The build must NEVER execute the template'
'@
    [IO.File]::WriteAllText((Join-Path $template 'Invoke-AppDeployToolkit.ps1'),$bootstrap)
    # Windows PowerShell 5.1 does not resolve dictionary keys when Sort-Object
    # receives a string property name (support was added in PowerShell 6).
    # Emulate that boundary so Linux/PS7 cannot conceal corrupt edit ordering.
    function Sort-Object {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)]$InputObject,
              [Parameter(Position=0)][object[]]$Property, [switch]$Descending)
        begin { $items=New-Object 'System.Collections.Generic.List[object]' }
        process { $items.Add($InputObject) }
        end {
            if ($Property.Count -eq 1 -and $Property[0] -is [string] -and $items.Count -gt 0 -and $items[0] -is [hashtable]) {
                # All requested property values are absent on the Hashtable
                # object itself; do not sort by its keys as PowerShell 7 would.
                $items.ToArray()
            } else {
                $items.ToArray() | Microsoft.PowerShell.Utility\Sort-Object -Property $Property -Descending:$Descending
            }
        }
    }
    try {
        $legacyTemplate=Join-Path $fixture 'ps51-template.ps1'
        [IO.File]::WriteAllText($legacyTemplate,$bootstrap)
        Set-BuilderTemplate $legacyTemplate '2.7.3'
        $rewritten=[IO.File]::ReadAllText($legacyTemplate)
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseInput($rewritten,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0 -and $rewritten.Contains("AppVersion='2.7.3'")) 'Template parses with Windows PowerShell 5.1 dictionary sorting semantics'
        Assert ($rewritten.Contains('Invoke-MedelaDeployment') -and $rewritten.Contains('preserve nested data') -and $rewritten.Contains('NEVER execute the template')) 'PS5-compatible edits retain BIOS function and custom bootstrap'
    } finally { Remove-Item Function:Sort-Object }
    [IO.File]::WriteAllText((Join-Path $template 'custom-config.txt'),'preserve my branding')
    $null=[IO.Directory]::CreateDirectory((Join-Path $template 'PSAppDeployToolkit.Extensions'))
    [IO.File]::WriteAllText((Join-Path $template 'PSAppDeployToolkit.Extensions/custom.ps1'),"throw 'do not run extensions during build'")
    $zip=Join-Path $fixture 'Custom Framework.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($template,$zip)
    $settings=New-PackageBuildSettings
    Assert ($settings.AllowScheduleLater -is [bool] -and $settings.AllowScheduleLater -and $settings.IconPath -eq '') 'New packages default to enabled scheduling and built-in icon'
    Assert ($settings.OutputRoot -eq '') 'Output destination requires a choice instead of silently selecting Documents'
    $legacyPreset=Join-Path $fixture 'v3-preset.psd1'
    Write-BuilderData $legacyPreset @{WindowHours=48;CompanyName='Legacy company'}
    $legacySettings=Import-PackagePreset $legacyPreset
    Assert ($legacySettings.AllowScheduleLater -and $legacySettings.IconPath -eq '' -and $legacySettings.WindowHours -eq 48) 'Old preset gains scheduling/icon defaults without changing its window'
    Write-BuilderData $legacyPreset @{AllowScheduleLater=$false}
    Assert (-not (Import-PackagePreset $legacyPreset).AllowScheduleLater) 'Explicit false survives preset loading'
    Write-BuilderData $legacyPreset @{AllowScheduleLater='false'}
    Reject {Import-PackagePreset $legacyPreset} 'String false cannot silently enable scheduling in the checkbox'
    $settings.FrameworkZip=$zip; $settings.BiosPath=Join-Path $fixture 'Approved Dell.exe'
    [IO.File]::WriteAllText($settings.BiosPath,'Inert BIOS fixture, NEVER execute')
    $settings.OutputRoot=$fixture; $settings.Models=@("Dell Pro Max 16 MC16250", "Dell O'Brien `$model")
    $settings.TargetVersion='2.7.3'; $settings.PackageReviewed=$true
    $settings.CompanyName="O'Brien & Co. `$literal"; $settings.WindowHours=48
    Assert-BuilderSettings $settings
    # Mock only Windows trust/ACL boundaries, never extraction, AST rewrite or serialization.
    function Assert-BuilderHost { }
    $script:protected=0
    $script:protectedPaths=New-Object 'Collections.Generic.List[string]'
    function Protect-BuilderDirectory { param($Path) $script:protected++; $script:protectedPaths.Add($Path) }
    $global:DellBuilderTestSignatureValid=$true
    function Get-AuthenticodeSignature {
        param($LiteralPath)
        [pscustomobject]@{Status=$(if ($global:DellBuilderTestSignatureValid) {'Valid'} else {'HashMismatch'}); SignerCertificate=[pscustomobject]@{Subject='CN=Dell Inc., O=Dell Inc., C=US'}}
    }
    $passwordText="test-only P'a`$s`"s\word"
    $secret=ConvertTo-SecureString $passwordText -AsPlainText -Force
    $script:progress=New-Object 'System.Collections.Generic.List[string]'
    $result=New-DellBiosPackage $settings $secret -Progress {param($text) $script:progress.Add($text)}
    Assert ($script:protected -eq 1) 'Output protected before files copied'
    Assert (-not $result.IntuneWinFile) 'Source-only build never claims intunewin'
    Assert ($result.SHA256 -eq (Get-FileHash -LiteralPath $settings.BiosPath).Hash) 'BIOS hash calculated from actual copied bytes'
    $source=$result.SourcePath
    $config=Import-PowerShellDataFile (Join-Path $source 'Files/BIOS-Config.psd1')
    Assert ($config.TargetVersion -eq '2.7.3' -and $config.Models[1] -eq $settings.Models[1]) 'Exact version and metacharacter models survive serialization'
    $password=Import-PowerShellDataFile (Join-Path $source 'Files/BIOS-Password.psd1')
    Assert ($password.Password -ceq $passwordText) 'Password metacharacters round trip literally'
    $brand=Import-PowerShellDataFile (Join-Path $source 'Files/UI/Branding.psd1')
    Assert ($brand.CompanyName -ceq $settings.CompanyName -and $brand.PowerMessage -match '51%') 'Branding is data and power text follows actual threshold'
    $policy=Import-PowerShellDataFile (Join-Path $source 'Files/Simple/Policy.psd1')
    Assert ($policy.AllowScheduleLater -eq $true -and (Get-Content (Join-Path $result.OutputDirectory 'Build.log') -Raw).Contains('Allow schedule later: True')) 'Enabled scheduling reaches policy and build notes'
    Assert ($policy.WindowHours -eq 48 -and $policy.Schema -eq 3 -and $policy.RestartCountdownMinutes -eq 60 -and $policy.RestartReminderMinutes -eq 15) 'Configured deferral and restart deadlines are packaged'
    $cachePlan=Get-CacheUpdatePlan (Join-Path $source 'Files') (Join-Path $fixture 'EmptyCache')
    Assert ($cachePlan.Count -eq 15 -and @($cachePlan | Where-Object Reason -ne 'Missing').Count -eq 0) 'Runtime manifest validates the complete simple payload'
    Assert (-not (Test-Path (Join-Path $source 'Files/Scheduler')) -and -not (Test-Path (Join-Path $source 'Files/Install-Scheduler.ps1'))) 'Builder does not package the retired daemon'
    $generated=Get-Content -LiteralPath (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Raw
    Assert ($generated.Contains("CustomField='preserve `$ and { braces }'") -and $generated.Contains('NEVER execute the template')) 'Custom metadata and bootstrap retained'
    Assert ($generated.Contains('Invoke-MedelaDeployment') -and -not $generated.Contains("'old install'")) 'BIOS Install function replaces the old function'
    Assert ($generated.Contains('Close-ADTSession -ExitCode 60001') -and -not $generated.Contains("'old uninstall'")) 'Firmware uninstall and repair explicitly fail'
    Assert ($generated.Contains("AppVersion='2.7.3'") -and $generated.Contains('AppRebootExitCodes=@()') -and $generated.Contains('AppProcessesToClose=@()')) 'App metadata prevents inherited close-app and restart codes'
    Assert ((Get-Content -LiteralPath (Join-Path $source 'custom-config.txt') -Raw) -eq 'preserve my branding') 'Custom framework file preserved'
    Assert ((Get-FileHash -LiteralPath (Join-Path $source 'PSAppDeployToolkit/PSAppDeployToolkit.psm1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $module 'PSAppDeployToolkit.psm1')).Hash) 'PSADT module preserved byte for byte'
    Assert ((Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'OriginalTemplate/Invoke-AppDeployToolkit.ps1') -Raw) -eq $bootstrap) 'Original bootstrap archived outside source'
    Assert (-not (Test-Path -LiteralPath (Join-Path $result.OutputDirectory '.buildwork'))) 'Temporary framework snapshot removed on success'
    $manifest=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'BuildManifest.json') -Raw
    $preset=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'Settings.psd1') -Raw
    $buildLog=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'Build.log') -Raw
    Assert (-not $manifest.Contains($passwordText) -and -not $preset.Contains($passwordText) -and -not $buildLog.Contains($passwordText) -and -not ($script:progress -join '').Contains($passwordText)) 'Password absent from manifest, preset, build log and progress'
    Assert (-not $manifest.Contains('BIOS-Password.psd1')) 'No secret file path or password hash in manifest'
    $loaded=Import-PackagePreset (Join-Path $result.OutputDirectory 'Settings.psd1')
    Assert (-not $loaded.PackageReviewed -and $loaded.Models[0] -eq $settings.Models[0]) 'Reusable preset clears prior approval'
    Assert ($loaded.OutputRoot -eq $settings.OutputRoot) 'Existing preset output choice round-trips without a new default'
    $injected=$settings.Clone(); $injected.Password=$passwordText
    Export-PackagePreset $injected (Join-Path $fixture 'safe.psd1')
    Assert (-not (Get-Content -LiteralPath (Join-Path $fixture 'safe.psd1') -Raw).Contains($passwordText)) 'Preset exporter allowlist drops unexpected secrets'
    Write-BuilderData (Join-Path $fixture 'bad-preset.psd1') @{Password=$passwordText}
    Reject { Import-PackagePreset (Join-Path $fixture 'bad-preset.psd1') } 'Preset importer refuses secret fields'
    foreach ($name in @('Detect-BIOS.ps1','Require-Model.ps1','Audit-BIOSAndBitLocker.ps1')) {
        $path=Join-Path $result.OutputDirectory ('Intune/'+$name)
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0 -and (Get-Content -LiteralPath $path -Raw).Contains($config.SHA256)) "Standalone $name parses and targets copied payload"
    }
    # Execute the GENERATED detection in isolated runspaces. All Windows APIs
    # are inert mocks. An exit cannot terminate this test process. Exercise the
    # contract Intune consumes: actual BIOS plus healthy resolved protection,
    # never enrollment, staging, or a nominally matching version alone.
    $detection=Join-Path $result.OutputDirectory 'Intune/Detect-BIOS.ps1'
    $expectedRuntime=Read-ApprovedRuntimeManifest (Join-Path $source 'Files')
    foreach ($case in @(
        @{Name='Current protected firmware';Version='2.7.3';Transaction='';Protection='On';Model=$settings.Models[0];Expected=$true},
        @{Name='Newer verified firmware';Version='2.8.0';Transaction='Verified';Protection='On';Model=$settings.Models[0];Expected=$true},
        @{Name='Below target without transaction';Version='2.6.0';Transaction='';Protection='On';Model=$settings.Models[0];Expected=$false},
        @{Name='Staged capsule is not detection';Version='2.6.0';Transaction='Staged';Protection='Off';Model=$settings.Models[0];Expected=$false},
        @{Name='Matching version with unresolved transaction';Version='2.7.3';Transaction='Staged';Protection='On';Model=$settings.Models[0];Expected=$false},
        @{Name='Matching version with suspended protection';Version='2.7.3';Transaction='Verified';Protection='Off';Model=$settings.Models[0];Expected=$false},
        @{Name='Incomplete transaction record';Version='2.7.3';Transaction='Incomplete';Protection='On';Model=$settings.Models[0];Expected=$false},
        @{Name='Wrong model';Version='2.7.3';Transaction='Verified';Protection='On';Model='Not approved';Expected=$false},
        @{Name='Current BIOS with older or drifted runtime';Version='2.7.3';Transaction='Verified';Protection='On';Model=$settings.Models[0];Cache='Drift';Expected=$false},
        @{Name='Verified firmware with retained credential package';Version='2.7.3';Transaction='Verified';Protection='On';Model=$settings.Models[0];Cache='Cleanup';Expected=$false},
        @{Name='Current BIOS with missing runtime';Version='2.7.3';Transaction='Verified';Protection='On';Model=$settings.Models[0];Cache='Missing';Expected=$false}
    )) {
        $runspace=[PowerShell]::Create()
        try {
            $null=$runspace.AddScript({
                param($Detection,$Case,$ExpectedRuntime)
                function Get-CimInstance { param($ClassName)
                    if ($ClassName -eq 'Win32_ComputerSystem') { [pscustomobject]@{Manufacturer='Dell Inc.';Model=$Case.Model} }
                    elseif ($ClassName -eq 'Win32_BIOS') { [pscustomobject]@{SMBIOSBIOSVersion=$Case.Version} }
                    else { throw 'Unexpected mocked CIM query.' }
                }
                function Import-Module { param($Name) if ($Name -ne 'BitLocker') { throw 'Unexpected module.' } }
                function Get-BitLockerVolume { param($MountPoint) [pscustomobject]@{VolumeStatus='FullyEncrypted';ProtectionStatus=$Case.Protection} }
                function Test-Path { param($LiteralPath)
                    if ($LiteralPath.Replace('\','/').EndsWith('State/ScheduledPackage')) { return $Case['Cache'] -eq 'Cleanup' }
                    if ($LiteralPath -ne 'HKLM:\SOFTWARE\ManagedDellBIOS') { throw 'Unexpected registry path.' }
                    return [bool]$Case.Transaction
                }
                function Get-ItemProperty { param($LiteralPath)
                    if ($Case.Transaction -eq 'Incomplete') { return [pscustomobject]@{SuspendedByUs='0'} }
                    [pscustomobject]@{Status=$Case.Transaction;SuspendedByUs='0'}
                }
                function Get-FileHash { param($LiteralPath,$Algorithm)
                    if ($Case['Cache'] -eq 'Missing') { throw 'Inert missing runtime file.' }
                    if ($Case['Cache'] -eq 'Drift') { return [pscustomobject]@{Hash=('0'*64)} }
                    $matches=@($ExpectedRuntime.Files | Where-Object { $LiteralPath.Replace('\','/').EndsWith($_.Destination) })
                    if ($matches.Count -ne 1 -or $Algorithm -ne 'SHA256') { throw 'Unexpected cache hash request.' }
                    [pscustomobject]@{Hash=$matches[0].SHA256}
                }
                & $Detection
                [pscustomobject]@{DetectionExit=$LASTEXITCODE}
            }).AddArgument($detection).AddArgument($case).AddArgument($expectedRuntime)
            $output=@($runspace.Invoke())
            $status=@($output | Where-Object { $_ -isnot [string] })
            $successText=@($output | Where-Object { $_ -is [string] -and $_ -like 'BIOS verified:*' })
            $expectedCode=if ($case.Expected) {0} else {1}
            Assert ($status.Count -eq 1 -and $status[0].DetectionExit -eq $expectedCode -and (($successText.Count -eq 1) -eq $case.Expected)) ('Generated detection: '+$case.Name)
        } finally { $runspace.Dispose() }
    }
    # Repeated builds never overwrite the previous artifact; password-free fleets omit the file.
    $settings.BiosPasswordRequired=$false
    $settings.AllowScheduleLater=$false
    $second=New-DellBiosPackage $settings
    Assert ($second.OutputDirectory -ne $result.OutputDirectory -and -not (Test-Path -LiteralPath (Join-Path $second.SourcePath 'Files/BIOS-Password.psd1'))) 'New build directory and no password file for password-free configuration'
    $secondPolicy=Import-PowerShellDataFile (Join-Path $second.SourcePath 'Files/Simple/Policy.psd1')
    $secondManifest=Get-Content (Join-Path $second.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    $secondPreset=Import-PackagePreset (Join-Path $second.OutputDirectory 'Settings.psd1')
    Assert (-not $secondPolicy.AllowScheduleLater -and -not $secondManifest.DeploymentPolicy.AllowScheduleLater -and -not $secondPreset.AllowScheduleLater) 'Disabled scheduling survives full build, records and preset round trip'
    Assert ($secondPolicy.WindowHours -eq 48 -and $secondPolicy.RestartCountdownMinutes -eq 60 -and $secondPolicy.RestartReminderMinutes -eq 15) 'Scheduling toggle leaves deferral and restart policy intact'
    Assert ($secondManifest.BuilderVersion -eq '5.0.0' -and $secondManifest.PackageType -eq 'BIOS' -and (Test-Path (Join-Path $second.SourcePath 'Files/UI/WindowChrome.ps1')) -and (Test-Path (Join-Path $second.SourcePath 'Files/UI/Theme.xaml'))) 'V4.4 BIOS packages retain shared custom caption and theme resources'
    # WPF image decoding is a Windows boundary. Exercise real packaging/hash/
    # allowlist logic with inert icon bytes and mock only assembly load/decode.
    function Add-Type {param($AssemblyName)
        if ($AssemblyName -ne 'PresentationCore') {Microsoft.PowerShell.Utility\Add-Type -AssemblyName $AssemblyName}
    }
    function Read-BiosWindowIcon {param($Path) if((Get-Item -LiteralPath $Path).Length -eq 0){throw 'inert decode rejection'}; [pscustomobject]@{InertIcon=$true}}
    try {
        foreach ($extension in @('.png','.ico')) {
            $settings.IconPath=Join-Path $fixture ('test-icon'+$extension)
            [IO.File]::WriteAllBytes($settings.IconPath,[byte[]]@(1,2,3,4))
            $iconBuild=New-DellBiosPackage $settings
            $iconFiles=Join-Path $iconBuild.SourcePath Files
            $iconBrand=Import-PowerShellDataFile (Join-Path $iconFiles UI/Branding.psd1)
            $asset=Join-Path $iconFiles ('UI/'+$iconBrand.IconFile)
            $iconManifest=Read-ApprovedRuntimeManifest $iconFiles
            Assert ($iconBrand.IconFile -eq ('Assets/app-icon'+$extension) -and (Get-FileHash $asset).Hash -eq (Get-FileHash $settings.IconPath).Hash) ('Custom '+$extension+' icon copied literally to branded asset')
            Assert (@($iconManifest.Files | Where-Object Destination -eq ('UI/'+$iconBrand.IconFile)).Count -eq 1 -and $iconManifest.Files.Count -eq 16) ('Custom '+$extension+' icon enters cache repair/detection manifest')
        }
        [IO.File]::WriteAllBytes($settings.IconPath,[byte[]]@())
        Reject {Assert-BuilderSettings $settings} 'Undecodable icon fails before a package build'
        $bad=$settings.Clone();$bad.IconPath=$settings.BiosPath
        Reject {Assert-BuilderSettings $bad} 'Executable cannot be selected as an icon'
    } finally {Remove-Item Function:Add-Type;Remove-Item Function:Read-BiosWindowIcon;$settings.IconPath=''}
    $global:DellBuilderTestSignatureValid=$false
    $before=@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count
    Reject { New-DellBiosPackage $settings } 'Invalid Dell signature fails build'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count -eq $before) 'Failure cleans partial output'
    $global:DellBuilderTestSignatureValid=$true
    # Numeric/range and review gates are effective, not decorative GUI fields.
    foreach ($case in @(@('MinimumBatteryPercent',50),@('MinimumBatteryRuntimeMinutes',241),@('BitLockerRebootCount',0),@('MinimumFreeSpaceGB',0),@('WindowHours',0),@('WindowHours',169),@('WindowHours',1.5),@('PromptTimeoutMinutes',0),@('RestartCountdownMinutes',0),@('RestartReminderMinutes',60),@('PackageReviewed',$false))) {
        $bad=$settings.Clone(); $bad[$case[0]]=$case[1]
        Reject { Assert-BuilderSettings $bad } ('Reject invalid '+$case[0]+'='+$case[1])
    }
    $bad=$settings.Clone(); $bad.RequireBattery=$false; $bad.MinimumBatteryRuntimeMinutes=10
    Reject { Assert-BuilderSettings $bad } 'Runtime gate requires a battery'
    $bad=$settings.Clone(); $bad.OutputRoot=$root
    Reject { New-DellBiosPackage $bad } 'Refuse output inside checkout'
    foreach ($destination in @('', 'relative-output', '\\server\share', (Join-Path $fixture 'missing-output'), $settings.BiosPath)) {
        $bad=$settings.Clone(); $bad.OutputRoot=$destination
        Reject {New-DellBiosPackage $bad} 'Invalid destination cannot generate a package'
    }
    $volumeRoot=[IO.Path]::GetPathRoot($fixture)
    Assert ((Resolve-BuilderOutputRoot $volumeRoot) -eq $volumeRoot) 'Root output remains absolute rather than becoming drive-relative'
    # ZIP traversal, Windows path normalization, duplicate names and embedded secrets.
    function New-TestZip([string]$Path,[string[]]$Names,[int]$Attributes=0) {
        $stream=[IO.File]::Open($Path,'CreateNew'); $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Names) { $entry=$archive.CreateEntry($name); if ($Attributes) { $entry.ExternalAttributes=$Attributes }; $writer=New-Object IO.StreamWriter($entry.Open()); $writer.Write('x'); $writer.Dispose() }
        } finally { $archive.Dispose(); $stream.Dispose() }
    }
    foreach ($names in @(@('../escape.txt'),@('/absolute.txt'),@('C:/absolute.txt'),@('file:stream'),@('folder/NUL.txt'),@('folder/trailing. '),@('same.txt','SAME.txt'),@('Files/BIOS-Password.psd1'))) {
        $badZip=Join-Path $fixture ([guid]::NewGuid().ToString()+'.zip'); New-TestZip $badZip $names
        $dest=Join-Path $fixture ([guid]::NewGuid().ToString())
        Reject { Expand-BuilderZip $badZip $dest } ('Reject ZIP '+($names -join ','))
        Assert (-not (Test-Path -LiteralPath $dest)) 'Archive validation fails before extraction'
    }
    $linkZip=Join-Path $fixture 'link.zip'; New-TestZip $linkZip @('symlink') ([int](0xA000 -shl 16))
    Reject { Expand-BuilderZip $linkZip (Join-Path $fixture 'link-out') } 'ZIP symlinks rejected'
    # Wrapped ZIP root and ambiguity handling.
    $wrapped=Join-Path $fixture 'Wrapped'; $null=[IO.Directory]::CreateDirectory($wrapped)
    Copy-Item -LiteralPath $template -Destination $wrapped -Recurse
    Assert ((Get-BuilderFramework $wrapped).Version -eq '4.1.0') 'One enclosing folder is supported'
    Copy-Item -LiteralPath $template -Destination (Join-Path $wrapped 'Second') -Recurse
    Reject { Get-BuilderFramework $wrapped } 'Multiple templates require user correction'
    Write-BuilderData (Join-Path $module 'PSAppDeployToolkit.psd1') @{ModuleVersion='4.2.0';RootModule='PSAppDeployToolkit.psm1'}
    Reject { Get-BuilderFramework $template } 'Unsupported framework version rejected'
    $malformed=Join-Path $fixture 'malformed.ps1'; [IO.File]::WriteAllText($malformed,$bootstrap.Replace('function Install-ADTDeployment','function WrongFunction'))
    Reject { Set-BuilderTemplate $malformed '2.7.3' } 'Template with missing function is never patched by guesswork'
    [IO.File]::WriteAllText($malformed,$bootstrap+"`nfunction Install-ADTDeployment { }")
    Reject { Set-BuilderTemplate $malformed '2.7.3' } 'Duplicate deployment functions rejected'
    # Exercise optional packaging orchestration while keeping all executables inert.
    $tool=Join-Path $fixture 'IntuneWinAppUtil.exe'; [IO.File]::WriteAllText($tool,'inert tool')
    $savedPrep=${function:Invoke-BuilderContentPrep}
    Reject { Invoke-BuilderContentPrep $tool $source $fixture } 'Non-Microsoft signer rejected before any native process starts'
    $script:prepCalls=0
    function Invoke-BuilderContentPrep {
        param($Tool,$Source,$Output)
        $script:prepCalls++
        Assert ((Test-Path -LiteralPath (Join-Path $Source 'Invoke-AppDeployToolkit.exe')) -and -not $Output.StartsWith($Source+[IO.Path]::DirectorySeparatorChar)) 'Content preparation uses generated source and output outside source'
        $file=Join-Path $Output 'Invoke-AppDeployToolkit.intunewin'
        [IO.File]::WriteAllText($file,'inert packaged output')
        return $file
    }
    $settings.ContentPrepTool=$tool
    $selectedOutput=Join-Path $fixture 'Chosen Output [pilot]'
    $null=[IO.Directory]::CreateDirectory($selectedOutput)
    $sentinel=Join-Path $selectedOutput 'unrelated.txt'
    [IO.File]::WriteAllText($sentinel,'keep this sibling')
    $settings.OutputRoot=$selectedOutput+[IO.Path]::DirectorySeparatorChar
    $packaged=New-DellBiosPackage $settings
    $manifestData=Get-Content -LiteralPath (Join-Path $packaged.OutputDirectory 'BuildManifest.json') -Raw | ConvertFrom-Json
    Assert ($script:prepCalls -eq 1 -and $packaged.IntuneWinFile -and $manifestData.OutputMode -eq 'IntuneWin') 'Optional packaging invoked once and reported accurately'
    Assert ($manifestData.IntuneWinSHA256 -eq (Get-FileHash -LiteralPath $packaged.IntuneWinFile).Hash) 'Completed package hash recorded'
    Assert ((Split-Path $packaged.OutputDirectory -Parent) -eq $selectedOutput) 'Package is built below the chosen folder with spaces and brackets'
    Assert ($packaged.SourcePath.StartsWith($packaged.OutputDirectory+[IO.Path]::DirectorySeparatorChar) -and $packaged.IntuneWinFile.StartsWith($packaged.OutputDirectory+[IO.Path]::DirectorySeparatorChar)) 'Source and optional intunewin share the chosen build directory'
    Assert ($manifestData.OutputRoot -eq $selectedOutput -and $manifestData.OutputDirectory -eq $packaged.OutputDirectory) 'Build manifest records canonical destination and actual unique output'
    $notes=Get-Content -LiteralPath (Join-Path $packaged.OutputDirectory 'Build.log') -Raw
    Assert ($notes.Contains('Output folder: '+$selectedOutput) -and $notes.Contains('Build directory: '+$packaged.OutputDirectory)) 'Build notes identify the selected destination'
    Assert ((Import-PackagePreset (Join-Path $packaged.OutputDirectory 'Settings.psd1')).OutputRoot -eq $settings.OutputRoot) 'Changed destination is retained in generated preset'
    Assert (-not $script:protectedPaths.Contains($selectedOutput) -and $script:protectedPaths.Contains($packaged.OutputDirectory)) 'Only new build directory receives output protection; selected parent is not modified'
    function Invoke-BuilderContentPrep { throw 'Inert simulated tool failure' }
    $before=@(Get-ChildItem -LiteralPath $selectedOutput -Directory -Filter 'DellBIOS-*').Count
    Reject { New-DellBiosPackage $settings } 'Content preparation failure cannot return build success'
    Assert (@(Get-ChildItem -LiteralPath $selectedOutput -Directory -Filter 'DellBIOS-*').Count -eq $before) 'Tool failure removes partial build from selected output'
    Assert ((Get-Content -LiteralPath $sentinel -Raw) -eq 'keep this sibling' -and (Test-Path -LiteralPath $packaged.IntuneWinFile)) 'Failed build preserves unrelated files and previously completed package'
    ${function:Invoke-BuilderContentPrep}=$savedPrep
    Assert ((Get-FileHash -LiteralPath $settings.BiosPath).Hash -eq $result.SHA256) 'Original BIOS input unchanged'
    Assert ((Get-Content -LiteralPath (Join-Path $template 'Invoke-AppDeployToolkit.ps1') -Raw) -eq $bootstrap) 'Original custom template unchanged'
    Write-Output "PASS: $count builder assertions (inert source builds, archive validation, AST integration, settings and secret handling). Windows trust/ACL boundaries mocked; no EXE run."
} finally {
    if (Get-Variable secret -ErrorAction SilentlyContinue) { $secret.Dispose() }
    $env:ProgramData=$oldProgramData
    Remove-Variable DellBuilderTestSignatureValid -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
