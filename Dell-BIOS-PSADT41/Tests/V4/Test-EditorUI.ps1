# Actual editor state/snapshot callbacks, without WPF or native RichTextBox.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$oldData=$env:ProgramData;if(-not $env:ProgramData){$env:ProgramData=[IO.Path]::GetTempPath()}
$count=0
function Check($Condition,$Name){$script:count++;if(-not $Condition){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name){$failed=$false;try{$null=& $Body}catch{$failed=$true};Check $failed $Name}
try {
    . "$root/Builder/Build-Package.ps1"
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Editor-UI.ps1",[ref]$tokens,[ref]$errors)
    foreach($name in @('Test-EditorDirectDocument','Save-EditorBuffer','Get-ActiveEditorDocument','Set-EditorAvailability','Clear-EditorDocument')){
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $controls=@{}
    foreach($name in @('EditorMode','EditorLoad','EditorImport','EditorSave','EditorValidate','EditorHost','SectionList','EditorStatus','EditorOpenScript','EditorOpenZip','EditorEditScript','EditorSaveScript','EditorSaveScriptAs','EditorCloseScript','EditorDocumentLabel','MetadataView','Reviewed')){
        $controls[$name]=[pscustomobject]@{IsEnabled=$true;SelectedIndex=0;Text='';Visibility='Visible';IsChecked=$false}
    }
    $controls.MetadataFields=[pscustomobject]@{Children=(New-Object Collections.ArrayList)}
    $script:fields=@{PackageType=[pscustomobject]@{SelectedValue='Application'};UseEditor=[pscustomobject]@{IsChecked=$false}}
    $script:metadataEdits=@{}; $script:editorSection='Install';$script:editorBox=[pscustomobject]@{ReadOnly=$false;Text="Write-Output 'new text'"}
    $script:editorDocument=@{SourceKind='ZIP';Text="# original`r`n";Sections=(New-MaintenanceSections);Mode='Application';ZIP_SHA256=('A'*64)}
    Set-EditorAvailability
    Check (-not $script:fields.UseEditor.IsChecked -and -not $controls.EditorHost.IsEnabled) 'PSADT default does not apply editable buffers'
    $controls.EditorMode.SelectedIndex=1;Set-EditorAvailability
    Check ($script:fields.UseEditor.IsChecked -and $controls.EditorHost.IsEnabled -and $controls.EditorSave.IsEnabled) 'Editor enables editing and save together'
    $s=New-PackageBuildSettings;$s.PackageType='Application';$s.UseEditor=$true
    $snapshot=Get-ActiveEditorDocument $s
    Check ($snapshot.Sections.Install -ceq $script:editorBox.Text -and $snapshot.ZIP_SHA256 -eq ('A'*64)) 'Active text is committed to build snapshot'
    $script:editorDocument.Sections.Install='Changed later'
    Check ($snapshot.Sections.Install -ne $script:editorDocument.Sections.Install) 'Background build snapshot is independent of future UI edits'
    $script:editorBox.Text='if (';Reject {Get-ActiveEditorDocument $s} 'Unsaved syntax error blocks build snapshot'
    $script:editorBox.Text='Write-Output 1';$s.PackageType='Driver';Reject {Get-ActiveEditorDocument $s} 'Changing deployment type requires editor reload'
    $s.UseEditor=$false;Check ($null -eq (Get-ActiveEditorDocument $s)) 'PSADT mode ignores old editor buffers'
    $savedDocument=$script:editorDocument
    $s.UseEditor=$true;$script:editorDocument=$null;Reject {Get-ActiveEditorDocument $s} 'Empty editor cannot produce a build'
    $s.SectionTemplatePath='approved.psadt.json';Check ($null -eq (Get-ActiveEditorDocument $s)) 'Explicit template path delegates to engine import when no live document exists'
    $script:editorDocument=$savedDocument
    foreach($mode in @('WindowsUpdate','Driver')){
        $script:fields.PackageType.SelectedValue=$mode;$controls.EditorMode.SelectedIndex=1;Set-EditorAvailability
        Check ($controls.EditorHost.IsEnabled -and $script:fields.UseEditor.IsChecked) "$mode supports section editor"
    }
    $script:fields.PackageType.SelectedValue='BIOS';Set-EditorAvailability
    Check (-not $script:fields.UseEditor.IsChecked -and -not $controls.EditorMode.IsEnabled -and -not $controls.EditorSave.IsEnabled) 'BIOS switches off editor replacement and disables editing controls'
    $script:editorDocument=@{SourceKind='Script';Text="# original`r`n";Mode='Script';Editable=$false;Signed=$false;Sections=(New-MaintenanceSections);MetadataText="@{AppName='Original'}"}
    Set-EditorAvailability
    Check ($controls.EditorOpenScript.IsEnabled -and $controls.EditorEditScript.IsEnabled -and $script:editorBox.ReadOnly -and -not $script:fields.UseEditor.IsChecked) 'Standalone PS1 preview works even with BIOS package settings selected'
    $script:editorDocument.Editable=$true;Set-EditorAvailability
    Check ($controls.EditorSaveScript.IsEnabled -and $controls.EditorSaveScriptAs.IsEnabled -and -not $script:editorBox.ReadOnly -and -not $controls.EditorEditScript.IsEnabled) 'EDIT unlocks direct saving and text editing'
    $script:editorSection='Metadata';$script:metadataEdits=@{AppName='New name'}
    Save-EditorBuffer
    Check ((Get-EditorMetadataFields $script:editorDocument.MetadataText).AppName.Value -eq 'New name' -and $script:metadataEdits.Count -eq 0) 'Metadata form commits pending text values'
    $script:editorSection='Install';$before=$script:editorDocument.Sections.Install
    $script:editorBox.Text=$before.Replace("`r`n","`n");Save-EditorBuffer
    Check ($script:editorDocument.Sections.Install -ceq $before) 'RichTextBox newline normalization alone does not dirty a section'
    $s.UseEditor=$true;Reject {Get-ActiveEditorDocument $s} 'Standalone PS1 is never silently injected into another package build'
    $script:editorDocument.Signed=$true;Set-EditorAvailability
    Check (-not $controls.EditorEditScript.IsEnabled -and -not $controls.EditorSaveScript.IsEnabled -and $script:editorBox.ReadOnly) 'Signed standalone input remains read-only'
    $keyHandler=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$script:editorBox' -and $n.Member.Value -eq 'Add_KeyDown'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $sender=[pscustomobject]@{ReadOnly=$true;SelectedText='unchanged'};$event=[pscustomobject]@{Control=$true;KeyCode='Tab';SuppressKeyPress=$false}
    & $keyHandler $sender $event
    Check ($sender.SelectedText -eq 'unchanged' -and -not $event.SuppressKeyPress) 'Custom keyboard handling cannot bypass read-only preview'
    $script:fields.PackageType.SelectedValue='Application';$controls.EditorMode.SelectedIndex=1
    $null=$controls.MetadataFields.Children.Add('stale field');$script:metadataEdits=@{AppName='stale'}
    Clear-EditorDocument
    Check ($null -eq $script:editorDocument -and $script:metadataEdits.Count -eq 0 -and $controls.MetadataFields.Children.Count -eq 0 -and $script:editorBox.Text -eq '') 'Closing a document clears metadata and text buffers'
    Check ($controls.EditorMode.IsEnabled -and $controls.EditorLoad.IsEnabled -and -not $controls.EditorCloseScript.IsEnabled) 'Closing a standalone document restores ZIP authoring'
    $parsed=Get-EditorSyntax "# comment`n`$sample = 'literal'`nif (`$true) { return 42 }"
    foreach($kind in @('Comment','Variable','StringLiteral','If','Number')){Check ($parsed.Tokens.Kind -contains $kind) "Parser provides $kind spans for syntax highlighting"}
    Write-Output "PASS: $count editor callback assertions. Native highlighting, caret, clipboard, undo and scaling require Windows pilot."
} finally {$env:ProgramData=$oldData}
