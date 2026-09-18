# Real source copies/ZIP/builds and AST review. MSI COM and Windows ACL boundaries mocked.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('UpgradeTests-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp);$count=0;$oldData=$env:ProgramData;$env:ProgramData=$temp
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Code,$Name){$failed=$false;try {$null=& $Code} catch {$failed=$true};Check $failed $Name}
function Write-Fixture($Path,$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
try {
 . "$root/Builder/Build-Package.ps1"
 function Protect-BuilderDirectory($Path) {}
 function Assert-BuilderHost {}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Tests/V4/Test-SectionEditor.ps1",[ref]$t,[ref]$e)
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-SectionFixture'},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
 $oldCode='{11111111-1111-1111-1111-111111111111}';$newCode='{22222222-2222-2222-2222-222222222222}'
 $text=(New-SectionFixture).Replace("AppName='Existing identity'","AppName='Existing identity';AppVersion='1.0.0'")
 $sections=Get-EditorSections $text
 $sections.PreInstall="Start-ADTMsiProcess -Action Uninstall -FilePath '$oldCode'"
 $sections.Install='Start-ADTMsiProcess -Action Install -FilePath "$($adtSession.DirFiles)\Old.msi"' # Nested expression intentionally requires keep-name or explicit editing.
 $prefix=Set-EditorSections $text $sections
 Check ((Apply-UpgradeReferencePlan $prefix (New-UpgradeReferencePlan $prefix 'Old.msi' 'New.msi')).Contains('$($adtSession.DirFiles)\New.msi')) 'Calculated directory prefix preserved while literal filename changes'
 $sections.Install='Start-ADTMsiProcess -Action Install -FilePath $calculatedInstaller'
 $dynamic=Set-EditorSections $text $sections
 Check ((New-UpgradeReferencePlan $dynamic 'Old.msi' 'New.msi').Count -eq 0) 'Calculated installer filename is not guessed'
 $sections.Install='Start-ADTMsiProcess -Action Install -FilePath "$dirFiles\Old.msi"'
 $sections.Uninstall="Start-ADTMsiProcess -Action Uninstall -FilePath '$oldCode'"
 $sections.Repair="Start-ADTMsiProcess -Action Repair -FilePath '$oldCode'"
 $text=Set-EditorSections $text $sections
 $edits=New-UpgradeReferencePlan $text 'Old.msi' 'New Setup.msi' $oldCode $newCode
 Check ($edits.Count -eq 4) 'Literal filename and all three product-code occurrences mapped'
 Check (@($edits|Where-Object {$_.Phase -eq 'PreInstall' -and -not $_.Selected}).Count -eq 1) 'Old-version pre-install removal is preserved by default'
 $rewritten=Apply-UpgradeReferencePlan $text $edits
 Check ($rewritten.Contains('New Setup.msi') -and $rewritten.Contains("Uninstall -FilePath '$oldCode'")) 'Install filename updated while old cleanup code remains'
 Check ([regex]::Matches($rewritten,[regex]::Escape($newCode)).Count -eq 2) 'Uninstall and repair target the replacement product'
 $bare="Start-Process Old.msi`n# Old.msi`nWrite-Output 'OtherOld.msi.bak'"
 $bareEdits=New-UpgradeReferencePlan $bare 'Old.msi' 'New Setup.msi'
 $bareResult=Apply-UpgradeReferencePlan $bare $bareEdits
 Check ($bareEdits.Count -eq 1 -and $bareResult.Contains("Start-Process 'New Setup.msi'") -and $bareResult.Contains('# Old.msi')) 'Bare arguments quoted; comments and filename substrings unchanged'
 $duplicate=New-UpgradeReferencePlan "Write-Output 'Old.msi'" 'Old.msi' 'New.msi'
 $duplicate[0].Selected=$true
 Reject {Apply-UpgradeReferencePlan "Write-Output 'Old.msi'" @($duplicate[0],$duplicate[0])} 'Overlapping selected edits refused'
 Reject {Apply-UpgradeReferencePlan 'different text' $edits} 'Stale script review refused'
 $logOnly=New-UpgradeReferencePlan "Write-ADTLog 'Installing Old.msi'" 'Old.msi' 'New.msi'
 Check (-not $logOnly[0].Selected -and -not $logOnly[0].CanDriveInstall) 'Log text is not an installation reference or an automatically selected change'
 $assigned=New-UpgradeReferencePlan "`$installer='Old.msi'" 'Old.msi' 'New.msi'
 Check (-not $assigned[0].Selected -and $assigned[0].CanDriveInstall) 'Assignments are available for explicit review without guessing data flow'
 $folder=Join-Path $temp 'Original';Write-Fixture (Join-Path $folder 'Invoke-AppDeployToolkit.ps1') $text
 Write-Fixture (Join-Path $folder 'Invoke-AppDeployToolkit.exe') 'INERT'
 Write-Fixture (Join-Path $folder 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') "@{ModuleVersion='4.1.8';RootModule='PSAppDeployToolkit.psm1'}"
 Write-Fixture (Join-Path $folder 'PSAppDeployToolkit/PSAppDeployToolkit.psm1') "throw 'NEVER IMPORT'"
 Write-Fixture (Join-Path $folder 'Files/Old.msi') 'old'
 Write-Fixture (Join-Path $folder 'Files/keep.txt') 'unchanged'
 $zip=Join-Path $temp 'original.zip';[IO.Compression.ZipFile]::CreateFromDirectory($folder,$zip);$originalHash=(Get-FileHash $zip).Hash
 $replacement=Join-Path $temp 'New Setup.msi';Write-Fixture $replacement 'new'
 function Read-UpgradeMsi([string]$Path) {
  $old=[IO.File]::ReadAllText($Path) -eq 'old'
  return @{ProductCode=$(if ($old) {$oldCode} else {$newCode});ProductVersion=$(if ($old) {'1.0.0'} else {'2.0.0'});UpgradeCode='{33333333-3333-3333-3333-333333333333}';ProductLanguage='1033';Template='x64;1033';ExternalMedia=$false}
 }
 $doc=Read-EditorPackage $zip;$snapshot=New-AuthoringSnapshot $doc;$work=New-UpgradeWorkspace $snapshot $temp
 Check ($work.Text -ceq $text -and @(Get-UpgradeInstallFiles $work).Count -eq 1) 'Workspace contains the selected complete package and payload inventory'
 $plan=New-PackageUpgradePlan $work 'Files/Old.msi' $replacement
 Reject {Complete-PackageUpgrade $work $plan} 'Apply requires review acknowledgement'
 $plan.Reviewed=$true;$built=Complete-PackageUpgrade $work $plan
 $updated=Get-EditorDocumentText $built.Document
 Check ($updated.Contains('New Setup.msi') -and $updated.Contains("AppVersion='2.0.0'")) 'Upgraded ZIP loads automatically with matching literal AppVersion updated'
 Check (-not (Test-Path (Join-Path $built.Source 'Files/Old.msi')) -and [IO.File]::ReadAllText((Join-Path $built.Source 'Files/New Setup.msi')) -eq 'new') 'Unused old payload removed and selected replacement packaged'
 Check ([IO.File]::ReadAllText((Join-Path $built.Source 'Files/keep.txt')) -eq 'unchanged' -and (Get-FileHash $zip).Hash -eq $originalHash) 'Other files and original ZIP preserved'
 $record=[IO.File]::ReadAllText((Join-Path $built.Source 'PSADT-Upgrade.json'))
 Check ($record -notmatch 'Start-ADTMsiProcess|Before|After|Value' -and $built.Record.DetectionReviewRequired) 'Upgrade record contains no script expressions or transform property values'
 $settings=New-PackageBuildSettings;$settings.PackageType='Application';$settings.FrameworkZip=$built.Zip;$settings.OutputRoot=$temp;$settings.ApplicationName='Fixture';$settings.ApplicationVersion='2.0.0';$settings.PackageReviewed=$true
 $package=New-DeploymentPackage $settings
 $manifest=Get-Content (Join-Path $package.OutputDirectory 'BuildManifest.json') -Raw|ConvertFrom-Json
 Check ($manifest.BuilderVersion -eq '5.0.0' -and $manifest.UpgradeRecordSHA256 -eq (Get-FileHash (Join-Path $built.Source 'PSADT-Upgrade.json')).Hash) 'Normal build retains upgrade provenance'
 $plan.NewHash='0'*64;Reject {Complete-PackageUpgrade $work $plan} 'Changed reviewed payload blocks application'
 $plan=New-PackageUpgradePlan $work 'Files/Old.msi' $replacement;$plan.Reviewed=$true
 foreach ($edit in $plan.Edits) {$edit.Selected=$false}
 Reject {Complete-PackageUpgrade $work $plan} 'Changing only payload with no installation reference selected is refused'
 $work.Text=$dynamic
 Reject {New-PackageUpgradePlan $work 'Files/Old.msi' $replacement} 'Calculated reference requests explicit keep-name choice'
 $same=New-PackageUpgradePlan $work 'Files/Old.msi' $replacement $true;$same.Reviewed=$true
 $sameResult=Complete-PackageUpgrade $work $same
 Check ([IO.File]::ReadAllText((Join-Path $sameResult.Source 'Files/Old.msi')) -eq 'new') 'Keep-name mode supports calculated references without guessing script changes'
 $work.Text=$text;$work.Signed=$true
 Reject {New-PackageUpgradePlan $work 'Files/Old.msi' $replacement} 'Signed scripts are never silently modified';$work.Signed=$false
 Reject {New-PackageUpgradePlan $work '../Old.msi' $replacement} 'Source traversal rejected by package inventory'
 Write-Fixture (Join-Path $work.Source 'Files/Other/Old.msi') 'other'
 Reject {New-PackageUpgradePlan $work 'Files/Old.msi' $replacement} 'Duplicate payload filenames require manual resolution'
 Remove-Item (Join-Path $work.Source 'Files/Other') -Recurse -Force
 $snapshot.SourceHash='F'*64;Reject {New-UpgradeWorkspace $snapshot $temp} 'Changed-on-disk ZIP cannot seed a replacement workspace'
 $rows=@(@{Table='Property';Column='Value';Row='SERVER'})
 $delta=Get-UpgradePropertyDelta $rows @{SERVER='old';ProductCode=$oldCode} @{SERVER='new';ProductCode=$oldCode}
 Check ($delta.Count -eq 1 -and $delta[0].Name -eq 'SERVER' -and $delta[0].Value -eq 'new') 'Only intentional transform Property deltas are migrated'
 Reject {Get-UpgradePropertyDelta @(@{Table='CustomAction';Column='Target';Row='Run'}) @{} @{}} 'Transforms changing custom actions require replacement MST'
 Reject {Get-UpgradePropertyDelta @(@{Table='Property';Column='Value';Row='ProductCode'}) @{ProductCode=$oldCode} @{ProductCode=$newCode}} 'Transform identity changes are never carried forward'
 $family=Read-UpgradeMsi (Join-Path $folder 'Files/Old.msi');$other=$family.Clone();$other.UpgradeCode=$newCode
 Reject {Assert-UpgradeMsiFamily $family $other} 'Different product families cannot receive automatically migrated MSTs'
 $other=$family.Clone();$other.Template='Intel;1033';Reject {Assert-UpgradeMsiFamily $family $other} 'Cross-architecture automatic transform migration refused'
 $work.Text=$text.Replace('Old.msi"','Old.msi" -Transforms "settings.mst"')
 Reject {New-PackageUpgradePlan $work 'Files/Old.msi' $replacement} 'Referenced MST cannot silently be skipped'
 Write-Fixture (Join-Path $work.Source 'Files/settings.mst') 'old mst'
 function New-UpgradeTransform($OldMsi,$NewMsi,$OldMst,$Destination,$Work){Write-Fixture $Destination 'generated mst';return @('SERVER')}
 function Test-UpgradeTransform($Msi,$Mst,$Work){}
 $mst=New-PackageUpgradePlan $work 'Files/Old.msi' $replacement $false 'Files/settings.mst';$mst.Reviewed=$true
 $mstResult=Complete-PackageUpgrade $work $mst
 Check ((Get-EditorDocumentText $mstResult.Document).Contains('New Setup-v5.mst') -and (Test-Path (Join-Path $mstResult.Source 'Files/New Setup-v5.mst'))) 'Migrated MST file and command reference stay together'
 Check ($mstResult.Record.TransformMode -eq 'PropertyMigration' -and $mstResult.Record.PropertyNames[0] -eq 'SERVER') 'MST provenance records property names only'
 Write-Fixture $mst.MstFile 'tampered';Reject {Complete-PackageUpgrade $work $mst} 'Changed reviewed transform blocked'
 Write-Output "PASS: $count package-upgrade assertions. Real ZIP/copy/build/AST flows; MSI COM and Windows ACLs mocked; no installers run."
} finally {$env:ProgramData=$oldData;if (Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
