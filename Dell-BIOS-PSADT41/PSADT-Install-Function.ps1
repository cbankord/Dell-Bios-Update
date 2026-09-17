# MedelaBIOS-FileVersion: 3.1.0
# Install Now / Schedule Install / Defer; no resident broker or UI task.
function Install-ADTDeployment {
    $adtSession.InstallPhase = 'Installation'
    $files = $adtSession.DirFiles
    . (Join-Path $files 'Common.ps1')
    foreach ($name in @('Cache.ps1','State.ps1','Safety.ps1','Scheduling.ps1','Live.ps1','Deployment.ps1')) {
        . (Join-Path $files ('Simple/'+$name))
    }
    $code = Invoke-MedelaDeployment $files
    Close-ADTSession -ExitCode $code
}
