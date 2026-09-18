# Standalone PSADT documents. Parsing/metadata inspection never evaluates code.
function Get-EditorExpression($Node) {
    if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { return $Node.Expression }
    if ($Node -is [Management.Automation.Language.PipelineAst]) { return $Node.GetPureExpression() }
    return $null
}
function Get-EditorMetadataLayout([string]$Text) {
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count) { Stop-BuilderValidation 'Correct the PowerShell syntax before editing metadata.' }
    $tables=@(foreach ($statement in Get-EditorTopStatements $parsed.Ast) {
        if ((Get-EditorVariableName $statement) -ne 'adtSession') { continue }
        $expression=Get-EditorExpression $statement.Right
        if ($expression -is [Management.Automation.Language.ConvertExpressionAst] -and $expression.Type.TypeName.FullName -eq 'ordered') { $expression=$expression.Child }
        if ($expression -is [Management.Automation.Language.HashtableAst]) { $expression }
    })
    if ($tables.Count -ne 1) { Stop-BuilderValidation 'Metadata editing requires one literal top-level adtSession table. Calculated metadata is left to the original script.' }
    return $tables[0]
}
function Get-EditorMetadataTable([string]$Text) {
    if ($Text.Length -gt 100000) { Stop-BuilderValidation 'Custom settings exceed 100,000 characters.' }
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count -or $parsed.Ast.EndBlock.Statements.Count -ne 1) { Stop-BuilderValidation 'Custom settings must be one valid PowerShell @{ ... } table.' }
    $table=Get-EditorExpression $parsed.Ast.EndBlock.Statements[0]
    if ($table -isnot [Management.Automation.Language.HashtableAst]) { Stop-BuilderValidation 'Custom settings must be a literal @{ ... } table; its values are parsed, not executed.' }
    foreach ($pair in $table.KeyValuePairs) {
        if ($pair.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst]) { Stop-BuilderValidation 'Metadata field names must be literal strings.' }
    }
    return $table
}
function Get-EditorMetadataFields([string]$Text,[string]$Kind='Table') {
    if ($Kind -eq 'Variables') { return Get-LegacyMetadataFields $Text }
    $table=Get-EditorMetadataTable $Text
    $fields=[ordered]@{}
    foreach ($pair in $table.KeyValuePairs) {
        $value=Get-EditorExpression $pair.Item2
        $literal=$value -is [Management.Automation.Language.StringConstantExpressionAst]
        $fields[$pair.Item1.Value]=@{Literal=$literal;Value=$(if ($literal) {$value.Value} else {$pair.Item2.Extent.Text})}
    }
    return $fields
}
function Set-EditorMetadataValues([string]$Text,[System.Collections.IDictionary]$Values,[string]$Kind='Table') {
    if ($Kind -eq 'Variables') { return Set-LegacyMetadataValues $Text $Values }
    $table=Get-EditorMetadataTable $Text
    $existing=@{}; foreach ($pair in $table.KeyValuePairs) { $existing[$pair.Item1.Value]=$pair }
    $edits=@(); $additions=New-Object 'Collections.Generic.List[string]'
    foreach ($key in $Values.Keys) {
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9]*$' -or $Values[$key] -isnot [string] -or $Values[$key].Length -gt 2000 -or $Values[$key] -match '[\x00-\x1f]') { Stop-BuilderValidation 'Metadata text fields must be plain text of 2,000 characters or less.' }
        $literal="'"+$Values[$key].Replace("'","''")+"'"
        if ($existing.ContainsKey($key)) {
            $pair=$existing[$key]; $expression=Get-EditorExpression $pair.Item2
            if ($expression -isnot [Management.Automation.Language.StringConstantExpressionAst]) { Stop-BuilderValidation 'A calculated metadata value must be edited explicitly in Custom settings.' }
            if ($expression.Value -ceq $Values[$key]) { continue }
            $edits+=@{Start=$pair.Item2.Extent.StartOffset;End=$pair.Item2.Extent.EndOffset;Text=$literal}
        } else { $additions.Add(('    {0} = {1}' -f $key,$literal)) }
    }
    if ($additions.Count) {
        $newline=if ($Text.Contains("`r`n")) {"`r`n"} else {"`n"}
        $edits+=@{Start=$table.Extent.EndOffset-1;End=$table.Extent.EndOffset-1;Text=($newline+($additions -join $newline)+$newline)}
    }
    foreach ($edit in $edits|Sort-Object -Property @{Expression={[int]$_.Start};Descending=$true}) { $Text=$Text.Remove($edit.Start,$edit.End-$edit.Start).Insert($edit.Start,$edit.Text) }
    $null=Get-EditorMetadataTable $Text
    return $Text
}
function Set-EditorScriptMetadata([string]$Script,[string]$MetadataText,[string]$Kind='Table') {
    if ($Kind -eq 'Variables') { return Set-LegacyScriptMetadata $Script $MetadataText }
    $null=Get-EditorMetadataTable $MetadataText
    $table=Get-EditorMetadataLayout $Script
    if ($table.Extent.Text -ceq $MetadataText) { return $Script }
    if ($Script -match '(?m)^# SIG # Begin signature block') { Stop-BuilderValidation 'Use an unsigned authoring copy before editing a signed deployment script.' }
    $result=$Script.Remove($table.Extent.StartOffset,$table.Extent.EndOffset-$table.Extent.StartOffset).Insert($table.Extent.StartOffset,$MetadataText)
    $null=Get-EditorMetadataLayout $result
    return $result
}
function Get-EditorByteHash([byte[]]$Bytes) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','') }
    finally { $hash.Dispose() }
}
function Get-EditorDocumentMetadataKind([System.Collections.IDictionary]$Document) {
    if ($Document.Contains('MetadataKind')) { return $Document.MetadataKind }
    return 'Table'
}
function Test-EditorFullScript([System.Collections.IDictionary]$Document) {
    return ($null -ne $Document -and $Document.Contains('LayoutKind') -and $Document.LayoutKind -eq 'FullScript')
}
function Assert-EditorScriptText([string]$Text) {
    if ($Text.Length -gt 2MB) { Stop-BuilderValidation 'The script exceeds the editor text limit.' }
    if ((Get-EditorSyntax $Text).Errors.Count) { Stop-BuilderValidation 'The deployment script has PowerShell syntax errors. Correct them before opening, saving or building.' }
}
function New-EditorTextDocument([string]$Text) {
    Assert-EditorScriptText $Text
    $document=@{Text=$Text;Signed=($Text -match '(?m)^# SIG # Begin signature block');Editable=$false;LayoutKind='Sections'}
    try { $document.Sections=Get-EditorSections $Text }
    catch {
        # Unknown boundaries never stop a valid script opening or cause guessed edits.
        $document.LayoutKind='FullScript';$document.CurrentScript=$Text
        $document.MetadataUnavailable=$true
        $document.LayoutNotice='Custom layout: the complete script is available in Full script. Section boundaries were not guessed.'
        return $document
    }
    try {
        $metadata=(Get-EditorMetadataLayout $Text).Extent.Text
        $null=Get-EditorMetadataTable $metadata
        $document.MetadataText=$metadata;$document.MetadataKind='Table'
    } catch {
        try { $document.MetadataText=(Get-LegacyMetadataLayout $Text).Text;$document.MetadataKind='Variables' }
        catch { $document.MetadataUnavailable=$true;$document.LayoutNotice='Metadata is calculated or stored elsewhere. Deployment sections remain editable; original metadata is preserved.' }
    }
    return $document
}
function Read-EditorScriptDocument([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ne '.ps1') { Stop-BuilderValidation 'Open a PSADT deployment .ps1 file.' }
    Assert-BuilderPath $Path
    $path=[IO.Path]::GetFullPath($Path)
    $stream=[IO.File]::Open($path,'Open','Read','Read'); $reader=$null; $memory=$null
    try {
        if ($stream.Length -gt 8MB) { Stop-BuilderValidation 'The script exceeds the editor 8 MB file limit.' }
        $memory=New-Object IO.MemoryStream; $stream.CopyTo($memory); $bytes=$memory.ToArray(); $memory.Position=0
        $reader=New-Object IO.StreamReader($memory,(New-Object Text.UTF8Encoding($false,$true)),$true)
        try { $text=$reader.ReadToEnd() } catch { Stop-BuilderValidation 'Use valid UTF-8 or BOM-marked Unicode for this authoring script.' }
        $document=New-EditorTextDocument $text
        $document.SourceKind='Script';$document.Mode='Script';$document.Path=$path;$document.FileSHA256=Get-EditorByteHash $bytes
        return $document
    } finally { if ($null -ne $reader) {$reader.Dispose()};if ($null -ne $memory) {$memory.Dispose()};$stream.Dispose() }
}
function Get-EditorDocumentText([System.Collections.IDictionary]$Document) {
    if (Test-EditorFullScript $Document) {
        Assert-EditorScriptText $Document.CurrentScript
        if ($Document.CurrentScript -cne $Document.Text -and $Document.Text -match '(?m)^# SIG # Begin signature block') { Stop-BuilderValidation 'Use an unsigned authoring copy before editing a signed deployment script.' }
        return $Document.CurrentScript
    }
    $text=Set-EditorSections $Document.Text $Document.Sections
    if ($Document.Contains('MetadataText')) { $text=Set-EditorScriptMetadata $text $Document.MetadataText (Get-EditorDocumentMetadataKind $Document) }
    $null=Get-EditorLayout $text
    return $text
}
function Test-EditorDocumentDirty([System.Collections.IDictionary]$Document) {
    if ($null -eq $Document) { return $false }
    if (Test-EditorFullScript $Document) { return $Document.CurrentScript -cne $Document.Text }
    $original=Get-EditorSections $Document.Text
    foreach ($key in Get-EditorSectionNames) { if ($original[$key] -cne $Document.Sections[$key]) { return $true } }
    if ($Document.Contains('MetadataText')) {
        $originalMetadata=if ((Get-EditorDocumentMetadataKind $Document) -eq 'Variables') { (Get-LegacyMetadataLayout $Document.Text).Text } else { (Get-EditorMetadataLayout $Document.Text).Extent.Text }
        if ($originalMetadata -cne $Document.MetadataText) { return $true }
    }
    return $false
}
function Save-EditorScriptDocument([System.Collections.IDictionary]$Document,[string]$Destination) {
    if (-not $Document.Contains('SourceKind') -or $Document.SourceKind -ne 'Script' -or -not $Document.Editable) { Stop-BuilderValidation 'Open a PS1 and click Edit before saving a script.' }
    if ($Document.Signed) { Stop-BuilderValidation 'Create an unsigned authoring copy before editing; existing signatures are not removed.' }
    $text=Get-EditorDocumentText $Document
    if (-not [IO.Path]::IsPathRooted($Destination) -or $Destination.StartsWith('\\') -or [IO.Path]::GetExtension($Destination) -ne '.ps1') { Stop-BuilderValidation 'Save to a local absolute PS1 path on an ACL-capable disk.' }
    $destination=[IO.Path]::GetFullPath($Destination); $parent=[IO.Path]::GetDirectoryName($destination)
    Assert-BuilderPath $parent
    $live=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'Medela/DellBIOS'))+[IO.Path]::DirectorySeparatorChar
    if ($destination.StartsWith($live,[StringComparison]::OrdinalIgnoreCase)) { Stop-BuilderValidation 'Edit an authoring copy outside the managed BIOS runtime cache.' }
    $same=[string]::Equals($destination,$Document.Path,[StringComparison]::OrdinalIgnoreCase)
    $mutexName='Local\PSADT-ScriptSave-'+(Get-EditorByteHash ([Text.Encoding]::UTF8.GetBytes($destination.ToUpperInvariant())))
    $mutex=New-Object Threading.Mutex($false,$mutexName); $owned=$false; $work=''
    try {
        try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) { Stop-BuilderValidation 'Another editor is saving this file. Retry when it finishes.' }
        if ($same) {
            Assert-BuilderPath $destination
            if ((Get-FileHash -LiteralPath $destination).Hash -ne $Document.FileSHA256) { Stop-BuilderValidation 'The PS1 changed on disk after it was opened. Reopen it, or Save as new PS1 to preserve your edits separately.' }
            if ($text -ceq $Document.Text) { return @{Document=$Document;BackupPath='';Changed=$false} }
        } elseif (Test-Path -LiteralPath $destination) { Stop-BuilderValidation 'Save as requires a new filename. Open an existing file first if you intend to replace it.' }
        $work=Join-Path $parent ('.psadt-save-'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($work); Protect-BuilderDirectory $work
        $temporary=Join-Path $work 'validated.ps1'
        [IO.File]::WriteAllText($temporary,$text,(New-Object Text.UTF8Encoding($true)))
        $backup=''
        if ($same) {
            Assert-BuilderPath $destination
            if ((Get-FileHash -LiteralPath $destination).Hash -ne $Document.FileSHA256) { Stop-BuilderValidation 'The source changed while the save was being prepared. Reopen it or save a new copy.' }
            $backup=$destination+'.'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.bak'
            [IO.File]::Replace($temporary,$destination,$backup,$false)
        } else { [IO.File]::Move($temporary,$destination) }
        $fresh=Read-EditorScriptDocument $destination; $fresh.Editable=$true
        return @{Document=$fresh;BackupPath=$backup;Changed=$true}
    } finally {
        if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
        if ($owned) { $mutex.ReleaseMutex() };$mutex.Dispose()
    }
}
