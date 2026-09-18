# v5.0.0 - The modal upgrade assistant keeps all copying/MSI inspection off the UI thread.
function Start-UpgradeDialogWork([string]$Operation,[hashtable]$Arguments) {
    $state=$script:upgradeDialog
    if ($null -ne $state.Job) {return}
    $worker=[PowerShell]::Create()
    try {
        $null=$worker.AddScript({param($engine,$operation,$arguments)
            $ErrorActionPreference='Stop';. $engine
            try {
                $value=switch ($operation) {
                    Prepare {New-UpgradeWorkspace @arguments}
                    Analyze {New-PackageUpgradePlan @arguments}
                    Apply {Complete-PackageUpgrade @arguments}
                    default {throw 'Unknown upgrade operation.'}
                }
                return @{Value=$value;Error=''}
            } catch {
                $message='The upgrade could not finish. Check the selected package, Windows Installer and file permissions. Original files are unchanged.'
                $cause=$_.Exception;while ($null -ne $cause) {if ($cause.Data.Contains('BuilderSafeMessage')) {$message=[string]$cause.Data['BuilderSafeMessage'];break};$cause=$cause.InnerException}
                return @{Value=$null;Error=$message}
            }
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($Operation).AddArgument($Arguments)
        $state.Job=@{Worker=$worker;Handle=$worker.BeginInvoke();Operation=$Operation}
        $state.Controls.Inputs.IsEnabled=$false;$state.Controls.Edits.IsEnabled=$false;$state.Controls.Apply.IsEnabled=$false
        $state.Controls.Progress.Visibility='Visible';$state.Controls.Progress.IsIndeterminate=$true
        $state.Controls.Status.Text=switch ($Operation) {Prepare {'Preparing an isolated copy...'} Analyze {'Inspecting the installer and transform without executing them...'} Apply {'Creating the reviewed package ZIP...'}}
    } catch { $worker.Dispose();$state.Controls.Status.Text='Could not start the background operation.' }
}
function Reset-UpgradeDialogReview {
    if ($null -eq $script:upgradeDialog.Job) {$script:upgradeDialog.Plan=$null;$script:upgradeDialog.Controls.Apply.IsEnabled=$false;$script:upgradeDialog.Controls.Reviewed.IsChecked=$false;$script:upgradeDialog.Controls.Edits.ItemsSource=$null}
}
function Show-PackageUpgradeDialog([hashtable]$Snapshot,[string]$OutputRoot) {
    [xml]$markup=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UpgradeWindow.xaml') -Raw
    $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup));$dialog.Owner=$window
    Initialize-BiosWindowChrome $dialog (Join-Path $script:BuilderSource 'Files/UI/Theme.xaml') $builderBrand (Get-BiosBrandIconPath $PSScriptRoot $builderBrand)
    $c=@{};foreach ($name in @('Inputs','OldInstaller','NewInstaller','BrowseInstaller','KeepName','OldTransform','NewTransform','BrowseTransform','Analyze','Identity','Edits','Reviewed','Status','Progress','Apply','Close')) {$c[$name]=$dialog.FindName($name)}
    $script:upgradeDialog=@{Window=$dialog;Controls=$c;Job=$null;Workspace=$null;Plan=$null;Result=$null;Closing=$false}
    foreach ($name in @('NewInstaller','NewTransform')) {$c[$name].Add_TextChanged({Reset-UpgradeDialogReview})}
    foreach ($name in @('OldInstaller','OldTransform')) {$c[$name].Add_SelectionChanged({Reset-UpgradeDialogReview})}
    $c.KeepName.Add_Click({Reset-UpgradeDialogReview})
    $c.BrowseInstaller.Add_Click({$picker=New-Object Microsoft.Win32.OpenFileDialog;$picker.Filter='Installer (*.msi;*.exe)|*.msi;*.exe';if ($picker.ShowDialog($script:upgradeDialog.Window)) {$script:upgradeDialog.Controls.NewInstaller.Text=$picker.FileName}})
    $c.BrowseTransform.Add_Click({$picker=New-Object Microsoft.Win32.OpenFileDialog;$picker.Filter='Windows Installer transform (*.mst)|*.mst';if ($picker.ShowDialog($script:upgradeDialog.Window)) {$script:upgradeDialog.Controls.NewTransform.Text=$picker.FileName}})
    $c.Analyze.Add_Click({
        $state=$script:upgradeDialog;$c=$state.Controls
        $state.Plan=$null;$c.Reviewed.IsChecked=$false;$c.Edits.ItemsSource=$null
        Start-UpgradeDialogWork 'Analyze' @{Workspace=$state.Workspace;OldRelative=[string]$c.OldInstaller.SelectedItem;Replacement=$c.NewInstaller.Text;KeepName=[bool]$c.KeepName.IsChecked;OldTransform=$(if ($c.OldTransform.SelectedIndex -gt 0) {[string]$c.OldTransform.SelectedItem} else {''});ReplacementTransform=$c.NewTransform.Text}
    })
    $c.Apply.Add_Click({
        $state=$script:upgradeDialog
        if ($null -eq $state.Plan) {return}
        $null=$state.Controls.Edits.CommitEdit();$state.Plan.Reviewed=[bool]$state.Controls.Reviewed.IsChecked
        Start-UpgradeDialogWork 'Apply' @{Workspace=$state.Workspace;Plan=$state.Plan}
    })
    $c.Close.Add_Click({$script:upgradeDialog.Window.Close()})
    $dialog.Add_Closing({param($sender,$e) if ($null -ne $script:upgradeDialog.Job) {$e.Cancel=$true;$script:upgradeDialog.Closing=$true;$script:upgradeDialog.Controls.Status.Text='Finishing the current operation and cleaning up before closing...'}})
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[timespan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $state=$script:upgradeDialog
        if ($null -eq $state.Job -or -not $state.Job.Handle.IsCompleted) {return}
        $operation=$state.Job.Operation
        try {
            $results=$state.Job.Worker.EndInvoke($state.Job.Handle)
            # HadErrors can remain true for a handled validation exception.
            # The explicit envelope is authoritative after EndInvoke succeeds.
            if ($results.Count -ne 1 -or -not $results[0].ContainsKey('Error')) {throw 'Background operation failed.'}
            $envelope=$results[0]
            if ($envelope.Error) {$state.Controls.Status.Text=$envelope.Error}
            else {
                switch ($operation) {
                    Prepare {
                        $state.Workspace=$envelope.Value
                        $files=@(Get-UpgradeInstallFiles $state.Workspace)
                        foreach ($file in $files|Where-Object {[IO.Path]::GetExtension($_) -in @('.msi','.exe')}) {$null=$state.Controls.OldInstaller.Items.Add($file)}
                        $null=$state.Controls.OldTransform.Items.Add('(None)')
                        foreach ($file in $files|Where-Object {[IO.Path]::GetExtension($_) -eq '.mst'}) {$null=$state.Controls.OldTransform.Items.Add($file)}
                        $state.Controls.OldInstaller.SelectedIndex=0;$state.Controls.OldTransform.SelectedIndex=0
                        $state.Controls.Status.Text='Select the installer and its replacement, then analyze.'
                    }
                    Analyze {
                        $state.Plan=$envelope.Value;$state.Controls.Edits.ItemsSource=$state.Plan.Edits
                        $state.Controls.Identity.Text=('MSI version: {0} → {1}   ProductCode: {2} → {3}{4}Product: {5} → {6}; publisher: {7} → {8}{4}UpgradeCode: {9} → {10}{4}Transform: {11}. Migrated properties: {12}' -f $state.Plan.OldInfo.ProductVersion,$state.Plan.NewInfo.ProductVersion,$state.Plan.OldInfo.ProductCode,$state.Plan.NewInfo.ProductCode,[Environment]::NewLine,$state.Plan.OldInfo.ProductName,$state.Plan.NewInfo.ProductName,$state.Plan.OldInfo.Manufacturer,$state.Plan.NewInfo.Manufacturer,$state.Plan.OldInfo.UpgradeCode,$state.Plan.NewInfo.UpgradeCode,$state.Plan.TransformMode,($state.Plan.PropertyNames -join ', '))
                        if ([IO.Path]::GetExtension($state.Plan.NewRelative) -eq '.exe') {$state.Controls.Identity.Text='EXE replacement: '+$state.Plan.NewRelative+'. Review the vendor switches, detection and AppVersion; EXE product codes are not inferred.'}
                        $state.Controls.Status.Text='Review each proposed change. MSI AppVersion is updated only when its existing literal value matches the old MSI version.'
                    }
                    Apply {$state.Result=$envelope.Value;$state.Closing=$true}
                }
            }
        } catch {$state.Controls.Status.Text='The background operation failed. Original package files are unchanged.'}
        finally {
            $state.Job.Worker.Dispose();$state.Job=$null
            $state.Controls.Inputs.IsEnabled=$null -ne $state.Workspace;$state.Controls.Edits.IsEnabled=$true;$state.Controls.Apply.IsEnabled=$null -ne $state.Plan
            $state.Controls.Progress.IsIndeterminate=$false;$state.Controls.Progress.Visibility='Collapsed'
        }
        if ($state.Closing) {$state.Window.Close()}
    })
    try {
        Start-UpgradeDialogWork 'Prepare' @{Snapshot=$Snapshot;OutputRoot=$OutputRoot};$timer.Start();$null=$dialog.ShowDialog()
        return $script:upgradeDialog.Result
    } finally {
        $timer.Stop();$state=$script:upgradeDialog
        if ($null -ne $state.Workspace) {
            if ($null -eq $state.Result) {Remove-Item -LiteralPath $state.Workspace.Root -Recurse -Force}
            else {
                $keep=[IO.Path]::GetDirectoryName($state.Result.Zip)
                Get-ChildItem -LiteralPath $state.Workspace.Root -Force|Where-Object FullName -ne $keep|Remove-Item -Recurse -Force
            }
        }
        $script:upgradeDialog=$null
    }
}
