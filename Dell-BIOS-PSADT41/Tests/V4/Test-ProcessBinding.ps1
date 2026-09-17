# Actual PowerShell parameter binding against official PSADT 4.1 API metadata.
# No framework bodies, Windows APIs, processes, firmware or restarts are run.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaBindingTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData;$env:ProgramData=$temp
$count=0
function Check($Condition,$Name){$script:count++;if(-not $Condition){throw "FAIL: $Name"}}
function Binding-Fails([scriptblock]$Body) {
    try {$null=&$Body;return $false}
    catch {if($_.FullyQualifiedErrorId -notlike 'AmbiguousParameterSet,*'){throw};return $true}
}
function New-ContractStub($Name,$Contract) {
    $declarations=@(foreach($parameter in $Contract.Parameters) {
        $attributes=@(foreach($set in $parameter.RequiredIn){"[Parameter(Mandatory=`$true,ParameterSetName='$set')]"})
        $attributes+=@(foreach($set in $parameter.OptionalIn){"[Parameter(Mandatory=`$false,ParameterSetName='$set')]"})
        # Identity is inert on Linux; real identity/session selection is a pilot gate.
        $type=$parameter.Type
        if($type -eq 'System.Security.Principal.NTAccount'){$type='string'}
        elseif($type -like 'PSADT.*'){$type='object'}
        ($attributes -join "`n")+"`n[$type]`$"+$parameter.Name
    })
    return "function $Name { [CmdletBinding(DefaultParameterSetName='$($Contract.DefaultParameterSet)')] param("+($declarations -join ",`n")+") process { Invoke-ContractProcess '$Name' `$PSBoundParameters `$PSCmdlet.ParameterSetName } }"
}
function Invoke-ContractProcess($Name,$Parameters,$Set) {
    $copy=@{};foreach($key in $Parameters.Keys){$copy[$key]=$Parameters[$key]}
    $script:calls.Add([pscustomobject]@{Name=$Name;Parameters=$copy;Set=$Set})
    if($script:throwAt -eq $Name){throw 'Inert process launch failure'}
    $isUser=$Name -eq 'Start-ADTProcessAsUser'
    if($Parameters.ContainsKey('NoWait') -and $Parameters.NoWait) {
        $source=New-Object 'Threading.Tasks.TaskCompletionSource[object]'
        if(-not $isUser){$source.SetResult([pscustomobject]@{ExitCode=$script:workerCode})}
        return [pscustomobject]@{Task=$source.Task}
    }
    [pscustomobject]@{ExitCode=$(if($isUser){$script:promptCode}else{$script:workerCode});StdOut='';StdErr=''}
}
try {
    . "$root/Files/Common.ps1"
    foreach($name in @('Cache','State','Live','Deployment')){. "$root/Files/Simple/$name.ps1"}
    function Get-BootId {'inert-boot'}
    function Write-BiosLog {param($Message)$script:logs.Add($Message)}
    $fixture=Get-Content "$root/Tests/Fixtures/PSADT41-ProcessParameters.json" -Raw | ConvertFrom-Json
    Check ($fixture.Schema -eq 1 -and $fixture.Releases.Count -eq 9) 'Fixture covers official 4.1.0 through 4.1.8'
    foreach($release in $fixture.Releases) {
        $version=$release.Version
        foreach($command in $release.Commands) {
            $contract=$fixture.Contracts.PSObject.Properties[$command.Contract].Value
            . ([scriptblock]::Create((New-ContractStub $command.Name $contract)))
        }
        $script:calls=New-Object 'Collections.Generic.List[object]'
        $script:logs=New-Object 'Collections.Generic.List[string]'
        $script:throwAt='';$script:workerCode=3010;$script:promptCode=10
        $cache=Join-Path $temp $version
        foreach($name in @('UI','State','Recovery')){$null=[IO.Directory]::CreateDirectory((Join-Path $cache $name))}

        $rejectOld=[version]$version -ge [version]'4.1.4'
        Check ((Binding-Fails {Start-ADTProcessAsUser -FilePath inert.exe -CreateNoWindow -NoStreamLogging -NoWait -PassThru -IgnoreExitCodes '*'}) -eq $rejectOld) "$version reproduces the old progress-launch compatibility boundary"
        Check ((Binding-Fails {Start-ADTProcess -FilePath inert.exe -WindowStyle Hidden -NoWait -PassThru -IgnoreExitCodes '*'}) -eq $rejectOld) "$version reproduces the old worker-launch compatibility boundary"
        Check ((Binding-Fails {Start-ADTProcess -FilePath inert.exe -WindowStyle Hidden -NoWait:$false -PassThru -IgnoreExitCodes '*'}) -eq $rejectOld) "$version reproduces false NoWait still selecting its parameter set"
        $calls.Clear()

        Check ((Invoke-MedelaPrompt $cache Install ([datetimeoffset]::UtcNow.AddDays(3).ToString('o')) 10) -eq 10) "$version synchronous prompt preserves Install Now response"
        Check ($calls[-1].Set -eq 'Default_CreateNoWindow_Wait' -and $calls[-1].Parameters.IgnoreExitCodes -eq '*') "$version prompt waits and accepts its control exit codes"
        $handle=Invoke-MedelaInstaller $cache 'inert Files' -NoWait
        Check ((Get-MedelaProcessResult $handle).ExitCode -eq 3010) "$version asynchronous installer result retains the staging code"
        Check ($calls[-1].Set -eq 'Default_WindowStyle_NoWait' -and -not $calls[-1].Parameters.ContainsKey('IgnoreExitCodes')) "$version asynchronous worker uses a valid parameter set"
        $script:workerCode=0
        Check ((Invoke-MedelaInstaller $cache 'inert Files' -PreflightOnly) -eq 0) "$version synchronous preflight returns its real code"
        Check ($calls[-1].Set -eq 'Default_WindowStyle_Wait' -and -not $calls[-1].Parameters.ContainsKey('NoWait') -and $calls[-1].Parameters.ArgumentList -like '* -PreflightOnly') "$version preflight omits NoWait instead of binding false"
        Check ((Invoke-MedelaInstaller $cache 'inert Files' -NoWait:$false) -eq 0 -and $calls[-1].Set -eq 'Default_WindowStyle_Wait') "$version explicit false wrapper input still chooses a waiting launch"

        foreach($code in @(3010,1618,60001,0)) {
            $calls.Clear();$script:workerCode=$code
            Check ((Invoke-MedelaStaging $cache 'inert Files') -eq $code) "$version complete staging path retains worker code $code"
            Check ($calls.Count -eq 2 -and $calls[0].Set -eq 'Default_CreateNoWindow_NoWait' -and $calls[1].Set -eq 'Default_WindowStyle_NoWait') "$version real staging launches progress before its asynchronous worker"
            Check (@(Get-ChildItem (Join-Path $cache UI) -Recurse -Filter Status.json).Count -eq 0) "$version staging cleans transient status after worker completion"
            foreach($call in $calls) {
                Check (-not $call.Parameters.ContainsKey('IgnoreExitCodes') -and -not $call.Parameters.ContainsKey('Timeout') -and -not $call.Parameters.ContainsKey('KillChildProcessesWithParent')) "$version asynchronous path adds no incompatible exit filter or firmware termination option"
            }
        }
        $calls.Clear();$script:throwAt='Start-ADTProcessAsUser';$failed=$false
        try {$null=Invoke-MedelaStaging $cache 'inert Files'}catch{$failed=$_.Exception.Message -eq 'Inert process launch failure'}
        Check ($failed -and $calls.Count -eq 1 -and $calls[0].Name -eq 'Start-ADTProcessAsUser') "$version failed progress launch never starts firmware"
        Check (@(Get-ChildItem (Join-Path $cache UI) -Recurse -Filter Status.json).Count -eq 0) "$version failed progress launch cleans temporary status"
        $calls.Clear();$script:throwAt='Start-ADTProcess';$failed=$false
        try {$null=Invoke-MedelaStaging $cache 'inert Files'}catch{$failed=$_.Exception.Message -eq 'Inert process launch failure'}
        Check ($failed -and $calls.Count -eq 2 -and @(Get-ChildItem (Join-Path $cache UI) -Recurse -Filter Status.json).Count -eq 0) "$version failed worker launch retires its progress feed without claiming staging"
        Check ($logs.Contains('Starting progress UI through PSADT (asynchronous).') -and $logs.Contains('Starting BIOS preparation worker through PSADT (asynchronous).')) "$version records distinct launch boundaries without arguments or secrets"
    }
    Write-Output "PASS: $count PSADT 4.1 process-binding assertions across nine release contracts. Actual PowerShell binder and deployment wrappers; Windows/process boundaries inert."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
