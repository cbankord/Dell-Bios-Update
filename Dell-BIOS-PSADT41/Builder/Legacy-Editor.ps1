# PSADT 3.x authoring adapters. Only AST/text operations; imported code never runs.
function Get-EditorVariableName($Assignment) {
    if ($Assignment -isnot [Management.Automation.Language.AssignmentStatementAst] -or $Assignment.Operator -ne 'Equals') { return '' }
    $left=$Assignment.Left
    while ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left=$left.Child }
    if ($left -is [Management.Automation.Language.VariableExpressionAst]) { return ($left.VariablePath.UserPath -replace '^script:','') }
    return ''
}
function Get-EditorTopStatements($Ast) {
    foreach ($statement in $Ast.EndBlock.Statements) {
        $statement
        if ($statement -is [Management.Automation.Language.TryStatementAst]) { $statement.Body.Statements }
    }
}
function Get-LegacyMetadataNames {
    @('AppVendor','AppName','AppVersion','AppArch','AppLang','AppRevision','AppScriptVersion','AppScriptDate','AppScriptAuthor','InstallName','InstallTitle')
}
function Get-LegacyMetadataLayout([string]$Text) {
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count) { Stop-BuilderValidation 'Correct the PowerShell syntax before editing metadata.' }
    $names=Get-LegacyMetadataNames
    $fields=@(Get-EditorTopStatements $parsed.Ast | Where-Object { (Get-EditorVariableName $_) -in $names })
    if (@($fields | Where-Object { (Get-EditorVariableName $_) -eq 'AppName' }).Count -ne 1 -or @($fields | Where-Object { (Get-EditorVariableName $_) -eq 'AppVersion' }).Count -ne 1) { Stop-BuilderValidation 'The legacy metadata block is unavailable or ambiguous.' }
    $parent=$fields[0].Parent
    foreach ($field in $fields) { if (-not [object]::ReferenceEquals($field.Parent,$parent)) { Stop-BuilderValidation 'Legacy metadata fields must share one script-level block.' } }
    $start=$fields[0].Extent.StartOffset; $end=$fields[-1].Extent.EndOffset
    $buffer=$Text.Substring($start,$end-$start)
    $null=Get-LegacyMetadataAssignments $buffer
    return @{Start=$start;End=$end;Text=$buffer}
}
function Get-LegacyMetadataAssignments([string]$Text) {
    if ($Text.Length -gt 100000) { Stop-BuilderValidation 'Custom settings exceed 100,000 characters.' }
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count -or $null -ne $parsed.Ast.ParamBlock -or $null -ne $parsed.Ast.BeginBlock -or $null -ne $parsed.Ast.ProcessBlock) { Stop-BuilderValidation 'Legacy custom settings must be valid variable assignments.' }
    $fields=[ordered]@{}
    foreach ($statement in $parsed.Ast.EndBlock.Statements) {
        $name=Get-EditorVariableName $statement
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$' -or $fields.Contains($name)) { Stop-BuilderValidation 'Legacy custom settings require unique variable assignments; use the full script view for other initialization code.' }
        $fields[$name]=$statement
    }
    return ,$fields
}
function Get-LegacyMetadataFields([string]$Text) {
    $assignments=Get-LegacyMetadataAssignments $Text; $fields=[ordered]@{}
    foreach ($key in $assignments.Keys) {
        $value=Get-EditorExpression $assignments[$key].Right
        $literal=$value -is [Management.Automation.Language.StringConstantExpressionAst]
        $fields[$key]=@{Literal=$literal;Value=$(if ($literal) {$value.Value} else {$assignments[$key].Right.Extent.Text})}
    }
    return ,$fields
}
function Set-LegacyMetadataValues([string]$Text,[System.Collections.IDictionary]$Values) {
    $fields=Get-LegacyMetadataAssignments $Text; $edits=@(); $additions=New-Object 'Collections.Generic.List[string]'
    foreach ($key in $Values.Keys) {
        if ($key -notin (Get-LegacyMetadataNames) -or $Values[$key] -isnot [string] -or $Values[$key].Length -gt 2000 -or $Values[$key] -match '[\x00-\x1f]') { Stop-BuilderValidation 'Enter a valid legacy metadata text value (2,000 characters maximum).' }
        $literal="'"+$Values[$key].Replace("'","''")+"'"
        if ($fields.Contains($key)) {
            $field=$fields[$key]; $expression=Get-EditorExpression $field.Right
            if ($expression -isnot [Management.Automation.Language.StringConstantExpressionAst]) { Stop-BuilderValidation 'A calculated metadata value must be edited explicitly in Custom settings.' }
            if ($expression.Value -ceq $Values[$key]) { continue }
            $edits+=@{Start=$field.Right.Extent.StartOffset;End=$field.Right.Extent.EndOffset;Text=$literal}
        } else { $additions.Add(('[string]${0} = {1}' -f $key,$literal)) }
    }
    foreach ($edit in $edits|Sort-Object -Property @{Expression={[int]$_.Start};Descending=$true}) { $Text=$Text.Remove($edit.Start,$edit.End-$edit.Start).Insert($edit.Start,$edit.Text) }
    if ($additions.Count) { $nl=if ($Text.Contains("`r`n")) {"`r`n"} else {"`n"}; $Text+=$nl+($additions -join $nl) }
    $null=Get-LegacyMetadataAssignments $Text
    return $Text
}
function Set-LegacyScriptMetadata([string]$Script,[string]$MetadataText) {
    $null=Get-LegacyMetadataAssignments $MetadataText
    $layout=Get-LegacyMetadataLayout $Script
    if ($layout.Text -ceq $MetadataText) { return $Script }
    if ($Script -match '(?m)^# SIG # Begin signature block') { Stop-BuilderValidation 'Use an unsigned authoring copy before editing a signed deployment script.' }
    $result=$Script.Remove($layout.Start,$layout.End-$layout.Start).Insert($layout.Start,$MetadataText)
    $null=Get-LegacyMetadataLayout $result
    return $result
}
function Get-LegacyEditorLayout([string]$Text,$Parsed) {
    $ranges=[ordered]@{}; $dispatcher=$null
    $blocks=@($Parsed.Ast.FindAll({param($n) $n -is [Management.Automation.Language.StatementBlockAst]},$true))
    foreach ($verb in @('Install','Uninstall','Repair')) {
        $main=switch ($verb) { Install {'Installation'} Uninstall {'Uninstallation'} Repair {'Repair'} }
        $expected=@(('Pre-'+$main),$main,('Post-'+$main));$candidates=@()
        foreach ($block in $blocks) {
            if ($block.Parent -isnot [Management.Automation.Language.IfStatementAst]) { continue }
            $phases=@($block.Statements | Where-Object { (Get-EditorVariableName $_) -eq 'installPhase' })
            if ($phases.Count -ne 3) { continue }
            $match=$true
            for ($i=0;$i -lt 3;$i++) { $value=Get-EditorExpression $phases[$i].Right; if ($value -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $value.Value -ne $expected[$i]) { $match=$false } }
            if ($match) { $candidates+=@{Block=$block;Phases=$phases} }
        }
        if ($candidates.Count -ne 1) { Stop-BuilderValidation 'Legacy section editing needs one Pre/main/Post block for Install, Uninstall and Repair. Use full script editing for this layout.' }
        $block=$candidates[0].Block;$phases=$candidates[0].Phases
        if ($null -eq $dispatcher) { $dispatcher=$block.Parent }
        elseif (-not [object]::ReferenceEquals($dispatcher,$block.Parent)) { Stop-BuilderValidation 'Legacy phases must belong to the same deployment dispatcher.' }
        $keys=@(('Pre'+$verb),$verb,('Post'+$verb))
        for ($i=0;$i -lt 3;$i++) {
            $lineEnd=$Text.IndexOf("`n",$phases[$i].Extent.EndOffset)
            if ($lineEnd -lt 0 -or $Text.Substring($phases[$i].Extent.EndOffset,$lineEnd-$phases[$i].Extent.EndOffset).Trim()) { Stop-BuilderValidation 'Legacy phase assignments must be on their own lines.' }
            $end=if ($i -lt 2) { $Text.LastIndexOf("`n",$phases[$i+1].Extent.StartOffset)+1 } else { $block.Extent.EndOffset-1 }
            $ranges[$keys[$i]]=@{Start=$lineEnd+1;End=$end}
        }
    }
    # Only script-level dispatchers are mapped. Nested app logic is never guessed.
    $anc=$dispatcher.Parent
    while ($null -ne $anc) { if ($anc -is [Management.Automation.Language.FunctionDefinitionAst] -or $anc -is [Management.Automation.Language.IfStatementAst]) { Stop-BuilderValidation 'Use full script editing for a nested legacy dispatcher.' };$anc=$anc.Parent }
    $first=$dispatcher.Extent.StartOffset
    $startTokens=@($Parsed.Tokens|Where-Object { $_.Kind -eq 'Comment' -and $_.Text -ceq '#region BuilderCustomFunctions' })
    $endTokens=@($Parsed.Tokens|Where-Object { $_.Kind -eq 'Comment' -and $_.Text -ceq '#endregion BuilderCustomFunctions' })
    $helpers=@($Parsed.Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object {
        $fn=$_; -not @($ranges.Values | Where-Object { $fn.Extent.StartOffset -ge $_.Start -and $fn.Extent.EndOffset -le $_.End }).Count
    })
    if ($startTokens.Count -or $endTokens.Count) {
        if ($startTokens.Count -ne 1 -or $endTokens.Count -ne 1 -or $endTokens[0].Extent.StartOffset -le $startTokens[0].Extent.EndOffset -or $endTokens[0].Extent.EndOffset -ge $first) { Stop-BuilderValidation 'Legacy custom/functions markers are ambiguous.' }
        $custom=@{Start=$startTokens[0].Extent.EndOffset;End=$endTokens[0].Extent.StartOffset;Marked=$true}
    } elseif ($helpers.Count) {
        $start=$helpers[0].Extent.StartOffset;$end=$helpers[-1].Extent.EndOffset
        if ($end -ge $first) { Stop-BuilderValidation 'Use full script editing for custom functions after the legacy dispatcher.' }
        foreach ($helper in $helpers) { if (-not [object]::ReferenceEquals($helper.Parent,$dispatcher.Parent)) { Stop-BuilderValidation 'Use full script editing for separate custom helper blocks.' } }
        $between=@($dispatcher.Parent.Statements|Where-Object { $_.Extent.StartOffset -ge $start -and $_.Extent.EndOffset -le $end })
        if (@($between|Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }).Count) { Stop-BuilderValidation 'Use full script editing for mixed legacy initialization and helpers.' }
        $custom=@{Start=$start;End=$end;Marked=$false}
    } else { $custom=@{Start=$first;End=$first;Marked=$false} }
    foreach ($helper in $helpers) { if ($helper.Extent.StartOffset -lt $custom.Start -or $helper.Extent.EndOffset -gt $custom.End) { Stop-BuilderValidation 'Custom functions outside the marked region require full script editing.' } }
    $ranges.CustomFunctions=$custom
    return $ranges
}
