#requires -Version 5.1
# Run with 64-bit Windows PowerShell -NoProfile -STA. Administrator is not required.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Build-Package.ps1"
Assert-BuilderHost
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use powershell.exe -NoProfile -STA -File Start-PackageBuilder.ps1.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, WindowsFormsIntegration
[xml]$xaml=Get-Content -LiteralPath "$PSScriptRoot/Window.xaml" -Raw
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$builderBrand=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Branding.psd1')
$window.Title=$builderBrand.AppTitle
Initialize-BiosWindowChrome $window (Join-Path $script:BuilderSource 'Files/UI/Theme.xaml') $builderBrand (Get-BiosBrandIconPath $PSScriptRoot $builderBrand)
$script:fields=@{}; $script:fieldBoxes=@{}; $script:kind=@{}; $script:job=$null; $script:lastOutput=''; $script:closeRequested=$false
$controls=@{}
foreach ($name in @('Tabs','FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','ApplicationExperiencePanel','OutputPanel','ReviewText','ReviewConsent','OutputNotice','Reviewed','BuildButton','OpenButton','Progress','BuildLog','LoadButton','SaveButton','CloseButton','EditorMode','EditorLoad','EditorImport','EditorSave','EditorValidate','EditorHost','SectionList','EditorStatus')) { $controls[$name]=$window.FindName($name) }
function Select-BuilderOutputFolder([string]$CurrentPath) {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $owner=$null
    try {
        $dialog.Description='Choose where to save the package. A new build folder will be created inside this location.'
        $dialog.ShowNewFolderButton=$true
        if ($CurrentPath -and (Test-Path -LiteralPath $CurrentPath -PathType Container)) { $dialog.SelectedPath=$CurrentPath }
        # Keep the native picker owned by this WPF window, including custom chrome.
        $owner=New-Object Windows.Forms.NativeWindow
        $interop=New-Object Windows.Interop.WindowInteropHelper($window)
        $owner.AssignHandle($interop.Handle)
        if ($dialog.ShowDialog($owner) -eq 'OK') { return $dialog.SelectedPath }
        return $CurrentPath # Cancelling does not replace the previously selected path.
    } finally {
        if ($null -ne $owner) { $owner.ReleaseHandle() }
        $dialog.Dispose()
    }
}
function Add-Heading($Panel,[string]$Title,[string]$Help) {
    $text=New-Object Windows.Controls.TextBlock; $text.Text=$Title; $text.FontSize=21; $text.FontWeight='SemiBold'; $text.Margin='0,12,0,6'; $null=$Panel.Children.Add($text)
    $note=New-Object Windows.Controls.TextBlock; $note.Text=$Help; $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedBrush'); $note.Margin='0,0,0,16'; $null=$Panel.Children.Add($note)
}
function Add-Field($Panel,[string]$Key,[string]$Label,[string]$Type='Text',[string]$Help='') {
    $box=New-Object Windows.Controls.StackPanel; $box.Margin='0,0,0,12'
    $caption=New-Object Windows.Controls.Label; $caption.Content=$Label; $caption.Padding='0,0,0,5'; $null=$box.Children.Add($caption)
    $row=New-Object Windows.Controls.DockPanel; $row.LastChildFill=$true
    if ($Type -eq 'Bool') { $inputControl=New-Object Windows.Controls.CheckBox; $inputControl.Content=$Label; $caption.Visibility='Collapsed' }
    elseif ($Type -eq 'Password') { $inputControl=New-Object Windows.Controls.PasswordBox; $inputControl.Padding='10,8' }
    elseif ($Type -eq 'Escrow') { $inputControl=New-Object Windows.Controls.ComboBox; $inputControl.Padding='10,8'; $null=$inputControl.Items.Add('EntraID'); $null=$inputControl.Items.Add('ADDS') }
    elseif ($Type -eq 'PackageType') {
        $inputControl=New-Object Windows.Controls.ComboBox; $inputControl.Padding='10,8'
        $inputControl.DisplayMemberPath='Label'; $inputControl.SelectedValuePath='Value'
        $null=$inputControl.Items.Add([pscustomobject]@{Label='BIOS update';Value='BIOS'})
        $null=$inputControl.Items.Add([pscustomobject]@{Label='Application';Value='Application'})
        $null=$inputControl.Items.Add([pscustomobject]@{Label='Windows Update';Value='WindowsUpdate'})
        $null=$inputControl.Items.Add([pscustomobject]@{Label='Dell Driver';Value='Driver'})
    }
    elseif ($Type -eq 'Context') { $inputControl=New-Object Windows.Controls.ComboBox; $inputControl.Padding='10,8'; $null=$inputControl.Items.Add('System'); $null=$inputControl.Items.Add('User') }
    else { $inputControl=New-Object Windows.Controls.TextBox }
    $inputControl.Name=$Key; [Windows.Automation.AutomationProperties]::SetName($inputControl,($Label -replace '_',''))
    $caption.Target=$inputControl
    if ($Type -in @('Multi','Models')) { $inputControl.AcceptsReturn=$true; $inputControl.TextWrapping='Wrap'; $inputControl.MinHeight=70; $inputControl.VerticalScrollBarVisibility='Auto' }
    if ($Type -in @('Bios','Zip','Tool','Image','Icon','Folder','Script','Payload')) {
        $browse=New-Object Windows.Controls.Button; $browse.Content=if ($Type -eq 'Folder') {'Choose _folder...'} else {'Browse...'}; $browse.Tag=@{Control=$inputControl;Type=$Type}; [Windows.Automation.AutomationProperties]::SetName($browse,('Browse for '+($Label -replace '_','')))
        [Windows.Controls.DockPanel]::SetDock($browse,'Right'); $null=$row.Children.Add($browse)
        $browse.Add_Click({ param($sender,$e)
            if ($sender.Tag.Type -eq 'Folder') {
                try { $sender.Tag.Control.Text=Select-BuilderOutputFolder $sender.Tag.Control.Text }
                catch { $controls.BuildLog.Text='Could not open the folder picker. Type an existing local folder in Output folder instead.' }
            } else {
                $dialog=New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Filter=switch ($sender.Tag.Type) { Payload {'Servicing payload (*.msu;*.cab;*.zip)|*.msu;*.cab;*.zip'} Zip {'PSADT deployment ZIP (*.zip)|*.zip'} Script {'PowerShell detection script (*.ps1)|*.ps1'} Image {'PNG or JPEG images|*.png;*.jpg;*.jpeg'} Icon {'Title-bar icon (*.png;*.ico)|*.png;*.ico'} default {'Executable (*.exe)|*.exe'} }
                if ($dialog.ShowDialog($window)) { $sender.Tag.Control.Text=$dialog.FileName }
            }
        })
    }
    $null=$row.Children.Add($inputControl); $null=$box.Children.Add($row)
    if ($Help) { $note=New-Object Windows.Controls.TextBlock; $note.Text=$Help; $note.FontSize=12; $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedBrush'); $null=$box.Children.Add($note) }
    $null=$Panel.Children.Add($box); $script:fields[$Key]=$inputControl; $script:fieldBoxes[$Key]=$box; $script:kind[$Key]=$Type
}
Add-Heading $controls.FilesPanel 'Choose what you are deploying' 'Choose the package type. PSADT is the default authoring view; Editor lets you change supported deployment sections.'
Add-Field $controls.FilesPanel PackageType '_Deployment type' PackageType 'BIOS, Windows Update and Dell Driver use PSADT 4.1.x. Application also accepts prepared PSADT 4.x or legacy 3.x app ZIPs.'
Add-Field $controls.FilesPanel BiosPath '_Dell BIOS executable' Bios 'The copied EXE is renamed ApprovedBIOS.exe, hashed and checked for a valid Dell signature. It is never run by the builder.'
Add-Field $controls.FilesPanel FrameworkZip '_PSADT deployment ZIP' Zip 'Choose a prepared BIOS template or your complete application deployment, including its framework and payloads. A single enclosing folder is supported.'
Add-Field $controls.FilesPanel ApplicationDetectionScript 'Intune _detection script' Script 'Required for Windows Update and Dell Driver. Optional for Application if you will configure detection in Intune. Verify the installed version after restart.'
Add-Field $controls.OutputPanel OutputRoot '_Output folder' Folder 'Choose or type an existing local folder outside the repository. Each build creates a new protected folder containing Source, Intune setup files and optional .intunewin output.'
Add-Field $controls.FilesPanel ContentPrepTool '_IntuneWinAppUtil.exe (optional)' Tool 'Select your Microsoft content prep tool to create .intunewin automatically. Leave blank to build the complete source package and Intune scripts.'
Add-Heading $controls.ApplicationPanel 'Package identity' 'These values identify the package. Windows Update and Driver generate install steps; Application keeps the supplied sections unless Editor is selected.'
Add-Field $controls.ApplicationPanel ApplicationName 'Package _name' Text 'For example: Abacus Client. Used in build records and output folder names.'
Add-Field $controls.ApplicationPanel ApplicationVersion 'Package _version' Text 'The version you are packaging; this does not edit version values in the supplied app.'
Add-Field $controls.ApplicationPanel ApplicationContext 'Intune install _behavior' Context 'System or User. Choose the context required by your existing app; this setting is recorded in the generated Intune instructions.'
Add-Heading $controls.MaintenancePanel 'Approved servicing payload' 'Use one approved standalone update, or a ZIP of extracted Dell INF drivers. All supporting driver files and catalogs must be included. Firmware drivers are excluded.'
Add-Field $controls.MaintenancePanel MaintenancePayload '_Update or driver payload' Payload 'Windows Update: MSU/CAB. Dell Driver: ZIP containing extracted INF/CAT/SYS files. This does not download updates or extract Dell EXEs/CAB driver packs.'
Add-Field $controls.MaintenancePanel WindowsBuild 'Approved Windows _build' Text 'Exact client build number, for example 26100. Check KB prerequisites, edition and architecture before approval. Online MSU requires Windows 11.'
Add-Field $controls.MaintenancePanel DriverModels 'Approved Dell _driver models (one per line)' Models 'Exact Win32_ComputerSystem.Model values. Required for Driver mode.'
$script:fields.UseEditor=$window.FindName('UseEditor'); $script:kind.UseEditor='Bool'
$script:fields.SectionTemplatePath=$window.FindName('SectionTemplatePath'); $script:kind.SectionTemplatePath='Text'
Add-Heading $controls.DeploymentPanel 'Target and credentials' 'One approved Dell BIOS executable per package. Exact model names come from Win32_ComputerSystem.Model. The builder cannot infer compatibility from the filename.'
Add-Field $controls.DeploymentPanel Models '_Approved models (one per line)' Models
Add-Field $controls.DeploymentPanel TargetVersion '_Expected BIOS version' Text 'Numeric version, for example 2.1.1. Use the Dell-approved target for the selected executable.'
Add-Field $controls.DeploymentPanel MinimumCurrentVersion 'Mi_nimum existing BIOS version' Text 'Set Dell prerequisite versions here. Default: 0.0.0.'
Add-Field $controls.DeploymentPanel BiosPasswordRequired 'BIOS administrator password is _required' Bool
Add-Field $controls.DeploymentPanel Password 'BIOS _password' Password 'Never saved in a preset or build log. The generated deployment uses the existing local shared-password mechanism.'
Add-Field $controls.DeploymentPanel PasswordConfirm '_Confirm BIOS password' Password
Add-Heading $controls.DeploymentPanel 'Firmware safety requirements' 'AC power is always required and is rechecked before staging and managed restart. The deadline never bypasses these checks.'
Add-Field $controls.DeploymentPanel RequireBattery 'Require a _battery (laptops)' Bool 'Clear only for approved desktop models without a battery.'
Add-Field $controls.DeploymentPanel MinimumBatteryPercent 'Minimum battery _percent' Int '51-100. The battery must meet or exceed this percentage; 51 remains the minimum allowed.'
Add-Field $controls.DeploymentPanel MinimumBatteryRuntimeMinutes 'Minimum estimated battery _runtime (minutes)' Int '0 disables this optional check; otherwise 1-240. Some devices do not report a usable estimate on AC and will wait for IT review. This is not a guaranteed runtime.'
Add-Field $controls.DeploymentPanel MinimumFreeSpaceGB 'Minimum free _space (GB)' Int '1-1024 GB on the Windows volume.'
Add-Field $controls.DeploymentPanel BitLockerRebootCount 'BitLocker reboot _count' Int '1-3. A finite suspension immediately around staging, never days before it.'
Add-Field $controls.DeploymentPanel EscrowDestination 'Recovery key _escrow' Escrow
Add-Field $controls.ExperiencePanel PromptTimeoutMinutes '_Install prompt timeout (minutes)' Int '1-30; default 10. Defer on timeout before the original deadline; request preparation after an overdue notice.'
Add-Field $controls.ExperiencePanel RestartCountdownMinutes '_Restart countdown (minutes)' Int '15-120; default 60. SYSTEM rechecks power before automatically requesting a restart. Unsafe power/sleep/session loss cancels this countdown.'
Add-Field $controls.ExperiencePanel RestartReminderMinutes 'Restart reminder _interval (minutes)' Int '1-30; default 15, less than the countdown. Restore/center the window and play the Windows alert sound.'
Add-Heading $controls.ExperiencePanel 'Deferrals and reminders' 'The deadline is saved at the first user prompt launch attempt. Future builds cannot extend it. Optional installation scheduling stays within this window.'
Add-Field $controls.ExperiencePanel AllowScheduleLater '_Allow schedule later' Bool 'Offer Schedule Install before the original deadline. Clear to offer Install Now and Defer only. This does not change deferrals or the post-install restart countdown. Previously accepted appointments are honored.'
Add-Field $controls.ExperiencePanel WindowHours '_Deferral window (hours)' Int '1-168; default 72. Unlimited deferrals before this deadline. After expiry, only Install Now remains available.'
Add-Field $controls.ExperiencePanel ReminderHours '_Reminder interval (hours)' Int '1-12; default 4. Minimum time between notices. Intune or the chosen install appointment supplies retries.'
Add-Heading $controls.ExperiencePanel 'Your branding' 'These settings remain separate from deployment logic. Choose high-contrast colors; preview and test the generated interface on Windows.'
foreach ($entry in @(@('CompanyName','Company name'),@('AppTitle','Window title'),@('Heading','Heading'),@('Purpose','Update purpose'),@('SupportText','Support text'),@('ReadyMessage','Restart-required message'))) { Add-Field $controls.ExperiencePanel $entry[0] $entry[1] Multi }
Add-Field $controls.ExperiencePanel IconPath 'Title-bar icon (optional)' Icon 'Local PNG or ICO, up to 1 MB and 1024 x 1024. Used by the builder preview and packaged app. Leave blank for the built-in device icon.'
Add-Field $controls.ExperiencePanel LogoPath 'Company logo (optional)' Image 'PNG/JPG, up to 10 MB. Leave blank to show company text only.'
Add-Field $controls.ExperiencePanel BannerPath 'Banner image (optional)' Image
foreach ($entry in @(@('AccentColor','Accent'),@('BackgroundColor','Background'),@('SurfaceColor','Cards'),@('TextColor','Text'),@('MutedColor','Secondary text'))) { Add-Field $controls.ExperiencePanel $entry[0] ($entry[1]+' color (#RRGGBB)') }
function Set-BuilderIconPreview {
    try {
        $path=if ($script:fields.PackageType.SelectedValue -ne 'BIOS') { '' } else { $script:fields.IconPath.Text.Trim() }
        if (-not $path) { $path=Get-BiosBrandIconPath $PSScriptRoot $builderBrand }
        $window.Icon=if ($path) { Read-BiosWindowIcon ([IO.Path]::GetFullPath($path)) } else { $window.FindResource('DefaultAppIcon') }
        $script:fields.IconPath.ToolTip='Icon preview; this icon will be included in the generated package.'
    } catch {
        $window.Icon=$window.FindResource('DefaultAppIcon')
        $script:fields.IconPath.ToolTip='Icon could not be previewed. Choose a valid local PNG/ICO; the build validates it again.'
    }
}
function Set-BuilderPackageMode {
    $isApp=$script:fields.PackageType.SelectedValue -ne 'BIOS'
    $biosVisibility=if ($isApp) {'Collapsed'} else {'Visible'}
    $appVisibility=if ($isApp) {'Visible'} else {'Collapsed'}
    $script:fieldBoxes.BiosPath.Visibility=$biosVisibility
    $script:fieldBoxes.ApplicationDetectionScript.Visibility=$appVisibility
    $controls.DeploymentPanel.Visibility=$biosVisibility; $controls.ExperiencePanel.Visibility=$biosVisibility
    $controls.ApplicationPanel.Visibility=$appVisibility; $controls.ApplicationExperiencePanel.Visibility=$appVisibility
    $maintenance=$script:fields.PackageType.SelectedValue -in @('WindowsUpdate','Driver')
    $controls.MaintenancePanel.Visibility=if ($maintenance) {'Visible'} else {'Collapsed'}
    $script:fieldBoxes.DriverModels.Visibility=if ($script:fields.PackageType.SelectedValue -eq 'Driver') {'Visible'} else {'Collapsed'}
    if ($maintenance) { $script:fields.ApplicationContext.SelectedItem='System' }
    $script:fields.ApplicationContext.IsEnabled=-not $maintenance
    $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear()
    $script:fields.Password.IsEnabled=(-not $isApp -and [bool]$script:fields.BiosPasswordRequired.IsChecked)
    $script:fields.PasswordConfirm.IsEnabled=$script:fields.Password.IsEnabled
    $controls.Reviewed.IsChecked=$false
    $controls.ReviewConsent.Text=if ($isApp) {'I reviewed this application ZIP, deployment logic, install context and detection plan. These settings are approved for a pilot.'} else {'I reviewed Dell compatibility, prerequisite versions and the trusted PSADT template. These settings are approved for a pilot.'}
    $controls.OutputNotice.Text=if ($isApp) {'Output contains your supplied application files. Keep sensitive data out of Git. Only the new build folder receives protected output permissions.'} else {'The package contains the shared BIOS password when configured. Protect Source and .intunewin; do not upload them to Git. Output is restricted to your Windows account, SYSTEM and Administrators.'}
    Set-BuilderIconPreview
    if (Get-Command Set-EditorAvailability -ErrorAction SilentlyContinue) { Set-EditorAvailability }
}
function Set-FormSettings([hashtable]$Settings) {
    foreach ($key in $script:fields.Keys) {
        if (-not $Settings.ContainsKey($key)) { continue }
        $field=$script:fields[$key]
        switch ($script:kind[$key]) {
            Bool { $field.IsChecked=[bool]$Settings[$key] }
            Escrow { $field.SelectedItem=$Settings[$key] }
            Context { $field.SelectedItem=$Settings[$key] }
            PackageType { $field.SelectedValue=$Settings[$key] }
            Models { $field.Text=@($Settings[$key]) -join "`r`n" }
            default { $field.Text=[string]$Settings[$key] }
        }
    }
    $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear(); $controls.Reviewed.IsChecked=$false
    Set-BuilderPackageMode
    $controls.EditorMode.SelectedIndex=if ($Settings.UseEditor -and $Settings.PackageType -ne 'BIOS') {1} else {0}
    if (Get-Command Set-EditorAvailability -ErrorAction SilentlyContinue) { $script:editorDocument=$null; $script:editorSection=''; $script:editorBox.Clear(); Set-EditorAvailability }
}
function Get-FormSettings {
    $settings=New-PackageBuildSettings
    $isApp=$script:fields.PackageType.SelectedValue -ne 'BIOS'
    foreach ($key in $settings.Keys | ForEach-Object { $_ }) {
        if (-not $script:fields.ContainsKey($key)) { continue }
        if ($isApp -and $key -notin @('PackageType','ApplicationName','ApplicationVersion','ApplicationContext','ApplicationDetectionScript','FrameworkZip','OutputRoot','ContentPrepTool','UseEditor','SectionTemplatePath','MaintenancePayload','WindowsBuild','DriverModels')) { continue }
        if (-not $isApp -and ($key -like 'Application*' -or $key -in @('UseEditor','SectionTemplatePath','MaintenancePayload','WindowsBuild','DriverModels'))) { continue }
        if ($script:fields.PackageType.SelectedValue -eq 'Application' -and $key -in @('MaintenancePayload','WindowsBuild','DriverModels')) { continue }
        $field=$script:fields[$key]
        switch ($script:kind[$key]) {
            Bool { $settings[$key]=[bool]$field.IsChecked }
            Int {
                $parsed=0
                if (-not [int]::TryParse($field.Text,[ref]$parsed)) { throw "Enter a whole number for $key." }
                $settings[$key]=$parsed
            }
            Escrow { $settings[$key]=[string]$field.SelectedItem }
            Context { $settings[$key]=[string]$field.SelectedItem }
            PackageType { $settings[$key]=[string]$field.SelectedValue }
            Models { $settings[$key]=@($field.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
            Multi { $settings[$key]=$field.Text }
            default { $settings[$key]=$field.Text.Trim() }
        }
    }
    $settings.PackageReviewed=[bool]$controls.Reviewed.IsChecked
    return $settings
}
function Update-Review {
    try {
        $s=Get-FormSettings
        $mode=if ($s.ContentPrepTool) {'Source + Intune scripts + .intunewin'} else {'Source + Intune scripts (.intunewin tool not selected)'}
        $destination=if ($s.OutputRoot) { $s.OutputRoot } else { 'Choose an output folder above before building.' }
        if ($s.PackageType -ne 'BIOS') {
            $detection=if ($s.ApplicationDetectionScript) {'Supplied custom script (not executed by builder)'} else {'Configure app-specific detection in Intune before assignment'}
            $controls.ReviewText.Text="Deployment type: $($s.PackageType)`nEditor enabled: $($s.UseEditor)`nApproved Windows build: $($s.WindowsBuild)`nName: $($s.ApplicationName)`nVersion: $($s.ApplicationVersion)`nInstall behavior: $($s.ApplicationContext)`nDetection: $detection`nApplication: supplied sections; servicing: generated steps; Editor: reviewed section changes`nOutput folder: $destination`nOutput contents: Source + Intune setup files$(if ($s.ContentPrepTool) {' + .intunewin'})`nNo BIOS controls or managed BIOS UI are added."
            return
        }
        $controls.ReviewText.Text="Models: $($s.Models -join ', ')`nTarget: $($s.TargetVersion)`nPower: AC required; battery minimum $($s.MinimumBatteryPercent)%`nDeadline: $($s.WindowHours) hours from first user prompt attempt`nAllow schedule later: $($s.AllowScheduleLater) (installation time only)`nReminder: $($s.ReminderHours) hours minimum; install prompt timeout: $($s.PromptTimeoutMinutes) minutes`nAfter staging: automatic restart countdown $($s.RestartCountdownMinutes) minutes; sound/recenter every $($s.RestartReminderMinutes) minutes`nOutput folder: $destination`nOutput contents: $mode`nPassword: excluded from this review and presets"
    } catch { $controls.ReviewText.Text=$_.Exception.Message }
}
$defaults=New-PackageBuildSettings
Set-FormSettings $defaults
$controls.Tabs.Add_SelectionChanged({ Update-Review })
# Every settings edit invalidates the previous review.
foreach ($field in $script:fields.Values) {
    if ($field -is [Windows.Controls.TextBox]) { $field.Add_TextChanged({ $controls.Reviewed.IsChecked=$false }) }
    elseif ($field -is [Windows.Controls.CheckBox]) { $field.Add_Click({ $controls.Reviewed.IsChecked=$false }) }
    elseif ($field -is [Windows.Controls.ComboBox]) { $field.Add_SelectionChanged({ $controls.Reviewed.IsChecked=$false }) }
    elseif ($field -is [Windows.Controls.PasswordBox]) { $field.Add_PasswordChanged({ $controls.Reviewed.IsChecked=$false }) }
}
$script:fields.IconPath.Add_TextChanged({ Set-BuilderIconPreview })
$script:fields.PackageType.Add_SelectionChanged({ Set-BuilderPackageMode; Update-Review })
$script:fields.OutputRoot.Add_TextChanged({ Update-Review })
$script:fields.BiosPasswordRequired.Add_Click({ $script:fields.Password.IsEnabled=[bool]$script:fields.BiosPasswordRequired.IsChecked; $script:fields.PasswordConfirm.IsEnabled=$script:fields.Password.IsEnabled })
$controls.LoadButton.Add_Click({
    $dialog=New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter='Builder preset (*.psd1)|*.psd1'
    if ($dialog.ShowDialog($window)) {
        try { Set-FormSettings (Import-PackagePreset $dialog.FileName); Update-Review }
        catch { $null=[Windows.MessageBox]::Show('Could not load this preset. It must be a builder settings file without secrets.','Load preset') }
    }
})
$controls.SaveButton.Add_Click({
    try {
        $settings=Get-FormSettings
        $dialog=New-Object Microsoft.Win32.SaveFileDialog; $dialog.Filter='Builder preset (*.psd1)|*.psd1'; $dialog.FileName='PSADT-settings.psd1'
        if ($dialog.ShowDialog($window)) { Export-PackagePreset $settings $dialog.FileName }
    } catch { $null=[Windows.MessageBox]::Show('Could not save the preset. Check numeric settings and the destination.','Save preset') }
})
. "$PSScriptRoot/Editor-UI.ps1"
function Test-PasswordConfirmation {
    # Compare SecureStrings without ever assigning either password to a UI TextBox.
    $first=$script:fields.Password.SecurePassword; $second=$script:fields.PasswordConfirm.SecurePassword
    $a=[IntPtr]::Zero; $b=[IntPtr]::Zero
    try {
        if ($first.Length -eq 0 -or $first.Length -ne $second.Length) { return $false }
        $a=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($first); $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        $difference=0
        for ($i=0; $i -lt ($first.Length*2); $i++) { $difference=$difference -bor ([Runtime.InteropServices.Marshal]::ReadByte($a,$i) -bxor [Runtime.InteropServices.Marshal]::ReadByte($b,$i)) }
        return $difference -eq 0
    } finally {
        if ($a -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a) }
        if ($b -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
        $first.Dispose(); $second.Dispose()
    }
}
$controls.BuildButton.Add_Click({
    $secret=$null; $worker=$null
    try {
        $settings=Get-FormSettings
        $settings.OutputRoot=Resolve-BuilderOutputRoot $settings.OutputRoot
        Assert-BuilderSettings $settings
        $editorSnapshot=Get-ActiveEditorDocument $settings
        if ($settings.PackageType -eq 'BIOS') {
            if ($settings.BiosPasswordRequired -and -not (Test-PasswordConfirmation)) { throw 'Enter the BIOS password twice; both entries must match.' }
            $secret=$script:fields.Password.SecurePassword
        }
        $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear()
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $worker=[PowerShell]::Create()
        $null=$worker.AddScript({param($engine,$settings,$secret,$queue,$editorDocument)
            $ErrorActionPreference='Stop'
            $queue.Enqueue('Loading builder scripts in the background PowerShell session...')
            . $engine
            New-DeploymentPackage -Settings $settings -BiosPassword $secret -EditorDocument $editorDocument -Progress {param($message) $queue.Enqueue($message)}
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($settings).AddArgument($secret).AddArgument($queue).AddArgument($editorSnapshot)
        $script:job=@{Worker=$worker; Handle=$worker.BeginInvoke(); Queue=$queue; Secret=$secret}
        foreach ($name in @('FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','OutputPanel','Reviewed','BuildButton','LoadButton','SaveButton','OpenButton')) { $controls[$name].IsEnabled=$false }
        $controls.BuildLog.Text='Starting build...'; $controls.Progress.Visibility='Visible'; $controls.Progress.IsIndeterminate=$true
    } catch {
        if ($null -eq $script:job) { if ($null -ne $worker) { $worker.Dispose() }; if ($null -ne $secret) { $secret.Dispose() } }
        $controls.BuildLog.Text=Get-BuilderFailureMessage $_
    }
})
$controls.OpenButton.Add_Click({ if ($script:lastOutput) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$script:lastOutput+'"') } })
$controls.CloseButton.Add_Click({ $window.Close() })
$window.Add_PreviewKeyDown({param($sender,$eventArgs)
    if ($eventArgs.Key -eq 'Escape') { $eventArgs.Handled=$true; $window.Close() }
})
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[timespan]::FromMilliseconds(250)
$timer.Add_Tick({
    if ($null -eq $script:job) { return }
    $message=''
    while ($script:job.Queue.TryDequeue([ref]$message)) { $controls.BuildLog.AppendText("`r`n"+$message); $controls.BuildLog.ScrollToEnd() }
    if ($script:job.Handle.IsCompleted) {
        try {
            $results=$script:job.Worker.EndInvoke($script:job.Handle)
            if ($script:job.Worker.HadErrors -or $results.Count -ne 1) {
                # Engine's catch deliberately sanitizes phase-specific build errors.
                $detail=if ($script:job.Worker.Streams.Error.Count) { Get-BuilderFailureMessage $script:job.Worker.Streams.Error[0] } else {'The build did not produce one result.'}
                $controls.BuildLog.AppendText("`r`nFAILED: "+$detail)
                if ($script:job.ContainsKey('Kind') -and $script:job.Kind -eq 'Editor') { $controls.EditorStatus.Text=$detail }
            } elseif ($script:job.ContainsKey('Kind') -and $script:job.Kind -eq 'Editor') {
                Set-EditorDocument $results[0]
                $script:fields.SectionTemplatePath.Text=$script:job.TemplatePath
                $controls.EditorStatus.Text='Loaded all ten sections. Review, edit, check syntax, or save a reusable template.'
                $controls.BuildLog.AppendText("`r`nEditor sections loaded. No package has been built.")
                $controls.OpenButton.IsEnabled=[bool]$script:lastOutput
            } else {
                $result=$results[0]; $script:lastOutput=$result.OutputDirectory
                $hashLabel=if ($null -ne $result.PSObject.Properties['PackageType'] -and $result.PackageType -ne 'BIOS') {'PSADT ZIP SHA256: '} else {'BIOS SHA256: '}
                $controls.BuildLog.AppendText("`r`nOutput: "+$result.OutputDirectory+"`r`n"+$hashLabel+$result.SHA256)
                if (-not $result.IntuneWinFile) { $controls.BuildLog.AppendText("`r`nSource build complete. No .intunewin was requested.") }
                $controls.OpenButton.IsEnabled=$true
            }
        } catch { $controls.BuildLog.AppendText("`r`nFAILED: " + (Get-BuilderFailureMessage $_)) }
        finally {
            $script:job.Worker.Dispose(); if ($null -ne $script:job.Secret) { $script:job.Secret.Dispose() }; $script:job=$null
            foreach ($name in @('FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','OutputPanel','Reviewed','BuildButton','LoadButton','SaveButton')) { $controls[$name].IsEnabled=$true }
            $controls.Reviewed.IsChecked=$false; $controls.Progress.IsIndeterminate=$false; $controls.Progress.Visibility='Collapsed'
        }
        # EndInvoke and disposal must finish before ShowDialog returns. Never
        # abort extraction/content prep or leave a credential-bearing partial build.
        if ($script:closeRequested) { $window.Close() }
    }
})
$window.Add_Closing({param($sender,$eventArgs)
    if ($null -ne $script:job) {
        $eventArgs.Cancel=$true
        if (-not $script:closeRequested) {
            $script:closeRequested=$true
            $controls.CloseButton.IsEnabled=$false; $controls.CloseButton.Content='Closing...'
            $controls.BuildLog.AppendText("`r`nClose requested. Finishing the current build and cleanup; this window will then close automatically.")
            $controls.BuildLog.ScrollToEnd()
        }
    }
})
try { Update-Review; $timer.Start(); $null=$window.ShowDialog() }
finally { $timer.Stop(); $script:editorColorTimer.Stop(); $script:editorBox.Dispose(); $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear() }
