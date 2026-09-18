$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SectionTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData; if (-not $env:ProgramData) { $env:ProgramData=$temp }
$count=0
function Check($Condition,$Name) { $script:count++; if (-not $Condition) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Body,$Name) { $failed=$false;try {$null=& $Body} catch {$failed=$true};Check $failed $Name }
function New-SectionFixture {
    $text="param([string]`$DeploymentType)`r`n`$adtSession=@{AppName='Existing identity'}`r`n"
    $text+="function Get-Custom { return 'unchanged helper' }`r`n"
    foreach ($verb in @('Install','Uninstall','Repair')) {
        $text+='function '+$verb+"-ADTDeployment {`r`n    [CmdletBinding()]`r`n    param()`r`n"
        foreach ($phase in @('Pre-','','Post-')) {
            $text+='    $adtSession.InstallPhase = '+"'$phase$verb'`r`n"
            $text+="    # $phase$verb`r`n    if (`$true) { Write-Output '$phase$verb' }`r`n"
        }
        $text+="}`r`n"
    }
    return $text+"throw 'Bootstrap must never execute'`r`n"
}
try {
    . "$root/Builder/Build-Package.ps1"
    $text=New-SectionFixture
    $sections=Get-EditorSections $text
    Check ($sections.Count -eq 10) 'All ten sections extracted'
    Check ($sections.CustomFunctions.Contains('unchanged helper')) 'Custom functions loaded'
    foreach ($name in Get-EditorSectionNames) { Check ([bool]$sections[$name]) "$name has original contents" }
    # Build the here-string without nesting PowerShell's same-quote here-string delimiter.
    $sections.Install="    `$literal = @'`r`nBraces { } and `$adtSession.InstallPhase = 'X'`r`n'@`r`n    if (`$true) { Write-Output `$literal }`r`n"
    $sections.CustomFunctions="function Get-Custom { return 'café' }`r`nfunction Get-Second { return 2 }"
    $edited=Set-EditorSections $text $sections
    Check ($edited.Contains("`$adtSession=@{AppName='Existing identity'}") -and $edited.EndsWith("throw 'Bootstrap must never execute'`r`n")) 'Metadata and bootstrap retained exactly'
    $round=Get-EditorSections $edited
    Check ($round.Install.Contains('Braces { }') -and $round.CustomFunctions.Contains('Get-Second')) 'Nested strings and custom functions round-trip'
    $twice=Set-EditorSections $edited $round
    Check (([regex]::Matches($twice,'#region BuilderCustomFunctions')).Count -eq 1) 'Repeated edit does not duplicate custom region'
    $template=Join-Path $temp 'sections.psadt.json'; Export-EditorTemplate $sections $template
    $loaded=Import-EditorTemplate $template
    foreach ($name in Get-EditorSectionNames) { Check ($loaded[$name] -ceq $sections[$name]) "$name JSON preserves literal text" }
    $json=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    Check ((@($json.PSObject.Properties.Name) -join ',') -eq 'Format,Schema,Sections') 'Save contains only format identity and sections'
    $invalid=[ordered]@{};foreach($key in $sections.Keys){$invalid[$key]=$sections[$key]}
    $invalid.Install='if ('; Reject {Set-EditorSections $text $invalid} 'Invalid code blocked before full script mutation'
    $invalid.Install="}`nfunction Evil {"; Reject {Set-EditorSections $text $invalid} 'Escaping section braces blocked'
    $invalid.Install='$adtSession.InstallPhase = "extra"'; Reject {Set-EditorSections $text $invalid} 'Ambiguous additional phase assignment blocked'
    Reject {Get-EditorSections ($text.Replace('function Repair-ADTDeployment','function Other-Deployment'))} 'Missing required deployment function rejected'
    Reject {Get-EditorSections ($text+"`nfunction Get-LateHelper {}`n")} 'Unsupported late custom functions rejected rather than lost'
    Reject {Set-EditorSections ($text+"`n# SIG # Begin signature block") $sections} 'Signed input cannot be silently invalidated'
    $bad=Join-Path $temp 'bad.json';[IO.File]::WriteAllText($bad,'{"Format":"PSADT-Sections","Schema":2,"Sections":{}}')
    Reject {Import-EditorTemplate $bad} 'Unsupported template schema rejected'
    $unicode=Join-Path $temp 'unicode.ps1';$expected='Write-Output "caf'+[char]0xE9+'"'
    [IO.File]::WriteAllText($unicode,$expected,(New-Object Text.UTF8Encoding($false)))
    Check ((Read-EditorScript $unicode) -ceq $expected) 'UTF-8 without BOM preserves Unicode independently of Windows ANSI defaults'
    [IO.File]::WriteAllBytes($unicode,[byte[]]@(0xFF,0xFE,0xFF))
    # Invalid non-BOM ANSI byte is rejected rather than replacing characters.
    [IO.File]::WriteAllBytes($unicode,[byte[]]@(0x80))
    Reject {Read-EditorScript $unicode} 'Invalid UTF-8 must be converted explicitly'
    Reject {Get-EditorSections ($text.Replace("'Pre-Install'","'Post-Install'"))} 'Reordered phase labels are not guessed'
    $settings=New-PackageBuildSettings; Check (-not $settings.UseEditor -and $settings.SectionTemplatePath -eq '') 'PSADT remains default authoring view'
    $settings.UseEditor=$true;$settings.SectionTemplatePath=$template
    $preset=Join-Path $temp 'preset.psd1';Export-PackagePreset $settings $preset
    $presetData=Import-PackagePreset $preset
    Check ($presetData.UseEditor -and $presetData.SectionTemplatePath -eq $template -and -not $presetData.PackageReviewed) 'Preset remembers editor choice and template path, not code or approval'
    Reject {Assert-BuilderSettings $settings} 'BIOS editor replacement rejected'
    Write-Output "PASS: $count section editor assertions. No imported code was executed."
} finally {$env:ProgramData=$oldData;Remove-Item -LiteralPath $temp -Recurse -Force}
