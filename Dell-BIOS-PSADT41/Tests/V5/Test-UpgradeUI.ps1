# Exercise the real async upgrade handlers with inert controls and EXE payloads.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('UpgradeUI-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp);$count=0;$oldData=$env:ProgramData;$env:ProgramData=$temp
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Write-Fixture($Path,$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
try {
 . "$root/Builder/Build-Package.ps1"
 function Protect-BuilderDirectory($Path){}
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Upgrade-UI.ps1",[ref]$t,[ref]$e)
 $engine=Join-Path $temp 'Engine.ps1';Write-Fixture $engine (". '"+"$root/Builder/Build-Package.ps1".Replace("'","''")+"'`nfunction Protect-BuilderDirectory(`$Path) {}`n")
 foreach ($name in @('Start-UpgradeDialogWork','Reset-UpgradeDialogReview')) {
  $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  $text=$fn.Extent.Text.Replace("(Join-Path `$PSScriptRoot 'Build-Package.ps1')",("'"+$engine.Replace("'","''")+"'"));. ([scriptblock]::Create($text))
 }
 function Get-UIHandler($Expression,$Method){return $ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq $Expression -and $n.Member.Value -eq $Method},$true).Arguments[0].ScriptBlock.GetScriptBlock()}
 $tick=Get-UIHandler '$timer' 'Add_Tick';$analyze=Get-UIHandler '$c.Analyze' 'Add_Click';$apply=Get-UIHandler '$c.Apply' 'Add_Click';$closing=Get-UIHandler '$dialog' 'Add_Closing'
 $c=@{};foreach($name in @('Inputs','OldInstaller','NewInstaller','KeepName','OldTransform','NewTransform','Edits','Identity','Reviewed','Status','Progress','Apply')) {
  $c[$name]=[pscustomobject]@{IsEnabled=$true;IsChecked=$false;Text='';SelectedIndex=-1;SelectedItem='';Items=(New-Object Collections.ArrayList);ItemsSource=$null;Visibility='Collapsed';IsIndeterminate=$false}
 }
 $c.Edits|Add-Member ScriptMethod CommitEdit {return $true}
 $window=[pscustomobject]@{Closed=$false};$window|Add-Member ScriptMethod Close {$this.Closed=$true}
 $script:upgradeDialog=@{Controls=$c;Window=$window;Job=$null;Workspace=$null;Plan=$null;Result=$null;Closing=$false}
 function Finish-Operation {
  if (-not $script:upgradeDialog.Job.Handle.AsyncWaitHandle.WaitOne(10000)) {throw 'Async operation timed out'}
  & $tick
  Check ($null -eq $script:upgradeDialog.Job -and -not $c.Progress.IsIndeterminate) 'Worker always disposes and clears progress'
 }
 $source=Join-Path $temp 'Source';Write-Fixture (Join-Path $source 'Deploy-Application.ps1') "param([string]`$DeploymentType,[string]`$DeployMode)`nStart-Process 'old.exe'"
 Write-Fixture (Join-Path $source 'Files/old.exe') 'old'
 $zip=Join-Path $temp 'Input.zip';Add-Type -AssemblyName System.IO.Compression.FileSystem;[IO.Compression.ZipFile]::CreateFromDirectory($source,$zip)
 $snapshot=New-AuthoringSnapshot (Read-EditorPackage $zip)
 Start-UpgradeDialogWork Prepare @{Snapshot=$snapshot;OutputRoot=$temp};Finish-Operation
 Check ($c.OldInstaller.Items[0] -eq 'Files/old.exe' -and $c.Inputs.IsEnabled) 'Prepared package inventory reaches the dialog'
 $replacement=Join-Path $temp 'new.exe';Write-Fixture $replacement 'new'
 $c.OldInstaller.SelectedItem='Files/old.exe';$c.NewInstaller.Text=$replacement;$c.OldTransform.SelectedIndex=0
 & $analyze;Finish-Operation
 Check ($null -ne $script:upgradeDialog.Plan -and $c.Edits.ItemsSource.Count -eq 1 -and $c.Apply.IsEnabled) 'Analyzed replacement reaches editable review grid'
 $c.Reviewed.IsChecked=$false;& $apply;Finish-Operation
 Check (-not $window.Closed -and $null -eq $script:upgradeDialog.Result -and $c.Status.Text.Contains('Review')) ('Unacknowledged review fails visibly and keeps dialog open: '+$c.Status.Text+'; closed='+$window.Closed)
 $c.Reviewed.IsChecked=$true;& $apply;Finish-Operation
 Check ($window.Closed -and $null -ne $script:upgradeDialog.Result -and (Get-EditorDocumentText $script:upgradeDialog.Result.Document).Contains('new.exe')) 'Apply creates ZIP, returns loaded document and closes only after cleanup'
 $script:upgradeDialog.Job=@{Inert=$true};$event=[pscustomobject]@{Cancel=$false};& $closing $window $event
 Check ($event.Cancel -and $script:upgradeDialog.Closing) 'Close during worker requests graceful completion'
 $script:upgradeDialog.Job=$null;Reset-UpgradeDialogReview
 Check ($null -eq $script:upgradeDialog.Plan -and -not $c.Apply.IsEnabled -and -not $c.Reviewed.IsChecked) 'Changed selections invalidate old approval and plan'
 # Failed analysis must restore inputs and display a safe, actionable error.
 $script:upgradeDialog.Closing=$false;$window.Closed=$false;$c.OldInstaller.SelectedItem='../old.exe'
 & $analyze;Finish-Operation
 Check ($c.Status.Text.Contains('Choose an existing MSI or EXE') -and $c.Inputs.IsEnabled -and -not $c.Apply.IsEnabled) 'Analysis validation error reaches dialog without EndInvoke wrapper'
 Write-Output "PASS: $count upgrade-dialog assertions. Real background worker and callbacks; WPF controls/ACLs inert, no installers run."
} finally {$env:ProgramData=$oldData;if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
