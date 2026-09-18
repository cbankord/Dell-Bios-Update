# Executes real request/receipt/hash/command logic with inert process and identity adapters.
$ErrorActionPreference='Stop';Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LocalTesting-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp);$count=0;$oldData=$env:ProgramData;$oldWindows=$env:SystemRoot;$env:ProgramData=$temp;$env:SystemRoot=$temp
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Reject([scriptblock]$Code,$Name){$failed=$false;try{$null=&$Code}catch{$failed=$true};Check $failed $Name}
function Write-Fixture($Path,$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text)}
try {
 . "$root/Builder/Build-Package.ps1"
 function Protect-BuilderDirectory($Path) {}
 $script:identity=@{SID='S-1-5-21-1-2-3-1001';Account='TEST\user';SessionId=1}
 function Get-LocalTestIdentity {return $script:identity}
 function Assert-LocalTestPsExec($Path) {if (-not (Test-Path $Path)) {throw 'No test tool'}}
 $source=Join-Path $temp 'Source';Write-Fixture (Join-Path $source 'Deploy-Application.ps1') "param([ValidateSet('Install','Repair','Uninstall')][string]`$DeploymentType,[ValidateSet('Silent','Interactive')][string]`$DeployMode)`nthrow 'MUST NOT RUN'"
 Write-Fixture (Join-Path $source 'AppDeployToolkit/AppDeployToolkitMain.ps1') "throw 'MUST NOT RUN'"
 Write-Fixture (Join-Path $source 'AppDeployToolkit/AppDeployToolkitConfig.xml') '<xml />'
 Write-Fixture (Join-Path $source 'Files/payload.txt') 'original'
 $workspace=@{Root=$temp;Source=$source};$tool=Join-Path $temp 'PsExec64.exe';Write-Fixture $tool 'INERT'
 Check ((Get-LocalTestArguments Install Silent) -join ' ' -eq '-DeploymentType Install -DeployMode Silent') 'Fixed lifecycle argument mapping'
 Reject {Get-LocalTestArguments 'Install;whoami' Silent} 'No command injection through action'
 Reject {Get-LocalTestArguments Install '-ExecutionPolicy Bypass'} 'Only reviewed mode values accepted'
 Reject {ConvertTo-LocalTestArgument 'path"malicious'} 'Quotes cannot escape process arguments'
 Check ((ConvertTo-LocalTestArgument 'C:\Apps\space path.ps1') -eq '"C:\Apps\space path.ps1"') 'Paths with spaces remain one Windows argument'
 Reject {New-LocalTestRequest $workspace Install SYSTEM Silent $tool $false} 'SYSTEM requires explicit PsExec license selection'
 $request=New-LocalTestRequest $workspace Install CurrentUser Interactive
 $json=Get-Content $request.Request -Raw|ConvertFrom-Json
 Check ($json.Action -eq 'Install' -and $json.Mode -eq 'Interactive' -and $json.Entry -eq 'Deploy-Application.ps1' -and $json.UserSid -eq $script:identity.SID) 'Current-user request captures action, context, entry point and account'
 Check ((Get-LocalTestHashes $source).Count -eq 4) 'Every source file pinned for testing'
 $system=New-LocalTestRequest $workspace Repair SYSTEM Interactive $tool $true
 $systemJson=Get-Content $system.Request -Raw|ConvertFrom-Json
 Check ($systemJson.Mode -eq 'Silent' -and $systemJson.PsExecSHA256 -eq (Get-FileHash $tool).Hash) 'SYSTEM forces Silent mode and pins selected PsExec'
 $script:calls=New-Object Collections.ArrayList;$script:exitCode=0
 function Start-Process {
  param($FilePath,$ArgumentList,$WorkingDirectory,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru,$Verb,$WindowStyle)
  $null=$script:calls.Add(@{Exe=$FilePath;Arguments=$ArgumentList;Directory=$WorkingDirectory;Verb=$Verb;WindowStyle=$WindowStyle})
  $p=[pscustomobject]@{ExitCode=$script:exitCode;HasExited=$true;Disposed=$false}
  $p|Add-Member ScriptMethod WaitForExit {}; $p|Add-Member ScriptMethod Dispose {$this.Disposed=$true};return $p
 }
 $null=Start-LocalTestProcess $request
 Check ($script:calls[-1].Arguments -match '-NoProfile' -and $script:calls[-1].Arguments -notmatch 'ExecutionPolicy|EncodedCommand' -and -not $script:calls[-1].Verb) 'Current-user launcher keeps execution policy and does not elevate'
 $null=Start-LocalTestProcess $system
 Check ($script:calls[-1].Verb -eq 'RunAs' -and $script:calls[-1].WindowStyle -eq 'Hidden') 'SYSTEM broker uses normal Windows elevation in a separate process'
 $evidence=Join-Path $temp 'Evidence';$null=[IO.Directory]::CreateDirectory($evidence)
 Invoke-LocalTestPayload $json $evidence
 $receipt=Get-Content (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'ProcessSucceeded' -and $receipt.ExitCode -eq 0 -and -not $receipt.DetectionVerified -and $receipt.SID -eq $script:identity.SID) 'Success receipt reports actual identity without claiming detection verified'
 Check ($script:calls[-1].Arguments -match '"-DeploymentType" "Install" "-DeployMode" "Interactive"' -and $script:calls[-1].Directory -eq $source) 'Legacy test launches the full entry script from package root'
 $json.Action='Repair';$script:exitCode=3010;Invoke-LocalTestPayload $json $evidence
 $receipt=Get-Content (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'RestartRequired' -and $receipt.Action -eq 'Repair') 'Repair and reboot-required return code preserved'
 $json.Action='Uninstall';$script:exitCode=1603;Invoke-LocalTestPayload $json $evidence
 $receipt=Get-Content (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'ProcessFailed' -and $receipt.ExitCode -eq 1603) 'Uninstall failure remains a failure'
 Write-Fixture (Join-Path $source 'Files/payload.txt') 'changed';$before=$script:calls.Count
 Invoke-LocalTestPayload $json $evidence
 $receipt=Get-Content (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'Failed' -and $script:calls.Count -eq $before) 'Changed payload cannot execute after review'
 Write-Fixture (Join-Path $source 'Files/payload.txt') 'original'
 Write-Fixture (Join-Path $source 'Files/extra.txt') 'injected';Reject {Assert-LocalTestHashes $source $json.Hashes} 'Unexpected additional payload blocked';Remove-Item (Join-Path $source 'Files/extra.txt')
 $probe=New-LocalTestRequest $workspace Probe SYSTEM Silent $tool $true;$probeJson=Get-Content $probe.Request -Raw|ConvertFrom-Json
 Reject {Invoke-LocalTestPayload $probeJson $evidence} 'SYSTEM label is not accepted under a user SID'
 $script:identity=@{SID='S-1-5-18';Account='NT AUTHORITY\SYSTEM';SessionId=0};$before=$script:calls.Count
 Invoke-LocalTestPayload $probeJson $evidence
 $receipt=Get-Content (Join-Path $evidence 'TestResult.json') -Raw|ConvertFrom-Json
 Check ($receipt.Status -eq 'ContextVerified' -and $receipt.SID -eq 'S-1-5-18' -and $receipt.SessionId -eq 0 -and $before -eq $script:calls.Count) 'Probe verifies actual SYSTEM/session without executing the app'
 $systemJson.Mode='Interactive';Reject {Invoke-LocalTestPayload $systemJson $evidence} 'SYSTEM interactive requests cannot bypass Silent mode'
 $limited="param([ValidateSet('Install','Uninstall')][string]`$DeploymentType,[string]`$DeployMode)"
 Write-Fixture (Join-Path $source 'Deploy-Application.ps1') $limited
 Reject {New-LocalTestRequest $workspace Repair CurrentUser Silent} 'Unsupported repair action detected before test launch'
 # Actual Closing callback retains a running test and never calls Stop/Kill.
 $t=$null;$e=$null;$main=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$t,[ref]$e)
 $closing=$main.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$window' -and $n.Member.Value -eq 'Add_Closing'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
 $controls=@{TestPanel=[pscustomobject]@{};TestStatus=[pscustomobject]@{Text=''}};$script:localTestProcess=[pscustomobject]@{HasExited=$false};$script:closeRequested=$false;$event=[pscustomobject]@{Cancel=$false}
 & $closing $null $event
 Check ($event.Cancel -and $script:closeRequested -and $null -ne $script:localTestProcess -and $controls.TestStatus.Text.Contains('deployment continues')) 'Closing UI waits without terminating an active deployment'
 Write-Output "PASS: $count local-testing assertions. Real hashes, requests, receipts and callbacks; process launch, identity and native trust are inert."
} finally {$env:ProgramData=$oldData;$env:SystemRoot=$oldWindows;if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
