$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Simple/Cache.ps1"
. "$root/Files/Simple/State.ps1"
$count=0
function Check($Value,$Name) { $script:count++; if (-not $Value) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Body,$Name) { $failed=$false; try { $null=&$Body } catch {$failed=$true}; Check $failed $Name }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaCacheTests-'+[guid]::NewGuid())
$files=Join-Path $temp 'Files'; $cache=Join-Path $temp 'Cache'
$null=[IO.Directory]::CreateDirectory($temp)
try {
    Copy-Item -LiteralPath "$root/Files" -Destination $files -Recurse
    $null=[IO.Directory]::CreateDirectory((Join-Path $cache 'State'))
    [IO.File]::WriteAllText((Join-Path $files 'BIOS-Password.psd1'),'inert-secret-do-not-copy')
    $statePath=Join-Path $cache 'State/original-deadline.json'
    [IO.File]::WriteAllText($statePath,'preserve-exact-state-bytes')
    $stateHash=(Get-FileHash $statePath).Hash
    Write-RuntimeManifest $files
    $plan=Get-CacheUpdatePlan $files $cache
    Check ($plan.Count -eq 11 -and @($plan|Where-Object Reason -ne 'Missing').Count -eq 0) 'All managed files identified on first install'
    Check (@($plan|Where-Object Source -match 'BIOS-Password|BIOS-Config|ApprovedBIOS').Count -eq 0) 'Cache allowlist excludes credentials and firmware/configuration'
    $script:events=New-Object 'Collections.Generic.List[string]'
    Update-MedelaCache $files $cache $plan {param($m) $script:events.Add($m)}
    Check ($events.Count -eq 11) 'Initial copies are recorded without secret data'
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -ne 'Current').Count -eq 0) 'Exact installed bytes are current'
    $current=Join-Path $cache 'Runtime/Common.ps1'
    $time=(Get-Item $current).LastWriteTimeUtc
    Update-MedelaCache $files $cache $plan
    Check ((Get-Item $current).LastWriteTimeUtc -eq $time) 'Unchanged files are not rewritten'
    Check ((Get-FileHash $statePath).Hash -eq $stateHash) 'Refresh preserves exact deadline-state bytes'
    $original=Get-Content -LiteralPath $current -Raw
    [IO.File]::WriteAllText($current,($original.Replace('MedelaBIOS-FileVersion: 2.2.0','MedelaBIOS-FileVersion: 1.9.0')))
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -eq 'OlderVersion').Count -eq 1) 'Older tattoo is selected for replacement'
    Update-MedelaCache $files $cache $plan
    Check ((Get-FileTattoo $current) -eq [version]'2.2.0') 'Older file replaced with packaged release'
    [IO.File]::AppendAllText($current,"`n# drift")
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -eq 'HashMismatch').Count -eq 1) 'Same tattoo with different bytes is repaired'
    Update-MedelaCache $files $cache $plan
    [IO.File]::WriteAllText($current,($original.Replace('# MedelaBIOS-FileVersion: 2.2.0','')))
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -eq 'Unversioned').Count -eq 1) 'Legacy unversioned file is selected'
    Update-MedelaCache $files $cache $plan
    Remove-Item -LiteralPath $current
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -eq 'Missing').Count -eq 1) 'A deleted key file is repaired without reenrollment'
    Update-MedelaCache $files $cache $plan
    [IO.File]::WriteAllText($current,($original.Replace('MedelaBIOS-FileVersion: 2.2.0','MedelaBIOS-FileVersion: 9.0.0')))
    Reject {Get-CacheUpdatePlan $files $cache} 'Newer installed code blocks the entire older package'
    [IO.File]::WriteAllText($current,$original)
    $source=Join-Path $files 'Common.ps1'; $sourceText=Get-Content $source -Raw
    [IO.File]::AppendAllText($source,"`n# changed after manifest")
    Reject {Get-CacheUpdatePlan $files $cache} 'Incoming hash mismatch fails before any replacement'
    [IO.File]::WriteAllText($source,$sourceText)
    $manifestPath=Join-Path $files 'RuntimeManifest.json'
    $manifest=Get-Content $manifestPath -Raw
    $data=$manifest|ConvertFrom-Json; $data.Files[0].Destination='../outside.ps1'
    [IO.File]::WriteAllText($manifestPath,($data|ConvertTo-Json -Depth 5))
    Reject {Get-CacheUpdatePlan $files $cache} 'Manifest cannot redirect a copy outside the allowlist'
    [IO.File]::WriteAllText($manifestPath,$manifest)
    $data=$manifest|ConvertFrom-Json; $data.Files+=@{Source='BIOS-Password.psd1';Destination='UI/Password.psd1';Version='2.2.0';SHA256=('a'*64)}
    [IO.File]::WriteAllText($manifestPath,($data|ConvertTo-Json -Depth 5))
    Reject {Get-CacheUpdatePlan $files $cache} 'Manifest cannot publish a secret in the public UI'
    [IO.File]::WriteAllText($manifestPath,$manifest)
    # Interrupt the real multi-file refresh at its second replacement. The
    # previous marker stays unchanged; a later run repairs exactly what remains.
    $a=Join-Path $cache 'Runtime/Common.ps1'; $b=Join-Path $cache 'Runtime/Install-DellBIOS.ps1'
    [IO.File]::AppendAllText($a,"`n# old"); [IO.File]::AppendAllText($b,"`n# old")
    $marker=Join-Path $cache 'State/InstalledFiles.json'; $markerHash=(Get-FileHash $marker).Hash
    $plan=Get-CacheUpdatePlan $files $cache
    $script:copies=0
    function Copy-Item {
        param($LiteralPath,$Destination,[switch]$Force)
        if ($Destination.EndsWith('.new')) { $script:copies++; if ($script:copies -eq 2) { throw 'inert-copy-failure' } }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    try { Reject {Update-MedelaCache $files $cache $plan} 'Failed replacement aborts the update' }
    finally { Remove-Item Function:Copy-Item }
    Check ((Get-FileHash $marker).Hash -eq $markerHash) 'Incomplete refresh never commits a new installed manifest'
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object Reason -ne 'Current').Count -eq 1) 'Next invocation recognizes the remaining repair'
    Update-MedelaCache $files $cache $plan
    Check (@((Get-CacheUpdatePlan $files $cache)|Where-Object Reason -ne 'Current').Count -eq 0) 'Next invocation completes interrupted refresh'
    foreach ($status in @('Preparing','Launching','Staged','FailedOrAmbiguous','FailedAfterReboot')) {
        Reject {Assert-CacheRefreshSafe ([pscustomobject]@{Status=$status;SuspendedByUs='1'}) $true} "No runtime replacement during $status"
    }
    Reject {Assert-CacheRefreshSafe ([pscustomobject]@{Status='Verified';SuspendedByUs='1'}) $true} 'Incomplete protection recovery also blocks replacement'
    Assert-CacheRefreshSafe ([pscustomobject]@{Status='Staged';SuspendedByUs='1'}) $false
    Check $true 'An unchanged runtime can offer the restart for an already staged update'
    Assert-CacheRefreshSafe ([pscustomobject]@{Status='Verified';SuspendedByUs='0'}) $true
    Check $true 'Fully resolved transaction permits repair'
    Check (-not (Get-Content $marker -Raw).Contains('inert-secret') -and -not (Test-Path (Join-Path $cache 'UI/BIOS-Password.psd1'))) 'Secret never appears in runtime manifest or public files'
    $brandPath=Join-Path $files 'UI/Branding.psd1'
    $brand=Get-Content $brandPath -Raw
    [IO.File]::WriteAllText($brandPath,($brand.Replace("LogoFile = ''","LogoFile = 'Assets/test-logo.png'")))
    [IO.File]::WriteAllBytes((Join-Path $files 'UI/Assets/test-logo.png'),[byte[]]@(1,2,3,4))
    Write-RuntimeManifest $files
    $plan=Get-CacheUpdatePlan $files $cache
    Update-MedelaCache $files $cache $plan
    $logo=Join-Path $cache 'UI/Assets/test-logo.png'
    Check ((Get-FileHash $logo).Hash -eq (Get-FileHash (Join-Path $files 'UI/Assets/test-logo.png')).Hash) 'Brand image bytes are preserved and verified through the manifest'
    [IO.File]::WriteAllBytes($logo,[byte[]]@(9,9,9,9))
    $plan=Get-CacheUpdatePlan $files $cache
    Check (@($plan|Where-Object { $_.Destination -eq 'UI/Assets/test-logo.png' -and $_.Reason -eq 'HashMismatch' }).Count -eq 1) 'Binary asset drift is detected without an inline tattoo'
    Write-Output "PASS: $count cache/version/repair assertions. Real file IO; no Windows ACL or firmware operations."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
