# Inline Windows editor. Plain-text buffers are the source of truth; colors are presentation only.
Add-Type -AssemblyName WindowsFormsIntegration, System.Drawing
$script:editorDocument=$null; $script:editorSection=''; $script:editorChanging=$false
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
for ($i=0;$i -lt $names.Count;$i++) { $null=$controls.SectionList.Items.Add([pscustomobject]@{Label=$labels[$i];Value=$names[$i]}) }
$controls.SectionList.DisplayMemberPath='Label'; $controls.SectionList.SelectedValuePath='Value'
function Save-EditorBuffer {
    if ($null -ne $script:editorDocument -and $script:editorSection) { $script:editorDocument.Sections[$script:editorSection]=$script:editorBox.Text }
}
function Set-EditorDocument($Document) {
    $script:editorDocument=$Document; $script:editorSection=''
    $controls.SectionList.SelectedIndex=-1; $controls.SectionList.SelectedIndex=0
    $controls.Reviewed.IsChecked=$false
}
function Get-ActiveEditorDocument([hashtable]$Settings) {
    if (-not $Settings.UseEditor) { return $null }
    Save-EditorBuffer
    if ($null -eq $script:editorDocument) {
        if ($Settings.SectionTemplatePath) { return $null } # Engine loads the explicitly selected reusable template.
        throw 'Load the selected ZIP in Editor before building.'
    }
    if ($script:editorDocument.Mode -ne $Settings.PackageType) { throw 'Deployment type changed. Reload the selected ZIP in Editor before building.' }
    Assert-EditorSections $script:editorDocument.Sections
    # A detached snapshot prevents UI changes racing the background build.
    $sections=[ordered]@{}
    foreach ($name in Get-EditorSectionNames) { $sections[$name]=[string]$script:editorDocument.Sections[$name] }
    return @{ZIP_SHA256=$script:editorDocument.ZIP_SHA256;Sections=$sections}
}
function Set-EditorAvailability {
    $allowed=$script:fields.PackageType.SelectedValue -ne 'BIOS'
    $controls.EditorMode.IsEnabled=$allowed
    if (-not $allowed) { $controls.EditorMode.SelectedIndex=0 }
    $editing=$allowed -and $controls.EditorMode.SelectedIndex -eq 1
    $script:fields.UseEditor.IsChecked=$editing
    foreach ($name in @('EditorLoad','EditorImport','EditorSave','EditorValidate','EditorHost','SectionList')) { $controls[$name].IsEnabled=$editing }
    $controls.EditorStatus.Text=if (-not $allowed) {'BIOS uses protected managed deployment functions. Choose Application, Windows Update or Dell Driver to edit sections.'} elseif (-not $editing) {'PSADT mode is the default. Choose Editor to load, change and reuse deployment sections.'} else {'Load the selected ZIP, choose a section, then edit. Save template stores only these ten sections. Changes are used when building in Editor mode.'}
}
$controls.EditorMode.Add_SelectionChanged({ Set-EditorAvailability; $controls.Reviewed.IsChecked=$false })
$controls.SectionList.Add_SelectionChanged({
    Save-EditorBuffer
    $script:editorSection=[string]$controls.SectionList.SelectedValue
    $script:editorChanging=$true
    try { $script:editorBox.Text=if ($null -ne $script:editorDocument -and $script:editorSection) { $script:editorDocument.Sections[$script:editorSection] } else { '' } }
    finally { $script:editorChanging=$false }
    $script:editorColorTimer.Stop(); $script:editorColorTimer.Start()
})
function Start-EditorPackageLoad([string]$TemplatePath='') {
    $worker=$null
    try {
        $s=Get-FormSettings
        if ($s.PackageType -eq 'BIOS') { throw 'BIOS sections are protected.' }
        $worker=[PowerShell]::Create()
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $null=$worker.AddScript({param($engine,$zip,$mode,$template)
            $ErrorActionPreference='Stop'
            . $engine
            try {
                $doc=Read-EditorPackage $zip
                if ($template) {
                    $doc.Sections=Import-EditorTemplate $template
                    $null=Set-EditorSections $doc.Text $doc.Sections
                } elseif ($mode -in @('WindowsUpdate','Driver')) { $doc.Sections=New-MaintenanceSections }
                $doc.Mode=$mode
                return $doc
            } catch {
                if ($_.Exception.Data.Contains('BuilderSafeMessage')) { throw [string]$_.Exception.Data['BuilderSafeMessage'] }
                throw 'Could not load the selected PSADT ZIP or section template. Check its path, layout and permissions. Temporary extraction has been cleaned up.'
            }
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($s.FrameworkZip).AddArgument($s.PackageType).AddArgument($TemplatePath)
        $script:job=@{Worker=$worker;Handle=$worker.BeginInvoke();Queue=$queue;Secret=$null;Kind='Editor';TemplatePath=$TemplatePath}
        foreach ($name in @('FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','OutputPanel','Reviewed','BuildButton','LoadButton','SaveButton','OpenButton')) { $controls[$name].IsEnabled=$false }
        $controls.Progress.Visibility='Visible';$controls.Progress.IsIndeterminate=$true
        $controls.BuildLog.Text='Loading PSADT sections in the background. No imported script is executed.'
        $controls.EditorStatus.Text='Loading sections... Close will wait for extraction cleanup.'
    } catch {
        if ($null -eq $script:job -and $null -ne $worker) { $worker.Dispose() }
        $controls.EditorStatus.Text=Get-BuilderFailureMessage $_
    }
}
$controls.EditorLoad.Add_Click({ Start-EditorPackageLoad })
$controls.EditorImport.Add_Click({
    $dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='PSADT section template (*.psadt.json)|*.psadt.json|JSON (*.json)|*.json'
    if ($dialog.ShowDialog($window)) { Start-EditorPackageLoad $dialog.FileName }
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
        $null=Set-EditorSections $script:editorDocument.Text $script:editorDocument.Sections
        $controls.EditorStatus.Text='All ten sections and the combined PSADT script pass syntax validation. No script was executed.'
    } catch { $controls.EditorStatus.Text=Get-BuilderFailureMessage $_ }
})
$script:editorBox.Add_KeyDown({param($sender,$e)
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
    if ($script:editorChanging) { return }
    $box=$script:editorBox; $start=$box.SelectionStart; $length=$box.SelectionLength
    $script:editorChanging=$true
    try {
        $parsed=Get-EditorSyntax $box.Text
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
        $box.Select([math]::Min($start,$box.TextLength),[math]::Min($length,[math]::Max(0,$box.TextLength-$start)))
    } finally { $script:editorChanging=$false }
})
Set-EditorAvailability
