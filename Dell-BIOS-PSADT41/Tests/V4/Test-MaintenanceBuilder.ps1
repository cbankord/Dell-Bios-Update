$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MaintenanceTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData; $oldWindir=$env:WINDIR
if (-not $env:ProgramData) { $env:ProgramData=$temp };$env:WINDIR=$temp
$count=0
function Check($Condition,$Name) {$script:count++;if(-not $Condition){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try {$null=& $Body}catch{$failed=$true};Check $failed $Name}
function Write-Fixture($Path,$Text) {$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true)))}
function Zip-Fixture($Folder) {$path=Join-Path $temp ([guid]::NewGuid().ToString()+'.zip');[IO.Compression.ZipFile]::CreateFromDirectory($Folder,$path);return $path}
try {
    . "$root/Builder/Build-Package.ps1"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Assert-BuilderHost {}
    $script:protected=New-Object 'Collections.Generic.List[string]'
    function Protect-BuilderDirectory($Path) {$script:protected.Add($Path)}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/Test-SectionEditor.ps1",[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-SectionFixture'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $source=Join-Path $temp 'Original'
    $original=New-SectionFixture
    Write-Fixture (Join-Path $source 'Invoke-AppDeployToolkit.ps1') $original
    [IO.File]::WriteAllText((Join-Path $source 'Invoke-AppDeployToolkit.ps1'),$original,(New-Object Text.UTF8Encoding($false))) # No BOM: an unnecessary editor write would change these bytes.
    Write-Fixture (Join-Path $source 'Invoke-AppDeployToolkit.exe') 'Inert launcher'
    Write-Fixture (Join-Path $source 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') "@{ModuleVersion='4.1.8';RootModule='PSAppDeployToolkit.psm1'}"
    Write-Fixture (Join-Path $source 'PSAppDeployToolkit/PSAppDeployToolkit.psm1') "throw 'Never import framework'"
    Write-Fixture (Join-Path $source 'Files/original.txt') 'preserved'
    $s=New-PackageBuildSettings;$s.FrameworkZip=Zip-Fixture $source;$s.OutputRoot=$temp
    $s.ApplicationName='Approved servicing';$s.ApplicationVersion='2026.09';$s.PackageReviewed=$true
    $s.WindowsBuild='26100';$s.PackageType='WindowsUpdate'
    $s.ApplicationDetectionScript=Join-Path $temp 'detection.ps1';Write-Fixture $s.ApplicationDetectionScript "throw 'Never execute detection'"
    $s.MaintenancePayload=Join-Path $temp 'update.msu';Write-Fixture $s.MaintenancePayload 'inert approved update'
    $update=New-DeploymentPackage $s
    $manifest=Get-Content (Join-Path $update.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    Check ($manifest.PackageType -eq 'WindowsUpdate' -and $manifest.BuilderVersion -eq '5.0.0' -and -not $manifest.SourcePreserved) 'Windows Update builds generated steps and truthful manifest'
    $entry=Get-Content (Join-Path $update.SourcePath 'Invoke-AppDeployToolkit.ps1') -Raw
    Check ($entry.Contains('Invoke-BuilderMaintenance') -and $entry.Contains('Close-ADTSession -ExitCode 3010')) 'Install and post-install generated with restart handoff'
    Check ($entry.Contains("AppName='Approved servicing'")) 'Generated servicing uses chosen application identity'
    Check ($manifest.PayloadSHA256 -eq (Get-FileHash $s.MaintenancePayload).Hash) 'Approved update payload hash recorded'
    Check (-not (Test-Path (Join-Path $update.SourcePath 'Files/BIOS-Config.psd1'))) 'No firmware configuration injected'
    $runtime=Join-Path $update.SourcePath 'Files/BuilderMaintenance'
    . (Join-Path $runtime 'Deploy-Maintenance.ps1')
    function Assert-MaintenanceHost {}
    $script:manufacturer='Dell Inc.';$script:model='Dell Pro Max 16 MC16250';$script:build='26100';$script:exitCode=0;$script:processCalls=0
    function Get-CimInstance($ClassName) {
        if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{Manufacturer=$script:manufacturer;Model=$script:model} }
        return [pscustomobject]@{BuildNumber=$script:build;ProductType=1}
    }
    function Write-ADTLogEntry($Message) {}
    function Start-ADTProcess($FilePath,$ArgumentList,[switch]$PassThru,$IgnoreExitCodes) {
        $script:processCalls++;$script:command=$FilePath;$script:arguments=$ArgumentList
        return [pscustomobject]@{ExitCode=$script:exitCode}
    }
    Check ((Invoke-BuilderMaintenance $runtime) -eq 0 -and $script:command.EndsWith('dism.exe')) 'Runtime calls DISM for approved update'
    Check ($script:arguments.Contains('/NoRestart') -and $script:arguments.Contains('/PreventPending') -and -not $script:arguments.Contains('/IgnoreCheck')) 'DISM suppresses restart and preserves applicability/pending gates'
    $script:exitCode=3010;Check ((Invoke-BuilderMaintenance $runtime) -eq 3010) 'Restart-required code preserved'
    $script:exitCode=87;Reject {Invoke-BuilderMaintenance $runtime} 'DISM errors not treated as installed'
    $script:exitCode=0;$script:build='22631';$before=$script:processCalls
    Reject {Invoke-BuilderMaintenance $runtime} 'Wrong Windows build blocked';Check ($script:processCalls -eq $before) 'Wrong build cannot launch servicing'
    $script:build='26100';$script:manufacturer='Other vendor';Reject {Invoke-BuilderMaintenance $runtime} 'Non-Dell blocked'
    $script:manufacturer='Dell Inc.'
    $payload=Join-Path $runtime 'Payload/ApprovedUpdate.msu';Write-Fixture $payload 'tampered update'
    Reject {Invoke-BuilderMaintenance $runtime} 'Changed payload hash blocked'
    foreach ($case in @(@('WindowsBuild',''),@('ApplicationContext','User'),@('ApplicationDetectionScript',''),@('WindowsBuild','19045'))) {
        $prior=$s[$case[0]];$s[$case[0]]=$case[1];Reject {New-DeploymentPackage $s} ('Update invalid '+$case[0]);$s[$case[0]]=$prior
    }
    $drivers=Join-Path $temp 'Drivers'
    Write-Fixture (Join-Path $drivers 'sub/device.inf') "[Version]`nClass=Net`nCatalogFile=device.cat"
    Write-Fixture (Join-Path $drivers 'sub/device.cat') 'inert catalog; Windows boundary mocked'
    Write-Fixture (Join-Path $drivers 'sub/device.sys') 'inert driver'
    $s.PackageType='Driver';$s.DriverModels=@('Dell Pro Max 16 MC16250');$s.MaintenancePayload=Zip-Fixture $drivers
    $driver=New-DeploymentPackage $s;$runtime=Join-Path $driver.SourcePath 'Files/BuilderMaintenance'
    Check ((Invoke-BuilderMaintenance $runtime) -eq 0 -and $script:command.EndsWith('pnputil.exe')) 'Driver launches PnPUtil'
    Check ($script:arguments.Contains('/subdirs /install') -and -not $script:arguments.Contains('/reboot')) 'Matching INF installation includes subfolders and never requests reboot'
    $script:model='Wrong model';$before=$script:processCalls;Reject {Invoke-BuilderMaintenance $runtime} 'Unapproved Dell model blocked';Check ($script:processCalls -eq $before) 'Model mismatch launches nothing';$script:model='Dell Pro Max 16 MC16250'
    Write-Fixture (Join-Path $runtime 'Payload/extra.inf') 'extra';Reject {Invoke-BuilderMaintenance $runtime} 'Unlisted driver payload blocked'
    Write-Fixture (Join-Path $drivers 'sub/device.inf') "[Version]`nClass=Firmware`nCatalogFile=device.cat"
    $s.MaintenancePayload=Zip-Fixture $drivers;$before=@(Get-ChildItem $temp -Directory -Filter 'PSADT-Driver-*').Count
    Reject {New-DeploymentPackage $s} 'Firmware INF rejected at packaging';Check (@(Get-ChildItem $temp -Directory -Filter 'PSADT-Driver-*').Count -eq $before) 'Rejected driver build cleans partial output only'
    $s.PackageType='Application';$s.UseEditor=$true
    $doc=Read-EditorPackage $s.FrameworkZip
    Check ($doc.Sections.Count -eq 10 -and $doc.ZIP_SHA256 -eq (Get-FileHash $s.FrameworkZip).Hash) 'Editor reads complete ZIP without running bootstrap'
    $noChange=New-DeploymentPackage $s -EditorDocument $doc
    $noChangeManifest=Get-Content (Join-Path $noChange.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    Check ($noChangeManifest.SourcePreserved -and $noChangeManifest.EditorApplied) 'No-op editor build records source preservation accurately'
    Check ((Get-FileHash (Join-Path $noChange.SourcePath 'Invoke-AppDeployToolkit.ps1')).Hash -eq (Get-FileHash (Join-Path $source 'Invoke-AppDeployToolkit.ps1')).Hash) 'No-op editor build preserves original encoding and exact bytes'
    $doc.MetadataText=Set-EditorMetadataValues $doc.MetadataText @{AppName='Edited app metadata'}
    $doc.Sections.Install="    throw 'Edited install must not execute during packaging'`r`n"
    $app=New-DeploymentPackage $s -EditorDocument $doc
    $edited=Get-Content (Join-Path $app.SourcePath 'Invoke-AppDeployToolkit.ps1') -Raw
    Check ($edited.Contains('Edited install must not execute') -and $edited.Contains('Bootstrap must never execute')) 'Editor applies section changes and retains bootstrap'
    Check ((Get-FileHash (Join-Path $app.SourcePath 'Files/original.txt')).Hash -eq (Get-FileHash (Join-Path $source 'Files/original.txt')).Hash) 'Editor preserves other source files'
    $manifest=Get-Content (Join-Path $app.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    Check ($edited.Contains("AppName='Edited app metadata'") -and $manifest.EntryScriptSHA256 -eq (Get-FileHash (Join-Path $app.SourcePath 'Invoke-AppDeployToolkit.ps1')).Hash) 'ZIP metadata edits reach Source and exact entry script hash is recorded'
    Check ($manifest.EditorApplied -and -not $manifest.SourcePreserved -and $manifest.SectionsSHA256.Length -eq 64) 'Edited build records exact section snapshot'
    $doc.ZIP_SHA256='A'*64;Reject {New-DeploymentPackage $s -EditorDocument $doc} 'Stale ZIP editor document cannot build'
    $s.SectionTemplatePath=Join-Path $app.OutputDirectory 'Sections.psadt.json'
    $app2=New-DeploymentPackage $s
    Check ((Get-Content (Join-Path $app2.SourcePath 'Invoke-AppDeployToolkit.ps1') -Raw).Contains('Edited install must not execute')) 'Reusable template works without live UI document'
    foreach ($dir in $script:protected|Where-Object { $_ -like '*PSADT-Editor-*' }) {Check (-not (Test-Path $dir)) 'Editor extraction always cleaned'}
    Write-Output "PASS: $count maintenance and editor build assertions. Host, native servicing, signatures and ACL application mocked; real packaging and runtime decisions exercised."
} finally {$env:ProgramData=$oldData;$env:WINDIR=$oldWindir;Remove-Item -LiteralPath $temp -Recurse -Force}
