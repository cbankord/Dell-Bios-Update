# PSADT 4.x section documents are data. Importing, highlighting and building never execute them.
function Get-EditorSectionNames {
    @('CustomFunctions','PreInstall','Install','PostInstall','PreUninstall','Uninstall','PostUninstall','PreRepair','Repair','PostRepair')
}
function Get-EditorSyntax([string]$Text) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    return @{Ast=$ast;Tokens=@($tokens);Errors=@($errors)}
}
function Read-EditorScript([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 8MB) { Stop-BuilderValidation 'Deployment script exceeds the editor file size limit.' }
    try { return [IO.File]::ReadAllText($Path,(New-Object Text.UTF8Encoding($false,$true))) }
    catch { Stop-BuilderValidation 'Editor input must use valid UTF-8 or BOM-marked Unicode. Convert a legacy ANSI authoring copy before editing.' }
}
function Assert-EditorSections([System.Collections.IDictionary]$Sections) {
    $names=@(Get-EditorSectionNames)
    if ($null -eq $Sections -or $Sections.Count -ne $names.Count) { Stop-BuilderValidation 'A section template must contain exactly the ten PSADT sections.' }
    foreach ($name in $names) {
        if (-not $Sections.Contains($name) -or $Sections[$name] -isnot [string] -or $Sections[$name].Length -gt 100000) { Stop-BuilderValidation 'Section names or text sizes are invalid (100,000 characters per section maximum).' }
        if ((Get-EditorSyntax $Sections[$name]).Errors.Count) { Stop-BuilderValidation "PowerShell syntax error in $name. Correct the section before saving or building." }
    }
}
function Export-EditorTemplate([System.Collections.IDictionary]$Sections,[string]$Path) {
    Assert-EditorSections $Sections
    # Only section text and format identity; no payloads, paths, passwords or build settings.
    $document=[ordered]@{Format='PSADT-Sections';Schema=1;Sections=$Sections}
    [IO.File]::WriteAllText($Path,($document|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($true)))
}
function Import-EditorTemplate([string]$Path) {
    Assert-BuilderPath $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 8MB) { Stop-BuilderValidation 'Section template exceeds 8 MB.' }
    try { $data=([IO.File]::ReadAllText($Path,(New-Object Text.UTF8Encoding($false,$true))))|ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-BuilderValidation 'Select a valid PSADT section template JSON file.' }
    if (@($data.PSObject.Properties.Name).Count -ne 3 -or $data.PSObject.Properties.Name -notcontains 'Format' -or $data.PSObject.Properties.Name -notcontains 'Schema' -or $data.PSObject.Properties.Name -notcontains 'Sections' -or $data.Format -cne 'PSADT-Sections' -or $data.Schema -ne 1) { Stop-BuilderValidation 'Unsupported section template format.' }
    $sections=[ordered]@{}
    foreach ($property in $data.Sections.PSObject.Properties) { $sections[$property.Name]=$property.Value }
    Assert-EditorSections $sections
    return $sections
}
function Get-EditorLayout([string]$Text) {
    if ($Text.Length -gt 2MB) { Stop-BuilderValidation 'Deployment script exceeds the editor 2 MB limit.' }
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count) { Stop-BuilderValidation 'The deployment script has syntax errors; no sections were changed.' }
    $ast=$parsed.Ast
    $functions=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    if (-not @($functions|Where-Object Name -in @('Install-ADTDeployment','Uninstall-ADTDeployment','Repair-ADTDeployment')).Count) { return Get-LegacyEditorLayout $Text $parsed }
    $ranges=[ordered]@{}
    $deployment=@()
    foreach ($verb in @('Install','Uninstall','Repair')) {
        $matches=@($functions|Where-Object Name -eq ($verb+'-ADTDeployment'))
        if ($matches.Count -ne 1) { Stop-BuilderValidation 'Editor requires one top-level Install, Uninstall and Repair-ADTDeployment function (PSADT 4.x).' }
        $fn=$matches[0]; $deployment+=,$fn
        if ($null -ne $fn.Body.BeginBlock -or $null -ne $fn.Body.ProcessBlock -or $null -eq $fn.Body.EndBlock) { Stop-BuilderValidation 'Advanced begin/process deployment functions are not supported by the section editor.' }
        $phases=@($fn.Body.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -match '^\$adtSession\.InstallPhase$'
        })
        if ($phases.Count -ne 3) { Stop-BuilderValidation 'Each deployment function must have three direct adtSession.InstallPhase assignments. The editor will not guess section boundaries.' }
        $expected=@(('Pre'+$verb),$verb,('Post'+$verb))
        # Phase boundaries must be standalone assignments, not statements sharing a line.
        for ($i=0;$i -lt 3;$i++) {
            $phaseValue=$phases[$i].Right.Extent.Text.Trim().Trim("'",'"')
            $allowed=switch ($i) {
                0 { @("Pre-$verb",'Pre-$($adtSession.DeploymentType)') }
                1 { @($verb,'$adtSession.DeploymentType') }
                2 { @("Post-$verb",'Post-$($adtSession.DeploymentType)') }
            }
            if ($phaseValue -notin $allowed) { Stop-BuilderValidation 'Phase assignments must identify Pre, main, and Post in their original order.' }
            $lineEnd=$Text.IndexOf("`n",$phases[$i].Extent.EndOffset)
            if ($lineEnd -lt 0 -or $Text.Substring($phases[$i].Extent.EndOffset,$lineEnd-$phases[$i].Extent.EndOffset).Trim()) { Stop-BuilderValidation 'Phase assignments must be on their own lines.' }
            $start=$lineEnd+1
            $end=if ($i -lt 2) { $Text.LastIndexOf("`n",$phases[$i+1].Extent.StartOffset)+1 } else { $fn.Body.Extent.EndOffset-1 }
            $ranges[$expected[$i]]=@{Start=$start;End=$end}
        }
    }
    $first=($deployment|Sort-Object { $_.Extent.StartOffset }|Select-Object -First 1).Extent.StartOffset
    $customStart=@($parsed.Tokens|Where-Object { $_.Kind -eq 'Comment' -and $_.Text -ceq '#region BuilderCustomFunctions' })
    $customEnd=@($parsed.Tokens|Where-Object { $_.Kind -eq 'Comment' -and $_.Text -ceq '#endregion BuilderCustomFunctions' })
    if ($customStart.Count -or $customEnd.Count) {
        if ($customStart.Count -ne 1 -or $customEnd.Count -ne 1 -or $customEnd[0].Extent.StartOffset -le $customStart[0].Extent.EndOffset -or $customEnd[0].Extent.EndOffset -ge $first) { Stop-BuilderValidation 'Custom/functions markers are ambiguous or outside the supported location before the deployment functions.' }
        $ranges.CustomFunctions=@{Start=$customStart[0].Extent.EndOffset;End=$customEnd[0].Extent.StartOffset;Marked=$true}
        foreach ($helper in $functions|Where-Object { $_.Name -notin @('Install-ADTDeployment','Uninstall-ADTDeployment','Repair-ADTDeployment') }) {
            if ($helper.Extent.StartOffset -lt $ranges.CustomFunctions.Start -or $helper.Extent.EndOffset -gt $ranges.CustomFunctions.End) { Stop-BuilderValidation 'Custom functions outside the marked editor region must be moved into that region before editing.' }
        }
    } else {
        $helpers=@($functions|Where-Object { $_.Name -notin @('Install-ADTDeployment','Uninstall-ADTDeployment','Repair-ADTDeployment') })
        if ($helpers.Count) {
            $start=$helpers[0].Extent.StartOffset; $end=$helpers[-1].Extent.EndOffset
            $between=@($ast.EndBlock.Statements|Where-Object { $_.Extent.StartOffset -ge $start -and $_.Extent.EndOffset -le $end })
            if ($end -ge $first -or @($between|Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count) { Stop-BuilderValidation 'Custom functions must form one block before the deployment functions. Use Application packaging without the editor for this customized layout.' }
            $ranges.CustomFunctions=@{Start=$start;End=$end;Marked=$false}
        } else { $ranges.CustomFunctions=@{Start=$first;End=$first;Marked=$false} }
    }
    return $ranges
}
function Get-EditorSections([string]$Text) {
    $layout=Get-EditorLayout $Text
    $sections=[ordered]@{}
    foreach ($name in Get-EditorSectionNames) { $range=$layout[$name]; $sections[$name]=$Text.Substring($range.Start,$range.End-$range.Start) }
    Assert-EditorSections $sections
    return $sections
}
function Set-EditorSections([string]$Text,[System.Collections.IDictionary]$Sections) {
    Assert-EditorSections $Sections
    $layout=Get-EditorLayout $Text
    $changed=$false
    foreach ($name in Get-EditorSectionNames) { $range=$layout[$name]; if ($Sections[$name] -cne $Text.Substring($range.Start,$range.End-$range.Start)) { $changed=$true; break } }
    if (-not $changed) { return $Text }
    if ($Text -match '(?m)^# SIG # Begin signature block') { Stop-BuilderValidation 'The deployment script is signed. Supply an unsigned authoring copy for editing, then sign the generated script under your policy.' }
    $edits=@(foreach ($name in Get-EditorSectionNames) {
        $range=$layout[$name]; $replacement=$Sections[$name]
        # A no-op edit must preserve the original bytes, comments and line endings.
        if ($replacement -ceq $Text.Substring($range.Start,$range.End-$range.Start)) { continue }
        if ($name -eq 'CustomFunctions' -and -not $range.Marked) {
            if (-not $replacement -and $range.Start -eq $range.End) { continue }
            $replacement="#region BuilderCustomFunctions`r`n"+$replacement+"`r`n#endregion BuilderCustomFunctions`r`n`r`n"
        } elseif ($name -eq 'CustomFunctions') { $replacement="`r`n"+$replacement.Trim("`r","`n")+"`r`n" }
        elseif (-not $replacement.EndsWith("`n")) { $replacement+="`r`n" }
        @{Start=$range.Start;End=$range.End;Text=$replacement}
    })
    foreach ($edit in $edits|Sort-Object -Property @{Expression={[int]$_.Start};Descending=$true}) { $Text=$Text.Remove($edit.Start,$edit.End-$edit.Start).Insert($edit.Start,$edit.Text) }
    # Re-parse and re-map the full result: escaped braces or newly injected phase markers fail closed.
    $null=Get-EditorLayout $Text
    return $Text
}
function Read-EditorPackage([string]$ZipPath) {
    Assert-BuilderPath $ZipPath
    $work=Join-Path ([IO.Path]::GetTempPath()) ('PSADT-Editor-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($work)
    try {
        Protect-BuilderDirectory $work
        $snapshot=Join-Path $work 'input.zip'; Copy-Item -LiteralPath $ZipPath -Destination $snapshot
        $hash=(Get-FileHash -LiteralPath $snapshot).Hash
        $expanded=Join-Path $work 'Expanded'; Expand-BuilderZip $snapshot $expanded
        $entries=@(Get-ChildItem -LiteralPath $expanded -Recurse -File | Where-Object Name -in @('Invoke-AppDeployToolkit.ps1','Deploy-Application.ps1'))
        if ($entries.Count -ne 1) { Stop-BuilderValidation 'The ZIP must contain one Invoke-AppDeployToolkit.ps1 or Deploy-Application.ps1. If it contains several deployments, open the intended PS1 or ZIP that deployment separately.' }
        $entry=$entries[0]
        $document=New-EditorTextDocument (Read-EditorScript $entry.FullName)
        $document.SourceKind='ZIP';$document.Mode='Application';$document.ZIP_SHA256=$hash;$document.Path=[IO.Path]::GetFullPath($ZipPath)
        $document.EntryScript=$entry.Name;$document.EntryPath=$entry.FullName.Substring($expanded.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $document.Editable=$true
        return $document
    } finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
}
