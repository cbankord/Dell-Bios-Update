# v5.0.0 - Detached authoring copies and reviewable installer upgrades.
function Copy-UpgradeTree([string]$Source,[string]$Destination) {
    Assert-BuilderPath $Source
    $sourceRoot=[IO.Path]::GetFullPath($Source).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetFullPath($Destination).StartsWith($sourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { Stop-BuilderValidation 'Choose a working folder outside the source package.' }
    $items=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)
    if ($items.Count -gt 20000) { Stop-BuilderValidation 'The authoring folder contains more than 20,000 entries. Open the deployment package folder only.' }
    [long]$total=0
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-BuilderValidation 'Package copies cannot include links or junctions.' }
        if (-not $item.PSIsContainer) { $total+=$item.Length;if ($item.Length -gt 2GB -or $total -gt 4GB) {Stop-BuilderValidation 'Package copy exceeds the 2 GB file or 4 GB package limit.'} }
    }
    $null=[IO.Directory]::CreateDirectory($Destination)
    foreach ($item in $items) {
        $relative=$item.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\','/'))
        $target=Join-Path $Destination $relative
        if ($item.PSIsContainer) { $null=[IO.Directory]::CreateDirectory($target) }
        else { Assert-BuilderPath $item.FullName;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));Copy-Item -LiteralPath $item.FullName -Destination $target }
    }
}
function New-AuthoringSnapshot([System.Collections.IDictionary]$Document) {
    if ($null -eq $Document) { Stop-BuilderValidation 'Open the complete application ZIP or its entry PS1 first.' }
    if ($Document.Mode -in @('BIOS','WindowsUpdate','Driver')) { Stop-BuilderValidation 'Installer replacement is for Application authoring. Use the dedicated payload settings for BIOS and servicing.' }
    $snapshot=@{Text=(Get-EditorDocumentText $Document);Path=$Document.Path;SourceKind=$Document.SourceKind;Signed=$Document.Signed}
    if ($Document.SourceKind -eq 'ZIP') { $snapshot.SourceHash=$Document.ZIP_SHA256;$snapshot.EntryPath=$Document.EntryPath }
    else { $snapshot.SourceHash=$Document.FileSHA256;$snapshot.EntryPath=[IO.Path]::GetFileName($Document.Path) }
    return $snapshot
}
function New-UpgradeWorkspace([hashtable]$Snapshot,[string]$OutputRoot) {
    $parent=Resolve-BuilderOutputRoot $OutputRoot
    $work=Join-Path $parent ('PSADT-Work-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($work);$success=$false
    try {
        Protect-BuilderDirectory $work
        Assert-BuilderPath $Snapshot.Path
        if ((Get-FileHash -LiteralPath $Snapshot.Path).Hash -ne $Snapshot.SourceHash) { Stop-BuilderValidation 'The source changed after opening. Reopen it before replacing an installer or testing.' }
        $source=Join-Path $work 'Source'
        if ($Snapshot.SourceKind -eq 'ZIP') {
            $zip=Join-Path $work 'input.zip';Copy-Item -LiteralPath $Snapshot.Path -Destination $zip
            if ((Get-FileHash -LiteralPath $zip).Hash -ne $Snapshot.SourceHash) { Stop-BuilderValidation 'The ZIP changed during copying. Reopen it and retry.' }
            $expanded=Join-Path $work 'Expanded';Expand-BuilderZip $zip $expanded
            $entry=Join-Path $expanded $Snapshot.EntryPath
            Assert-BuilderPath $entry
            Copy-UpgradeTree ([IO.Path]::GetDirectoryName($entry)) $source
            Remove-Item -LiteralPath $expanded -Recurse -Force;Remove-Item -LiteralPath $zip -Force
        } else {
            if ([IO.Path]::GetFileName($Snapshot.Path) -notin @('Deploy-Application.ps1','Invoke-AppDeployToolkit.ps1')) { Stop-BuilderValidation 'For replacement/testing, open the standard entry PS1 in its complete app folder, or open the complete ZIP.' }
            Copy-UpgradeTree ([IO.Path]::GetDirectoryName($Snapshot.Path)) $source
            if ((Get-FileHash -LiteralPath (Join-Path $source $Snapshot.EntryPath)).Hash -ne $Snapshot.SourceHash) { Stop-BuilderValidation 'The entry script changed during copying. Reopen it and retry.' }
        }
        $entryName=[IO.Path]::GetFileName($Snapshot.EntryPath)
        $entry=Join-Path $source $entryName
        if ((Read-EditorScript $entry) -cne $Snapshot.Text) {
            if ($Snapshot.Signed) { Stop-BuilderValidation 'Signed source cannot be edited automatically.' }
            [IO.File]::WriteAllText($entry,$Snapshot.Text,(New-Object Text.UTF8Encoding($true)))
        }
        $success=$true
        return @{Root=$work;Source=$source;EntryScript=$entryName;Text=$Snapshot.Text;InputHash=$Snapshot.SourceHash;Signed=$Snapshot.Signed}
    } finally { if (-not $success -and (Test-Path -LiteralPath $work)) {Remove-Item -LiteralPath $work -Recurse -Force} }
}
function Get-UpgradeInstallFiles([hashtable]$Workspace) {
    $files=Join-Path $Workspace.Source 'Files'
    if (-not (Test-Path -LiteralPath $files -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $files -Recurse -File|Where-Object Extension -in @('.msi','.exe','.mst')|ForEach-Object {$_.FullName.Substring($Workspace.Source.Length+1).Replace('\','/')}|Sort-Object)
}
function Get-UpgradePhase([string]$Text,[int]$Offset,$Layout) {
    if ($null -ne $Layout) { foreach ($key in $Layout.Keys) { if ($Offset -ge $Layout[$key].Start -and $Offset -lt $Layout[$key].End) {return [string]$key} } }
    return 'Custom/script'
}
function New-UpgradeReferencePlan([string]$Text,[string]$OldName,[string]$NewName,[string]$OldCode='',[string]$NewCode='',[string]$OldMst='',[string]$NewMst='') {
    Assert-EditorScriptText $Text
    $layout=$null;try {$layout=Get-EditorLayout $Text} catch {}
    $nodes=(Get-EditorSyntax $Text).Ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true)
    $edits=New-Object Collections.ArrayList;$seen=@{}
    foreach ($node in $nodes) {
        # A calculated directory prefix is fine. If a nested expression contains a
        # replacement target, leave the outer node alone to avoid overlapping edits.
        if ($node -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
            $nestedTarget=$false
            foreach ($nested in $node.NestedExpressions) {foreach ($target in @($OldName,$OldCode,$OldMst)) {if ($target -and $nested.Extent.Text.IndexOf($target,[StringComparison]::OrdinalIgnoreCase) -ge 0) {$nestedTarget=$true}}}
            if ($nestedTarget) {continue}
        }
        if ($seen.ContainsKey($node.Extent.StartOffset)) { continue };$seen[$node.Extent.StartOffset]=$true
        $before=$node.Extent.Text;$after=$before;$kinds=@()
        foreach ($pair in @(@($OldName,$NewName,'Installer'),@($OldMst,$NewMst,'Transform'),@($OldCode,$NewCode,'ProductCode'))) {
            if (-not $pair[0] -or -not $pair[1] -or $pair[0] -ieq $pair[1]) { continue }
            $pattern='(?i)(?<![\p{L}\p{N}_.-])'+[regex]::Escape($pair[0])+'(?![\p{L}\p{N}_.-])'
            if ([regex]::IsMatch($after,$pattern)) {
                $replacement=[string]$pair[1]
                $after=[regex]::Replace($after,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m)$replacement})
                $kinds+=$pair[2]
            }
        }
        if ($after -ceq $before) { continue }
        if ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'BareWord' -and $after -match '\s') { $after="'"+$after.Replace("'","''")+"'" }
        $phase=Get-UpgradePhase $Text $node.Extent.StartOffset $layout
        $parent=$node.Parent;$command='';$assignment=$false
        while ($null -ne $parent) {
            if ($parent -is [Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -in @('Start-ADTMsiProcess','Execute-MSI','Start-ADTProcess','Execute-Process','Start-Process','msiexec','msiexec.exe')) {$command=$parent.GetCommandName();break}
            if ($parent -is [Management.Automation.Language.AssignmentStatementAst]) {$assignment=$true;break}
            $parent=$parent.Parent
        }
        $canDriveInstall=[bool]$command -or $assignment
        $selected=[bool]$command -and (($kinds -notcontains 'ProductCode' -and $phase -ne 'PreInstall') -or ($phase -match '^(Pre|Post)?(Uninstall|Repair)$'))
        $context=if ($command) {$command} elseif ($assignment) {'Assignment (review)'} else {'Other expression (review)'}
        $null=$edits.Add([pscustomobject]@{Selected=[bool]$selected;CanDriveInstall=$canDriveInstall;Context=$context;Kind=($kinds -join ', ');Phase=$phase;Line=$node.Extent.StartLineNumber;Start=$node.Extent.StartOffset;End=$node.Extent.EndOffset;Before=$before;After=$after})
    }
    return ,$edits.ToArray()
}
function Apply-UpgradeReferencePlan([string]$Text,$Edits) {
    $previous=$Text.Length+1
    foreach ($edit in @($Edits|Where-Object Selected|Sort-Object Start -Descending)) {
        if ($edit.Start -lt 0 -or $edit.End -gt $Text.Length -or $edit.End -gt $previous -or $Text.Substring($edit.Start,$edit.End-$edit.Start) -cne $edit.Before) { Stop-BuilderValidation 'The upgrade review is stale or has overlapping edits. Analyze the package again.' }
        $Text=$Text.Remove($edit.Start,$edit.End-$edit.Start).Insert($edit.Start,$edit.After);$previous=$edit.Start
    }
    Assert-EditorScriptText $Text
    return $Text
}
function New-PackageUpgradePlan([hashtable]$Workspace,[string]$OldRelative,[string]$Replacement,[bool]$KeepName=$false,[string]$OldTransform='',[string]$ReplacementTransform='') {
    if ($Workspace.Signed) { Stop-BuilderValidation 'Use an unsigned authoring copy for installer upgrades. Sign the final package through your approved process.' }
    $inventory=@(Get-UpgradeInstallFiles $Workspace)
    if ($OldRelative -notin $inventory -or [IO.Path]::GetExtension($OldRelative) -notin @('.msi','.exe')) { Stop-BuilderValidation 'Choose an existing MSI or EXE under this package Files folder.' }
    Assert-BuilderPath $Replacement
    $old=Join-Path $Workspace.Source $OldRelative
    $oldName=[IO.Path]::GetFileName($OldRelative)
    $newName=if ($KeepName) {$oldName} else {[IO.Path]::GetFileName($Replacement)}
    if ($newName -notmatch '^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,180}\.(?i:msi|exe)$' -or [IO.Path]::GetExtension($Replacement) -ine [IO.Path]::GetExtension($old)) { Stop-BuilderValidation 'Use an MSI-to-MSI or EXE-to-EXE replacement with a simple filename (letters, digits, spaces, dots, parentheses, plus or hyphen).' }
    if (@($inventory|Where-Object {[IO.Path]::GetFileName($_) -ieq $oldName}).Count -ne 1) { Stop-BuilderValidation 'Multiple payloads have this filename. Make the package references unambiguous before using automatic replacement.' }
    $newRelative=($OldRelative.Substring(0,$OldRelative.Length-$oldName.Length)+$newName)
    if ($newRelative -ine $OldRelative -and (Test-Path -LiteralPath (Join-Path $Workspace.Source $newRelative))) { Stop-BuilderValidation 'The replacement filename already exists in the package. Choose a unique name or Keep existing filename.' }
    $staging=Join-Path $Workspace.Root ('Analysis-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($staging)
    $success=$false
    try {
        $newFile=Join-Path $staging $newName;Copy-Item -LiteralPath $Replacement -Destination $newFile
        $oldInfo=@{ProductCode='';ProductVersion='';ProductName='';Manufacturer='';UpgradeCode=''};$newInfo=@{ProductCode='';ProductVersion='';ProductName='';Manufacturer='';UpgradeCode=''}
        if ([IO.Path]::GetExtension($old) -eq '.msi') {
            $oldInfo=Read-UpgradeMsi $old;$newInfo=Read-UpgradeMsi $newFile
            if ($newInfo.ExternalMedia) {Stop-BuilderValidation 'The replacement MSI requires external CAB or loose payload files. Upgrade the complete vendor payload together in a working app folder; single-file replacement cannot validate those dependencies.'}
        }
        $mstFile='';$mstRelative='';$mstName='';$oldMstName='';$propertyNames=@();$transformMode='None'
        $hasTransforms=$Workspace.Text -match '(?i)\.mst\b|\bTRANSFORMS\s*='
        if ($hasTransforms -and -not $OldTransform) { Stop-BuilderValidation 'This script references a transform. Select its existing MST and migrate it, or select a reviewed replacement MST.' }
        if ($OldTransform) {
            if ([IO.Path]::GetExtension($old) -ne '.msi' -or $OldTransform -notin $inventory -or [IO.Path]::GetExtension($OldTransform) -ne '.mst') {Stop-BuilderValidation 'Choose a packaged MST associated with the selected MSI.'}
            $oldMstName=[IO.Path]::GetFileName($OldTransform)
            $referencedMsts=@($inventory|Where-Object {[IO.Path]::GetExtension($_) -eq '.mst' -and $Workspace.Text.IndexOf([IO.Path]::GetFileName($_),[StringComparison]::OrdinalIgnoreCase) -ge 0})
            if ($referencedMsts.Count -gt 1) {Stop-BuilderValidation 'Multiple MSTs are referenced. Review and upgrade the complete transform chain in your authoring package; this assistant migrates one transform at a time.'}
            if (@($inventory|Where-Object {[IO.Path]::GetFileName($_) -ieq $oldMstName}).Count -ne 1) {Stop-BuilderValidation 'Transform filenames must be unique in this package.'}
            $mstName=[IO.Path]::GetFileNameWithoutExtension($newName)+'-v5.mst'
            $mstRelative=$OldTransform.Substring(0,$OldTransform.Length-$oldMstName.Length)+$mstName
            if (Test-Path -LiteralPath (Join-Path $Workspace.Source $mstRelative)) {Stop-BuilderValidation 'The generated MST filename already exists. Rename the replacement installer before analyzing again.'}
            $mstFile=Join-Path $staging $mstName
            if ($ReplacementTransform) {
                Assert-BuilderPath $ReplacementTransform
                if ([IO.Path]::GetExtension($ReplacementTransform) -ne '.mst') {Stop-BuilderValidation 'Select an MST for the replacement transform.'}
                Copy-Item -LiteralPath $ReplacementTransform -Destination $mstFile;$transformMode='Replacement'
            } else {
                $propertyNames=@(New-UpgradeTransform $old $newFile (Join-Path $Workspace.Source $OldTransform) $mstFile $staging);$transformMode='PropertyMigration'
            }
            Test-UpgradeTransform $newFile $mstFile $staging
        }
        $edits=New-UpgradeReferencePlan $Workspace.Text $oldName $newName $oldInfo.ProductCode $newInfo.ProductCode $oldMstName $mstName
        if ($oldName -ine $newName -and -not @($edits|Where-Object {$_.Kind -match 'Installer'}).Count) {Stop-BuilderValidation 'No literal installer filename was found. Choose Keep existing filename for a computed/zero-configuration reference, or edit the command explicitly first.'}
        if ($OldTransform -and -not @($edits|Where-Object {$_.Kind -match 'Transform'}).Count) {Stop-BuilderValidation 'The MST reference is calculated or embedded. Edit it to a literal packaged filename before migrating the transform.'}
        $success=$true
        return @{Staging=$staging;SourceHashes=(Get-LocalTestHashes $Workspace.Source);TextHash=(Get-EditorByteHash ([Text.Encoding]::UTF8.GetBytes($Workspace.Text)));OldRelative=$OldRelative;NewRelative=$newRelative;NewFile=$newFile;NewHash=(Get-FileHash $newFile).Hash;OldHash=(Get-FileHash $old).Hash;OldInfo=$oldInfo;NewInfo=$newInfo;Edits=$edits;OldTransform=$OldTransform;MstRelative=$mstRelative;MstFile=$mstFile;MstHash=$(if ($mstFile) {(Get-FileHash $mstFile).Hash} else {''});TransformMode=$transformMode;PropertyNames=$propertyNames;Reviewed=$false}
    } finally {if (-not $success -and (Test-Path -LiteralPath $staging)) {Remove-Item -LiteralPath $staging -Recurse -Force}}
}
function Complete-PackageUpgrade([hashtable]$Workspace,[hashtable]$Plan) {
    if (-not $Plan.Reviewed) {Stop-BuilderValidation 'Review filename/product-code changes, transform behavior, detection and external payload dependencies before applying.'}
    Assert-LocalTestHashes $Workspace.Source $Plan.SourceHashes
    if ((Get-EditorByteHash ([Text.Encoding]::UTF8.GetBytes($Workspace.Text))) -ne $Plan.TextHash -or (Get-FileHash $Plan.NewFile).Hash -ne $Plan.NewHash -or (Get-FileHash (Join-Path $Workspace.Source $Plan.OldRelative)).Hash -ne $Plan.OldHash) {Stop-BuilderValidation 'A reviewed input changed. Analyze again before applying.'}
    $text=Apply-UpgradeReferencePlan $Workspace.Text $Plan.Edits
    if ($Plan.OldRelative -ine $Plan.NewRelative -and -not @($Plan.Edits|Where-Object {$_.Selected -and $_.CanDriveInstall -and $_.Kind -match 'Installer' -and $_.Phase -notmatch 'Uninstall|Repair|PreInstall'}).Count) {Stop-BuilderValidation 'Select an installation command argument or reviewed assignment, or keep the existing filename. Changing only log text or uninstall/repair would not update installation.'}
    if ($Plan.MstFile -and -not @($Plan.Edits|Where-Object {$_.Selected -and $_.CanDriveInstall -and $_.Kind -match 'Transform' -and $_.Phase -notmatch 'Uninstall|Repair|PreInstall'}).Count) {Stop-BuilderValidation 'Select the installation transform command argument or reviewed assignment.'}
    $output=Join-Path $Workspace.Root ('Upgraded-'+[guid]::NewGuid().ToString('N'));$source=Join-Path $output 'Source';$success=$false
    try {
        Copy-UpgradeTree $Workspace.Source $source
        Assert-LocalTestHashes $source $Plan.SourceHashes
        Copy-Item -LiteralPath $Plan.NewFile -Destination (Join-Path $source $Plan.NewRelative) -Force
        $oldName=[IO.Path]::GetFileName($Plan.OldRelative)
        $retained=$Plan.OldRelative -ine $Plan.NewRelative -and $text.IndexOf($oldName,[StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($Plan.OldRelative -ine $Plan.NewRelative -and -not $retained) {Remove-Item -LiteralPath (Join-Path $source $Plan.OldRelative) -Force}
        if ($Plan.MstFile) {
            if ((Get-FileHash $Plan.MstFile).Hash -ne $Plan.MstHash) {Stop-BuilderValidation 'The reviewed transform changed. Analyze again.'}
            Copy-Item -LiteralPath $Plan.MstFile -Destination (Join-Path $source $Plan.MstRelative)
            if ($text.IndexOf([IO.Path]::GetFileName($Plan.OldTransform),[StringComparison]::OrdinalIgnoreCase) -lt 0) {Remove-Item -LiteralPath (Join-Path $source $Plan.OldTransform) -Force}
        }
        $document=New-EditorTextDocument $text
        if ($Plan.NewInfo.ProductVersion -and $document.Contains('MetadataText')) {
            $kind=Get-EditorDocumentMetadataKind $document;$fields=Get-EditorMetadataFields $document.MetadataText $kind
            if ($fields.Contains('AppVersion') -and $fields.AppVersion.Literal -and $fields.AppVersion.Value -eq $Plan.OldInfo.ProductVersion) {
                $text=Set-EditorScriptMetadata $text (Set-EditorMetadataValues $document.MetadataText @{AppVersion=$Plan.NewInfo.ProductVersion} $kind) $kind
            }
        }
        [IO.File]::WriteAllText((Join-Path $source $Workspace.EntryScript),$text,(New-Object Text.UTF8Encoding($true)))
        $record=[ordered]@{Schema=1;BuilderVersion='5.0.0';CreatedUtc=[datetimeoffset]::UtcNow.ToString('o');InputSHA256=$Workspace.InputHash;OldInstaller=$Plan.OldRelative;Installer=$Plan.NewRelative;OldSHA256=$Plan.OldHash;SHA256=$Plan.NewHash;OldProductCode=$Plan.OldInfo.ProductCode;ProductCode=$Plan.NewInfo.ProductCode;ProductVersion=$Plan.NewInfo.ProductVersion;OldInstallerRetained=$retained;TransformMode=$Plan.TransformMode;Transform=$Plan.MstRelative;TransformSHA256=$Plan.MstHash;PropertyNames=@($Plan.PropertyNames);Edits=@($Plan.Edits|ForEach-Object {@{Kind=$_.Kind;Phase=$_.Phase;Line=$_.Line;Applied=[bool]$_.Selected}});DetectionReviewRequired=$true;WindowsPilotRequired=$true}
        [IO.File]::WriteAllText((Join-Path $source 'PSADT-Upgrade.json'),($record|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
        $zip=Join-Path $output 'Upgraded-Application.zip';[IO.Compression.ZipFile]::CreateFromDirectory($source,$zip)
        $document=Read-EditorPackage $zip;$success=$true
        return @{Zip=$zip;Source=$source;Record=$record;Document=$document}
    } finally {if (-not $success -and (Test-Path -LiteralPath $output)) {Remove-Item -LiteralPath $output -Recurse -Force}}
}
