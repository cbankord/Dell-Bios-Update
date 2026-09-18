$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ScriptEditorTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp);$oldData=$env:ProgramData
$env:ProgramData=$temp
$count=0
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name){$failed=$false;try{$null=& $Body}catch{$failed=$true};Check $failed $Name}
try {
    . "$root/Builder/Build-Package.ps1"
    $protected=New-Object 'Collections.Generic.List[string]'
    function Protect-BuilderDirectory($Path){$protected.Add($Path)}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/Test-SectionEditor.ps1",[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-SectionFixture'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $metadata=@'
@{
    # Preserve metadata comments and nested custom settings.
    AppName = 'Original app'
    AppVendor = 'Original vendor'
    AppVersion = '1.0'
    AppScriptAuthor = 'Original author'
    AppProcessesToClose = @('excel', @{Name='winword';Description='Word'})
    RequireAdmin = $true
    CustomValue = $(throw 'Never evaluate metadata')
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
}
'@
    $text=(New-SectionFixture).Replace("@{AppName='Existing identity'}",$metadata)
    $path=Join-Path $temp 'Invoke-AppDeployToolkit.ps1'
    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
    $originalHash=(Get-FileHash $path).Hash
    $doc=Read-EditorScriptDocument $path
    Check ($doc.SourceKind -eq 'Script' -and -not $doc.Editable -and $doc.Sections.Count -eq 10) 'Open PS1 previews sections without ZIP or build settings'
    Check ($doc.FileSHA256 -eq $originalHash -and $doc.Text -ceq $text) 'Text and hash come from the same byte snapshot'
    $fields=Get-EditorMetadataFields $doc.MetadataText
    Check ($fields.AppName.Literal -and $fields.AppName.Value -eq 'Original app') 'App name loaded as literal metadata'
    Check (-not $fields.CustomValue.Literal -and $fields.CustomValue.Value.Contains('Never evaluate')) 'Calculated metadata displayed without execution'
    Check (-not $fields.AppProcessesToClose.Literal -and $fields.AppProcessesToClose.Value.Contains('winword')) 'Nested custom settings preserved as source'
    Reject {Save-EditorScriptDocument $doc $path} 'Save requires explicit Edit state'
    $doc.Editable=$true
    Check (-not (Test-EditorDocumentDirty $doc)) 'Unchanged document is clean'
    $result=Save-EditorScriptDocument $doc $path
    Check (-not $result.Changed -and -not $result.BackupPath -and (Get-FileHash $path).Hash -eq $originalHash) 'No-op save keeps exact bytes and creates no backup'
    Check ((Get-EditorDocumentText $doc) -ceq $text) 'No-op section assembly preserves helper layout and metadata'
    $newName="Contoso's `$client"
    $doc.MetadataText=Set-EditorMetadataValues $doc.MetadataText @{AppName=$newName;AppVersion='2.0';AppScriptAuthor='New author';AppLang='EN'}
    $doc.Sections.Install="    Write-Output 'New installation'`r`n"
    $doc.Sections.CustomFunctions="function Get-Custom { return 'New helper' }"
    Check (Test-EditorDocumentDirty $doc) 'Metadata and section changes mark document dirty'
    $updated=Get-EditorMetadataFields $doc.MetadataText
    Check ($updated.AppName.Value -ceq $newName -and $updated.AppScriptAuthor.Value -eq 'New author' -and $updated.AppLang.Value -eq 'EN') 'Text values quote safely and missing metadata fields can be added'
    Check ($doc.MetadataText.Contains("@{Name='winword';Description='Word'}") -and $doc.MetadataText.Contains("CustomValue = `$(throw 'Never evaluate metadata')")) 'Unedited expressions, arrays and nested tables retained exactly'
    $result=Save-EditorScriptDocument $doc $path
    Check ($result.Changed -and (Test-Path $result.BackupPath)) 'Replacing the opened PS1 creates a backup'
    Check ((Get-FileHash $result.BackupPath).Hash -eq $originalHash) 'Backup retains original bytes including original encoding'
    $doc=$result.Document
    Check ($doc.Editable -and -not (Test-EditorDocumentDirty $doc)) 'Successful save returns fresh editable clean document'
    Check ($doc.Text.Contains('New installation') -and $doc.Text.Contains("throw 'Bootstrap must never execute'")) 'Saved code changes sections but keeps untouched bootstrap'
    Check (([IO.File]::ReadAllBytes($path)[0..2] -join ',') -eq '239,187,191') 'Edited saves use UTF-8 BOM for Windows PowerShell 5.1'
    Check (@(Get-ChildItem -LiteralPath $temp -Directory -Filter '.psadt-save-*').Count -eq 0) 'Save staging folder cleaned'
    Check ($protected.Count -eq 1 -and $protected[0] -ne $temp) 'Only private temporary child protected; source parent permissions untouched'
    $doc.Sections.PostInstall="    Write-Output 'Post install change'`n"
    [IO.File]::AppendAllText($path,"`n# Edited externally")
    $externalHash=(Get-FileHash $path).Hash
    Reject {Save-EditorScriptDocument $doc $path} 'External disk changes block overwrite'
    Check ((Get-FileHash $path).Hash -eq $externalHash) 'Conflict preserves the external writer version'
    $newPath=Join-Path $temp 'NewCopy.ps1';$copy=Save-EditorScriptDocument $doc $newPath
    Check ($copy.Document.Text.Contains('Post install change') -and (Get-FileHash $path).Hash -eq $externalHash) 'Save as new PS1 preserves pending edits without touching externally changed source'
    Reject {Save-EditorScriptDocument $doc $newPath} 'Save as does not overwrite another existing script'
    $bad=Read-EditorScriptDocument $path;$bad.Editable=$true;$bad.Sections.Install='if ('
    Reject {Save-EditorScriptDocument $bad $path} 'Invalid section blocked before disk writes'
    Check ((Get-FileHash $path).Hash -eq $externalHash) 'Syntax failure leaves original intact'
    Reject {Set-EditorMetadataValues $metadata @{CustomValue='override'}} 'Metadata form cannot silently replace a calculated expression'
    Reject {Set-EditorScriptMetadata $text "@{AppName='X'}`nthrow 'escape'"} 'Custom settings cannot escape the metadata table'
    Reject {Get-EditorMetadataTable "@{AppName='X';AppName='Y'}"} 'Duplicate metadata keys rejected'
    $settings=New-PackageBuildSettings;$settings.ApplicationName='Generated';$settings.ApplicationVersion='3.0'
    $generated=Set-MaintenanceIdentity $text $settings
    Check ($generated.Contains("AppName = 'Generated'") -and $generated.Contains("@{Name='winword';Description='Word'}")) 'Servicing identity accepts nested process metadata and preserves nested content'
    $signedPath=Join-Path $temp 'Signed.ps1';[IO.File]::WriteAllText($signedPath,$text+"`n# SIG # Begin signature block")
    $signed=Read-EditorScriptDocument $signedPath;$signed.Editable=$true
    Reject {Save-EditorScriptDocument $signed $signedPath} 'Signed input cannot be changed or stripped'
    $live=Join-Path $env:ProgramData 'Medela/DellBIOS';$null=[IO.Directory]::CreateDirectory($live)
    Reject {Save-EditorScriptDocument $copy.Document (Join-Path $live 'runtime.ps1')} 'Live BIOS cache cannot be a save destination'
    # A failed atomic replacement cleans only temporary output.
    $fresh=Read-EditorScriptDocument $path;$fresh.Editable=$true;$fresh.Sections.Install="    Write-Output 2`n"
    function Protect-BuilderDirectory($Path){throw 'inert ACL failure'}
    Reject {Save-EditorScriptDocument $fresh $path} 'Save protection failure is contained'
    Check ((Get-FileHash $path).Hash -eq $externalHash -and @(Get-ChildItem $temp -Directory -Filter '.psadt-save-*').Count -eq 0) 'Failed save preserves source and cleans its private temporary child'
    Write-Output "PASS: $count direct PS1/metadata/save assertions. Real file IO and atomic replacement; Windows ACL application mocked."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
