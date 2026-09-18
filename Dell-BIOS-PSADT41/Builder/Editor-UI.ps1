# Inline Windows editor. Plain-text buffers are the source of truth; colors are presentation only.
Add-Type -AssemblyName WindowsFormsIntegration, System.Drawing
if (-not ('Medela.EditorV44.RenderScope' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Editor-Rendering.cs') }
$script:editorDocument=$null; $script:editorSection=''; $script:editorChanging=$false
$script:metadataEdits=@{}; $script:metadataControls=@{}; $script:lastColoredText=$null
$script:editorBox=New-Object Windows.Forms.RichTextBox
$script:editorBox.Font=New-Object Drawing.Font('Consolas',11)
$script:editorBox.AcceptsTab=$false; $script:editorBox.WordWrap=$false
$script:editorBox.DetectUrls=$false; $script:editorBox.HideSelection=$false
$script:editorBox.AccessibleName='PowerShell section editor'
$script:editorBox.AccessibleDescription='Edit the selected PSADT section. Control plus Tab inserts four spaces. Tab moves to the next control.'
$script:editorBox.MaxLength=100000
$controls.EditorHost.Child=$script:editorBox
$labels=@('Custom / functions','Pre install','Install','Post install','Pre uninstall','Uninstall','Post uninstall','Pre repair','Repair','Post repair')
$names=@(Get-EditorSectionNames)
foreach ($item in @(@{Label='Metadata';Value='Metadata'},@{Label='Custom settings';Value='CustomSettings'})) { $null=$controls.SectionList.Items.Add([pscustomobject]$item) }
for ($i=0;$i -lt $names.Count;$i++) { $null=$controls.SectionList.Items.Add([pscustomobject]@{Label=$labels[$i];Value=$names[$i]}) }
$controls.SectionList.DisplayMemberPath='Label'; $controls.SectionList.SelectedValuePath='Value'
function Test-EditorDirectDocument {
    return ($null -ne $script:editorDocument -and $script:editorDocument.Contains('SourceKind') -and $script:editorDocument.SourceKind -eq 'Script')
}
function Save-EditorBuffer {
    if ($null -eq $script:editorDocument -or -not $script:editorSection) { return }
    if ($script:editorSection -eq 'Metadata') {
        if ($script:metadataEdits.Count) {
            $script:editorDocument.MetadataText=Set-EditorMetadataValues $script:editorDocument.MetadataText $script:metadataEdits (Get-EditorDocumentMetadataKind $script:editorDocument)
            $script:metadataEdits=@{}
        }
        return
    }
    $isSettings=$script:editorSection -eq 'CustomSettings'
    if ($isSettings -and -not $script:editorDocument.Contains('MetadataText')) { return }
    $prior=if ($script:editorSection -eq 'FullScript') {$script:editorDocument.CurrentScript} elseif ($isSettings) { $script:editorDocument.MetadataText } else { $script:editorDocument.Sections[$script:editorSection] }
    $text=$script:editorBox.Text
    # RichTextBox normalizes CRLF to LF. Merely visiting a page must not dirty it.
    if ($prior.Replace("`r`n","`n") -ceq $text.Replace("`r`n","`n")) { return }
    $newline=if ($script:editorDocument.Text.Contains("`r`n")) {"`r`n"} else {"`n"}
    $text=$text.Replace("`r`n","`n").Replace("`n",$newline)
    if ($script:editorSection -eq 'FullScript') {$script:editorDocument.CurrentScript=$text} elseif ($isSettings) { $script:editorDocument.MetadataText=$text } else { $script:editorDocument.Sections[$script:editorSection]=$text }
}
function Show-EditorMetadata {
    $controls.MetadataFields.Children.Clear(); $script:metadataControls=@{}; $script:metadataEdits=@{}
    if ($null -eq $script:editorDocument -or -not $script:editorDocument.Contains('MetadataText')) { return }
    $kind=Get-EditorDocumentMetadataKind $script:editorDocument
    $values=Get-EditorMetadataFields $script:editorDocument.MetadataText $kind
    $note=New-Object Windows.Controls.TextBlock
    $note.Text=if ($kind -eq 'Variables') {'Legacy PSADT metadata. Custom settings contains the original variable declarations. Calculated values are never evaluated.'} else {'Common metadata fields. Custom settings contains the full adtSession table, including arrays, flags and calculated values.'}
    $note.TextWrapping='Wrap';$note.Margin='0,0,0,12';$null=$controls.MetadataFields.Children.Add($note)
    foreach ($item in @(@('AppName','App name'),@('AppVendor','Publisher / vendor'),@('AppVersion','App version'),@('AppScriptAuthor','Script author'),@('AppScriptVersion','Script version'),@('AppScriptDate','Script date'),@('AppArch','Architecture'),@('AppLang','Language'),@('AppRevision','Revision'),@('InstallName','Install name'),@('InstallTitle','Install title'))) {
        $key=$item[0];$label=New-Object Windows.Controls.Label;$label.Content=$item[1]
        $inputControl=New-Object Windows.Controls.TextBox;$inputControl.MaxLength=2000;$inputControl.Margin='0,0,0,8'
        $literal=(-not $values.Contains($key) -or $values[$key].Literal)
        $inputControl.Text=if ($values.Contains($key)) {$values[$key].Value} else {''}
        $inputControl.IsReadOnly=-not $literal
        $inputControl.ToolTip=if ($literal) {$key} else {'Calculated value. Edit the expression in Custom settings.'}
        $inputControl.Tag=@{Key=$key;Original=$inputControl.Text}
        [Windows.Automation.AutomationProperties]::SetName($inputControl,$item[1]);$label.Target=$inputControl
        $inputControl.Add_TextChanged({param($sender,$e)
            if ($script:editorChanging) { return }
            if ($sender.Text -ceq $sender.Tag.Original) { $script:metadataEdits.Remove($sender.Tag.Key) } else { $script:metadataEdits[$sender.Tag.Key]=$sender.Text }
            $controls.Reviewed.IsChecked=$false; $controls.EditorStatus.Text='Unsaved metadata changes. Save PS1 includes metadata; Save template stores sections only.'
        })
        $script:metadataControls[$key]=$inputControl
        $null=$controls.MetadataFields.Children.Add($label);$null=$controls.MetadataFields.Children.Add($inputControl)
    }
}
function Set-EditorDocument($Document) {
    $script:editorChanging=$true
    try {
        $script:editorDocument=$Document; $script:editorSection=''; $script:metadataEdits=@{}
        $controls.EditorDocumentLabel.Text=if ($Document.Contains('Path')) {$Document.Path} else {'Selected ZIP deployment script'}
        if ($Document.Contains('EntryPath')) { $controls.EditorDocumentLabel.Text+='  >  '+$Document.EntryPath }
        $controls.SectionList.Items.Clear()
        if (Test-EditorFullScript $Document) { $null=$controls.SectionList.Items.Add([pscustomobject]@{Label='Full script';Value='FullScript'}) }
        else {
            if ($Document.Contains('MetadataText')) {
                foreach ($item in @(@{Label='Metadata';Value='Metadata'},@{Label='Custom settings';Value='CustomSettings'})) { $null=$controls.SectionList.Items.Add([pscustomobject]$item) }
            }
            for ($i=0;$i -lt $names.Count;$i++) { $null=$controls.SectionList.Items.Add([pscustomobject]@{Label=$labels[$i];Value=$names[$i]}) }
        }
        $controls.SectionList.SelectedIndex=-1
    } finally { $script:editorChanging=$false }
    $controls.SectionList.SelectedIndex=0
    $controls.Reviewed.IsChecked=$false
    Set-EditorAvailability
}
function Clear-EditorDocument {
    $script:editorChanging=$true
    try {
        $script:editorDocument=$null; $script:editorSection=''; $script:metadataEdits=@{}; $script:metadataControls=@{}
        $controls.SectionList.SelectedIndex=-1; $script:editorBox.Text=''; $controls.MetadataFields.Children.Clear(); $controls.EditorDocumentLabel.Text=''
        $controls.MetadataView.Visibility='Collapsed'; $controls.EditorHost.Visibility='Visible'
        $script:lastColoredText=$null; $controls.Reviewed.IsChecked=$false
    } finally { $script:editorChanging=$false }
    Set-EditorAvailability
}
function Confirm-EditorReplacement {
    Save-EditorBuffer
    if (-not (Test-EditorDocumentDirty $script:editorDocument)) { return $true }
    return ([Windows.MessageBox]::Show($window,'The editor has unsaved changes. Replace them? Choose No to save the PS1 or a section template first.','Replace editor contents','YesNo','Question') -eq 'Yes')
}
function Get-ActiveEditorDocument([hashtable]$Settings) {
    if (-not $Settings.UseEditor) { return $null }
    Save-EditorBuffer
    if ($null -eq $script:editorDocument) {
        if ($Settings.SectionTemplatePath) { return $null } # Engine loads the explicitly selected reusable template.
        throw 'Load the selected ZIP in Editor before building.'
    }
    if (Test-EditorDirectDocument) { throw 'This is a standalone PS1. Save it, then ZIP the complete app and load that ZIP before building with editor changes.' }
    if ($script:editorDocument.Mode -ne $Settings.PackageType) { throw 'Deployment type changed. Reload the selected ZIP in Editor before building.' }
    if (Test-EditorFullScript $script:editorDocument) {
        if ($Settings.PackageType -ne 'Application') { throw 'Generated servicing requires mapped PSADT 4.1 sections. Use Application mode for a custom full script.' }
        return @{ZIP_SHA256=$script:editorDocument.ZIP_SHA256;LayoutKind='FullScript';CurrentScript=(Get-EditorDocumentText $script:editorDocument)}
    }
    Assert-EditorSections $script:editorDocument.Sections
    # A detached snapshot prevents UI changes racing the background build.
    $sections=[ordered]@{}
    foreach ($name in Get-EditorSectionNames) { $sections[$name]=[string]$script:editorDocument.Sections[$name] }
    $snapshot=@{ZIP_SHA256=$script:editorDocument.ZIP_SHA256;Sections=$sections}
    if ($script:editorDocument.Contains('MetadataText')) {
        $kind=Get-EditorDocumentMetadataKind $script:editorDocument
        $null=Get-EditorMetadataFields $script:editorDocument.MetadataText $kind
        $snapshot.MetadataText=[string]$script:editorDocument.MetadataText;$snapshot.MetadataKind=$kind
    }
    return $snapshot
}
function Set-EditorAvailability {
    $direct=Test-EditorDirectDocument
    $allowed=$script:fields.PackageType.SelectedValue -ne 'BIOS'
    $controls.EditorMode.IsEnabled=($allowed -and -not $direct)
    if ($direct) { $controls.EditorMode.SelectedIndex=1 } elseif (-not $allowed) { $controls.EditorMode.SelectedIndex=0 }
    $packageEditing=$allowed -and $controls.EditorMode.SelectedIndex -eq 1 -and -not $direct
    $script:fields.UseEditor.IsChecked=$packageEditing
    $hasDocument=$null -ne $script:editorDocument
    $signed=$hasDocument -and $script:editorDocument.Contains('Signed') -and $script:editorDocument.Signed
    $editing=($hasDocument -and -not $signed -and (($direct -and $script:editorDocument.Editable) -or $packageEditing))
    $controls.EditorOpenScript.IsEnabled=$true
    $controls.EditorOpenZip.IsEnabled=$true
    $controls.EditorEditScript.IsEnabled=($direct -and -not $signed -and -not $script:editorDocument.Editable)
    $controls.EditorSaveScript.IsEnabled=($direct -and $editing);$controls.EditorSaveScriptAs.IsEnabled=$editing
    $controls.EditorCloseScript.IsEnabled=$hasDocument
    $controls.EditorLoad.IsEnabled=$true
    $controls.EditorImport.IsEnabled=($editing -and -not (Test-EditorFullScript $script:editorDocument))
    foreach ($name in @('EditorSave','EditorValidate')) { $controls[$name].IsEnabled=($hasDocument -and ($direct -or $packageEditing)) }
    if (Test-EditorFullScript $script:editorDocument) { $controls.EditorSave.IsEnabled=$false }
    $controls.SectionList.IsEnabled=($hasDocument -and ($direct -or $packageEditing))
    $controls.EditorHost.IsEnabled=$controls.SectionList.IsEnabled
    $controls.MetadataView.IsEnabled=$editing
    $script:editorBox.ReadOnly=-not $editing
    $controls.EditorStatus.Text=if ($direct) {
        if ($signed) {'Signed script opened for review. Create an unsigned authoring copy to edit; signatures are never removed automatically.'}
        elseif ($editing) {'Editing PS1. Save PS1 includes metadata and code; replacing the opened file keeps a backup. Save template stores only sections.'}
        else {'PS1 opened for review. Click EDIT to change metadata, custom settings and deployment sections.'}
    } elseif (-not $allowed) {'Open ZIP loads its deployment script into Editor automatically. Managed BIOS package functions remain protected.'}
    elseif (-not $packageEditing) {'Open ZIP or Load selected ZIP switches to Editor automatically. Open PS1 also works without a package.'}
    else {'Load the selected ZIP to edit its sections and metadata. Imported code is never executed.'}
    if ($hasDocument -and $script:editorDocument.Contains('LayoutNotice')) { $controls.EditorStatus.Text+=' '+$script:editorDocument.LayoutNotice }
}
$controls.EditorMode.Add_SelectionChanged({ Set-EditorAvailability; $controls.Reviewed.IsChecked=$false })
$controls.SectionList.Add_SelectionChanged({
    if ($script:editorChanging) { return }
    $previous=$script:editorSection
    try {
        Save-EditorBuffer
        $script:editorSection=[string]$controls.SectionList.SelectedValue
        $script:editorChanging=$true
        $metadata=$script:editorSection -eq 'Metadata'
        $controls.MetadataView.Visibility=if ($metadata) {'Visible'} else {'Collapsed'}
        $controls.EditorHost.Visibility=if ($metadata) {'Collapsed'} else {'Visible'}
        if ($metadata) { Show-EditorMetadata }
        else {
            $script:editorBox.Text=if ($null -eq $script:editorDocument -or -not $script:editorSection) {''}
                elseif ($script:editorSection -eq 'CustomSettings') { if ($script:editorDocument.Contains('MetadataText')) {$script:editorDocument.MetadataText} else {'# This app calculates metadata. Its original bootstrap is preserved.'} }
                elseif ($script:editorSection -eq 'FullScript') {$script:editorDocument.CurrentScript}
                else {$script:editorDocument.Sections[$script:editorSection]}
        }
        $script:editorBox.MaxLength=if ($script:editorSection -eq 'FullScript') {2MB} else {100000}
        Set-EditorAvailability
        if ($script:editorSection -in @('Metadata','CustomSettings') -and $null -ne $script:editorDocument -and -not $script:editorDocument.Contains('MetadataText')) {
            $script:editorBox.ReadOnly=$true; $controls.EditorStatus.Text='This app calculates metadata. The original script is preserved; metadata editing is unavailable for this layout.'
        }
        $script:lastColoredText=$null
        $script:editorColorTimer.Stop(); if (-not $metadata) {$script:editorColorTimer.Start()}
    } catch {
        $script:editorSection=$previous; $script:editorChanging=$true; $controls.SectionList.SelectedValue=$previous
        $controls.MetadataView.Visibility=if ($previous -eq 'Metadata') {'Visible'} else {'Collapsed'}
        $controls.EditorHost.Visibility=if ($previous -eq 'Metadata') {'Collapsed'} else {'Visible'}
        $controls.EditorStatus.Text=Get-BuilderFailureMessage $_
    } finally { $script:editorChanging=$false }
})
function Open-EditorScriptDialog {
    $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='PSADT deployment script (*.ps1)|*.ps1'
    if ($dialog.ShowDialog($window)) { Start-EditorPackageLoad -ScriptPath $dialog.FileName }
}
function Open-EditorZipDialog {
    $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='PSADT framework or application ZIP (*.zip)|*.zip'
    if ($dialog.ShowDialog($window)) { Start-EditorPackageLoad -ZipPath $dialog.FileName }
}
$controls.EditorOpenZip.Add_Click({ Open-EditorZipDialog })
$controls.EditorOpenScript.Add_Click({ Open-EditorScriptDialog })
$controls.EditorEditScript.Add_Click({
    if (Test-EditorDirectDocument) {
        if ($script:editorDocument.Signed) { return }
        $script:editorDocument.Editable=$true; Set-EditorAvailability
    }
})
function Save-EditorScriptUI([bool]$SaveAs) {
    try {
        Save-EditorBuffer
        if ($null -eq $script:editorDocument) { throw 'Open a ZIP or PS1 first.' }
        $direct=Test-EditorDirectDocument
        if (-not $direct -and -not $SaveAs) { throw 'Use Save as new PS1 to export the deployment script from this ZIP.' }
        $path=$script:editorDocument.Path
        if ($SaveAs) {
            $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='PowerShell script (*.ps1)|*.ps1';$dialog.OverwritePrompt=$false
            $dialog.InitialDirectory=[IO.Path]::GetDirectoryName($path)
            $dialog.FileName=if ($direct) {[IO.Path]::GetFileNameWithoutExtension($path)+'.edited.ps1'} else {$script:editorDocument.EntryScript}
            if (-not $dialog.ShowDialog($window)) { return };$path=$dialog.FileName
        }
        $saveDocument=$script:editorDocument
        if (-not $direct) {
            $saveDocument=@{};foreach ($key in $script:editorDocument.Keys) {$saveDocument[$key]=$script:editorDocument[$key]}
            $saveDocument.SourceKind='Script';$saveDocument.Editable=$true
        }
        $result=Save-EditorScriptDocument $saveDocument $path
        if ($direct) { Set-EditorDocument $result.Document }
        $controls.EditorStatus.Text=if (-not $result.Changed) {'No changes to save; original file left intact.'} elseif ($result.BackupPath) {'Saved PS1. Previous version: '+$result.BackupPath} else {'Saved new PS1: '+$path}
    } catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
}
$controls.EditorSaveScript.Add_Click({ Save-EditorScriptUI $false })
$controls.EditorSaveScriptAs.Add_Click({ Save-EditorScriptUI $true })
$controls.EditorCloseScript.Add_Click({
    try { if (Confirm-EditorReplacement) { Clear-EditorDocument } }
    catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
})
function Get-EditorLoadSettings([string]$ScriptPath,[string]$ZipPath) {
    $s=New-PackageBuildSettings
    if ($ScriptPath) { $s.PackageType='Script';return $s }
    $s.FrameworkZip=if ($ZipPath) {$ZipPath} else {$script:fields.FrameworkZip.Text}
    if (-not $s.FrameworkZip) { throw 'Choose Open ZIP, or select a PSADT ZIP in Files first.' }
    $s.PackageType=if (-not $ZipPath -and $script:fields.PackageType.SelectedValue -in @('WindowsUpdate','Driver')) {$script:fields.PackageType.SelectedValue} else {'Application'}
    if ($s.PackageType -ne 'Application') { $s.ApplicationName=$script:fields.ApplicationName.Text;$s.ApplicationVersion=$script:fields.ApplicationVersion.Text }
    return $s
}
function Complete-EditorLoad($Document,$Job) {
    if ($Document.SourceKind -eq 'ZIP') {
        $script:fields.PackageType.SelectedValue=$Document.Mode
        $script:fields.FrameworkZip.Text=$Document.Path
        $controls.EditorMode.SelectedIndex=1
        if ($Document.Mode -eq 'Application') {
            $replaceIdentity=$Job.ContainsKey('OpenedZip') -and $Job.OpenedZip
            $values=if ($Document.Contains('MetadataText')) {Get-EditorMetadataFields $Document.MetadataText (Get-EditorDocumentMetadataKind $Document)} else {[ordered]@{}}
            foreach ($pair in @(@('AppName','ApplicationName'),@('AppVersion','ApplicationVersion'))) {
                if ($replaceIdentity) { $script:fields[$pair[1]].Text='' }
                if (-not $script:fields[$pair[1]].Text -and $values.Contains($pair[0]) -and $values[$pair[0]].Literal) { $script:fields[$pair[1]].Text=$values[$pair[0]].Value }
            }
        }
    }
    $controls.EditorTab.IsSelected=$true
    Set-EditorDocument $Document
    $script:fields.SectionTemplatePath.Text=$Job.TemplatePath
}
function Start-EditorPackageLoad([string]$TemplatePath='',[string]$ScriptPath='',[string]$ZipPath='') {
    $worker=$null
    try {
        if ($null -ne $script:job) { throw 'Wait for the current operation to finish.' }
        if (-not (Confirm-EditorReplacement)) { return }
        if ($ScriptPath -and [IO.Path]::GetExtension($ScriptPath) -eq '.zip') { $ZipPath=$ScriptPath;$ScriptPath='' }
        $s=Get-EditorLoadSettings $ScriptPath $ZipPath
        $worker=[PowerShell]::Create()
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $null=$worker.AddScript({param($engine,$zip,$mode,$template,$scriptPath,$identity)
            $ErrorActionPreference='Stop'
            . $engine
            try {
                if ($scriptPath) { return Read-EditorScriptDocument $scriptPath }
                $doc=Read-EditorPackage $zip
                if ($template) {
                    $doc.Sections=Import-EditorTemplate $template
                    if (Test-EditorFullScript $doc) { Stop-BuilderValidation 'Section templates require a recognized section layout. This deployment uses Full script editing.' }
                    $null=Set-EditorSections $doc.Text $doc.Sections
                } elseif ($mode -in @('WindowsUpdate','Driver')) {
                    if (Test-EditorFullScript $doc) { Stop-BuilderValidation 'Generated servicing requires the standard PSADT 4.1 section layout.' }
                    $doc.Sections=New-MaintenanceSections
                    $doc.MetadataText=(Get-EditorMetadataLayout (Set-MaintenanceIdentity $doc.Text $identity)).Extent.Text
                    $doc.MetadataKind='Table'
                }
                $doc.Mode=$mode
                return $doc
            } catch {
                $detail='Could not open this file. Check its path, valid PowerShell syntax and permissions. Imported code was not executed.'
                $cause=$_.Exception
                while ($null -ne $cause) { if ($cause.Data.Contains('BuilderSafeMessage')) {$detail=[string]$cause.Data['BuilderSafeMessage'];break};$cause=$cause.InnerException }
                return @{EditorLoadError=$detail}
            }
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($s.FrameworkZip).AddArgument($s.PackageType).AddArgument($TemplatePath).AddArgument($ScriptPath).AddArgument($s)
        $script:job=@{Worker=$worker;Handle=$worker.BeginInvoke();Queue=$queue;Secret=$null;Kind='Editor';TemplatePath=$TemplatePath;OpenedZip=[bool]$ZipPath}
        Set-BuilderBusy $true
        $controls.BuildLog.Text='Loading PSADT sections in the background. No imported script is executed.'
        $controls.EditorStatus.Text='Loading sections... Close will wait for extraction cleanup.'
    } catch {
        if ($null -eq $script:job -and $null -ne $worker) { $worker.Dispose() }
        $controls.EditorStatus.Text=Get-BuilderFailureMessage $_
    }
}
$controls.EditorLoad.Add_Click({ Start-EditorPackageLoad })
$controls.EditorTab.Add_Selected({param($sender,$eventArgs)
    if (-not [object]::ReferenceEquals($eventArgs.OriginalSource,$sender)) { return }
    if ($sender.IsSelected -and $null -eq $script:job -and $null -eq $script:editorDocument -and $script:fields.FrameworkZip.Text) { Start-EditorPackageLoad }
})
$controls.EditorImport.Add_Click({
    $dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='PSADT section template (*.psadt.json)|*.psadt.json|JSON (*.json)|*.json'
    if ($dialog.ShowDialog($window)) {
        if (Test-EditorDirectDocument) {
            try {
                if (-not (Confirm-EditorReplacement)) { return }
                $sections=Import-EditorTemplate $dialog.FileName
                $null=Set-EditorSections $script:editorDocument.Text $sections
                $script:editorDocument.Sections=$sections; Set-EditorDocument $script:editorDocument
                $controls.EditorStatus.Text='Section template applied to the open PS1. Metadata is retained. Save PS1 to write these changes.'
            } catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
        } else { Start-EditorPackageLoad $dialog.FileName }
    }
})
$controls.EditorSave.Add_Click({
    try {
        Save-EditorBuffer
        if ($null -eq $script:editorDocument) { throw 'Load a package first.' }
        Assert-EditorSections $script:editorDocument.Sections
        $dialog=New-Object Microsoft.Win32.SaveFileDialog; $dialog.Filter='PSADT section template (*.psadt.json)|*.psadt.json'; $dialog.FileName='Deployment-sections.psadt.json'
        if ($dialog.ShowDialog($window)) {
            Export-EditorTemplate $script:editorDocument.Sections $dialog.FileName
            $script:fields.SectionTemplatePath.Text=$dialog.FileName
            $controls.EditorStatus.Text='Saved the ten sections. The source ZIP and deployment script were not modified. Keep credentials out of section text.'
        }
    } catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
})
$controls.EditorValidate.Add_Click({
    try {
        Save-EditorBuffer
        if ($null -eq $script:editorDocument) { throw 'Load a package first.' }
        $null=Get-EditorDocumentText $script:editorDocument
        $controls.EditorStatus.Text='Metadata, settings, sections and the combined PSADT script pass syntax validation. No script was executed.'
    } catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
})
$script:editorBox.Add_KeyDown({param($sender,$e)
    if ($sender.ReadOnly) { return }
    if ($e.Control -and $e.KeyCode -eq 'Tab') { $e.SuppressKeyPress=$true; $sender.SelectedText='    ' }
    if ($e.Control -and $e.KeyCode -eq 'V') {
        # Paste plain text only; never import RTF objects or images into script buffers.
        $e.SuppressKeyPress=$true
        if ([Windows.Forms.Clipboard]::ContainsText()) { $sender.SelectedText=[Windows.Forms.Clipboard]::GetText() }
    }
})
$script:editorBox.Add_TextChanged({
    if ($script:editorChanging) { return }
    $controls.Reviewed.IsChecked=$false
    $script:editorColorTimer.Stop(); $script:editorColorTimer.Start()
})
$script:editorColorTimer=New-Object Windows.Threading.DispatcherTimer
$script:editorColorTimer.Interval=[timespan]::FromMilliseconds(600)
$script:editorColorTimer.Add_Tick({
    $script:editorColorTimer.Stop()
    if ($script:editorChanging -or -not $controls.EditorHost.IsVisible) { return }
    $box=$script:editorBox; $text=$box.Text
    if ($text -ceq $script:lastColoredText) { return }
    if ($text.Length -gt 100000) { $script:lastColoredText=$text;return } # Large full scripts stay responsive in plain text.
    $start=$box.SelectionStart; $length=$box.SelectionLength; $modified=$box.Modified; $render=$null
    $script:editorChanging=$true
    try {
        $parsed=Get-EditorSyntax $text
        $render=[Medela.EditorV44.RenderScope]::Begin($box.Handle)
        $box.SelectAll(); $box.SelectionColor=[Drawing.SystemColors]::WindowText
        if (-not [Windows.SystemParameters]::HighContrast) {
            foreach ($token in $parsed.Tokens) {
                $color=switch -Regex ([string]$token.Kind) {
                    '^Comment$' {'#386641';break}
                    'String|HereString' {'#9C3F00';break}
                    '^Variable$|^SplattedVariable$' {'#075E85';break}
                    '^Number$' {'#7050A0';break}
                    '^(Function|If|Else|ElseIf|Foreach|For|While|Return|Try|Catch|Finally|Throw|Param|Switch)$' {'#244ABA';break}
                    default {''}
                }
                if ($color -and $token.Extent.EndOffset -le $box.TextLength) {
                    $box.Select($token.Extent.StartOffset,$token.Extent.EndOffset-$token.Extent.StartOffset)
                    $box.SelectionColor=[Drawing.ColorTranslator]::FromHtml($color)
                }
            }
        }
        $script:lastColoredText=$text
    } catch {
        # Presentation failures must not close the editor or lose its plain-text buffer.
        $script:lastColoredText=$text
        $controls.EditorStatus.Text='Syntax colors could not refresh. Your text is intact; editing and saving remain available. Include native editor rendering in the Windows pilot.'
    } finally {
        try {
            $box.Select([math]::Min($start,$box.TextLength),[math]::Min($length,[math]::Max(0,$box.TextLength-$start)))
            $box.Modified=$modified
            if ($null -ne $render) {
                try { $render.Dispose() } catch { $controls.EditorStatus.Text='Syntax rendering cleanup failed. Text is intact; save your edits and reopen the editor.' }
            }
        } finally { $script:editorChanging=$false }
    }
})
Set-EditorAvailability
