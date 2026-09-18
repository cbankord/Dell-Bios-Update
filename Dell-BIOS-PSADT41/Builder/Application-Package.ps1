# Application packaging preserves the supplied deployment; it never runs its code.
function New-DeploymentPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings,[Security.SecureString]$BiosPassword,[scriptblock]$Progress={},[System.Collections.IDictionary]$EditorDocument)
    switch ($Settings.PackageType) {
        BIOS { return New-DellBiosPackage -Settings $Settings -BiosPassword $BiosPassword -Progress $Progress }
        { $_ -in @('Application','WindowsUpdate','Driver') } { return New-ApplicationPackage -Settings $Settings -Progress $Progress -EditorDocument $EditorDocument }
        default { throw 'Choose BIOS update, Application, Windows Update or Dell Driver.' }
    }
}
function Assert-ApplicationBuildSettings([hashtable]$Settings) {
    if ($Settings.PackageReviewed -isnot [bool] -or -not $Settings.PackageReviewed) { throw 'Review and approve the application package before building.' }
    foreach ($key in @('ApplicationName','ApplicationVersion')) {
        if ($Settings[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings[$key]) -or $Settings[$key].Length -gt 150 -or $Settings[$key] -match '[\x00-\x1f]') { throw "Enter $key (1-150 characters, no control characters)." }
    }
    if ($Settings.ApplicationContext -notin @('System','User')) { throw 'Application install behavior must be System or User.' }
    foreach ($key in @('FrameworkZip','OutputRoot')) { if ([string]::IsNullOrWhiteSpace($Settings[$key])) { throw "Choose $key." } }
    foreach ($key in @('FrameworkZip','ContentPrepTool','ApplicationDetectionScript')) {
        if ($Settings[$key]) {
            if (-not (Test-Path -LiteralPath $Settings[$key] -PathType Leaf)) { throw "Selected $key file does not exist." }
            Assert-BuilderPath $Settings[$key]
        }
    }
    if ([IO.Path]::GetExtension($Settings.FrameworkZip) -ne '.zip') { throw 'Select a ZIP containing your complete PSADT application.' }
    if ($Settings.ContentPrepTool -and [IO.Path]::GetFileName($Settings.ContentPrepTool) -ine 'IntuneWinAppUtil.exe') { throw 'Select the official IntuneWinAppUtil.exe content prep tool.' }
    if ($Settings.ApplicationDetectionScript -and ([IO.Path]::GetExtension($Settings.ApplicationDetectionScript) -ne '.ps1' -or (Get-Item -LiteralPath $Settings.ApplicationDetectionScript).Length -gt 1MB)) { throw 'Select a PowerShell detection script (.ps1), no larger than 1 MB.' }
}
function Get-ApplicationFramework([string]$ExpandedRoot) {
    $candidates=@(foreach ($file in Get-ChildItem -LiteralPath $ExpandedRoot -Recurse -File | Where-Object Name -in @('Invoke-AppDeployToolkit.ps1','Deploy-Application.ps1')) {
        $folder=$file.DirectoryName
        if ($file.Name -eq 'Invoke-AppDeployToolkit.ps1' -and (Test-Path -LiteralPath (Join-Path $folder 'Invoke-AppDeployToolkit.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $folder 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') -PathType Leaf)) {
            @{Root=$folder;Generation=4;EntryScript=$file.Name;SetupFile='Invoke-AppDeployToolkit.exe';Version=''}
        } elseif ($file.Name -eq 'Deploy-Application.ps1' -and (Test-Path -LiteralPath (Join-Path $folder 'AppDeployToolkit/AppDeployToolkitMain.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $folder 'AppDeployToolkit/AppDeployToolkitConfig.xml') -PathType Leaf)) {
            $setup=if (Test-Path -LiteralPath (Join-Path $folder 'Deploy-Application.exe') -PathType Leaf) {'Deploy-Application.exe'} else {'Deploy-Application.ps1'}
            @{Root=$folder;Generation=3;EntryScript=$file.Name;SetupFile=$setup;Version='3.x (legacy layout)'}
        }
    })
    if ($candidates.Count -ne 1) { Stop-BuilderValidation 'Application ZIP must contain exactly one complete PSADT 4.x or legacy 3.x deployment. A source-code archive or nested second package is not supported.' }
    $framework=$candidates[0]
    if ($framework.Generation -eq 4) {
        $module=Join-Path $framework.Root 'PSAppDeployToolkit'
        $manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $module 'PSAppDeployToolkit.psd1')
        $version=[version]$manifest.ModuleVersion
        if ($version.Major -ne 4 -or -not $manifest.RootModule -or $manifest.RootModule -notmatch '^[A-Za-z0-9_.-]+\.psm1$' -or -not (Test-Path -LiteralPath (Join-Path $module $manifest.RootModule) -PathType Leaf)) { Stop-BuilderValidation 'Application framework requires a PSADT 4.x manifest and its declared root module.' }
        $framework.Version=$version.ToString()
    }
    return $framework
}
function New-ApplicationPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings,[scriptblock]$Progress={},[System.Collections.IDictionary]$EditorDocument)
    Assert-BuilderHost
    if ($Settings.PackageType -notin @('Application','WindowsUpdate','Driver')) { throw 'Use Application, WindowsUpdate or Driver mode.' }
    Assert-BuilderSettings $Settings
    $outputParent=Resolve-BuilderOutputRoot $Settings.OutputRoot
    $label=($Settings.ApplicationName -replace '[^A-Za-z0-9_-]','-').Trim('-')
    if (-not $label) { $label='Application' }
    $label=$label.Substring(0,[math]::Min(40,$label.Length))
    $build=Join-Path $outputParent ('PSADT-'+$Settings.PackageType+'-'+$label+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=[IO.Directory]::CreateDirectory($build)
    $success=$false; $phase='securing application output'
    try {
        Protect-BuilderDirectory $build
        & $Progress ('Creating '+$Settings.PackageType+' package in: '+$build)
        $work=Join-Path $build '.buildwork'; $null=[IO.Directory]::CreateDirectory($work)
        $phase='validating the application ZIP'
        $snapshot=Join-Path $work 'application.zip'
        Copy-Item -LiteralPath $Settings.FrameworkZip -Destination $snapshot
        $zipHash=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
        $expanded=Join-Path $work 'Expanded'
        Expand-BuilderZip $snapshot $expanded
        $framework=Get-ApplicationFramework $expanded
        $source=Join-Path $build 'Source'; $null=[IO.Directory]::CreateDirectory($source)
        Get-ChildItem -LiteralPath $framework.Root -Force | Copy-Item -Destination $source -Recurse -Force
        $sections=$null; $payloadHash=''; $sectionHash=''; $entryChanged=$false; $fullScript=$false
        $maintenance=$Settings.PackageType -in @('WindowsUpdate','Driver')
        if ($maintenance) {
            if ($framework.Generation -ne 4 -or ([version]$framework.Version).Minor -ne 1) { Stop-BuilderValidation 'Generated Windows Update and Dell Driver deployments require a PSADT 4.1.x template.' }
            $phase='preparing approved servicing payload'
            $payloadHash=Add-MaintenancePayload $Settings $source $work
            $sections=New-MaintenanceSections
        }
        if ($Settings.UseEditor) {
            $phase='validating editor sections'
            if ($null -ne $EditorDocument) {
                if ($EditorDocument.ZIP_SHA256 -ne $zipHash) { Stop-BuilderValidation 'The PSADT ZIP changed after the editor loaded it. Reload the package in Editor before building.' }
                $fullScript=Test-EditorFullScript $EditorDocument
                if ($fullScript) {
                    if ($maintenance) { Stop-BuilderValidation 'Generated servicing requires mapped PSADT 4.1 sections. Use Application mode for full script editing.' }
                } else { $sections=$EditorDocument.Sections }
            } elseif ($Settings.SectionTemplatePath) { $sections=Import-EditorTemplate $Settings.SectionTemplatePath }
            else { Stop-BuilderValidation 'Load the selected ZIP in Editor, or select a saved section template before building in Editor mode.' }
        }
        if ($null -ne $sections -or $fullScript) {
            $phase='integrating PSADT sections'
            $entry=Join-Path $source $framework.EntryScript
            $originalText=Read-EditorScript $entry
            $text=if ($fullScript) { Get-EditorDocumentText @{LayoutKind='FullScript';Text=$originalText;CurrentScript=$EditorDocument.CurrentScript} } else { Set-EditorSections $originalText $sections }
            if ($maintenance) { $text=Set-MaintenanceIdentity $text $Settings }
            if (-not $fullScript -and $Settings.UseEditor -and $null -ne $EditorDocument -and $EditorDocument.Contains('MetadataText')) { $text=Set-EditorScriptMetadata $text $EditorDocument.MetadataText (Get-EditorDocumentMetadataKind $EditorDocument) }
            $entryChanged=$text -cne $originalText
            if ($entryChanged) { [IO.File]::WriteAllText($entry,$text,(New-Object Text.UTF8Encoding($true))) }
            if (-not $fullScript) {
                Export-EditorTemplate $sections (Join-Path $build 'Sections.psadt.json')
                $sectionHash=(Get-FileHash -LiteralPath (Join-Path $build 'Sections.psadt.json')).Hash
            }
        }
        $phase='validating resulting application source'
        & $Progress 'Checking PowerShell syntax; supplied scripts and payloads are never executed by the builder...'
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object Extension -in @('.ps1','.psd1')) {
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { Stop-BuilderValidation 'A supplied application PowerShell file has syntax errors. Correct it in the source ZIP before building.' }
        }
        $phase='preparing application detection'
        $intune=Join-Path $build 'Intune'; $null=[IO.Directory]::CreateDirectory($intune)
        $detection=@{Mode='ConfigureInIntune';Script='';SHA256=''}
        if ($Settings.ApplicationDetectionScript) {
            $scriptPath=Join-Path $intune 'Detect-Application.ps1'
            Copy-Item -LiteralPath $Settings.ApplicationDetectionScript -Destination $scriptPath
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { Stop-BuilderValidation 'The application detection script has syntax errors. No detection code was executed.' }
            $detection=@{Mode='CustomScript';Script='Intune/Detect-Application.ps1';SHA256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash}
        }
        $command=$framework.SetupFile
        if ($framework.SetupFile -eq 'Deploy-Application.ps1') { $command='powershell.exe -NoProfile -File Deploy-Application.ps1' }
        $install=$command+' -DeploymentType Install -DeployMode Silent'
        $uninstall=$command+' -DeploymentType Uninstall -DeployMode Silent'
        $instructions=@(
            'APPLICATION INTUNE SETTINGS - REVIEW BEFORE ASSIGNMENT'
            ('Install behavior: '+$Settings.ApplicationContext)
            ('Install command: '+$install)
            ('Uninstall command: '+$uninstall)
            ('Setup file for content preparation: '+$framework.SetupFile)
            ('Detection: '+$detection.Mode)
            'If CustomScript, upload Detect-Application.ps1. Otherwise configure an app-specific MSI, file, registry or custom detection rule in Intune.'
            'No universal detection script is generated. Check installed and absent states; use the required architecture and user/system context.'
            'Choose requirements, timeout, return-code mappings and restart policy to match this application. Review uninstall support in the original script.'
            'Existing or edited PSADT code owns app behavior. No BIOS policy, cache, BitLocker handling, scheduling or restart countdown is added.'
            'WindowsUpdate/Driver defaults suppress installer restarts and return 3010; configure Intune soft reboot handling and one restart policy. Do not add a competing timer.'
            'Generated servicing defaults do not implement uninstall or repair. Do not assign an uninstall intent without authoring and testing an approved rollback.'
            'Editor changes invalidate script signatures. Sign edited/generated scripts if required before final content preparation.'
            'Commands use Silent mode for Intune. Review custom bootstrap behavior; the builder does not certify arbitrary app code.'
            'For a script-only legacy launcher, review PowerShell host architecture; Intune command-line powershell.exe can start a 32-bit host.'
            'https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32'
        )
        [IO.File]::WriteAllLines((Join-Path $intune 'Install-Commands.txt'),$instructions,(New-Object Text.UTF8Encoding($true)))
        $intuneWin=''
        if ($Settings.ContentPrepTool) {
            $phase='running Microsoft content preparation'
            & $Progress 'Packaging the reviewed PSADT deployment with your Microsoft content prep tool...'
            $output=Join-Path $build 'Package'; $null=[IO.Directory]::CreateDirectory($output)
            $intuneWin=Invoke-BuilderContentPrep $Settings.ContentPrepTool $source $output -SetupFile $framework.SetupFile
        }
        $phase='writing application build records'
        $manifest=[ordered]@{
            BuilderVersion=$script:BuilderVersion;PackageType=$Settings.PackageType;BuiltUtc=[datetimeoffset]::UtcNow.ToString('o')
            ApplicationName=$Settings.ApplicationName;ApplicationVersion=$Settings.ApplicationVersion
            InstallBehavior=$Settings.ApplicationContext;FrameworkVersion=$framework.Version
            FrameworkGeneration=$framework.Generation;PackageZIP_SHA256=$zipHash;SetupFile=$framework.SetupFile
            InstallCommand=$install;UninstallCommand=$uninstall;Detection=$detection
            EntryScriptSHA256=(Get-FileHash -LiteralPath (Join-Path $source $framework.EntryScript)).Hash
            EditorLayout=$(if ($fullScript) {'FullScript'} elseif ($null -ne $sections) {'Sections'} else {'Unchanged'})
            SourcePreserved=(-not $maintenance -and -not $entryChanged);EditorApplied=$Settings.UseEditor;SectionsSHA256=$sectionHash;PayloadSHA256=$payloadHash;WindowsBuild=$Settings.WindowsBuild;DriverModels=@($Settings.DriverModels);OutputRoot=$outputParent;OutputDirectory=$build
            OutputMode=$(if ($intuneWin) {'IntuneWin'} else {'SourceOnly'})
            IntuneWinSHA256=$(if ($intuneWin) {(Get-FileHash -LiteralPath $intuneWin -Algorithm SHA256).Hash} else {''})
            UpgradeRecordSHA256=$(if (Test-Path -LiteralPath (Join-Path $source 'PSADT-Upgrade.json')) {(Get-FileHash -LiteralPath (Join-Path $source 'PSADT-Upgrade.json')).Hash} else {''})
        }
        [IO.File]::WriteAllText((Join-Path $build 'BuildManifest.json'),($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllLines((Join-Path $build 'Build.log'),@(
            ('Builder version: '+$script:BuilderVersion); ('Package type: '+$Settings.PackageType)
            ('Application: '+$Settings.ApplicationName+' / '+$Settings.ApplicationVersion)
            ('PSADT framework: '+$framework.Version); ('Input ZIP SHA256: '+$zipHash)
            ('Output folder: '+$outputParent); ('Build directory: '+$build)
            ('Output mode: '+$manifest.OutputMode); ('Detection: '+$detection.Mode)
            ('Sections applied: '+($null -ne $sections)+'; sections SHA256: '+$sectionHash)
            ('Editor layout: '+$manifest.EditorLayout)
            'No managed BIOS helpers or credentials injected.'
        ),(New-Object Text.UTF8Encoding($true)))
        Export-PackagePreset $Settings (Join-Path $build 'Settings.psd1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Application-Readme.txt') -Destination (Join-Path $build 'READ-ME-FIRST.txt')
        Remove-Item -LiteralPath $work -Recurse -Force
        $success=$true
        & $Progress 'Package build complete. Review READ-ME-FIRST.txt and Intune/Install-Commands.txt before deployment.'
        return [pscustomobject]@{PackageType=$Settings.PackageType;OutputDirectory=$build;SourcePath=$source;IntuneWinFile=$intuneWin;SHA256=$zipHash;FrameworkVersion=$framework.Version}
    } catch {
        $detail='Inspect the selected application ZIP and settings.'
        if ($_.Exception.Data.Contains('BuilderSafeMessage')) { $detail=[string]$_.Exception.Data['BuilderSafeMessage'] }
        throw "Build failed while $phase. $detail No package is ready; partial output will be removed."
    } finally {
        if (-not $success -and (Test-Path -LiteralPath $build)) { Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction Stop }
    }
}
