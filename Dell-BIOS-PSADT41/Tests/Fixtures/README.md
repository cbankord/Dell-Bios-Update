# PSADT parameter contracts

`PSADT41-ProcessParameters.json` records public parameter names, types, mandatory
flags and parameter-set membership from official PSADT tags 4.1.0 through 4.1.8.
Each command identifies its upstream source URL. Retrieved 2026-09-17.

This is API metadata, not a bundled framework. The binding regression reconstructs
inert advanced functions and lets PowerShell enforce those parameter sets while
running our real launch/orchestration functions. Windows-only identity types are
substituted with inert objects/strings; framework defaults, validation callbacks
and all process-launch code are excluded. No executable is run. This catches the
4.1.4+ incompatibility between NoWait and IgnoreExitCodes that permissive mocks
missed, including the fact that explicitly passing NoWait:$false still binds it.

To regenerate, place the reviewed official `Start-ADTProcess.ps1` and
`Start-ADTProcessAsUser.ps1` in folders named for each release, then run:

```powershell
./Tests/Tools/Export-PSADTProcessParameters.ps1 -SourceDirectory C:\ReviewedPSADT -OutputPath ./Tests/Fixtures/PSADT41-ProcessParameters.json
```

The exporter parses source without importing or executing the framework. Native
Windows PowerShell 5.1, PSADT session launch, WPF and Dell hardware still require
the Windows pilot. Third-party framework source remains available from the
linked PSAppDeployToolkit repository under its stated LGPL-3.0 license.
