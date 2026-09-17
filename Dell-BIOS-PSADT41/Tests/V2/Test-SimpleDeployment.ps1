$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaFlowTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldProgramData=$env:ProgramData; $env:ProgramData=$temp
$count=0
function Check($Value,$Name) {$script:count++; if (-not $Value) {if (Get-Variable logs -Scope Script -ErrorAction SilentlyContinue) {Write-Host ($script:logs -join "`n")}; throw "FAIL: $Name"}}
function Reject([scriptblock]$Body,$Name) {$failed=$false;try{&$Body}catch{$failed=$true};Check $failed $Name}
try {
    . "$root/Files/Common.ps1"
    foreach ($name in @('Cache','State','Safety','Deployment')) {. "$root/Files/Simple/$name.ps1"}
    $files=Join-Path $temp Files; Copy-Item -LiteralPath "$root/Files" -Destination $files -Recurse
    $config=Import-PowerShellDataFile (Join-Path $files 'BIOS-Config.psd1')
    $config.SHA256='a'*64; $config.PackageReviewed=$true
    # Config is serialized as a literal here; the inert EXE/password boundaries
    # are mocked. The production installer itself remains covered by base tests.
    $text=Get-Content (Join-Path $files 'BIOS-Config.psd1') -Raw
    $text=$text -replace "SHA256 = '[^']*'",("SHA256 = '"+('a'*64)+"'")
    $text=$text -replace 'PackageReviewed = \$false','PackageReviewed = $true'
    [IO.File]::WriteAllText((Join-Path $files 'BIOS-Config.psd1'),$text)
    Write-RuntimeManifest $files
    function Assert-MedelaHost {}
    function Assert-Model {}
    function Assert-Payload {}
    function Get-BiosPassword {}
    function Get-MedelaRoot {$script:cache}
    function Initialize-MedelaCache {param($Root) foreach($name in @('Runtime','State','UI','Recovery')) {$null=[IO.Directory]::CreateDirectory((Join-Path $Root $name))}}
    function Enter-LegacyRetirement {param($Root,$Config,$StatePath,$Policy) @()}
    function Get-State {$script:txn}
    function Get-BootId {'boot-one'}
    function Get-CimInstance {param($ClassName) [pscustomobject]@{SMBIOSBIOSVersion=$script:actual}}
    function Get-ADTLoggedOnUser {if($script:active){[pscustomobject]@{IsActiveUserSession=$true}}}
    function Write-ADTLogEntry {param($Message,$Severity) $script:logs.Add($Message)}
    function Write-BiosLog {param($Message) $script:logs.Add($Message)}
    function Assert-PostBootHealth {$script:healthChecks++; if($script:healthBad){throw 'BitLocker still suspended'}}
    function Invoke-MedelaPrompt {
        param($Root,$Mode,$Deadline,$Minutes,$Message,[switch]$Overdue)
        $script:modes.Add($Mode)
        if($script:answers.Count -eq 0){throw 'Unexpected UI call'}
        $script:answers.Dequeue()
    }
    function Invoke-MedelaInstaller {
        param($Root,$Files,[switch]$PreflightOnly)
        $script:launches++
        if ($script:installerCode -eq 3010) {$script:txn=[pscustomobject]@{Status='Staged';BootId='boot-one';TargetVersion=$config.TargetVersion;PayloadHash=$config.SHA256;SuspendedByUs='1'}}
        $script:installerCode
    }
    function Invoke-MedelaRestart {param($Config) if($script:powerBad){throw 'AC disconnected'}; $script:restarts++}
    function Fresh {
        $script:cache=Join-Path $temp ([guid]::NewGuid().ToString('N'))
        $script:WorkDir=Join-Path $cache Recovery
        $script:txn=$null; $script:active=$true; $script:actual='1.0.0'; $script:installerCode=3010
        $script:healthBad=$false; $script:powerBad=$false; $script:launches=0; $script:restarts=0; $script:healthChecks=0
        $script:answers=New-Object 'Collections.Generic.Queue[int]'
        $script:modes=New-Object 'Collections.Generic.List[string]'; $script:logs=New-Object 'Collections.Generic.List[string]'
        $script:path=Join-Path $cache ('State/'+(Get-PackageId $config)+'.json')
    }
    function Expire-Reminder {$s=Read-ScheduleFile $path;$s.NextNoticeUtc='';Save-ScheduleFile $s $path}
    Fresh; $script:active=$false
    Check ((Invoke-MedelaDeployment $files) -eq 1618) 'No active user returns retry'
    $s=Read-ScheduleFile $path
    Check (-not $s.DeadlineUtc -and $launches -eq 0 -and $modes.Count -eq 0) 'Unattended attempt does not start window, display UI or flash'
    Fresh; $answers.Enqueue(11)
    Check ((Invoke-MedelaDeployment $files) -eq 1618) 'Defer returns Intune retry'
    $s=Read-ScheduleFile $path; $deadline=$s.DeadlineUtc
    Check ($s.FirstNoticeUtc -and [datetimeoffset]::Parse($s.DeadlineUtc) -eq [datetimeoffset]::Parse($s.FirstNoticeUtc).AddHours(72) -and $launches -eq 0) 'First prompt attempt persists the original 72-hour deadline'
    $modes.Clear()
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and $modes.Count -eq 0) 'Repeated package run respects reminder cooldown'
    Expire-Reminder; $answers.Enqueue(11)
    $null=Invoke-MedelaDeployment $files
    Check ((Read-ScheduleFile $path).DeadlineUtc -eq $deadline) 'Another deferral preserves deadline'
    Remove-Item -LiteralPath $path
    Check ((Invoke-MedelaDeployment $files) -eq 60001 -and -not (Test-Path $path)) 'Missing enrolled state fails without granting a new window'
    Fresh; $answers.Enqueue(10); $answers.Enqueue(13)
    Check ((Invoke-MedelaDeployment $files) -eq 1618) 'Successful staging followed by Restart Later is still pending'
    Check ($launches -eq 1 -and $restarts -eq 0 -and ($modes -join ',') -eq 'Install,Restart') 'Install Now stages once and then displays the restart prompt'
    Expire-Reminder; $modes.Clear(); $answers.Enqueue(12)
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and $launches -eq 1 -and $restarts -eq 1 -and ($modes -join ',') -eq 'Restart') 'Staged retry offers guarded restart without reflashing'
    Expire-Reminder; $answers.Enqueue(12); $answers.Enqueue(14); $script:powerBad=$true
    $null=Invoke-MedelaDeployment $files
    Check ($restarts -eq 1 -and $launches -eq 1 -and $modes[-1] -eq 'Info') 'Failed restart safety gate explains hold without restarting or restaging'
    # Same runtime can prompt a staged transaction, but an altered key file
    # makes the entire attempt hold until the firmware transaction is resolved.
    $runtime=Join-Path $cache 'Runtime/Common.ps1'
    $before=Get-Content $runtime -Raw; [IO.File]::AppendAllText($runtime,"`n# drift")
    Expire-Reminder
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and (Get-Content $runtime -Raw).EndsWith('# drift')) 'Pending capsule prevents cached-file replacement'
    Fresh; $script:actual=$config.TargetVersion
    Check ((Invoke-MedelaDeployment $files) -eq 0 -and $healthChecks -eq 1 -and $modes.Count -eq 0 -and $launches -eq 0) 'Only actual BIOS plus health checks report complete'
    $script:txn=[pscustomobject]@{Status='Verified';SuspendedByUs='1'}
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and $healthChecks -eq 1) 'Unchanged runtime does not report completion while protection ownership is unresolved'
    Fresh; $script:actual=$config.TargetVersion; $script:healthBad=$true
    Check ((Invoke-MedelaDeployment $files) -eq 60001) 'Correct BIOS with failed protection check is not complete'
    Fresh; $answers.Enqueue(10); $answers.Enqueue(14); $script:installerCode=1618
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and ($modes -join ',') -eq 'Install,Info' -and $restarts -eq 0) 'Installer prerequisite failure never displays success or restarts'
    Fresh; $script:txn=[pscustomobject]@{Status='Launching';SuspendedByUs='1'}
    Check ((Invoke-MedelaDeployment $files) -eq 1618 -and $launches -eq 0) 'Ambiguous active transaction blocks updates and firmware launch'

    $t=[datetimeoffset]'2026-09-01T12:00:00Z'
    $legacy=@{PackageId='unit';Phase='Scheduled';WindowHours=48;FirstNotifiedUtc=$t.ToString('o');DeadlineUtc=$t.AddHours(48).ToString('o');NextNoticeUtc=$t.AddHours(4).ToString('o');LastObservedUtc=$t.ToString('o');ScheduledUtc=$t.AddHours(20).ToString('o')}
    $migrated=Import-LegacyDeadline $legacy unit 72
    Check ($migrated.WindowHours -eq 48 -and $migrated.DeadlineUtc -eq $legacy.DeadlineUtc -and -not $migrated.NextNoticeUtc) 'Legacy schedule imports original window/deadline and becomes due for the next package attempt'
    Start-SimpleNotice $migrated $t.AddDays(20)
    Check ($migrated.DeadlineUtc -eq $legacy.DeadlineUtc) 'Migration/code update cannot extend an overdue deadline'
    Reject {Import-LegacyDeadline $legacy different 72} 'Another unfinished firmware package cannot be migrated over'
    $migrated.DeadlineUtc=$t.AddHours(49).ToString('o')
    Reject {Assert-SimpleState $migrated unit} 'Extended deadline is rejected'

    # Execute the real UI callbacks with inert controls/window, without WPF.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Files/UI/Show-BiosUI.ps1",[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-Prompt'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $Mode='Install';$Demo=$false;$Overdue=$false;$deadline=[datetimeoffset]::UtcNow.AddDays(-1)
    $script:expires=[datetimeoffset]::UtcNow.AddSeconds(-1);$script:choice=1;$script:accepted=$false
    $c=@{Secondary=@{Visibility='Visible'};StatusText=@{Text=''};Remaining=@{Text=''}}
    $window=[pscustomobject]@{Closed=$false};$window|Add-Member ScriptMethod Close {$this.Closed=$true}
    Update-Prompt
    Check ($c.Secondary.Visibility -eq 'Collapsed' -and $script:choice -eq 10 -and $window.Closed) 'Overdue visible prompt removes defer and requests installation on timeout'
    $deadline=[datetimeoffset]::UtcNow.AddDays(1);$script:choice=1;Update-Prompt
    Check ($script:choice -eq 11) 'Before deadline timeout only defers'
    $Overdue=$true;Update-Prompt
    Check ($script:choice -eq 10 -and $c.Secondary.Visibility -eq 'Collapsed') 'SYSTEM overdue decision survives a backward clock change in the UI'
    $Overdue=$false
    $Mode='Restart';$script:choice=1;Update-Prompt
    Check ($script:choice -eq 13) 'Restart prompt timeout never requests a forced restart'
    $closing=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Closing'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $Mode='Install';$deadline=[datetimeoffset]::UtcNow.AddDays(-1);$script:accepted=$false;$e=@{Cancel=$false}
    &$closing $window $e
    Check ($e.Cancel) 'Closing the overdue installation prompt cannot grant another deferral'
    [xml]$xml=Get-Content "$root/Files/UI/Window.xaml" -Raw
    Check ($xml.DocumentElement.Width -eq '600' -and $null -ne $xml.SelectSingleNode('//*[@*[local-name()="Name"]="ActionBar"]')) 'Compact prompt retains a dedicated action bar'
    Write-Output "PASS: $count simple flow/state/UI assertions. Windows host, UI, firmware and restart boundaries mocked."
} finally {$env:ProgramData=$oldProgramData; Remove-Item -LiteralPath $temp -Recurse -Force}
