# v5.0.0 - Explicit local actions, asynchronous staging and a separate monitored process.
. "$PSScriptRoot/Upgrade-UI.ps1"
$script:localTestProcess=$null;$script:localTestRequest=$null;$script:testContext='CurrentUser';$script:testEvidence=''
function Update-V5Actions {
    if (-not $controls.ContainsKey('EditorReplaceInstaller')) {return}
    $doc=$script:editorDocument;$available=$null -ne $doc -and $doc.Mode -in @('Script','Application')
    $controls.EditorReplaceInstaller.IsEnabled=$available -and -not $doc.Signed -and $doc.Editable
    foreach ($name in @('TestInstall','TestRepair','TestUninstall')) {$controls[$name].IsEnabled=$available}
    $controls.TestPackage.Text=if ($available) {$doc.Path+' (current editor contents)'} else {'Open an Application ZIP or its PS1 in Editor. Tests require a complete PSADT package.'}
}
function Get-V5OutputRoot {
    $path=$script:fields.OutputRoot.Text
    if (-not $path) {$path=Select-BuilderOutputFolder '';if ($path) {$script:fields.OutputRoot.Text=$path}}
    return Resolve-BuilderOutputRoot $path
}
$controls.EditorReplaceInstaller.Add_Click({
    try {
        Save-EditorBuffer
        $result=Show-PackageUpgradeDialog (New-AuthoringSnapshot $script:editorDocument) (Get-V5OutputRoot)
        if ($null -ne $result) {
            Complete-EditorLoad $result.Document @{TemplatePath='';OpenedZip=$true}
            $script:fields.ApplicationDetectionScript.Text='' # Existing detection must be reviewed for the new product.
            $controls.EditorStatus.Text='Upgraded ZIP opened in Editor: '+$result.Zip+'. Review detection, then build or run a local test.'
            $controls.BuildLog.AppendText("`r`nUpgrade working package: "+$result.Zip+"`r`nDetection selection cleared; review it for the new installer.")
        }
    } catch {$controls.EditorStatus.Text=Get-BuilderFailureMessage $_}
})
function Start-V5LocalTest([string]$Action) {
    $worker=$null
    try {
        if ($null -ne $script:job -or $null -ne $script:localTestProcess) {throw 'Wait for the current operation to finish.'}
        $context=if ($Action -eq 'Probe') {'SYSTEM'} else {$script:testContext}
        $mode=if ($context -eq 'SYSTEM') {'Silent'} else {[string]$controls.TestMode.SelectedItem.Content}
        $snapshot=$null;if ($Action -ne 'Probe') {Save-EditorBuffer;$snapshot=New-AuthoringSnapshot $script:editorDocument}
        $output=Get-V5OutputRoot
        $psexec=$controls.TestPsExec.Text;$eula=[bool]$controls.TestEula.IsChecked
        if ($context -eq 'SYSTEM') {if (-not $eula) {throw 'Review and accept the PsExec license before a SYSTEM test.'};Assert-LocalTestPsExec $psexec}
        if ($Action -ne 'Probe') {
            $message="Run $Action on $env:COMPUTERNAME using $context / $mode?`r`n`r`nThis executes the full package, including current editor changes. It can install, remove software or restart this computer. Use a Windows test device or VM. Closing the builder waits for the test; it does not cancel it."
            if ([Windows.MessageBox]::Show($window,$message,'Run local package test','YesNo','Warning') -ne 'Yes') {return}
        }
        $worker=[PowerShell]::Create();$queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $null=$worker.AddScript({param($engine,$snapshot,$output,$action,$context,$mode,$psexec,$eula)
            $ErrorActionPreference='Stop';. $engine;$workspace=$null
            try {
                if ($action -eq 'Probe') {
                    $parent=Resolve-BuilderOutputRoot $output;$root=Join-Path $parent ('PSADT-Test-'+[guid]::NewGuid().ToString('N'))
                    $null=[IO.Directory]::CreateDirectory($root);Protect-BuilderDirectory $root;$workspace=@{Root=$root;Source=''}
                } else {$workspace=New-UpgradeWorkspace $snapshot $output}
                return @{Test=(New-LocalTestRequest $workspace $action $context $mode $psexec $eula);Error=''}
            } catch {
                if ($null -ne $workspace -and (Test-Path -LiteralPath $workspace.Root)) {Remove-Item -LiteralPath $workspace.Root -Recurse -Force}
                $message='Could not prepare this local test. Check the full framework, entry parameters, paths, source changes and permissions.'
                $cause=$_.Exception;while ($null -ne $cause) {if ($cause.Data.Contains('BuilderSafeMessage')) {$message=[string]$cause.Data['BuilderSafeMessage'];break};$cause=$cause.InnerException}
                return @{Test=$null;Error=$message}
            }
        }).AddArgument((Join-Path $PSScriptRoot 'Build-Package.ps1')).AddArgument($snapshot).AddArgument($output).AddArgument($Action).AddArgument($context).AddArgument($mode).AddArgument($psexec).AddArgument($eula)
        $script:job=@{Worker=$worker;Handle=$worker.BeginInvoke();Queue=$queue;Secret=$null;Kind='LocalTest'}
        Set-BuilderBusy $true;$controls.TestStatus.Text='Preparing a private snapshot of the current package...'
    } catch {if ($null -eq $script:job -and $null -ne $worker) {$worker.Dispose()};$controls.TestStatus.Text=Get-BuilderFailureMessage $_}
}
function Complete-V5TestPreparation($Envelope) {
    if ($Envelope.Error) {$controls.TestStatus.Text=$Envelope.Error;return}
    if ($script:closeRequested) {$controls.TestStatus.Text='Test preparation finished. Close was requested, so no deployment was launched.';return}
    $script:localTestRequest=$Envelope.Test
    $script:localTestProcess=Start-LocalTestProcess $Envelope.Test
    $script:testEvidence=[IO.Path]::GetDirectoryName($Envelope.Test.Result)
    $controls.TestStatus.Text=$Envelope.Test.Action+' running under '+$Envelope.Test.Context+'. Waiting for the process and cleanup; no cancellation timer is armed.'
}
$controls.TestInstall.Add_Click({Start-V5LocalTest 'Install'})
$controls.TestRepair.Add_Click({Start-V5LocalTest 'Repair'})
$controls.TestUninstall.Add_Click({Start-V5LocalTest 'Uninstall'})
$controls.TestSystem.Add_Click({Start-V5LocalTest 'Probe'})
$controls.TestCurrentUser.Add_Click({$script:testContext='CurrentUser';$controls.TestContext.Text='Current user';$controls.TestMode.IsEnabled=$true})
$controls.TestBrowsePsExec.Add_Click({$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='Microsoft PsExec (*.exe)|*.exe';if ($dialog.ShowDialog($window)) {$controls.TestPsExec.Text=$dialog.FileName}})
$controls.TestOpenEvidence.Add_Click({if ($script:testEvidence -and (Test-Path -LiteralPath $script:testEvidence)) {Start-Process explorer.exe -ArgumentList (ConvertTo-LocalTestArgument $script:testEvidence)}})
$script:localTestTimer=New-Object Windows.Threading.DispatcherTimer;$script:localTestTimer.Interval=[timespan]::FromMilliseconds(500)
$script:localTestTimer.Add_Tick({
    if ($null -eq $script:localTestProcess -or -not $script:localTestProcess.HasExited) {return}
    try {
        $test=$script:localTestRequest
        if (-not (Test-Path -LiteralPath $test.Result) -or (Get-Item -LiteralPath $test.Result).Length -gt 64KB) {throw 'No completion receipt was produced. Elevation or policy may have blocked the runner. Check the selected PsExec tool and the protected DellBIOS child folder.'}
        $result=Get-Content -LiteralPath $test.Result -Raw|ConvertFrom-Json
        if ($result.Id -ne $test.Id) {throw 'The test receipt does not match this run.'}
        if ($result.Status -eq 'ContextVerified' -and $result.SID -eq 'S-1-5-18' -and $test.Action -eq 'Probe') {
            $script:testContext='SYSTEM';$controls.TestContext.Text='SYSTEM — verified (session 0, Silent)';$controls.TestMode.SelectedIndex=0;$controls.TestMode.IsEnabled=$false
        }
        $controls.TestStatus.Text=$result.Status+'; exit code: '+$result.ExitCode+'; SID: '+$result.SID+"`r`n"+$result.Message+"`r`nEvidence: "+$script:testEvidence
        if ($result.Status -eq 'Running') {$controls.TestStatus.Text='The runner ended without a completion receipt. The outcome is unknown; inspect processes and logs before another test. '+$script:testEvidence}
        $controls.BuildLog.AppendText("`r`nLocal test "+$test.Id+': '+$test.Action+' / '+$test.Context+' / '+$result.Status)
    } catch {$controls.TestStatus.Text=Get-BuilderFailureMessage $_}
    finally {$script:localTestProcess.Dispose();$script:localTestProcess=$null;Set-BuilderBusy $false}
    if ($script:closeRequested) {$window.Close()}
})
$script:localTestTimer.Start();Update-V5Actions
