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
    foreach($name in @('Save-EditorBuffer','Get-ActiveEditorDocument','Set-EditorAvailability')){
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $controls=@{}
    foreach($name in @('EditorMode','EditorLoad','EditorImport','EditorSave','EditorValidate','EditorHost','SectionList','EditorStatus')){
        $controls[$name]=[pscustomobject]@{IsEnabled=$true;SelectedIndex=0;Text=''}
    }
    $script:fields=@{PackageType=[pscustomobject]@{SelectedValue='Application'};UseEditor=[pscustomobject]@{IsChecked=$false}}
    $script:editorSection='Install';$script:editorBox=[pscustomobject]@{Text="Write-Output 'new text'"}
    $script:editorDocument=@{Sections=(New-MaintenanceSections);Mode='Application';ZIP_SHA256=('A'*64)}
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
    $s.UseEditor=$true;$script:editorDocument=$null;Reject {Get-ActiveEditorDocument $s} 'Empty editor cannot produce a build'
    $s.SectionTemplatePath='approved.psadt.json';Check ($null -eq (Get-ActiveEditorDocument $s)) 'Explicit template path delegates to engine import when no live document exists'
    foreach($mode in @('WindowsUpdate','Driver')){
        $script:fields.PackageType.SelectedValue=$mode;$controls.EditorMode.SelectedIndex=1;Set-EditorAvailability
        Check ($controls.EditorHost.IsEnabled -and $script:fields.UseEditor.IsChecked) "$mode supports section editor"
    }
    $script:fields.PackageType.SelectedValue='BIOS';Set-EditorAvailability
    Check (-not $script:fields.UseEditor.IsChecked -and -not $controls.EditorMode.IsEnabled -and -not $controls.EditorSave.IsEnabled) 'BIOS switches off editor replacement and disables editing controls'
    $parsed=Get-EditorSyntax "# comment`n`$sample = 'literal'`nif (`$true) { return 42 }"
    foreach($kind in @('Comment','Variable','StringLiteral','If','Number')){Check ($parsed.Tokens.Kind -contains $kind) "Parser provides $kind spans for syntax highlighting"}
    Write-Output "PASS: $count editor callback assertions. Native highlighting, caret, clipboard, undo and scaling require Windows pilot."
} finally {$env:ProgramData=$oldData}
