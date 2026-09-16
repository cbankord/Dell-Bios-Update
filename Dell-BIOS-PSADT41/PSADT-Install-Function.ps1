# V2: replace ONLY Install-ADTDeployment in stock Invoke-AppDeployToolkit.ps1.
# The durable SYSTEM controller owns staging and restart; PSADT installs it.
function Install-ADTDeployment {
    $adtSession.InstallPhase = 'Installation'
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not [Environment]::Is64BitProcess) { $powerShell = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
    $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $adtSession.DirFiles 'Install-Scheduler.ps1')
    $result = Start-ADTProcess -FilePath $powerShell -ArgumentList $args -WindowStyle Hidden -PassThru -IgnoreExitCodes '*'
    if ($null -eq $result) { throw 'Scheduler enrollment returned no result.' }
    if ($result.ExitCode -eq 0) {
        $active = Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession } | Select-Object -First 1
        if ($active) {
            try {
                $ui = Join-Path $env:ProgramFiles 'ManagedDellBIOS-v2\Show-BiosUI.ps1'
                $uiArgs = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $ui
                $null = Start-ADTProcessAsUser -FilePath $powerShell -ArgumentList $uiArgs -WindowStyle Hidden -NoWait
            } catch { Write-ADTLogEntry -Message 'UI launch deferred to the registered user task. See Scheduler.log for enrollment status.' -Severity 2 }
        }
    }
    # Do not return 3010 to Intune or invoke PSADT's restart prompt in V2.
    Close-ADTSession -ExitCode $result.ExitCode
}
