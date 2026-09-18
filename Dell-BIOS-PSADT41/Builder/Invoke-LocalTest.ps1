#requires -Version 5.1
# v5.0.0 - Isolated local test process. Never dot-sources the application into the editor.
param([Parameter(Mandatory)][string]$Request,[switch]$SystemChild)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
. "$PSScriptRoot/Local-Test.ps1"
$requestData=Get-Content -LiteralPath $Request -Raw|ConvertFrom-Json
if ($requestData.Context -eq 'CurrentUser' -or $SystemChild) {
    $evidence=if ($SystemChild) {Join-Path $PSScriptRoot 'Evidence'} else {$PSScriptRoot}
    Invoke-LocalTestPayload $requestData $evidence
    exit 0
}
. "$PSScriptRoot/Cache.ps1"
$stage='';$process=$null;$completed=$false;$phase='creating the protected SYSTEM test folder'
try {
    $stage=New-SystemTestDirectory $requestData
    $evidence=Join-Path $stage 'Evidence'
    $phase='validating Microsoft PsExec'
    if (-not $requestData.EulaAccepted) {throw 'PsExec license was not accepted.'}
    Assert-LocalTestPsExec $requestData.PsExec
    if ((Get-FileHash -LiteralPath $requestData.PsExec).Hash -ne $requestData.PsExecSHA256) {throw 'PsExec changed after selection.'}
    $psexec=Join-Path $stage ([IO.Path]::GetFileName($requestData.PsExec));Copy-Item -LiteralPath $requestData.PsExec -Destination $psexec
    Assert-LocalTestPsExec $psexec
    if ((Get-FileHash -LiteralPath $psexec).Hash -ne $requestData.PsExecSHA256) {throw 'PsExec changed during copying.'}
    $phase='snapshotting the reviewed package'
    if ($requestData.Action -ne 'Probe') {
        Assert-LocalTestHashes $requestData.Source $requestData.Hashes
        $source=Join-Path $stage 'Source';$null=[IO.Directory]::CreateDirectory($source)
        foreach ($property in $requestData.Hashes.PSObject.Properties) {
            $file=Join-Path $requestData.Source $property.Name;Assert-LocalTestPath $file
            $target=Join-Path $source $property.Name
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));Copy-Item -LiteralPath $file -Destination $target
        }
        Assert-LocalTestHashes $source $requestData.Hashes;$requestData.Source=$source
    }
    foreach ($name in @('Local-Test.ps1','Invoke-LocalTest.ps1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name)}
    $protectedRequest=Join-Path $stage 'Request.json';Write-LocalTestResult $protectedRequest $requestData
    $hostExe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    # No -i: session 0 and Silent mode approximate Intune SYSTEM execution.
    $arguments=@('-accepteula','-nobanner','-r',('MedelaPSADTTest-'+$requestData.Id.Substring(0,12)),'-s','-w',$stage,$hostExe,'-NoProfile','-File',(Join-Path $stage 'Invoke-LocalTest.ps1'),'-Request',$protectedRequest,'-SystemChild')
    $phase='starting the SYSTEM process'
    $process=Start-Process -FilePath $psexec -ArgumentList (@($arguments|ForEach-Object {ConvertTo-LocalTestArgument $_}) -join ' ') -WorkingDirectory $stage -RedirectStandardOutput (Join-Path $evidence 'psexec-out.log') -RedirectStandardError (Join-Path $evidence 'psexec-error.log') -PassThru
    $process.WaitForExit()
    if (-not (Test-Path -LiteralPath (Join-Path $evidence 'TestResult.json'))) {throw 'SYSTEM did not produce a test receipt.'}
    $receipt=Get-Content -LiteralPath (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
    $completed=$receipt.Status -ne 'Running'
} catch {
    if ($stage) {Write-LocalTestResult (Join-Path $stage 'Evidence/TestResult.json') @{Schema=1;Id=$requestData.Id;Action=$requestData.Action;Context='SYSTEM';Status='LaunchFailed';Message=('SYSTEM test failed while '+$phase+'. Check elevation, PsExec, folder protection and organization policy.');ExitCode=$null;SID='';DetectionVerified=$false}}
    Write-Error ('SYSTEM test failed while '+$phase+'. Shared Medela permissions were not changed.') -ErrorAction Continue
    exit 60001
} finally {
    if ($null -ne $process) {$process.Dispose()}
    # Keep evidence. No scheduled task, persistent broker or SYSTEM editor is created.
    if ($stage -and ($completed -or $null -eq $process)) {Get-ChildItem -LiteralPath $stage -Force|Where-Object Name -ne 'Evidence'|Remove-Item -Recurse -Force -ErrorAction Continue}
}
