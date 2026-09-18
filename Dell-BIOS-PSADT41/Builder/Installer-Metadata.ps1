# v5.0.0 - Windows Installer database inspection only. Never installs a product.
function Invoke-UpgradeCom($Object,[string]$Name,[object[]]$Arguments=@(),[string]$Kind='InvokeMethod') {
    return $Object.GetType().InvokeMember($Name,[Reflection.BindingFlags]$Kind,$null,$Object,$Arguments)
}
function Close-UpgradeCom($Object) {
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object) }
}
function Read-UpgradeMsiRows($Database,[string]$Query,[string[]]$Columns) {
    $view=$null;$record=$null;$rows=New-Object Collections.ArrayList
    try {
        $view=Invoke-UpgradeCom $Database 'OpenView' @($Query)
        $null=Invoke-UpgradeCom $view 'Execute'
        while ($null -ne ($record=Invoke-UpgradeCom $view 'Fetch')) {
            $row=@{}
            for ($i=0;$i -lt $Columns.Count;$i++) { $row[$Columns[$i]]=[string](Invoke-UpgradeCom $record 'StringData' @($i+1) 'GetProperty') }
            $null=$rows.Add($row);Close-UpgradeCom $record;$record=$null
        }
        return ,$rows.ToArray()
    } finally { Close-UpgradeCom $record;Close-UpgradeCom $view }
}
function Get-UpgradeMsiProperties($Database) {
    $properties=@{}
    foreach ($row in (Read-UpgradeMsiRows $Database 'SELECT `Property`, `Value` FROM `Property`' @('Property','Value'))) { $properties[$row.Property]=$row.Value }
    return $properties
}
function Read-UpgradeMsi([string]$Path) {
    $installer=$null;$db=$null;$summary=$null
    try {
        Assert-BuilderPath $Path
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $db=Invoke-UpgradeCom $installer 'OpenDatabase' @([IO.Path]::GetFullPath($Path),0)
        $properties=Get-UpgradeMsiProperties $db
        $summary=Invoke-UpgradeCom $db 'SummaryInformation' @(0) 'GetProperty'
        $identity=@{ProductCode='';UpgradeCode='';ProductVersion='';ProductName='';Manufacturer='';ProductLanguage='';Template=[string](Invoke-UpgradeCom $summary 'Property' @(7) 'GetProperty');ExternalMedia=$false}
        foreach ($key in @('ProductCode','UpgradeCode','ProductVersion','ProductName','Manufacturer','ProductLanguage')) { if ($properties.ContainsKey($key)) { $identity[$key]=[string]$properties[$key] } }
        if ($identity.ProductCode -notmatch '^\{[0-9a-fA-F-]{36}\}$' -or -not $identity.ProductVersion) { Stop-BuilderValidation 'The selected MSI has no usable product identity.' }
        $tables=Read-UpgradeMsiRows $db 'SELECT `Name` FROM `_Tables`' @('Name')
        if (@($tables|Where-Object Name -eq 'Media').Count) {
            foreach ($media in (Read-UpgradeMsiRows $db 'SELECT `Cabinet` FROM `Media`' @('Cabinet'))) {if (-not $media.Cabinet.StartsWith('#')) {$identity.ExternalMedia=$true}}
        }
        return $identity
    } catch { Stop-BuilderValidation 'Could not read the MSI database. Use a valid MSI on Windows; no installer was executed.' }
    finally { Close-UpgradeCom $summary;Close-UpgradeCom $db;Close-UpgradeCom $installer }
}
function Assert-UpgradeMsiFamily($Old,$New) {
    if (-not $Old.UpgradeCode -or $Old.UpgradeCode -ine $New.UpgradeCode -or $Old.ProductLanguage -ne $New.ProductLanguage -or $Old.Template.Split(';')[0] -ine $New.Template.Split(';')[0]) {
        Stop-BuilderValidation 'Automatic MST migration requires the same MSI UpgradeCode, language and platform. Supply a vendor-reviewed replacement MST for a different product family or architecture.'
    }
}
function Get-UpgradePropertyDelta($Rows,[hashtable]$Before,[hashtable]$After) {
    $protected=@('ProductCode','UpgradeCode','ProductVersion','ProductLanguage','ProductName','Manufacturer')
    foreach ($row in $Rows) {
        if ($row.Table -ne 'Property' -or $row.Column -notin @('Value','INSERT','DELETE') -or -not $row.Row -or $row.Row -match '\s') {
            Stop-BuilderValidation 'This MST changes more than Property values. Automatic migration is unavailable; select a reviewed replacement MST. The original transform remains intact.'
        }
    }
    $delta=@()
    foreach ($key in @(@($Before.Keys)+@($After.Keys)|Sort-Object -Unique)) {
        if ($Before.ContainsKey($key) -and $After.ContainsKey($key) -and $Before[$key] -ceq $After[$key]) { continue }
        if ($key -in $protected) { Stop-BuilderValidation 'The MST changes MSI product identity. Rebuild that transform with the vendor tool; product identity is never copied from the old MSI.' }
        $delta+=@{Name=$key;Remove=(-not $After.ContainsKey($key));Value=$(if ($After.ContainsKey($key)) {$After[$key]} else {''})}
    }
    if (-not $delta.Count) { Stop-BuilderValidation 'The MST has no Property changes to migrate. Select a reviewed replacement transform or edit the package explicitly.' }
    return ,$delta
}
function Set-UpgradeMsiProperty($Installer,$Database,$Change,[bool]$Exists) {
    $view=$null;$record=$null
    try {
        if ($Change.Remove) {
            if (-not $Exists) { return }
            $query='DELETE FROM `Property` WHERE `Property` = ?';$values=@($Change.Name)
        } elseif ($Exists) { $query='UPDATE `Property` SET `Value` = ? WHERE `Property` = ?';$values=@($Change.Value,$Change.Name) }
        else { $query='INSERT INTO `Property` (`Property`, `Value`) VALUES (?, ?)';$values=@($Change.Name,$Change.Value) }
        $view=Invoke-UpgradeCom $Database 'OpenView' @($query)
        $record=Invoke-UpgradeCom $Installer 'CreateRecord' @($values.Count)
        for ($i=0;$i -lt $values.Count;$i++) { $null=Invoke-UpgradeCom $record 'StringData' @(($i+1),[string]$values[$i]) 'SetProperty' }
        $null=Invoke-UpgradeCom $view 'Execute' @($record)
    } finally { Close-UpgradeCom $record;Close-UpgradeCom $view }
}
function New-UpgradeTransform([string]$OldMsi,[string]$NewMsi,[string]$OldMst,[string]$Destination,[string]$Work) {
    Assert-UpgradeMsiFamily (Read-UpgradeMsi $OldMsi) (Read-UpgradeMsi $NewMsi)
    $installer=$null;$oldDb=$null;$viewDb=$null;$baseDb=$null;$changedDb=$null
    $oldCopy=Join-Path $Work ('mst-old-'+[guid]::NewGuid().ToString('N')+'.msi')
    $newCopy=Join-Path $Work ('mst-new-'+[guid]::NewGuid().ToString('N')+'.msi')
    try {
        Copy-Item -LiteralPath $OldMsi -Destination $oldCopy
        Copy-Item -LiteralPath $NewMsi -Destination $newCopy
        (Get-Item -LiteralPath $oldCopy).IsReadOnly=$false
        (Get-Item -LiteralPath $newCopy).IsReadOnly=$false
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $viewDb=Invoke-UpgradeCom $installer 'OpenDatabase' @($oldCopy,1)
        $null=Invoke-UpgradeCom $viewDb 'ApplyTransform' @($OldMst,256)
        $rows=Read-UpgradeMsiRows $viewDb 'SELECT `Table`, `Column`, `Row` FROM `_TransformView`' @('Table','Column','Row')
        Close-UpgradeCom $viewDb;$viewDb=$null
        $oldDb=Invoke-UpgradeCom $installer 'OpenDatabase' @($oldCopy,1)
        $before=Get-UpgradeMsiProperties $oldDb
        $null=Invoke-UpgradeCom $oldDb 'ApplyTransform' @($OldMst,0)
        $after=Get-UpgradeMsiProperties $oldDb
        $delta=Get-UpgradePropertyDelta $rows $before $after
        $baseDb=Invoke-UpgradeCom $installer 'OpenDatabase' @($NewMsi,0)
        $changedDb=Invoke-UpgradeCom $installer 'OpenDatabase' @($newCopy,1)
        $newProperties=Get-UpgradeMsiProperties $changedDb
        foreach ($change in $delta) { Set-UpgradeMsiProperty $installer $changedDb $change $newProperties.ContainsKey($change.Name) }
        $null=Invoke-UpgradeCom $changedDb 'Commit'
        if (-not (Invoke-UpgradeCom $changedDb 'GenerateTransform' @($baseDb,$Destination))) { Stop-BuilderValidation 'The new MSI already contains these property settings; no replacement MST was generated. Review the transform reference manually.' }
        # Language + ProductCode + full version equality + UpgradeCode, no suppressed errors.
        $null=Invoke-UpgradeCom $changedDb 'CreateTransformSummaryInfo' @($baseDb,$Destination,0,2339)
        return @($delta|ForEach-Object {$_.Name}) # Names only: transform values can contain secrets.
    } catch {
        if ($_.Exception.Data.Contains('BuilderSafeMessage')) { throw }
        Stop-BuilderValidation 'Windows Installer could not migrate this MST. Supply a vendor-reviewed replacement. No original MSI or MST was changed.'
    } finally {
        foreach ($com in @($changedDb,$baseDb,$oldDb,$viewDb,$installer)) { Close-UpgradeCom $com }
        foreach ($path in @($oldCopy,$newCopy)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }
}
function Test-UpgradeTransform([string]$Msi,[string]$Mst,[string]$Work) {
    $installer=$null;$db=$null
    $copy=Join-Path $Work ('mst-check-'+[guid]::NewGuid().ToString('N')+'.msi')
    try {
        Copy-Item -LiteralPath $Msi -Destination $copy
        (Get-Item -LiteralPath $copy).IsReadOnly=$false
        $installer=New-Object -ComObject WindowsInstaller.Installer
        $db=Invoke-UpgradeCom $installer 'OpenDatabase' @($copy,1)
        $before=Get-UpgradeMsiProperties $db
        $before['Template']=(Read-UpgradeMsi $Msi).Template
        Assert-UpgradeTransformSummary $installer $Mst $before
        $null=Invoke-UpgradeCom $db 'ApplyTransform' @($Mst,0)
        $after=Get-UpgradeMsiProperties $db
        foreach ($key in @('ProductCode','UpgradeCode','ProductVersion','ProductLanguage')) {
            if ($before[$key] -cne $after[$key]) { Stop-BuilderValidation 'The replacement MST changes product identity. Use a transform authored for the new product without overriding its identity.' }
        }
    } catch {
        if ($_.Exception.Data.Contains('BuilderSafeMessage')) { throw }
        Stop-BuilderValidation 'The MST could not be applied to a copy of the new MSI without suppressed errors. Select a compatible transform.'
    } finally { Close-UpgradeCom $db;Close-UpgradeCom $installer;if (Test-Path -LiteralPath $copy) {Remove-Item -LiteralPath $copy -Force} }
}
function Assert-UpgradeTransformSummary($Installer,[string]$Mst,[hashtable]$Properties) {
    $summary=$null
    try {
        $summary=Invoke-UpgradeCom $Installer 'SummaryInformation' @($Mst,0) 'GetProperty'
        $revision=[string](Invoke-UpgradeCom $summary 'Property' @(9) 'GetProperty')
        $template=[string](Invoke-UpgradeCom $summary 'Property' @(7) 'GetProperty')
        if ($template.Split(';')[0] -and $template.Split(';')[0] -ine $Properties.Template.Split(';')[0]) {Stop-BuilderValidation 'The MST platform does not match the new MSI.'}
        $flags=([int](Invoke-UpgradeCom $summary 'Property' @(16) 'GetProperty') -shr 16) -band 0xffff
        $parts=$revision.Split(';');$baseCode='';$baseVersion=''
        if ($parts.Count -ge 2 -and $parts[0] -match '^(\{[0-9A-Fa-f-]{36}\})(.+)$') {$baseCode=$Matches[1];$baseVersion=$Matches[2]}
        if (($flags -band 2) -and $baseCode -ine $Properties.ProductCode) {Stop-BuilderValidation 'The MST summary requires a different ProductCode. Supply a transform for the new MSI.'}
        if (($flags -band 2048) -and ($parts.Count -lt 3 -or $parts[2] -ine $Properties.UpgradeCode)) {Stop-BuilderValidation 'The MST summary requires a different UpgradeCode.'}
        if ($flags -band 1) {
            $template=[string](Invoke-UpgradeCom $summary 'Property' @(7) 'GetProperty')
            $languages=$template.Split(';')
            if ($languages.Count -lt 2 -or $Properties.ProductLanguage -notin $languages[1].Split(',')) {Stop-BuilderValidation 'The MST summary language does not match the new MSI.'}
        }
        if ($flags -band 56) {
            if (-not $baseVersion) {Stop-BuilderValidation 'The transform version validation is incomplete.'}
            $actual=[version]$Properties.ProductVersion;$expected=[version]$baseVersion
            $length=if ($flags -band 32) {3} elseif ($flags -band 16) {2} else {1}
            $a=@($actual.Major,$actual.Minor,[math]::Max(0,$actual.Build));$b=@($expected.Major,$expected.Minor,[math]::Max(0,$expected.Build));$comparison=0
            for ($i=0;$i -lt $length;$i++) {if ($a[$i] -ne $b[$i]) {$comparison=$a[$i].CompareTo($b[$i]);break}}
            $valid=(($flags -band 64) -and $comparison -lt 0) -or (($flags -band 128) -and $comparison -le 0) -or (($flags -band 256) -and $comparison -eq 0) -or (($flags -band 512) -and $comparison -ge 0) -or (($flags -band 1024) -and $comparison -gt 0)
            if (-not $valid) {Stop-BuilderValidation 'The MST summary version requirement does not match the new MSI.'}
        }
    } finally {Close-UpgradeCom $summary}
}
