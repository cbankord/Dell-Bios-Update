# Replace ONLY Install-ADTDeployment in your stock PSADT 4.1.x template with this.
# Keep the original template's bootstrap, session handling and other functions.
function Install-ADTDeployment {
    $adtSession.InstallPhase = 'Installation'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not [Environment]::Is64BitProcess) {
        $powerShell = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $adtSession.DirFiles 'Install-DellBIOS.ps1')
    $result = Start-ADTProcess -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru -IgnoreExitCodes '*'
    if ($null -eq $result) { throw 'BIOS deployment returned no process result.' }
    Close-ADTSession -ExitCode $result.ExitCode
}
