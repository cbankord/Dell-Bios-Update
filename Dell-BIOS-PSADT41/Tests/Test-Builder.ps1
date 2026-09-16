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
    [IO.File]::WriteAllText((Join-Path $template 'custom-config.txt'),'preserve my branding')
    $null=[IO.Directory]::CreateDirectory((Join-Path $template 'PSAppDeployToolkit.Extensions'))
    [IO.File]::WriteAllText((Join-Path $template 'PSAppDeployToolkit.Extensions/custom.ps1'),"throw 'do not run extensions during build'")
    $zip=Join-Path $fixture 'Custom Framework.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($template,$zip)
    $settings=New-PackageBuildSettings
    $settings.FrameworkZip=$zip; $settings.BiosPath=Join-Path $fixture 'Approved Dell.exe'
    [IO.File]::WriteAllText($settings.BiosPath,'Inert BIOS fixture, NEVER execute')
    $settings.OutputRoot=$fixture; $settings.Models=@("Dell Pro Max 16 MC16250", "Dell O'Brien `$model")
    $settings.TargetVersion='2.7.3'; $settings.PackageReviewed=$true
    $settings.CompanyName="O'Brien & Co. `$literal"; $settings.WindowHours=48
    Assert-BuilderSettings $settings
    # Mock only Windows trust/ACL boundaries, never extraction, AST rewrite or serialization.
    function Assert-BuilderHost { }
    $script:protected=0
    function Protect-BuilderDirectory { param($Path) $script:protected++ }
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
    $policy=Import-PowerShellDataFile (Join-Path $source 'Files/Scheduler/Policy.psd1')
    Assert ($policy.WindowHours -eq 48) 'Configured deadline is packaged'
    $generated=Get-Content -LiteralPath (Join-Path $source 'Invoke-AppDeployToolkit.ps1') -Raw
    Assert ($generated.Contains("CustomField='preserve `$ and { braces }'") -and $generated.Contains('NEVER execute the template')) 'Custom metadata and bootstrap retained'
    Assert ($generated.Contains('Start-ADTProcessAsUser') -and -not $generated.Contains("'old install'")) 'BIOS Install function replaces the old function'
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
    # Repeated builds never overwrite the previous artifact; password-free fleets omit the file.
    $settings.BiosPasswordRequired=$false
    $second=New-DellBiosPackage $settings
    Assert ($second.OutputDirectory -ne $result.OutputDirectory -and -not (Test-Path -LiteralPath (Join-Path $second.SourcePath 'Files/BIOS-Password.psd1'))) 'New build directory and no password file for password-free configuration'
    $global:DellBuilderTestSignatureValid=$false
    $before=@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count
    Reject { New-DellBiosPackage $settings } 'Invalid Dell signature fails build'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count -eq $before) 'Failure cleans partial output'
    $global:DellBuilderTestSignatureValid=$true
    # Numeric/range and review gates are effective, not decorative GUI fields.
    foreach ($case in @(@('MinimumBatteryPercent',50),@('MinimumBatteryRuntimeMinutes',241),@('BitLockerRebootCount',0),@('MinimumFreeSpaceGB',0),@('WindowHours',0),@('WindowHours',169),@('WindowHours',1.5),@('FinalWarningMinutes',14),@('PackageReviewed',$false))) {
        $bad=$settings.Clone(); $bad[$case[0]]=$case[1]
        Reject { Assert-BuilderSettings $bad } ('Reject invalid '+$case[0]+'='+$case[1])
    }
    $bad=$settings.Clone(); $bad.RequireBattery=$false; $bad.MinimumBatteryRuntimeMinutes=10
    Reject { Assert-BuilderSettings $bad } 'Runtime gate requires a battery'
    $bad=$settings.Clone(); $bad.OutputRoot=$root
    Reject { New-DellBiosPackage $bad } 'Refuse output inside checkout'
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
    $packaged=New-DellBiosPackage $settings
    $manifestData=Get-Content -LiteralPath (Join-Path $packaged.OutputDirectory 'BuildManifest.json') -Raw | ConvertFrom-Json
    Assert ($script:prepCalls -eq 1 -and $packaged.IntuneWinFile -and $manifestData.OutputMode -eq 'IntuneWin') 'Optional packaging invoked once and reported accurately'
    Assert ($manifestData.IntuneWinSHA256 -eq (Get-FileHash -LiteralPath $packaged.IntuneWinFile).Hash) 'Completed package hash recorded'
    function Invoke-BuilderContentPrep { throw 'Inert simulated tool failure' }
    $before=@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count
    Reject { New-DellBiosPackage $settings } 'Content preparation failure cannot return build success'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'DellBIOS-*').Count -eq $before) 'Tool failure removes partial build'
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
