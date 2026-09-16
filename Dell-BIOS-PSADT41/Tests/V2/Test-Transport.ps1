$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Scheduler/Transport.ps1"
$count=0
function Check($v,$name) { $script:count++; if (-not $v) { throw "FAIL: $name" } }
$stream=New-Object IO.MemoryStream
try {
    Write-PipeMessage $stream @{Action='Schedule';Utc='2026-09-18T12:00:00Z'}
    $stream.Position=0
    $result=ConvertFrom-SchedulerJson (Read-PipeMessage $stream)
    Check ($result.Action -eq 'Schedule' -and $result.Utc -is [string]) 'Framing roundtrip preserves date strings'
    foreach($size in @(-1,0,1,16385,[int]::MaxValue)) {
        $stream.SetLength(0);$stream.Position=0
        $bytes=[BitConverter]::GetBytes([int]$size);$stream.Write($bytes,0,4);$stream.Position=0
        $rejected=$false; try { $null=Read-PipeMessage $stream } catch { $rejected=$true }
        Check $rejected "Reject invalid length $size"
    }
    $stream.SetLength(0);$stream.Position=0
    $rejected=$false; try { $null=Read-PipeMessage $stream } catch { $rejected=$true }
    Check $rejected 'Reject truncated frame'
} finally { $stream.Dispose() }
# Compile native declarations, without invoking any Windows APIs.
$source=Get-Content "$root/Files/Scheduler/Windows.ps1" -Raw
$cs=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition $cs
Check ([bool]('ManagedBiosV2.Peer' -as [type])) 'Compile authenticated-peer native declaration'
$source=Get-Content "$root/Files/UI/Show-BiosUI.ps1" -Raw
$cs=[regex]::Match($source,"(?s)Add-Type @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition $cs
Check ([bool]('BiosVisibleDesktop' -as [type])) 'Compile visible-desktop native declaration'
Write-Output "PASS: $count transport/native-declaration assertions. Windows calls were not invoked."
