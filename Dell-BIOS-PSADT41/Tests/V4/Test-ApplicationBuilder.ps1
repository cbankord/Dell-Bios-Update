# Real package IO, ZIP parsing and mode dispatch. No installer or supplied script runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaAppTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData; if (-not $env:ProgramData) { $env:ProgramData=$temp }
$count=0
function Check($Condition,$Name) { $script:count++; if (-not $Condition) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Body,$Name) { $failed=$false; try { $null=& $Body } catch { $failed=$true }; Check $failed $Name }
function Write-Fixture($Path,$Content) { $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($true))) }
function Compress-Fixture($Folder) { $zip=Join-Path $temp ([guid]::NewGuid().ToString()+'.zip'); [IO.Compression.ZipFile]::CreateFromDirectory($Folder,$zip); return $zip }
try {
    . "$root/Builder/Build-Package.ps1"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Assert-BuilderHost {}
    $script:protected=New-Object 'Collections.Generic.List[string]'
    function Protect-BuilderDirectory($Path) { $script:protected.Add($Path) }
    foreach ($name in @('Set-BuilderTemplate','Assert-Payload','Assert-Config','Write-RuntimeManifest','Assert-SimplePolicy')) {
        Set-Item -Path ('Function:'+$name) -Value { throw 'Application must never enter BIOS logic' }
    }
    $settings=New-PackageBuildSettings
    Check ($settings.PackageType -eq 'BIOS') 'Default mode preserves existing BIOS workflow'
    $preset=Join-Path $temp 'old-preset.psd1'
    Write-BuilderData $preset @{OutputRoot=$temp;TargetVersion='2.7.3'}
    $old=Import-PackagePreset $preset
    Check ($old.PackageType -eq 'BIOS' -and $old.OutputRoot -eq $temp -and $old.TargetVersion -eq '2.7.3') 'Legacy preset gains BIOS mode without losing settings'
    $settings.PackageType='Application'; $settings.ApplicationName='Example App'; $settings.ApplicationVersion='2026.09-beta'
    $settings.PackageReviewed=$true
    $output=Join-Path $temp 'Chosen Output [Apps]'; $null=[IO.Directory]::CreateDirectory($output)
    $settings.OutputRoot=$output
    Write-Fixture (Join-Path $output 'sibling.txt') 'preserve unrelated output'
    # Inactive BIOS settings must never be validated, read as files or copied.
    $settings.BiosPath='nonexistent-BIOS.exe'; $settings.MinimumBatteryPercent=0
    $settings.IconPath='nonexistent-bios-icon.png'; $settings.BiosPasswordRequired=$true
    $original=Join-Path $temp 'App Source'
    Write-Fixture (Join-Path $original 'Invoke-AppDeployToolkit.ps1') @'
param([string]$DeploymentType,[string]$DeployMode)
$adtSession=@{AppName='Keep original identity';AppVersion='Vendor version'}
function Install-ADTDeployment { throw 'Never execute original install' }
function Uninstall-ADTDeployment { throw 'Never execute original uninstall' }
function Repair-ADTDeployment { throw 'Never execute original repair' }
throw 'Never execute bootstrap'
'@
    Write-Fixture (Join-Path $original 'Invoke-AppDeployToolkit.exe') 'Inert launcher'
    Write-Fixture (Join-Path $original 'PSAppDeployToolkit/PSAppDeployToolkit.psm1') "throw 'Never import supplied module'"
    Write-Fixture (Join-Path $original 'Files/Common.ps1') "throw 'Application-owned Common.ps1 must survive'"
    Write-Fixture (Join-Path $original 'Files/setup.msi') 'Inert installer bytes'
    Write-Fixture (Join-Path $original 'Files/UI/Branding.psd1') "@{AppTitle='Existing app branding'}"
    Write-Fixture (Join-Path $original 'PSAppDeployToolkit.Extensions/extension.ps1') "throw 'Never execute extension'"
    foreach ($version in @('4.0.0','4.1.8','4.2.0')) {
        Write-BuilderData (Join-Path $original 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') @{ModuleVersion=$version;RootModule='PSAppDeployToolkit.psm1'}
        $settings.FrameworkZip=Compress-Fixture $original
        $events=New-Object 'Collections.Generic.List[string]'
        $result=New-DeploymentPackage -Settings $settings -Progress {param($message) $events.Add($message)}
        Check ($result.PackageType -eq 'Application' -and $result.FrameworkVersion -eq $version) "$version builds through application dispatcher"
        $inputs=@(Get-ChildItem -LiteralPath $original -Recurse -File)
        $outputs=@(Get-ChildItem -LiteralPath $result.SourcePath -Recurse -File)
        Check ($inputs.Count -eq $outputs.Count) "$version source has no injected files"
        foreach ($file in $inputs) {
            $relative=$file.FullName.Substring($original.Length+1)
            $copied=Join-Path $result.SourcePath $relative
            Check ((Get-FileHash -LiteralPath $file.FullName).Hash -eq (Get-FileHash -LiteralPath $copied).Hash) "$version retains bytes of $relative"
        }
        foreach ($path in @('Files/BIOS-Config.psd1','Files/BIOS-Password.psd1','Files/Simple/Deployment.ps1','Files/RuntimeManifest.json')) {
            Check (-not (Test-Path -LiteralPath (Join-Path $result.SourcePath $path))) "$version adds no $path"
        }
        $manifest=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
        Check ($manifest.BuilderVersion -eq '5.0.0' -and $manifest.PackageType -eq 'Application' -and $manifest.SourcePreserved) "$version records mode and source preservation"
        Check ($manifest.Detection.Mode -eq 'ConfigureInIntune' -and -not (Test-Path -LiteralPath (Join-Path $result.OutputDirectory 'Intune/Detect-Application.ps1'))) "$version never invents universal detection"
        Check ($manifest.ApplicationVersion -eq '2026.09-beta' -and $manifest.InstallCommand -eq 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent') "$version app label is independent of original product metadata"
        $loaded=Import-PackagePreset (Join-Path $result.OutputDirectory 'Settings.psd1')
        Check ($loaded.PackageType -eq 'Application' -and $loaded.ApplicationName -eq $settings.ApplicationName -and -not $loaded.PackageReviewed) "$version application preset round-trips with review cleared"
        Check ((Split-Path $result.OutputDirectory -Parent) -eq $output -and $script:protected.Contains($result.OutputDirectory) -and -not $script:protected.Contains($output)) "$version protects only the new child in chosen output"
        Check (-not (Test-Path -LiteralPath (Join-Path $result.OutputDirectory '.buildwork'))) "$version removes staging snapshot on success"
    }
    Reject {New-DellBiosPackage -Settings $settings} 'Application input cannot enter BIOS-only entry point'
    $detection=Join-Path $temp 'Detection.ps1'; Write-Fixture $detection "throw 'Detection must never execute while building'"
    $settings.ApplicationDetectionScript=$detection; $settings.ApplicationContext='User'
    $tool=Join-Path $temp 'IntuneWinAppUtil.exe'; Write-Fixture $tool 'Inert Microsoft tool boundary'
    $settings.ContentPrepTool=$tool; $script:prepCalls=0
    function Invoke-BuilderContentPrep($Tool,$Source,$Output,$SetupFile) {
        $script:prepCalls++; $script:lastSetup=$SetupFile
        Check (Test-Path -LiteralPath (Join-Path $Source $SetupFile)) 'Content prep receives actual package launcher'
        $path=Join-Path $Output (([IO.Path]::GetFileNameWithoutExtension($SetupFile))+'.intunewin')
        Write-Fixture $path 'Inert intunewin output'; return $path
    }
    $result=New-DeploymentPackage $settings
    $manifest=Get-Content -LiteralPath (Join-Path $result.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    $copiedDetection=Join-Path $result.OutputDirectory 'Intune/Detect-Application.ps1'
    Check ($manifest.InstallBehavior -eq 'User' -and $manifest.Detection.Mode -eq 'CustomScript') 'User context and supplied detection reach build manifest'
    Check ((Get-FileHash -LiteralPath $detection).Hash -eq (Get-FileHash -LiteralPath $copiedDetection).Hash -and $manifest.Detection.SHA256 -eq (Get-FileHash -LiteralPath $copiedDetection).Hash) 'Detection bytes/signature retained outside deployment source'
    Check ($script:prepCalls -eq 1 -and $script:lastSetup -eq 'Invoke-AppDeployToolkit.exe' -and $manifest.OutputMode -eq 'IntuneWin') 'Optional application packaging reports actual intunewin'
    $completed=$result.IntuneWinFile
    # Legacy PSADT layouts, both with and without the optional EXE launcher.
    $legacy=Join-Path $temp 'Legacy'
    Write-Fixture (Join-Path $legacy 'Deploy-Application.ps1') "param([string]`$DeploymentType,[string]`$DeployMode)`nthrow 'Never execute legacy app'"
    Write-Fixture (Join-Path $legacy 'AppDeployToolkit/AppDeployToolkitMain.ps1') "throw 'Never load legacy toolkit'"
    Write-Fixture (Join-Path $legacy 'AppDeployToolkit/AppDeployToolkitConfig.xml') '<Configuration />'
    foreach ($withExe in @($false,$true)) {
        if ($withExe) { Write-Fixture (Join-Path $legacy 'Deploy-Application.exe') 'Inert legacy launcher' }
        $settings.FrameworkZip=Compress-Fixture $legacy
        $legacyResult=New-DeploymentPackage $settings
        $manifest=Get-Content -LiteralPath (Join-Path $legacyResult.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
        $expected=if ($withExe) {'Deploy-Application.exe'} else {'Deploy-Application.ps1'}
        Check ($manifest.FrameworkGeneration -eq 3 -and $script:lastSetup -eq $expected) 'Legacy app selects its actual launcher for content prep'
        Check ($manifest.UninstallCommand.Contains('-DeploymentType Uninstall -DeployMode Silent') -and $manifest.InstallCommand.Contains($expected)) 'Legacy commands preserve existing install/uninstall entry point'
    }
    $settings.FrameworkZip=Compress-Fixture $original
    foreach ($case in @(@('ApplicationName',''),@('ApplicationVersion',''),@('ApplicationContext','Administrator'),@('PackageReviewed',$false),@('PackageType','Unknown'),@('OutputRoot',''))) {
        $bad=$settings.Clone(); $bad[$case[0]]=$case[1]
        Reject {New-DeploymentPackage $bad} ('Reject invalid '+$case[0])
    }
    $bad=$settings.Clone();$bad.OutputRoot=$root
    Reject {New-DeploymentPackage $bad} 'Application output inside checkout is refused'
    $before=@(Get-ChildItem -LiteralPath $output -Directory).Count
    Write-Fixture $detection "param( # inert-private-detection-detail"
    Reject {New-DeploymentPackage $settings} 'Detection parser failure blocks completed output'
    Check (@(Get-ChildItem -LiteralPath $output -Directory).Count -eq $before) 'Detection failure removes partial application package'
    $settings.ApplicationDetectionScript=''
    function Invoke-BuilderContentPrep { throw 'inert-private-tool-detail' }
    $message='';try {$null=New-DeploymentPackage $settings}catch{$message=$_.Exception.Message}
    Check ($message.Contains('running Microsoft content preparation') -and -not $message.Contains('inert-private-tool-detail')) 'Tool error is phase-specific without private native details'
    Check (@(Get-ChildItem -LiteralPath $output -Directory).Count -eq $before -and (Test-Path -LiteralPath $completed) -and (Get-Content -LiteralPath (Join-Path $output 'sibling.txt') -Raw) -eq 'preserve unrelated output') 'Failed app build preserves completed output and siblings'
    $settings.ContentPrepTool=''
    Write-Fixture (Join-Path $original 'bad.ps1') 'param('
    $settings.FrameworkZip=Compress-Fixture $original
    Reject {New-DeploymentPackage $settings} 'Malformed application code is parsed but never run'
    Remove-Item -LiteralPath (Join-Path $original 'bad.ps1')
    Write-Fixture (Join-Path $original 'Files/BIOS-Password.psd1') "@{Password='inert'}"
    $settings.FrameworkZip=Compress-Fixture $original
    Reject {New-DeploymentPackage $settings} 'Embedded BIOS password remains forbidden in application archives'
    Remove-Item -LiteralPath (Join-Path $original 'Files/BIOS-Password.psd1')
    $mixed=Join-Path $temp 'Mixed';$null=[IO.Directory]::CreateDirectory($mixed)
    Copy-Item -LiteralPath $original -Destination (Join-Path $mixed 'App4') -Recurse
    Copy-Item -LiteralPath $legacy -Destination (Join-Path $mixed 'App3') -Recurse
    $settings.FrameworkZip=Compress-Fixture $mixed
    Reject {New-DeploymentPackage $settings} 'Multiple mixed-generation deployments are ambiguous and rejected'
    Check (@(Get-ChildItem -LiteralPath $output -Directory).Count -eq $before) 'All rejected packages finish partial cleanup'
    Write-Output "PASS: $count application packaging assertions. Real source/archive IO; Windows trust/ACL/tool boundaries inert."
} finally { $env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force }
