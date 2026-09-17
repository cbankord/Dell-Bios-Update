# MedelaBIOS-FileVersion: 2.2.0
# Install Now / Defer; one PSADT invocation. No resident scheduler.
function Install-ADTDeployment {
    $adtSession.InstallPhase = 'Installation'
    $files = $adtSession.DirFiles
    . (Join-Path $files 'Common.ps1')
    foreach ($name in @('Cache.ps1','State.ps1','Safety.ps1','Deployment.ps1')) {
        . (Join-Path $files ('Simple/'+$name))
    }
    $code = Invoke-MedelaDeployment $files
    Close-ADTSession -ExitCode $code
}
