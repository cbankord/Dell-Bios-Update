#requires -Version 5.1
# Windows-only database test. Creates inert MSI/MST databases; NEVER installs them.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Builder/Build-Package.ps1";Assert-BuilderHost
$temp=Join-Path ([IO.Path]::GetTempPath()) ('NativeMsiV5-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($temp)
$count=0
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function New-InertMsi([string]$Path,[string]$Code,[string]$Version) {
 $installer=$null;$db=$null;$view=$null;$summary=$null
 try {
  $installer=New-Object -ComObject WindowsInstaller.Installer;$db=Invoke-UpgradeCom $installer OpenDatabase @($Path,3)
  $view=Invoke-UpgradeCom $db OpenView @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)')
  $null=Invoke-UpgradeCom $view Execute
  $values=@{ProductCode=$Code;UpgradeCode='{33333333-3333-3333-3333-333333333333}';ProductVersion=$Version;ProductName='Inert test database';Manufacturer='Test fixture';ProductLanguage='1033';SERVER='default'}
  foreach($key in $values.Keys){Set-UpgradeMsiProperty $installer $db @{Name=$key;Value=$values[$key];Remove=$false} $false}
  $summary=Invoke-UpgradeCom $db SummaryInformation @(20) GetProperty
  foreach($pair in @(@(7,'x64;1033'),@(9,('{'+[guid]::NewGuid().ToString().ToUpperInvariant()+'}')),@(14,200),@(15,2))) {$null=Invoke-UpgradeCom $summary Property @($pair[0],$pair[1]) SetProperty}
  $null=Invoke-UpgradeCom $summary Persist;$null=Invoke-UpgradeCom $db Commit
 } finally {foreach($com in @($summary,$view,$db,$installer)){Close-UpgradeCom $com}}
}
try {
 $old=Join-Path $temp 'old.msi';$new=Join-Path $temp 'new.msi';$oldMst=Join-Path $temp 'old.mst';$newMst=Join-Path $temp 'new.mst'
 New-InertMsi $old '{11111111-1111-1111-1111-111111111111}' '1.0.0';New-InertMsi $new '{22222222-2222-2222-2222-222222222222}' '2.0.0'
 $oldHash=(Get-FileHash $old).Hash;$newHash=(Get-FileHash $new).Hash
 Check ((Read-UpgradeMsi $new).ProductVersion -eq '2.0.0') 'Native COM reads MSI metadata'
 $modified=Join-Path $temp 'modified.msi';Copy-Item $old $modified
 $installer=$null;$base=$null;$changed=$null
 try {
  $installer=New-Object -ComObject WindowsInstaller.Installer;$base=Invoke-UpgradeCom $installer OpenDatabase @($old,0);$changed=Invoke-UpgradeCom $installer OpenDatabase @($modified,1)
  Set-UpgradeMsiProperty $installer $changed @{Name='SERVER';Value="example's server";Remove=$false} $true
  $null=Invoke-UpgradeCom $changed Commit;$null=Invoke-UpgradeCom $changed GenerateTransform @($base,$oldMst);$null=Invoke-UpgradeCom $changed CreateTransformSummaryInfo @($base,$oldMst,0,2339)
 } finally {foreach($com in @($changed,$base,$installer)){Close-UpgradeCom $com}}
 $names=@(New-UpgradeTransform $old $new $oldMst $newMst $temp)
 Check ($names.Count -eq 1 -and $names[0] -eq 'SERVER') 'Native transform migration carries intended property delta'
 Test-UpgradeTransform $new $newMst $temp
 Check ($true) 'Generated transform summary and application match replacement MSI'
 $failed=$false;try{Test-UpgradeTransform $new $oldMst $temp}catch{$failed=$true}
 Check $failed 'Old product-bound transform rejected for replacement MSI'
 $installer=$null;$db=$null
 try {
  $copy=Join-Path $temp 'verify.msi';Copy-Item $new $copy;$installer=New-Object -ComObject WindowsInstaller.Installer;$db=Invoke-UpgradeCom $installer OpenDatabase @($copy,1)
  $null=Invoke-UpgradeCom $db ApplyTransform @($newMst,0);$properties=Get-UpgradeMsiProperties $db
  Check ($properties.SERVER -eq "example's server" -and $properties.ProductVersion -eq '2.0.0' -and $properties.ProductCode -eq '{22222222-2222-2222-2222-222222222222}') 'Migrated property persists without old identity or SQL quoting errors'
 } finally {Close-UpgradeCom $db;Close-UpgradeCom $installer}
 Check ((Get-FileHash $old).Hash -eq $oldHash -and (Get-FileHash $new).Hash -eq $newHash) 'Original MSI bytes remain intact'
 Write-Output "PASS: $count native Windows MSI assertions. No product installed."
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
