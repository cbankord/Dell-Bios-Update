# Actual form/mode callbacks with inert controls; no WPF or deployment execution.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaModeTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData; if (-not $env:ProgramData) { $env:ProgramData=$temp }
$count=0
function Check($Condition,$Name) { $script:count++;if (-not $Condition) { throw "FAIL: $Name" } }
try {
    . "$root/Builder/Build-Package.ps1"
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$tokens,[ref]$errors)
    foreach ($name in @('Set-BuilderPackageMode','Set-FormSettings','Get-FormSettings','Update-Review')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Set-BuilderIconPreview {}
    $script:fields=@{};$script:fieldBoxes=@{};$script:kind=@{}
    $defaults=New-PackageBuildSettings
    foreach ($key in $defaults.Keys) {
        $fieldKind=if ($defaults[$key] -is [bool]) {'Bool'} elseif ($defaults[$key] -is [int]) {'Int'} else {'Text'}
        if ($key -eq 'PackageType') {$fieldKind='PackageType'}
        elseif ($key -eq 'ApplicationContext') {$fieldKind='Context'}
        elseif ($key -eq 'EscrowDestination') {$fieldKind='Escrow'}
        elseif ($key -in @('Models','DriverModels')) {$fieldKind='Models'}
        $script:kind[$key]=$fieldKind
        $script:fields[$key]=[pscustomobject]@{Text='';SelectedItem='';SelectedValue='';IsChecked=$false;IsEnabled=$true}
        $script:fieldBoxes[$key]=[pscustomobject]@{Visibility='Visible'}
    }
    foreach ($key in @('Password','PasswordConfirm')) {
        $script:fields[$key]=[pscustomobject]@{Text='';Cleared=0;IsEnabled=$true}
        $script:fields[$key] | Add-Member ScriptMethod Clear {$this.Cleared++}
        $script:fields[$key] | Add-Member ScriptProperty SecurePassword {throw 'Form serialization must never read a password'}
        $script:kind[$key]='Password'
    }
    $controls=@{}
    foreach ($key in @('DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorMode','ExperiencePanel','ApplicationExperiencePanel','Reviewed','ReviewConsent','OutputNotice','ReviewText')) {
        $controls[$key]=[pscustomobject]@{Visibility='Visible';IsChecked=$true;Text='';SelectedIndex=0}
    }
    Set-FormSettings $defaults
    Check ($script:fields.PackageType.SelectedValue -eq 'BIOS' -and $controls.DeploymentPanel.Visibility -eq 'Visible' -and $controls.ApplicationPanel.Visibility -eq 'Collapsed') 'Initial BIOS form retains firmware controls'
    Check ($script:fields.Password.IsEnabled -and $script:fields.Password.Cleared -gt 0) 'BIOS mode allows a fresh password when required'
    $script:fields.MinimumBatteryPercent.Text='invalid inactive value'
    $script:fields.PackageType.SelectedValue='Application'
    $controls.Reviewed.IsChecked=$true;$cleared=$script:fields.Password.Cleared
    Set-BuilderPackageMode
    Check ($controls.DeploymentPanel.Visibility -eq 'Collapsed' -and $controls.ExperiencePanel.Visibility -eq 'Collapsed' -and $script:fieldBoxes.BiosPath.Visibility -eq 'Collapsed') 'Application hides BIOS executable and firmware/experience settings'
    Check ($controls.ApplicationPanel.Visibility -eq 'Visible' -and $controls.ApplicationExperiencePanel.Visibility -eq 'Visible' -and $script:fieldBoxes.ApplicationDetectionScript.Visibility -eq 'Visible') 'Application exposes app settings and detection'
    Check (-not $script:fields.Password.IsEnabled -and $script:fields.Password.Cleared -gt $cleared -and -not $controls.Reviewed.IsChecked) 'Mode switch clears password and prior review'
    Check ($controls.ReviewConsent.Text.Contains('application ZIP') -and -not $controls.OutputNotice.Text.Contains('shared BIOS password')) 'Application consent and output copy describe app packaging'
    $script:fields.ApplicationName.Text='Example App';$script:fields.ApplicationVersion.Text='4.3.1194'
    $script:fields.ApplicationContext.SelectedItem='User';$script:fields.OutputRoot.Text=$temp
    $controls.Reviewed.IsChecked=$true
    $app=Get-FormSettings
    Check ($app.PackageType -eq 'Application' -and $app.ApplicationName -eq 'Example App' -and $app.ApplicationContext -eq 'User') 'Actual form serializes app mode and metadata'
    Check ($app.MinimumBatteryPercent -eq 51 -and $app.BiosPath -eq '' -and $app.IconPath -eq '' -and -not $app.ContainsKey('Password')) 'Invalid hidden BIOS inputs are not parsed or forwarded'
    Update-Review
    Check ($controls.ReviewText.Text.Contains('Configure app-specific detection') -and $controls.ReviewText.Text.Contains('Output folder: '+$temp)) 'Application review requires an explicit detection plan and shows output'
    Check (-not $controls.ReviewText.Text.Contains('battery minimum') -and -not $controls.ReviewText.Text.Contains('automatic restart countdown')) 'Application review adds no BIOS power or restart instructions'
    $preset=Join-Path $temp 'AppPreset.psd1';Export-PackagePreset $app $preset
    Set-FormSettings (Import-PackagePreset $preset)
    Check ($script:fields.PackageType.SelectedValue -eq 'Application' -and $script:fields.ApplicationName.Text -eq 'Example App' -and -not $controls.Reviewed.IsChecked) 'Saved application preset restores application UI and clears review'
    $script:fields.ApplicationDetectionScript.Text='C:\Detection.ps1';Update-Review
    Check ($controls.ReviewText.Text.Contains('Supplied custom script')) 'Detection selection is visible in application review'
    $legacy=Join-Path $temp 'Legacy.psd1';Write-BuilderData $legacy @{TargetVersion='2.7.3';OutputRoot=$temp;Models=@('Approved Dell')}
    Set-FormSettings (Import-PackagePreset $legacy)
    Check ($script:fields.PackageType.SelectedValue -eq 'BIOS' -and $controls.ExperiencePanel.Visibility -eq 'Visible' -and $script:fieldBoxes.ApplicationDetectionScript.Visibility -eq 'Collapsed') 'Old BIOS preset restores BIOS UI after app mode'
    $bios=Get-FormSettings
    Check ($bios.TargetVersion -eq '2.7.3' -and $bios.Models[0] -eq 'Approved Dell' -and $bios.ApplicationName -eq '') 'BIOS form drops inactive app fields and keeps existing firmware settings'
    foreach ($mode in @('WindowsUpdate','Driver')) {
        $script:fields.PackageType.SelectedValue=$mode;Set-BuilderPackageMode
        Check ($controls.MaintenancePanel.Visibility -eq 'Visible' -and $script:fields.ApplicationContext.SelectedItem -eq 'System' -and -not $script:fields.ApplicationContext.IsEnabled) "$mode exposes servicing inputs and requires System"
        $script:fields.ApplicationName.Text='Servicing';$script:fields.ApplicationVersion.Text='1.0';$script:fields.WindowsBuild.Text='26100'
        $script:fields.DriverModels.Text='Dell Pro Max 16 MC16250';$script:fields.MaintenancePayload.Text='C:\approved.zip'
        $s=Get-FormSettings
        Check ($s.PackageType -eq $mode -and $s.WindowsBuild -eq '26100' -and $s.DriverModels[0] -eq 'Dell Pro Max 16 MC16250') "$mode serializes its own servicing inputs"
        Export-PackagePreset $s $preset;Set-FormSettings (Import-PackagePreset $preset)
        Check ($script:fields.PackageType.SelectedValue -eq $mode -and -not $controls.Reviewed.IsChecked) "$mode preset restores mode without approval"
    }
    [xml]$xml=Get-Content "$root/Builder/Window.xaml" -Raw
    Check ($xml.DocumentElement.Title -eq 'PSADT Deployment Builder v5') 'Builder has neutral v4.5 identity'
    $caption=$xml.SelectSingleNode("//*[@*[local-name()='Name']='CaptionClose']")
    Check ($null -ne $caption -and $null -ne $xml.SelectSingleNode("//*[@*[local-name()='Name']='CloseButton']")) 'Custom title-bar and footer close controls remain'
    Write-Output "PASS: $count builder mode assertions. Actual form/preset/review callbacks; native WPF remains a Windows pilot."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
