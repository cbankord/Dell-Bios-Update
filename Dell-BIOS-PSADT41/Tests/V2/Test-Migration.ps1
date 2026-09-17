$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaMigrationTests-'+[guid]::NewGuid())
$oldData=$env:ProgramData; $oldPrograms=$env:ProgramFiles
$count=0
function Check($Value,$Name) {$script:count++; if (-not $Value) {throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try{$null=&$Body}catch{$failed=$true};Check $failed $Name}
try {
    $env:ProgramData=Join-Path $temp Data; $env:ProgramFiles=Join-Path $temp Programs
    . "$root/Files/Common.ps1"
    foreach($name in @('Cache','State','Deployment')) {. "$root/Files/Simple/$name.ps1"}
    $cache=Join-Path $env:ProgramData 'Medela/DellBIOS'
    $legacyRoot=Join-Path $env:ProgramData ManagedDellBIOS
    $oldUI=Join-Path $env:ProgramFiles ManagedDellBIOS-v2
    foreach($dir in @((Join-Path $cache State),$legacyRoot,$oldUI)) {$null=[IO.Directory]::CreateDirectory($dir)}
    $cfg=@{TargetVersion='2.0.0';SHA256=('a'*64)}; $policy=@{WindowHours=72}
    $statePath=Join-Path $cache 'State/unit.json'
    $t=[datetimeoffset]::UtcNow.AddHours(-80)
    $legacy=@{Schema=2;PackageId=(Get-PackageId $cfg);Phase='Pending';WindowHours=72;FirstNotifiedUtc=$t.ToString('o');DeadlineUtc=$t.AddHours(72).ToString('o');NextNoticeUtc='';LastObservedUtc=$t.ToString('o');ScheduledUtc=''}
    Save-ScheduleFile $legacy (Join-Path $legacyRoot Schedule-v2.json)
    Save-ScheduleFile @{Schema=2} (Join-Path $legacyRoot Enrollment-v2.json)
    [IO.File]::WriteAllText((Join-Path $oldUI Show-BiosUI.ps1),'inert legacy UI')
    $script:tasks=@(
        [pscustomobject]@{TaskName='ManagedDellBIOS-v2-Controller';Actions=@([pscustomobject]@{Arguments=('-File "'+(Join-Path $legacyRoot 'Runtime-v2\Scheduler\Start-Broker.ps1')+'"')})},
        [pscustomobject]@{TaskName='ManagedDellBIOS-v2-UserUI';Actions=@([pscustomobject]@{Arguments=('-File "'+(Join-Path $oldUI Show-BiosUI.ps1)+'"')})}
    )
    $script:txn=$null; $script:taskChanges=0; $script:killed=@();$script:removed=@()
    function Get-State {$script:txn}
    function Get-ScheduledTask {param($TaskName,$ErrorAction) $script:tasks}
    function Disable-ScheduledTask {param($InputObject) $script:taskChanges++}
    function Stop-ScheduledTask {param($InputObject) $script:taskChanges++}
    function Unregister-ScheduledTask {param($InputObject,[switch]$Confirm) $script:removed+=,$InputObject.TaskName}
    function Get-CimInstance {
        param($ClassName,$Filter)
        [pscustomobject]@{ProcessId=101;CommandLine=('-NoProfile -STA -File "'+(Join-Path $oldUI Show-BiosUI.ps1)+'"')}
        [pscustomobject]@{ProcessId=102;CommandLine='-File "C:\inert\Install-DellBIOS.ps1"'}
    }
    function Stop-Process {param($Id,$ErrorAction) $script:killed+=,$Id}
    function Write-BiosLog {param($Message)}
    $script:txn=[pscustomobject]@{Status='Staged';SuspendedByUs='1'}
    Reject {Enter-LegacyRetirement $cache $cfg $statePath $policy} 'Staged legacy firmware blocks retirement'
    Check ($taskChanges -eq 0 -and $killed.Count -eq 0 -and (Test-Path $oldUI)) 'Blocked migration leaves all tasks and UI untouched'
    $script:txn=$null
    $legacy.Phase='Preparing';Save-ScheduleFile $legacy (Join-Path $legacyRoot Schedule-v2.json)
    Reject {Enter-LegacyRetirement $cache $cfg $statePath $policy} 'Legacy preparing phase also blocks retirement'
    Check ($taskChanges -eq 0) 'Preparing controller is never forcibly stopped'
    $legacy.Phase='Pending';Save-ScheduleFile $legacy (Join-Path $legacyRoot Schedule-v2.json)
    $firmwareGuard=[IO.File]::Open((Join-Path $legacyRoot Deployment.lock),'OpenOrCreate','ReadWrite','None')
    try {Reject {Enter-LegacyRetirement $cache $cfg $statePath $policy} 'Busy legacy firmware lock blocks retirement'} finally {$firmwareGuard.Dispose()}
    $savedArguments=$tasks[0].Actions[0].Arguments; $tasks[0].Actions[0].Arguments='-File C:\unexpected.ps1'
    Reject {Enter-LegacyRetirement $cache $cfg $statePath $policy} 'Unexpected task action is not stopped or deleted'
    $tasks[0].Actions[0].Arguments=$savedArguments
    $held=Enter-LegacyRetirement $cache $cfg $statePath $policy
    try {
        $migrated=Read-ScheduleFile $statePath
        Check ([datetimeoffset]::Parse($migrated.DeadlineUtc) -eq [datetimeoffset]::Parse($legacy.DeadlineUtc)) 'Overdue legacy deadline migrates without extension'
        Check ($taskChanges -eq 4 -and $removed.Count -eq 2) 'Only two legacy application tasks are retired'
        Check ($killed.Count -eq 1 -and $killed[0] -eq 101) 'Only exact legacy UI process is stopped, never installer'
        Check (-not (Test-Path $oldUI) -and (Test-Path (Join-Path $legacyRoot Schedule-v2.json))) 'Program Files UI removed; legacy protected state retained'
        Reject {[IO.File]::Open((Join-Path $legacyRoot Deployment.lock),'OpenOrCreate','ReadWrite','None')} 'Legacy transaction lock stays held until new deployment completes'
    } finally {foreach($guard in $held){$guard.Dispose()}}
    Reject {Enter-LegacyRetirement $cache $cfg $statePath $policy} 'Recreated legacy tasks identify an old competing assignment'
    $script:tasks=@();$before=(Get-FileHash $statePath).Hash
    $null=Enter-LegacyRetirement $cache $cfg $statePath $policy
    Check ((Get-FileHash $statePath).Hash -eq $before) 'Repeated migration never resets state'
    Write-Output "PASS: $count legacy migration assertions. Real file locks/state IO; task/process operations mocked."
} finally {$env:ProgramData=$oldData;$env:ProgramFiles=$oldPrograms;if(Test-Path $temp){Remove-Item $temp -Recurse -Force}}
