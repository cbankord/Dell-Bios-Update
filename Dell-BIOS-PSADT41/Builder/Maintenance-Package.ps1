# Windows servicing and Dell INF driver packages share PSADT packaging, not BIOS state.
function Assert-MaintenanceSettings([hashtable]$Settings) {
    if ($Settings.ApplicationContext -ne 'System') { throw 'Windows updates and Dell drivers require System install behavior.' }
    if ($Settings.WindowsBuild -notmatch '^\d{5}$') { throw 'Enter the approved Windows build number, for example 26100. Build compatibility is checked on the endpoint.' }
    if (-not $Settings.ApplicationDetectionScript) { throw 'Windows updates and drivers require your tested Intune detection script. Check the installed package or device driver version, including the post-restart state.' }
    if (-not (Test-Path -LiteralPath $Settings.MaintenancePayload -PathType Leaf)) { throw 'Choose the update or driver payload.' }
    Assert-BuilderPath $Settings.MaintenancePayload
    $extension=[IO.Path]::GetExtension($Settings.MaintenancePayload)
    if ($Settings.PackageType -eq 'WindowsUpdate') {
        if ($extension -notin @('.msu','.cab')) { throw 'Windows Update requires an approved standalone .msu or .cab package.' }
        if ($extension -eq '.msu' -and [int]$Settings.WindowsBuild -lt 22000) { throw 'Online DISM installation of MSU packages requires Windows 11 (build 22000 or later).' }
    } elseif ($extension -ne '.zip') { throw 'Dell Driver requires a ZIP containing an extracted INF driver package, including its CAT and supporting files.' }
    if ($Settings.PackageType -eq 'Driver') {
        if ($Settings.DriverModels -isnot [array] -or $Settings.DriverModels.Count -lt 1) { throw 'Enter at least one exact approved Dell model for the driver.' }
        foreach ($model in $Settings.DriverModels) { if ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model) -or $model.Length -gt 150 -or $model -match '[\x00-\x1f*?]') { throw 'Use exact, plain-text Dell model names without wildcards.' } }
    }
}
function New-MaintenanceSections {
    $sections=[ordered]@{}
    foreach ($name in Get-EditorSectionNames) { $sections[$name]="    # $name`r`n" }
    $sections.PreInstall="    Show-ADTInstallationProgress`r`n"
    $sections.Install=@'
    # SYSTEM performs servicing. No automatic firmware or BitLocker changes.
    . (Join-Path $adtSession.DirFiles 'BuilderMaintenance/Deploy-Maintenance.ps1')
    $maintenanceResult = Invoke-BuilderMaintenance -Root (Join-Path $adtSession.DirFiles 'BuilderMaintenance')
'@
    $sections.PostInstall=@'
    # Intune owns the restart decision for this non-BIOS deployment.
    if ($maintenanceResult -eq 3010) { Close-ADTSession -ExitCode 3010 }
'@
    $sections.Uninstall="    throw 'Uninstall is not automatically supported for this servicing package. Use an approved rollback deployment.'`r`n"
    $sections.Repair="    throw 'Repair is not automatically supported for this servicing package.'`r`n"
    return $sections
}
function Set-MaintenanceIdentity([string]$Text,[hashtable]$Settings) {
    $table=Get-EditorMetadataLayout $Text
    $values=@{AppName=$Settings.ApplicationName;AppVersion=$Settings.ApplicationVersion}
    $edits=@(foreach ($pair in $table.KeyValuePairs) {
        $key=$pair.Item1.Extent.Text.Trim("'",'"')
        if ($values.ContainsKey($key)) { @{Start=$pair.Item2.Extent.StartOffset;End=$pair.Item2.Extent.EndOffset;Text=("'"+$values[$key].Replace("'","''")+"'")} }
        elseif ($key -eq 'AppSuccessExitCodes') { @{Start=$pair.Item2.Extent.StartOffset;End=$pair.Item2.Extent.EndOffset;Text='@(0)'} }
        elseif ($key -eq 'AppRebootExitCodes') { @{Start=$pair.Item2.Extent.StartOffset;End=$pair.Item2.Extent.EndOffset;Text='@(3010)'} }
    })
    foreach ($edit in $edits|Sort-Object -Property @{Expression={[int]$_.Start};Descending=$true}) { $Text=$Text.Remove($edit.Start,$edit.End-$edit.Start).Insert($edit.Start,$edit.Text) }
    return $Text
}
function Add-MaintenancePayload([hashtable]$Settings,[string]$Source,[string]$Work) {
    $target=Join-Path $Source 'Files/BuilderMaintenance'
    if (Test-Path -LiteralPath $target) { Stop-BuilderValidation 'The input ZIP already contains Files/BuilderMaintenance. Use the original PSADT template to avoid overwriting accepted package content.' }
    $null=[IO.Directory]::CreateDirectory($target)
    $payload=Join-Path $target 'Payload'
    if ($Settings.PackageType -eq 'Driver') {
        $snapshot=Join-Path $Work 'driver.zip'; Copy-Item -LiteralPath $Settings.MaintenancePayload -Destination $snapshot
        Expand-BuilderZip $snapshot $payload
        $inf=@(Get-ChildItem -LiteralPath $payload -Recurse -Filter '*.inf' -File)
        if (-not $inf.Count -or -not @(Get-ChildItem -LiteralPath $payload -Recurse -Filter '*.cat' -File).Count) { Stop-BuilderValidation 'Driver ZIP must contain INF files and signed driver catalogs. Include all original supporting files.' }
        foreach ($file in $inf) {
            $text=Get-Content -LiteralPath $file.FullName -Raw
            if ($text -match '(?im)^\s*Class\s*=\s*"?Firmware\b' -or $text -match '(?i)f2e7dd72-6468-4e36-b6f1-6488f42c1b52') { Stop-BuilderValidation 'Firmware-class INF packages are not supported in Driver mode. Use the managed BIOS workflow for BIOS updates.' }
        }
        $payloadHash=(Get-FileHash -LiteralPath $snapshot).Hash
    } else {
        $null=[IO.Directory]::CreateDirectory($payload)
        $name='ApprovedUpdate'+[IO.Path]::GetExtension($Settings.MaintenancePayload).ToLowerInvariant()
        Copy-Item -LiteralPath $Settings.MaintenancePayload -Destination (Join-Path $payload $name)
        $payloadHash=(Get-FileHash -LiteralPath (Join-Path $payload $name)).Hash
    }
    $files=@(foreach ($file in Get-ChildItem -LiteralPath $payload -Recurse -File) {
        @{Path=$file.FullName.Substring($payload.Length+1).Replace('\','/');SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash}
    })
    $config=@{Schema=1;PackageType=$Settings.PackageType;WindowsBuild=$Settings.WindowsBuild;Models=@($Settings.DriverModels);Files=$files}
    [IO.File]::WriteAllText((Join-Path $target 'Maintenance.json'),($config|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Deploy-Maintenance.ps1') -Destination $target
    return $payloadHash
}
