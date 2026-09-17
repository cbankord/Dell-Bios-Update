#requires -Version 5.1
# Run with 64-bit Windows PowerShell -NoProfile -STA. Administrator is not required.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Build-Package.ps1"
Assert-BuilderHost
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Use powershell.exe -NoProfile -STA -File Start-PackageBuilder.ps1.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[xml]$xaml=Get-Content -LiteralPath "$PSScriptRoot/Window.xaml" -Raw
$reader=New-Object Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$builderBrand=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Branding.psd1')
$window.Title=$builderBrand.AppTitle
Initialize-BiosWindowChrome $window (Join-Path $script:BuilderSource 'Files/UI/Theme.xaml') $builderBrand (Get-BiosBrandIconPath $PSScriptRoot $builderBrand)
$script:fields=@{}; $script:kind=@{}; $script:job=$null; $script:lastOutput=''; $script:closeRequested=$false
$controls=@{}
foreach ($name in @('Tabs','FilesPanel','DeploymentPanel','ExperiencePanel','ReviewText','Reviewed','BuildButton','OpenButton','Progress','BuildLog','LoadButton','SaveButton','CloseButton')) { $controls[$name]=$window.FindName($name) }
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
    else { $inputControl=New-Object Windows.Controls.TextBox }
    $inputControl.Name=$Key; [Windows.Automation.AutomationProperties]::SetName($inputControl,($Label -replace '_',''))
    $caption.Target=$inputControl
    if ($Type -in @('Multi','Models')) { $inputControl.AcceptsReturn=$true; $inputControl.TextWrapping='Wrap'; $inputControl.MinHeight=70; $inputControl.VerticalScrollBarVisibility='Auto' }
    if ($Type -in @('Bios','Zip','Tool','Image','Icon','Folder')) {
        $browse=New-Object Windows.Controls.Button; $browse.Content='Browse...'; $browse.Tag=@{Control=$inputControl;Type=$Type}; [Windows.Automation.AutomationProperties]::SetName($browse,('Browse for '+$Label))
        [Windows.Controls.DockPanel]::SetDock($browse,'Right'); $null=$row.Children.Add($browse)
        $browse.Add_Click({ param($sender,$e)
            if ($sender.Tag.Type -eq 'Folder') {
                $dialog=New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description='Choose a local output folder outside this repository'; $dialog.ShowNewFolderButton=$true
                try { if ($dialog.ShowDialog() -eq 'OK') { $sender.Tag.Control.Text=$dialog.SelectedPath } } finally { $dialog.Dispose() }
            } else {
                $dialog=New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Filter=switch ($sender.Tag.Type) { Zip {'PSADT template ZIP (*.zip)|*.zip'} Image {'PNG or JPEG images|*.png;*.jpg;*.jpeg'} Icon {'Title-bar icon (*.png;*.ico)|*.png;*.ico'} default {'Executable (*.exe)|*.exe'} }
                if ($dialog.ShowDialog($window)) { $sender.Tag.Control.Text=$dialog.FileName }
            }
        })
    }
    $null=$row.Children.Add($inputControl); $null=$box.Children.Add($row)
    if ($Help) { $note=New-Object Windows.Controls.TextBlock; $note.Text=$Help; $note.FontSize=12; $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedBrush'); $null=$box.Children.Add($note) }
    $null=$Panel.Children.Add($box); $script:fields[$Key]=$inputControl; $script:kind[$Key]=$Type
}
Add-Heading $controls.FilesPanel 'Start with your approved files' 'Choose a prepared PSADT 4.1.x deployment template ZIP. A single enclosing folder is fine. Your module, extensions and framework customization are preserved.'
Add-Field $controls.FilesPanel BiosPath '_Dell BIOS executable' Bios 'The copied EXE is renamed ApprovedBIOS.exe, hashed and checked for a valid Dell signature. It is never run by the builder.'
Add-Field $controls.FilesPanel FrameworkZip '_Custom PSADT ZIP' Zip 'Must contain Invoke-AppDeployToolkit.ps1, Invoke-AppDeployToolkit.exe and PSAppDeployToolkit/PSAppDeployToolkit.psd1 (4.1.x).'
Add-Field $controls.FilesPanel OutputRoot '_Output folder' Folder 'Each build creates a new protected folder. Choose a local folder outside the repository.'
Add-Field $controls.FilesPanel ContentPrepTool '_IntuneWinAppUtil.exe (optional)' Tool 'Select your Microsoft content prep tool to create .intunewin automatically. Leave blank to build the complete source package and Intune scripts.'
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
        $path=$script:fields.IconPath.Text.Trim()
        if (-not $path) { $path=Get-BiosBrandIconPath $PSScriptRoot $builderBrand }
        $window.Icon=if ($path) { Read-BiosWindowIcon ([IO.Path]::GetFullPath($path)) } else { $window.FindResource('DefaultAppIcon') }
        $script:fields.IconPath.ToolTip='Icon preview; this icon will be included in the generated package.'
    } catch {
        $window.Icon=$window.FindResource('DefaultAppIcon')
        $script:fields.IconPath.ToolTip='Icon could not be previewed. Choose a valid local PNG/ICO; the build validates it again.'
    }
}
function Set-FormSettings([hashtable]$Settings) {
    foreach ($key in $script:fields.Keys) {
        if (-not $Settings.ContainsKey($key)) { continue }
        $field=$script:fields[$key]
        switch ($script:kind[$key]) {
            Bool { $field.IsChecked=[bool]$Settings[$key] }
            Escrow { $field.SelectedItem=$Settings[$key] }
            Models { $field.Text=@($Settings[$key]) -join "`r`n" }
            default { $field.Text=[string]$Settings[$key] }
        }
    }
    $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear(); $controls.Reviewed.IsChecked=$false
    Set-BuilderIconPreview
    $script:fields.Password.IsEnabled=[bool]$Settings.BiosPasswordRequired; $script:fields.PasswordConfirm.IsEnabled=[bool]$Settings.BiosPasswordRequired
}
function Get-FormSettings {
    $settings=New-PackageBuildSettings
    foreach ($key in $settings.Keys | ForEach-Object { $_ }) {
        if (-not $script:fields.ContainsKey($key)) { continue }
        $field=$script:fields[$key]
        switch ($script:kind[$key]) {
            Bool { $settings[$key]=[bool]$field.IsChecked }
            Int {
                $parsed=0
                if (-not [int]::TryParse($field.Text,[ref]$parsed)) { throw "Enter a whole number for $key." }
                $settings[$key]=$parsed
            }
            Escrow { $settings[$key]=[string]$field.SelectedItem }
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
        $controls.ReviewText.Text="Models: $($s.Models -join ', ')`nTarget: $($s.TargetVersion)`nPower: AC required; battery minimum $($s.MinimumBatteryPercent)%`nDeadline: $($s.WindowHours) hours from first user prompt attempt`nAllow schedule later: $($s.AllowScheduleLater) (installation time only)`nReminder: $($s.ReminderHours) hours minimum; install prompt timeout: $($s.PromptTimeoutMinutes) minutes`nAfter staging: automatic restart countdown $($s.RestartCountdownMinutes) minutes; sound/recenter every $($s.RestartReminderMinutes) minutes`nOutput: $mode`nPassword: excluded from this review and presets"
    } catch { $controls.ReviewText.Text=$_.Exception.Message }
}
$defaults=New-PackageBuildSettings
$defaults.OutputRoot=[Environment]::GetFolderPath('MyDocuments')
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
        $dialog=New-Object Microsoft.Win32.SaveFileDialog; $dialog.Filter='Builder preset (*.psd1)|*.psd1'; $dialog.FileName='DellBIOS-settings.psd1'
        if ($dialog.ShowDialog($window)) { Export-PackagePreset $settings $dialog.FileName }
    } catch { $null=[Windows.MessageBox]::Show('Could not save the preset. Check numeric settings and the destination.','Save preset') }
})
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
        $settings=Get-FormSettings; Assert-BuilderSettings $settings
        if ($settings.BiosPasswordRequired -and -not (Test-PasswordConfirmation)) { throw 'Enter the BIOS password twice; both entries must match.' }
        $secret=$script:fields.Password.SecurePassword
        $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear()
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $worker=[PowerShell]::Create()
        $null=$worker.AddScript({param($engine,$settings,$secret,$queue)
            $ErrorActionPreference='Stop'
            $queue.Enqueue('Loading builder scripts in the background PowerShell session...')
            . $engine
            New-DellBiosPackage -Settings $settings -BiosPassword $secret -Progress {param($message) $queue.Enqueue($message)}
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($settings).AddArgument($secret).AddArgument($queue)
        $script:job=@{Worker=$worker; Handle=$worker.BeginInvoke(); Queue=$queue; Secret=$secret}
        foreach ($name in @('FilesPanel','DeploymentPanel','ExperiencePanel','Reviewed','BuildButton','LoadButton','SaveButton','OpenButton')) { $controls[$name].IsEnabled=$false }
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
            } else {
                $result=$results[0]; $script:lastOutput=$result.OutputDirectory
                $controls.BuildLog.AppendText("`r`nOutput: "+$result.OutputDirectory+"`r`nBIOS SHA256: "+$result.SHA256)
                if (-not $result.IntuneWinFile) { $controls.BuildLog.AppendText("`r`nSource build complete. No .intunewin was requested.") }
                $controls.OpenButton.IsEnabled=$true
            }
        } catch { $controls.BuildLog.AppendText("`r`nFAILED: " + (Get-BuilderFailureMessage $_)) }
        finally {
            $script:job.Worker.Dispose(); $script:job.Secret.Dispose(); $script:job=$null
            foreach ($name in @('FilesPanel','DeploymentPanel','ExperiencePanel','Reviewed','BuildButton','LoadButton','SaveButton')) { $controls[$name].IsEnabled=$true }
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
finally { $timer.Stop(); $script:fields.Password.Clear(); $script:fields.PasswordConfirm.Clear() }
