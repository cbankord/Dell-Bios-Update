# Real archive/script IO with only Windows host/ACL operations mocked. No imported app runs.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ZipEditor-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp);$oldData=$env:ProgramData;$env:ProgramData=$temp
$count=0
function Check($Value,$Name) {$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try{$null=& $Body}catch{$failed=$true};Check $failed $Name}
function Write-Fixture($Path,$Text) {$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function New-Zip($Folder) {$path=Join-Path $temp ([guid]::NewGuid().ToString()+'.zip');[IO.Compression.ZipFile]::CreateFromDirectory($Folder,$path);return $path}
function New-LegacyFixture {
    $text=@'
param([string]$DeploymentType='Install')
try {
    [string]$appVendor='Example'
    [string]$appName='Legacy application'
    [string]$appVersion='1.0'
    $CustomSetting=$(throw 'Metadata must never execute')
    [string]$appScriptAuthor='Original author'
    function Get-Helper { 'Original helper' }
'@
    foreach($verb in @('Install','Uninstall','Repair')) {
        $condition=if($verb -eq 'Install'){"if (`$DeploymentType -eq 'Install')"}else{"elseif (`$DeploymentType -eq '$verb')"}
        $main=switch($verb){Install{'Installation'} Uninstall{'Uninstallation'} Repair{'Repair'}}
        $text+="`n    $condition {`n"
        foreach($phase in @(('Pre-'+$main),$main,('Post-'+$main))) { $text+="        [string]`$installPhase = '$phase'`n        Write-Output '$phase original'`n" }
        $text+="    }`n"
    }
    $text+="    throw 'Bootstrap must never execute'`n} catch { throw }`n"
    return $text
}
try {
    . "$root/Builder/Build-Package.ps1"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Assert-BuilderHost {}
    $script:protected=New-Object 'Collections.Generic.List[string]'
    function Protect-BuilderDirectory($Path) {$script:protected.Add($Path)}
    $legacy=New-LegacyFixture
    $doc=New-EditorTextDocument $legacy
    Check ($doc.LayoutKind -eq 'Sections' -and $doc.MetadataKind -eq 'Variables' -and $doc.Sections.Count -eq 10) 'Legacy variables and all nine phases load without adtSession'
    Check ((Get-EditorDocumentText $doc) -ceq $legacy) 'Unchanged legacy script round-trips byte-for-byte as text'
    $fields=Get-EditorMetadataFields $doc.MetadataText $doc.MetadataKind
    Check ($fields.AppName.Value -eq 'Legacy application' -and -not $fields.CustomSetting.Literal) 'Legacy literal and calculated values inspected without execution'
    $doc.MetadataText=Set-EditorMetadataValues $doc.MetadataText @{AppName="New 'name' `$literal";AppScriptAuthor='New author';AppLang='EN'} $doc.MetadataKind
    $before=Get-EditorSections $legacy
    foreach($key in Get-EditorSectionNames) { $doc.Sections[$key]=if($key -eq 'CustomFunctions'){"function Get-Helper { 'Edited helper' }"}else{"Write-Output '$key edited'"} }
    $edited=Get-EditorDocumentText $doc;$after=Get-EditorSections $edited
    foreach($key in Get-EditorSectionNames) { Check ($after[$key].Contains('edited') -or $after[$key].Contains('Edited helper')) "$key legacy edit reaches correct phase" }
    $meta=Get-EditorMetadataFields ((Get-LegacyMetadataLayout $edited).Text) 'Variables'
    Check ($meta.AppName.Value -ceq "New 'name' `$literal" -and $meta.AppScriptAuthor.Value -eq 'New author' -and $meta.AppLang.Value -eq 'EN') 'Legacy metadata quotes correctly and adds missing fields'
    Check ($edited.Contains("throw 'Bootstrap must never execute'") -and $edited.Contains("throw 'Metadata must never execute'")) 'Legacy bootstrap and custom calculated settings retained'
    Reject {Set-LegacyMetadataValues $doc.MetadataText @{AppName="bad`nvalue"}} 'Control characters cannot escape metadata form'
    Reject {Get-LegacyMetadataAssignments "`$appName='a';`$appName='b'"} 'Duplicate legacy metadata names rejected'
    $tokens=$null;$errors=$null
    $fixtureAst=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/Test-SectionEditor.ps1",[ref]$tokens,[ref]$errors)
    $fn=$fixtureAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-SectionFixture'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $modern=New-SectionFixture
    $calculated=$modern.Replace("`$adtSession = @{AppName='Existing identity'}","`$adtSession = Get-CalculatedSession")
    # Fixture spelling can omit spaces; ensure the metadata assignment really changed.
    $calculated=$calculated.Replace("`$adtSession=@{AppName='Existing identity'}","`$adtSession=Get-CalculatedSession")
    $calculatedDoc=New-EditorTextDocument $calculated
    Check ($calculatedDoc.LayoutKind -eq 'Sections' -and $calculatedDoc.MetadataUnavailable -and -not $calculatedDoc.Contains('MetadataText')) 'Calculated metadata does not prevent section editing'
    Check ((Get-EditorDocumentText $calculatedDoc) -ceq $calculated) 'Calculated metadata preserved without execution or replacement'
    $typed=$modern.Replace('$adtSession =','[hashtable]$script:adtSession =').Replace('$adtSession=@{','[hashtable]$script:adtSession=@{')
    $typedDoc=New-EditorTextDocument $typed
    Check ($typedDoc.MetadataKind -eq 'Table') 'Typed script-scoped adtSession metadata recognized'
    $wrapped="try {`n$modern`n} catch { throw }"
    Check ((Get-EditorMetadataLayout $wrapped).Extent.Text.Contains('AppName')) 'Script-level try wrapper allows literal metadata inspection'
    $custom="`$appName='Custom app'`nthrow 'Custom source never executes'"
    $raw=New-EditorTextDocument $custom
    Check ($raw.LayoutKind -eq 'FullScript' -and (Get-EditorDocumentText $raw) -ceq $custom) 'Unmapped layout opens as exact full script'
    $raw.CurrentScript+="`n# reviewed custom change"
    Check (Test-EditorDocumentDirty $raw) 'Full-script changes tracked'
    $raw.CurrentScript='if (';Reject {Get-EditorDocumentText $raw} 'Full-script syntax errors block save/build'
    $signed=New-EditorTextDocument ($custom+"`n# SIG # Begin signature block");$signed.CurrentScript+="`n# change"
    Reject {Get-EditorDocumentText $signed} 'Full-script fallback cannot bypass signed source guard'
    $legacyRoot=Join-Path $temp 'Legacy/Wrapper/App'
    Write-Fixture (Join-Path $legacyRoot 'Deploy-Application.ps1') $legacy
    Write-Fixture (Join-Path $legacyRoot 'AppDeployToolkit/AppDeployToolkitMain.ps1') "throw 'Never run framework'"
    Write-Fixture (Join-Path $legacyRoot 'AppDeployToolkit/AppDeployToolkitConfig.xml') '<config />'
    Write-Fixture (Join-Path $legacyRoot 'Files/payload.txt') 'Unchanged payload'
    $zip=New-Zip (Join-Path $temp 'Legacy');$zipHash=(Get-FileHash $zip).Hash
    $loaded=Read-EditorPackage $zip
    Check ($loaded.EntryScript -eq 'Deploy-Application.ps1' -and $loaded.EntryPath -eq 'Wrapper/App/Deploy-Application.ps1' -and $loaded.Editable) 'Wrapped legacy ZIP entry selected automatically and editable'
    $s=New-PackageBuildSettings;$s.PackageType='Application';$s.FrameworkZip=$zip;$s.ApplicationName='Legacy package';$s.ApplicationVersion='1.0';$s.UseEditor=$true;$s.PackageReviewed=$true;$s.OutputRoot=$temp
    $noop=New-DeploymentPackage $s -EditorDocument $loaded
    Check ((Get-FileHash (Join-Path $noop.SourcePath 'Deploy-Application.ps1')).Hash -eq (Get-FileHash (Join-Path $legacyRoot 'Deploy-Application.ps1')).Hash) 'Legacy no-op editor build preserves original bytes'
    $loaded.MetadataText=Set-EditorMetadataValues $loaded.MetadataText @{AppName='Edited legacy ZIP'} 'Variables'
    $loaded.Sections.Install="Write-Output 'Legacy install edit'"
    $built=New-DeploymentPackage $s -EditorDocument $loaded
    $entry=Read-EditorScript (Join-Path $built.SourcePath 'Deploy-Application.ps1')
    Check ($entry.Contains('Edited legacy ZIP') -and $entry.Contains('Legacy install edit')) 'Legacy metadata and sections both applied to built Source'
    Check ((Get-Content (Join-Path $built.SourcePath 'Files/payload.txt') -Raw) -eq 'Unchanged payload' -and (Get-FileHash $zip).Hash -eq $zipHash) 'Payload and original ZIP preserved'
    $manifest=Get-Content (Join-Path $built.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
    Check ($manifest.EditorLayout -eq 'Sections' -and $manifest.EntryScriptSHA256 -eq (Get-FileHash (Join-Path $built.SourcePath 'Deploy-Application.ps1')).Hash) 'Legacy build records actual entry and section mode'
    Write-Fixture (Join-Path $legacyRoot 'Deploy-Application.ps1') $custom
    $s.FrameworkZip=New-Zip (Join-Path $temp 'Legacy');$rawZip=Read-EditorPackage $s.FrameworkZip;$rawZip.CurrentScript+="`n# Approved raw edit"
    $built=New-DeploymentPackage $s -EditorDocument $rawZip
    Check ((Read-EditorScript (Join-Path $built.SourcePath 'Deploy-Application.ps1')).Contains('Approved raw edit')) 'Full-script fallback builds approved text through application mode'
    Check (-not (Test-Path (Join-Path $built.OutputDirectory 'Sections.psadt.json'))) 'Full-script mode does not generate a misleading section template'
    $rawZip.ZIP_SHA256='A'*64;Reject {New-DeploymentPackage $s -EditorDocument $rawZip} 'Full-script builds retain stale ZIP protection'
    $draft=Join-Path $temp 'Draft'
    Write-Fixture (Join-Path $draft 'Invoke-AppDeployToolkit.ps1') $modern
    $draftZip=New-Zip $draft;$draftDoc=Read-EditorPackage $draftZip
    Check ($draftDoc.EntryScript -eq 'Invoke-AppDeployToolkit.ps1' -and $draftDoc.MetadataKind -eq 'Table') 'Template ZIP opens for authoring before framework packaging validation'
    $s.FrameworkZip=$draftZip;Reject {New-DeploymentPackage $s -EditorDocument $draftDoc} 'Incomplete authoring ZIP still fails complete-package build validation'
    Write-Fixture (Join-Path $draft 'other/Deploy-Application.ps1') $legacy
    Reject {Read-EditorPackage (New-Zip $draft)} 'Ambiguous archive never silently selects a deployment'
    $calculatedPath=Join-Path $temp 'Calculated.ps1';Write-Fixture $calculatedPath $calculated
    $direct=Read-EditorScriptDocument $calculatedPath;$direct.Editable=$true;$direct.Sections.Install="Write-Output 'New install'"
    $save=Save-EditorScriptDocument $direct $calculatedPath
    Check ($save.Changed -and (Read-EditorScript $calculatedPath).Contains('Get-CalculatedSession')) 'Calculated metadata PS1 can save phase changes with its original metadata intact'
    foreach($path in $script:protected|Where-Object {$_ -like '*PSADT-Editor-*'}) {Check (-not (Test-Path $path)) 'ZIP editor extraction cleaned'}
    Write-Output "PASS: $count ZIP/legacy/fallback editor assertions. Imported code not executed; Windows host and ACL boundaries mocked."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
