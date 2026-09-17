# Execute the real verifier main block in isolated runspaces, with inert Windows
# firmware/BitLocker/task APIs. Retained-source deletion and file locks are real.
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaScheduledRecovery-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData;$count=0
function Check($Value,$Name) {$script:count++;if (-not $Value) {throw "FAIL: $Name"}}
try {
    $text=Get-Content "$root/Files/Verify-AfterReboot.ps1" -Raw
    $main=$text.Substring($text.IndexOf('$lock = $null;'))
    foreach ($case in @('Passed','FailedBIOS','SameBoot','RecoveryBlocked','PackageBusy','CleanupBlocked','FinalCleanupBlocked')) {
        $data=Join-Path $temp $case;$env:ProgramData=$data
        $cache=Join-Path $data 'Medela/DellBIOS'
        foreach ($name in @('Runtime','State/ScheduledPackage/Source/Files','Recovery')) {$null=[IO.Directory]::CreateDirectory((Join-Path $cache $name))}
        foreach ($name in @('Cache','State','Scheduling')) {Copy-Item "$root/Files/Simple/$name.ps1" (Join-Path $cache "Runtime/$name.ps1")}
        $id='v2-2.7.3-'+('a'*64)
        [IO.File]::WriteAllText((Join-Path $cache 'State/ScheduledPackage/Ready.json'),(@{Schema=1;PackageId=$id}|ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $cache 'State/ScheduledPackage/Source/Files/BIOS-Password.psd1'),'inert-secret')
        [IO.File]::WriteAllText((Join-Path $cache 'State/original-deadline.json'),'preserve-deadline')
        [IO.File]::WriteAllText((Join-Path $cache 'Recovery/ApprovedBIOS.exe'),'inert-recovery')
        $held=$null;$ps=[PowerShell]::Create()
        try {
            if ($case -eq 'PackageBusy') {$held=[IO.File]::Open((Join-Path $cache 'State/Package.lock'),'OpenOrCreate','ReadWrite','None')}
            $null=$ps.AddScript({param($Root,$Case,$Cache)
                . "$Root/Files/Common.ps1"
                $script:scenario=$Case;$script:cache=$Cache
                $script:record=@{Status='Staged';BootId='before';TargetVersion='2.7.3';PayloadHash=('a'*64);SuspendedByUs='1'}
                $script:resumes=0;$script:removedVerifier=0;$script:logs=New-Object 'Collections.Generic.List[string]'
                function Get-State {$script:record}
                function Set-StateValue {param($Name,$Value) $script:record[$Name]=$Value}
                function Get-BootId {if($script:scenario -eq 'SameBoot') {'before'} else {'after'}}
                function Import-Module {param($Name) if($Name -ne 'BitLocker'){throw 'Unexpected module'}}
                function Get-BitLockerVolume {param($MountPoint) [pscustomobject]@{VolumeStatus='FullyEncrypted';ProtectionStatus=$(if($script:resumes){'On'}else{'Off'})}}
                function Resume-BitLocker {param($MountPoint,$ErrorAction)
                    if($script:scenario -eq 'RecoveryBlocked'){throw 'inert recovery failure'}
                    $script:resumes++
                }
                function Get-CimInstance {param($ClassName) [pscustomobject]@{SMBIOSBIOSVersion=$(if($script:scenario -eq 'FailedBIOS'){'2.6.0'}else{'2.7.3'})}}
                function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $null}
                function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm)
                    if($TaskName -ne 'ManagedDellBIOS-VerifyAndResume'){throw 'Unexpected task cleanup'}
                    $script:removedVerifier++
                }
                function Remove-MedelaVerifiedUI {param($WorkDir,$OldBoot,$CurrentBoot)}
                function Write-BiosLog {param($Message) $script:logs.Add($Message)}
                if($script:scenario -eq 'CleanupBlocked') {
                    function Remove-Item {param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction) throw 'inert snapshot deletion failure'}
                } elseif($script:scenario -eq 'FinalCleanupBlocked') {
                    function Remove-Item {param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction)
                        if($LiteralPath -eq (Join-Path $script:cache 'State/ScheduledPackage')) {throw 'inert final directory deletion failure'}
                        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
                    }
                }
            }).AddArgument($root).AddArgument($case).AddArgument($cache)
            $null=$ps.Invoke();Check (-not $ps.HadErrors) ($case+': verifier fixture initialized')
            $ps.Commands.Clear();$null=$ps.AddScript($main);$null=$ps.Invoke()
            $record=$ps.Runspace.SessionStateProxy.GetVariable('record')
            $removed=$ps.Runspace.SessionStateProxy.GetVariable('removedVerifier')
            $resumes=$ps.Runspace.SessionStateProxy.GetVariable('resumes')
            $slotExists=Test-Path (Join-Path $cache 'State/ScheduledPackage')
            if ($case -in @('Passed','FailedBIOS')) {
                $status=if($case -eq 'Passed'){'Verified'}else{'FailedAfterReboot'}
                Check ($record.Status -eq $status -and $record.SuspendedByUs -eq '0' -and $resumes -eq 1 -and -not $slotExists -and $removed -eq 1) ($case+': definitive result and protection recovery precede source/verifier cleanup')
            } elseif ($case -in @('CleanupBlocked','FinalCleanupBlocked')) {
                Check ($record.Status -eq 'Verified' -and $record.SuspendedByUs -eq '0' -and $slotExists -and $removed -eq 0) 'Cleanup failure retains verifier task for another attempt'
                if ($case -eq 'CleanupBlocked') {Check (Test-Path (Join-Path $cache 'State/ScheduledPackage/Ready.json')) 'Identifying marker retained while credential-source cleanup remains incomplete'}
                $ps.Commands.Clear();$null=$ps.AddScript('Microsoft.PowerShell.Management\Remove-Item Function:Remove-Item');$null=$ps.Invoke()
                $ps.Commands.Clear();$null=$ps.AddScript($main);$null=$ps.Invoke()
                Check (-not (Test-Path (Join-Path $cache 'State/ScheduledPackage')) -and $ps.Runspace.SessionStateProxy.GetVariable('removedVerifier') -eq 1) ($case+': next verifier completes interrupted cleanup before retiring')
            } else {
                Check ($record.Status -eq 'Staged' -and $record.SuspendedByUs -eq '1' -and $resumes -eq 0 -and $slotExists -and $removed -eq 0) ($case+': retains capsule protection ownership, private package and verifier')
            }
            Check ((Get-Content (Join-Path $cache 'State/original-deadline.json') -Raw) -ceq 'preserve-deadline' -and (Get-Content (Join-Path $cache 'Recovery/ApprovedBIOS.exe') -Raw) -ceq 'inert-recovery') ($case+': deadline and recovery records retained')
        } finally {if($null -ne $held){$held.Dispose()};$ps.Dispose()}
    }
    Write-Output "PASS: $count post-boot scheduled-source recovery assertions. Real locks and cleanup; Windows firmware/BitLocker/task boundaries mocked."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
