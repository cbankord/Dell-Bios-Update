# Standalone PSADT 4.x documents. Parsing/metadata inspection never evaluates code.
function Get-EditorExpression($Node) {
    if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { return $Node.Expression }
    if ($Node -is [Management.Automation.Language.PipelineAst]) { return $Node.GetPureExpression() }
    return $null
}
function Get-EditorMetadataLayout([string]$Text) {
    $parsed=Get-EditorSyntax $Text
    if ($parsed.Errors.Count) { Stop-BuilderValidation 'Correct the PowerShell syntax before editing metadata.' }
    $tables=@(foreach ($statement in $parsed.Ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.AssignmentStatementAst] -or $statement.Left.Extent.Text -ne '$adtSession') { continue }
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
function Get-EditorMetadataFields([string]$Text) {
    $table=Get-EditorMetadataTable $Text
    $fields=[ordered]@{}
    foreach ($pair in $table.KeyValuePairs) {
        $value=Get-EditorExpression $pair.Item2
        $literal=$value -is [Management.Automation.Language.StringConstantExpressionAst]
        $fields[$pair.Item1.Value]=@{Literal=$literal;Value=$(if ($literal) {$value.Value} else {$pair.Item2.Extent.Text})}
    }
    return $fields
}
function Set-EditorMetadataValues([string]$Text,[System.Collections.IDictionary]$Values) {
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
function Set-EditorScriptMetadata([string]$Script,[string]$MetadataText) {
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
        $metadata=(Get-EditorMetadataLayout $text).Extent.Text
        $null=Get-EditorMetadataTable $metadata
        return @{SourceKind='Script';Mode='Script';Path=$path;FileSHA256=(Get-EditorByteHash $bytes);Text=$text;MetadataText=$metadata;Sections=(Get-EditorSections $text);Signed=($text -match '(?m)^# SIG # Begin signature block');Editable=$false}
    } finally { if ($null -ne $reader) {$reader.Dispose()};if ($null -ne $memory) {$memory.Dispose()};$stream.Dispose() }
}
function Get-EditorDocumentText([System.Collections.IDictionary]$Document) {
    $text=Set-EditorSections $Document.Text $Document.Sections
    if ($Document.Contains('MetadataText')) { $text=Set-EditorScriptMetadata $text $Document.MetadataText }
    $null=Get-EditorLayout $text
    return $text
}
function Test-EditorDocumentDirty([System.Collections.IDictionary]$Document) {
    if ($null -eq $Document) { return $false }
    $original=Get-EditorSections $Document.Text
    foreach ($key in Get-EditorSectionNames) { if ($original[$key] -cne $Document.Sections[$key]) { return $true } }
    if ($Document.Contains('MetadataText') -and (Get-EditorMetadataLayout $Document.Text).Extent.Text -cne $Document.MetadataText) { return $true }
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
