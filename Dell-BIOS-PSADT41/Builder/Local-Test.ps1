# v5.0.0 - Explicit local lifecycle tests. These are real installations, not a sandbox.
function Get-LocalTestArguments([string]$Action,[string]$Mode) {
    if ($Action -notin @('Install','Repair','Uninstall') -or $Mode -notin @('Silent','Interactive')) { throw 'Choose Install, Repair or Uninstall and Silent or Interactive mode.' }
    return @('-DeploymentType',$Action,'-DeployMode',$Mode)
}
function Assert-LocalTestPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {throw 'Tests require local absolute paths.'}
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Local tests cannot use links or junctions.'}
        $item=if ($item -is [IO.DirectoryInfo]) {$item.Parent} else {$item.Directory}
    }
}
function Get-LocalTestHashes([string]$Source) {
    Assert-LocalTestPath $Source
    $files=@(Get-ChildItem -LiteralPath $Source -Recurse -Force -File)
    if ($files.Count -gt 20000) {throw 'Test package contains too many files.'}
    $hashes=@{};[long]$total=0
    foreach ($file in $files) {
        Assert-LocalTestPath $file.FullName;$total+=$file.Length
        if ($file.Length -gt 2GB -or $total -gt 4GB) {throw 'Test package exceeds supported size.'}
        $hashes[$file.FullName.Substring($Source.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}
function Assert-LocalTestHashes([string]$Source,$Expected) {
    $actual=Get-LocalTestHashes $Source
    $expectedMap=@{}
    if ($Expected -is [System.Collections.IDictionary]) {foreach ($key in $Expected.Keys) {$expectedMap[$key]=$Expected[$key]}}
    else {foreach ($property in $Expected.PSObject.Properties) {$expectedMap[$property.Name]=[string]$property.Value}}
    if ($actual.Count -ne $expectedMap.Count) {throw 'The reviewed test package file list changed. Prepare a new test.'}
    foreach ($key in $actual.Keys) {if (-not $expectedMap.ContainsKey($key) -or $actual[$key] -ne $expectedMap[$key]) {throw 'A reviewed test file changed. Prepare a new test.'}}
}
function Assert-LocalTestPsExec([string]$Path) {
    Assert-LocalTestPath $Path
    if ([IO.Path]::GetFileName($Path) -notin @('PsExec.exe','PsExec64.exe')) {throw 'Select Microsoft PsExec.exe or PsExec64.exe.'}
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?Microsoft Corporation"?(?:,|$)') {throw 'PsExec must have a valid Microsoft signature.'}
}
function ConvertTo-LocalTestArgument([string]$Value) {
    if ($Value -match '["\r\n\x00]' -or $Value.EndsWith('\')) {throw 'Unsupported character in test argument.'}
    return '"'+$Value+'"'
}
function Get-LocalTestHostPath {
    return Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
}
function Write-LocalTestResult([string]$Path,$Value) {
    # All privileged writes stay inside the protected, generated evidence directory.
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
}
function Get-LocalTestIdentity {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    return @{SID=$identity.User.Value;Account=$identity.Name;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId}
}
function New-LocalTestRequest([hashtable]$Workspace,[string]$Action,[string]$Context,[string]$Mode,[string]$PsExec='',[bool]$EulaAccepted=$false) {
    if ($Action -notin @('Install','Repair','Uninstall','Probe') -or $Context -notin @('CurrentUser','SYSTEM')) {throw 'Unsupported local test action or context.'}
    if ($Action -eq 'Probe' -and $Context -ne 'SYSTEM') {throw 'The context probe is for SYSTEM only.'}
    if ($Context -eq 'SYSTEM') {
        if (-not $EulaAccepted) {throw 'Review and accept the Microsoft PsExec license in Local tests first.'}
        Assert-LocalTestPsExec $PsExec;$Mode='Silent'
    }
    $id=[guid]::NewGuid().ToString('N')
    $entry='';$hashes=@{}
    if ($Action -ne 'Probe') {
        $null=Get-LocalTestArguments $Action $Mode
        $framework=Get-ApplicationFramework $Workspace.Source;$entry=$framework.SetupFile
        $scriptText=Read-EditorScript (Join-Path $Workspace.Source $framework.EntryScript)
        $parsed=Get-EditorSyntax $scriptText
        if ($parsed.Errors.Count) {throw 'Correct deployment script syntax before running a local test.'}
        $parameterNames=@($parsed.Ast.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
        if ('DeploymentType' -notin $parameterNames -or 'DeployMode' -notin $parameterNames) {throw 'The entry script must expose DeploymentType and DeployMode parameters for lifecycle testing.'}
        foreach ($parameter in $parsed.Ast.ParamBlock.Parameters) {
            $value=switch ($parameter.Name.VariablePath.UserPath) {DeploymentType {$Action} DeployMode {$Mode} default {''}}
            if (-not $value) {continue}
            foreach ($attribute in $parameter.Attributes|Where-Object {$_.TypeName.FullName -in @('ValidateSet','ValidateSetAttribute')}) {
                $allowed=@($attribute.PositionalArguments|Where-Object {$_ -is [Management.Automation.Language.StringConstantExpressionAst]}|ForEach-Object {$_.Value})
                if ($allowed.Count -and $value -notin $allowed) {throw 'The selected action or mode is not supported by the entry script ValidateSet.'}
            }
        }
        $hashes=Get-LocalTestHashes $Workspace.Source
    }
    $job=Join-Path $Workspace.Root ('Test-'+$id);$null=[IO.Directory]::CreateDirectory($job);Protect-BuilderDirectory $job
    foreach ($name in @('Local-Test.ps1','Invoke-LocalTest.ps1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $job $name)}
    Copy-Item -LiteralPath (Join-Path $script:BuilderSource 'Files/Simple/Cache.ps1') -Destination (Join-Path $job 'Cache.ps1')
    $identity=Get-LocalTestIdentity
    $result=if ($Context -eq 'SYSTEM') {Join-Path (Get-MedelaRoot) ('BuilderTest-'+$id+'/Evidence/TestResult.json')} else {Join-Path $job 'TestResult.json'}
    $request=@{Schema=1;Id=$id;Action=$Action;Context=$Context;Mode=$Mode;Source=$Workspace.Source;Entry=$entry;Hashes=$hashes;UserSid=$identity.SID;PsExec=$PsExec;PsExecSHA256=$(if ($PsExec) {(Get-FileHash -LiteralPath $PsExec).Hash} else {''});EulaAccepted=$EulaAccepted}
    $requestPath=Join-Path $job 'Request.json';Write-LocalTestResult $requestPath $request
    return @{Job=$job;Request=$requestPath;Result=$result;Action=$Action;Context=$Context;Id=$id;Source=$Workspace.Source}
}
function Start-LocalTestProcess([hashtable]$Test) {
    $hostExe=Get-LocalTestHostPath
    $arguments=@('-NoProfile','-File',(Join-Path $Test.Job 'Invoke-LocalTest.ps1'),'-Request',$Test.Request)
    $parameters=@{FilePath=$hostExe;ArgumentList=(@($arguments|ForEach-Object {ConvertTo-LocalTestArgument $_}) -join ' ');PassThru=$true;WorkingDirectory=$Test.Job;WindowStyle='Hidden'}
    if ($Test.Context -eq 'SYSTEM') {$parameters.Verb='RunAs'}
    return Start-Process @parameters
}
function New-SystemTestDirectory($Request) {
    if ($Request.Id -notmatch '^[0-9a-f]{32}$' -or $Request.UserSid -notmatch '^S-1-(?:5-(?:21-\d+-\d+-\d+-\d+|18)|12-1-\d+-\d+-\d+-\d+)$') {throw 'Invalid test identifier or originating account.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'SYSTEM tests require normal administrator elevation.'}
    $root=Get-MedelaRoot;$parent=[IO.Path]::GetDirectoryName($root)
    Assert-NoCacheLinks $root
    if (-not (Test-Path -LiteralPath $parent)) {$null=[IO.Directory]::CreateDirectory($parent)}
    Assert-MedelaSharedParent $parent # Read only; never change shared Medela permissions.
    $acl=New-MedelaDirectoryAcl $true;$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    if (-not (Test-Path -LiteralPath $root)) {New-MedelaCacheDirectory $root $acl}
    Assert-MedelaSharedParent $root
    $stage=Join-Path $root ('BuilderTest-'+$Request.Id)
    if (Test-Path -LiteralPath $stage) {throw 'This SYSTEM test identifier was already used.'}
    $private=New-MedelaDirectoryAcl;$private.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    # Originating user can traverse this root and read Evidence, but cannot change SYSTEM code.
    $user=New-Object Security.Principal.SecurityIdentifier($Request.UserSid)
    $private.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user,'ReadAndExecute','None','None','Allow')))
    New-MedelaCacheDirectory $stage $private
    $evidenceAcl=New-MedelaDirectoryAcl;$evidenceAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $evidenceAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    New-MedelaCacheDirectory (Join-Path $stage 'Evidence') $evidenceAcl
    return $stage
}
function Invoke-LocalTestPayload($Request,[string]$Evidence) {
    if ($Request.Schema -ne 1 -or $Request.Action -notin @('Install','Repair','Uninstall','Probe') -or $Request.Context -notin @('CurrentUser','SYSTEM')) {throw 'Invalid test request.'}
    $identity=Get-LocalTestIdentity;$sid=$identity.SID
    if ($Request.Context -eq 'SYSTEM' -and ($sid -ne 'S-1-5-18' -or $Request.Mode -ne 'Silent')) {throw 'The test did not start as SYSTEM in Silent mode.'}
    $result=@{Schema=1;Id=$Request.Id;Action=$Request.Action;Context=$Request.Context;Account=$identity.Account;SID=$sid;SessionId=$identity.SessionId;StartedUtc=[datetimeoffset]::UtcNow.ToString('o');Status='Running';ExitCode=$null;DetectionVerified=$false;Phase='Preparing';Message='Live test started.'}
    $path=Join-Path $Evidence 'TestResult.json';Write-LocalTestResult $path $result
    $mutex=$null;$owned=$false;$process=$null
    try {
        if ($Request.Action -eq 'Probe') {$result.Status='ContextVerified';$result.ExitCode=0;$result.Message='SYSTEM identity verified. No deployment was executed.';return}
        $mutex=New-Object Threading.Mutex($false,'Global\Medela-PSADT-LocalTest')
        try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if (-not $owned) {throw 'Another local package test is running.'}
        Assert-LocalTestHashes $Request.Source $Request.Hashes
        if ($Request.Entry -notin @('Invoke-AppDeployToolkit.exe','Deploy-Application.exe','Deploy-Application.ps1')) {throw 'Unsupported PSADT launcher.'}
        $arguments=Get-LocalTestArguments $Request.Action $Request.Mode
        $exe=Join-Path $Request.Source $Request.Entry
        if ($Request.Entry -eq 'Deploy-Application.ps1') {
            $arguments=@('-NoProfile','-File',$exe)+$arguments
            $exe=Get-LocalTestHostPath
        }
        $result.Phase='Executing';Write-LocalTestResult $path $result
        $process=Start-Process -FilePath $exe -ArgumentList (@($arguments|ForEach-Object {ConvertTo-LocalTestArgument $_}) -join ' ') -WorkingDirectory $Request.Source -RedirectStandardOutput (Join-Path $Evidence 'stdout.log') -RedirectStandardError (Join-Path $Evidence 'stderr.log') -PassThru
        $process.WaitForExit();$result.ExitCode=$process.ExitCode;$result.Phase='Finished'
        $result.Status=if ($process.ExitCode -eq 0) {'ProcessSucceeded'} elseif ($process.ExitCode -in @(3010,1641)) {'RestartRequired'} else {'ProcessFailed'}
        $result.Message='The process finished. Check the PSADT log and installed state; the exit code alone does not verify installation, repair or removal.'
    } catch {$result.Status='Failed';$result.Message='The local test could not finish during '+$result.Phase+'. Check the package, permissions, existing test and application-control policy. No process was terminated by this runner.'}
    finally {
        if ($null -ne $process) {$process.Dispose()};if ($owned) {$mutex.ReleaseMutex()};if ($null -ne $mutex) {$mutex.Dispose()}
        $result.FinishedUtc=[datetimeoffset]::UtcNow.ToString('o');Write-LocalTestResult $path $result
    }
}
