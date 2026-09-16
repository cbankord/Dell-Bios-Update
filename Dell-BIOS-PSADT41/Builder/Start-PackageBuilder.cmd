@echo off
setlocal
set "BIOS_BUILDER_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "BIOS_BUILDER_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%BIOS_BUILDER_PS%" -NoProfile -STA -File "%~dp0Start-PackageBuilder.ps1"
if errorlevel 1 pause
endlocal
