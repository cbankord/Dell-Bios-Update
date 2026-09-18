# BuilderMaintenance-FileVersion: 4.3.0
# Included only in WindowsUpdate/Driver Source. Dot-sourcing defines functions only.
function Assert-MaintenanceHost {
    if (-not [Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT') { throw 'Servicing requires 64-bit Windows.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { if ($identity.User.Value -ne 'S-1-5-18') { throw 'Deploy this servicing package through Intune as SYSTEM.' } }
    finally { $identity.Dispose() }
}
function Invoke-BuilderMaintenance([string]$Root) {
    Assert-MaintenanceHost
    $config=Get-Content -LiteralPath (Join-Path $Root 'Maintenance.json') -Raw|ConvertFrom-Json
    if ($config.Schema -ne 1 -or $config.PackageType -notin @('WindowsUpdate','Driver')) { throw 'Invalid servicing configuration.' }
    $computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($computer.Manufacturer -notmatch '^Dell(?: Inc\.?| Computer Corporation)?$') { throw 'This servicing package is approved for Dell computers only.' }
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.BuildNumber -ne $config.WindowsBuild -or $os.ProductType -ne 1) { throw 'This package is not approved for the installed Windows client build.' }
    if ($config.PackageType -eq 'Driver' -and $computer.Model -notin @($config.Models)) { throw 'This driver package is not approved for this Dell model.' }
    $payload=Join-Path $Root 'Payload'
    $prefix=[IO.Path]::GetFullPath($payload)+[IO.Path]::DirectorySeparatorChar
    $actual=@(Get-ChildItem -LiteralPath $payload -Recurse -File -ErrorAction Stop)
    if ($actual.Count -ne @($config.Files).Count -or -not $actual.Count) { throw 'Servicing payload inventory has changed.' }
    foreach ($entry in $config.Files) {
        $path=[IO.Path]::GetFullPath((Join-Path $payload $entry.Path))
        if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $entry.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.SHA256) { throw 'Servicing payload failed its approved SHA256 check.' }
    }
    # Serialize our update/driver packages. DISM/PnP also enforce their own servicing locks.
    $mutex=New-Object Threading.Mutex($false,'Global\Medela-PSADT-Servicing')
    $owned=$false
    try {
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { throw 'Another managed servicing package is active. Retry after it finishes.' }
        if ($config.PackageType -eq 'WindowsUpdate') {
            if ($actual.Count -ne 1 -or $actual[0].Extension -notin @('.msu','.cab')) { throw 'Windows Update requires one approved MSU or CAB.' }
            if ($actual[0].Extension -eq '.msu' -and [int]$os.BuildNumber -lt 22000) { throw 'Online MSU servicing requires Windows 11.' }
            $exe=Join-Path $env:WINDIR 'System32/dism.exe'
            $arguments='/Online /Add-Package /PackagePath:"'+$actual[0].FullName+'" /Quiet /NoRestart /PreventPending'
        } else {
            $infs=@($actual|Where-Object Extension -eq '.inf')
            if (-not $infs.Count) { throw 'No driver INF files were found.' }
            foreach ($inf in $infs) {
                $text=Get-Content -LiteralPath $inf.FullName -Raw
                if ($text -match '(?im)^\s*Class\s*=\s*"?Firmware\b' -or $text -match '(?i)f2e7dd72-6468-4e36-b6f1-6488f42c1b52') { throw 'Firmware-class drivers are not allowed in Driver mode.' }
            }
            $exe=Join-Path $env:WINDIR 'System32/pnputil.exe'
            $arguments='/add-driver "'+(Join-Path $payload '*.inf')+'" /subdirs /install'
        }
        Write-ADTLogEntry -Message ('Starting approved '+$config.PackageType+' servicing; Windows will validate package signatures and applicability.')
        # Synchronous only. Never combine NoWait with IgnoreExitCodes (PSADT 4.1 parameter sets).
        $result=Start-ADTProcess -FilePath $exe -ArgumentList $arguments -PassThru -IgnoreExitCodes '*'
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode']) { throw 'Servicing did not report an exit code.' }
        $code=[int]$result.ExitCode
        Write-ADTLogEntry -Message ('Servicing process returned '+$code+'. Intune detection must verify the installed state.')
        if ($code -notin @(0,3010)) { throw "Servicing failed or is not applicable (exit code $code). Inspect the PSADT log and Windows servicing logs." }
        return $code
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
