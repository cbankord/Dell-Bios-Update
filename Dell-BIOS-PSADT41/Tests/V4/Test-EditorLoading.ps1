# Actual async loader, completion/polling and editor state, with inert UI controls.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EditorLoading-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp);$oldData=$env:ProgramData;$env:ProgramData=$temp
$count=0
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Write-Fixture($Path,$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
function Import-Function($Ast,$Name){$fn=$Ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true);return [scriptblock]::Create($fn.Extent.Text)}
try {
    . "$root/Builder/Build-Package.ps1"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tokens=$null;$errors=$null
    $editorAst=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Editor-UI.ps1",[ref]$tokens,[ref]$errors)
    $mainAst=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$tokens,[ref]$errors)
    $fixtureAst=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/Test-ZipEditor.ps1",[ref]$tokens,[ref]$errors)
    . (Import-Function $fixtureAst 'New-LegacyFixture')
    foreach($name in @('Get-EditorLoadSettings','Complete-EditorLoad','Set-EditorDocument','Set-EditorAvailability','Clear-EditorDocument','Test-EditorDirectDocument','Save-EditorBuffer','Get-ActiveEditorDocument')) { . (Import-Function $editorAst $name) }
    . (Import-Function $mainAst 'Set-BuilderBusy')
    # The real worker imports the real engine; only its Windows ACL boundary is replaced.
    $engine=Join-Path $temp 'Engine.ps1'
    Write-Fixture $engine (". '"+"$root/Builder/Build-Package.ps1".Replace("'","''")+"'`nfunction Protect-BuilderDirectory(`$Path) {}`n")
    $loader=(Import-Function $editorAst 'Start-EditorPackageLoad').ToString().Replace("(Join-Path `$PSScriptRoot 'Build-Package.ps1')",("'"+$engine.Replace("'","''")+"'"))
    . ([scriptblock]::Create($loader))
    $tick=$mainAst.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$timer' -and $n.Member.Value -eq 'Add_Tick'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $tabSelected=$editorAst.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$controls.EditorTab' -and $n.Member.Value -eq 'Add_Selected'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $controls=@{}
    foreach($name in @('FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','OutputPanel','Reviewed','BuildButton','LoadButton','SaveButton','OpenButton','Progress','BuildLog','EditorMode','EditorLoad','EditorImport','EditorSave','EditorValidate','EditorHost','SectionList','EditorStatus','EditorOpenScript','EditorOpenZip','EditorEditScript','EditorSaveScript','EditorSaveScriptAs','EditorCloseScript','EditorDocumentLabel','MetadataView','MetadataFields','EditorTab')) {
        $controls[$name]=[pscustomobject]@{IsEnabled=$true;IsChecked=$false;SelectedIndex=0;Text='';Visibility='Visible';IsSelected=$false;IsIndeterminate=$false;Items=(New-Object Collections.ArrayList);Children=(New-Object Collections.ArrayList)}
    }
    $controls.BuildLog|Add-Member ScriptMethod AppendText {param($text)$this.Text+=$text}
    $controls.BuildLog|Add-Member ScriptMethod ScrollToEnd {}
    $script:fields=@{PackageType=[pscustomobject]@{SelectedValue='BIOS'};UseEditor=[pscustomobject]@{IsChecked=$false}}
    foreach($name in @('FrameworkZip','ApplicationName','ApplicationVersion','SectionTemplatePath')) {$script:fields[$name]=[pscustomobject]@{Text=''}}
    $script:editorBox=[pscustomobject]@{Text='';ReadOnly=$true};$script:editorDocument=$null;$script:editorSection='';$script:metadataEdits=@{};$script:job=$null;$script:lastOutput='';$script:closeRequested=$false
    $labels=@('Custom / functions','Pre install','Install','Post install','Pre uninstall','Uninstall','Post uninstall','Pre repair','Repair','Post repair');$names=@(Get-EditorSectionNames)
    function Confirm-EditorReplacement {return $true}
    function Get-FormSettings {throw 'Opening a script/ZIP must not validate unrelated build fields'}
    function Finish-Load {
        if ($null -eq $script:job) {throw ('No async job: '+$controls.EditorStatus.Text)}
        if (-not $script:job.Handle.AsyncWaitHandle.WaitOne(10000)) {throw 'Editor load timed out'}
        & $tick
        Check ($null -eq $script:job -and $controls.EditorPanel.IsEnabled) 'Async load always disposes worker and restores controls'
    }
    $folder=Join-Path $temp 'Input';Write-Fixture (Join-Path $folder 'Deploy-Application.ps1') (New-LegacyFixture)
    $zip=Join-Path $temp 'App.zip';[IO.Compression.ZipFile]::CreateFromDirectory($folder,$zip)
    Set-EditorAvailability
    Check ($controls.EditorOpenZip.IsEnabled -and $controls.EditorLoad.IsEnabled) 'ZIP actions available before choosing Editor or package type'
    Start-EditorPackageLoad -ZipPath $zip
    Check ($script:fields.PackageType.SelectedValue -eq 'BIOS') 'Opening does not change package mode before the worker succeeds'
    Finish-Load
    Check ($script:fields.PackageType.SelectedValue -eq 'Application' -and $controls.EditorMode.SelectedIndex -eq 1 -and $script:fields.UseEditor.IsChecked -and $controls.EditorTab.IsSelected) 'Open ZIP automatically activates application authoring and Editor view'
    Check ($script:editorDocument.EntryScript -eq 'Deploy-Application.ps1' -and -not $script:editorBox.ReadOnly -and $controls.SectionList.Items.Count -eq 12) 'Legacy ZIP opens editable metadata, settings and all ten sections'
    Check ($script:fields.FrameworkZip.Text -eq $zip -and $script:fields.ApplicationName.Text -eq 'Legacy application' -and $script:fields.ApplicationVersion.Text -eq '1.0') 'Loaded archive and literal identity populate package fields'
    & $tabSelected $controls.EditorTab ([pscustomobject]@{OriginalSource=$controls.EditorTab})
    Check ($null -eq $script:job) 'Revisiting Editor does not overwrite an existing document'
    Clear-EditorDocument
    & $tabSelected $controls.EditorTab ([pscustomobject]@{OriginalSource=$controls.EditorTab})
    Finish-Load
    Check ($script:editorDocument.SourceKind -eq 'ZIP' -and $controls.EditorMode.SelectedIndex -eq 1) 'Entering empty Editor automatically loads the selected ZIP'
    $prior=$script:editorDocument
    Write-Fixture (Join-Path $folder 'Other/Invoke-AppDeployToolkit.ps1') "throw 'inert'"
    $ambiguous=Join-Path $temp 'Ambiguous.zip';[IO.Compression.ZipFile]::CreateFromDirectory($folder,$ambiguous)
    Start-EditorPackageLoad -ZipPath $ambiguous;Finish-Load
    Check ([object]::ReferenceEquals($prior,$script:editorDocument) -and $script:fields.FrameworkZip.Text -eq $zip) 'Failed ZIP open retains the previous document and package selection'
    Check ($controls.EditorStatus.Text.Contains('one Invoke-AppDeployToolkit.ps1') -and -not $controls.EditorStatus.Text.Contains('EndInvoke')) 'Known load error is readable without EndInvoke wrapper'
    $scriptPath=Join-Path $temp 'Custom.ps1';Write-Fixture $scriptPath "`$adtSession = Get-SessionSettings`nthrow 'No import execution'"
    Start-EditorPackageLoad -ScriptPath $scriptPath;Finish-Load
    Check ($script:editorDocument.LayoutKind -eq 'FullScript' -and $controls.SectionList.Items.Count -eq 1 -and $controls.SectionList.Items[0].Value -eq 'FullScript') 'Nonstandard PS1 opens complete text instead of a metadata error'
    Check ($controls.EditorMode.SelectedIndex -eq 1 -and $script:editorBox.ReadOnly -and $controls.EditorEditScript.IsEnabled -and -not $controls.EditorSave.IsEnabled) 'Direct PS1 keeps explicit EDIT and disables incompatible section templates'
    $script:editorDocument.Editable=$true;$script:editorSection='FullScript';$script:editorBox.Text=$script:editorDocument.CurrentScript+"`n# edit";Save-EditorBuffer
    Check ($script:editorDocument.CurrentScript.EndsWith('# edit')) 'Full-script buffer commits changes'
    Set-EditorAvailability
    Check ($controls.EditorSaveScript.IsEnabled -and $controls.EditorSaveScriptAs.IsEnabled -and -not $controls.EditorImport.IsEnabled) 'Full-script direct save enabled without section-template replacement'
    Write-Fixture $scriptPath 'if ('
    Start-EditorPackageLoad -ScriptPath $scriptPath;Finish-Load
    Check ($controls.EditorStatus.Text.Contains('syntax errors') -and -not $controls.EditorStatus.Text.Contains('EndInvoke')) 'Syntax load failure is clean and retains the editable document'
    $rawFolder=Join-Path $temp 'Raw';Write-Fixture (Join-Path $rawFolder 'Invoke-AppDeployToolkit.ps1') "throw 'Custom source never executes'"
    $rawArchive=Join-Path $temp 'Raw.zip';[IO.Compression.ZipFile]::CreateFromDirectory($rawFolder,$rawArchive)
    Start-EditorPackageLoad -ZipPath $rawArchive;Finish-Load
    Check ($script:editorDocument.LayoutKind -eq 'FullScript' -and -not $script:editorBox.ReadOnly -and $script:fields.ApplicationName.Text -eq '' -and $script:fields.ApplicationVersion.Text -eq '') 'Full-script ZIP opens editable and clears stale identity from the previous app'
    $script:editorSection='FullScript';$script:editorBox.Text=$script:editorDocument.CurrentScript+"`n# Raw ZIP edit"
    $settings=New-PackageBuildSettings;$settings.PackageType='Application';$settings.UseEditor=$true
    $snapshot=Get-ActiveEditorDocument $settings
    Check ($snapshot.LayoutKind -eq 'FullScript' -and $snapshot.CurrentScript.Contains('Raw ZIP edit') -and $snapshot.ZIP_SHA256 -eq (Get-FileHash $rawArchive).Hash) 'Full-script ZIP build snapshot keeps exact text and archive identity'
    Write-Output "PASS: $count async editor loading assertions. Actual worker and completion callbacks; native controls and ACL application mocked."
} finally {
    if ($null -ne $script:job) {$script:job.Worker.Dispose()}
    $env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force
}
