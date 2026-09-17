$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$oldProgramData=$env:ProgramData
$dir=Join-Path ([IO.Path]::GetTempPath()) ('BiosGuardTest-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $dir
$env:ProgramData=$dir
try {
    . "$root/Files/Common.ps1"
    . "$root/Files/Simple/State.ps1"
    . "$root/Files/Simple/Safety.ps1"
    $script:count=0
    function Check($v,$n) { $script:count++; if (-not $v) { throw "FAIL: $n" } }
    function Reject([scriptblock]$body,$n) { $failed=$false;try{&$body}catch{$failed=$true};Check $failed $n }
    $cfg=@{TargetVersion='2.1.1';SHA256=('a'*64)}
    $txn=[pscustomobject]@{Status='Staged';TargetVersion='2.1.1';PayloadHash=('a'*64);BootId='boot';SuspendedByUs='1'}
    $script:volume=[pscustomobject]@{LockStatus='Unlocked';VolumeStatus='FullyEncrypted';ProtectionStatus='Off'}
    function Assert-Model {}
    function Assert-Power {}
    function Import-Module {}
    function Get-BitLockerVolume { $script:volume }
    Assert-RestartSafe $cfg $txn boot
    Check $true 'Matching capsule with owned suspension permits restart'
    Reject {Assert-RestartSafe $cfg $txn anotherBoot} 'Old boot cannot trigger restart'
    Reject {Assert-RestartSafe $cfg $null boot} 'Missing transaction cannot trigger restart'
    $txn.PayloadHash='b'*64
    Reject {Assert-RestartSafe $cfg $txn boot} 'Wrong payload cannot trigger restart'
    $txn.PayloadHash='a'*64;$txn.Status='Launching'
    Reject {Assert-RestartSafe $cfg $txn boot} 'In-progress staging cannot trigger restart'
    $txn.Status='Staged';$txn.SuspendedByUs='0'
    Reject {Assert-RestartSafe $cfg $txn boot} 'Unowned suspension cannot trigger restart'
    $txn.SuspendedByUs='1';$script:volume.ProtectionStatus='On'
    Reject {Assert-RestartSafe $cfg $txn boot} 'Unexpected active protection cannot trigger restart'
    $script:volume.ProtectionStatus='Off';$script:volume.LockStatus='Locked'
    Reject {Assert-RestartSafe $cfg $txn boot} 'Locked OS volume blocks restart'
    $script:volume.LockStatus='Unlocked';$script:volume.VolumeStatus='FullyDecrypted'
    Reject {Assert-RestartSafe $cfg $txn boot} 'Unexpected encryption change blocks restart'
    $txn.SuspendedByUs='0'
    Assert-RestartSafe $cfg $txn boot
    Check $true 'Intentionally unencrypted device permits matching staged restart'
    $path=Join-Path $dir state.json
    $state=New-SimpleState unit 72
    Save-ScheduleFile $state $path
    $reloaded=Read-ScheduleFile $path
    Assert-SimpleState $reloaded unit
    Check ($reloaded.PackageId -eq 'unit') 'Durable state roundtrip'
    $state.Phase='Pending';Save-ScheduleFile $state $path
    $reloaded=Read-ScheduleFile $path
    Check ($reloaded.Phase -eq 'Pending' -and -not (Test-Path ($path+'.new'))) 'Atomic replace completes without stale temp'
    Remove-Item -LiteralPath $path
    Reject { Read-ScheduleFile $path } 'Missing state fails instead of creating new deadline'
    [IO.File]::WriteAllText($path,'broken-json')
    Reject { Read-ScheduleFile $path } 'Corrupt state fails closed'
    Write-Output "PASS: $script:count restart-guard and real file-persistence assertions. BitLocker APIs were mocked."
} finally {
    $env:ProgramData=$oldProgramData
    Remove-Item -LiteralPath $dir -Recurse -Force
}
