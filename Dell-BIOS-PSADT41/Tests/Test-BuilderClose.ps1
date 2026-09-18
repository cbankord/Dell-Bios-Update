# Exercise actual builder event handlers and async worker cleanup without WPF.
# No BIOS, template or content-prep executable is run.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path $PSScriptRoot -Parent
. "$root/Files/UI/WindowChrome.ps1"
$count=0
function Assert($Condition,[string]$Name) { $script:count++; if (-not $Condition) { throw "FAIL: $Name" } }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Builder script parses'
# Import only the GUI's diagnostic function; no Windows deployment initialization.
$engine=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Build-Package.ps1",[ref]$tokens,[ref]$errors)
$diagnostic=$engine.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BuilderFailureMessage'},$true)
. ([scriptblock]::Create($diagnostic.Extent.Text))
function Get-Handler([string]$Target,[string]$Event) {
    $calls=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq $Target -and $node.Member.Value -eq $Event
    },$true))
    if ($calls.Count -ne 1) { throw "Expected one $Target.$Event handler." }
    return $calls[0].Arguments[0].ScriptBlock.GetScriptBlock()
}
$busy=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-BuilderBusy'},$true)
. ([scriptblock]::Create($busy.Extent.Text))
$script:lastOutput=''
$script:closing=Get-Handler '$window' 'Add_Closing'
$click=Get-Handler '$controls.CloseButton' 'Add_Click'
$escape=Get-Handler '$window' 'Add_PreviewKeyDown'
$tick=Get-Handler '$timer' 'Add_Tick'
$dialogTry=$ast.Find({param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text.Contains('$window.ShowDialog()')
},$true)
$onExit=[scriptblock]::Create($dialogTry.Finally.Statements.Extent.Text -join "`n")
$controls=@{}
foreach ($name in @('FilesPanel','DeploymentPanel','ApplicationPanel','MaintenancePanel','EditorPanel','ExperiencePanel','OutputPanel','Reviewed','BuildButton','LoadButton','SaveButton','OpenButton','CloseButton','Progress')) {
    $controls[$name]=[pscustomobject]@{IsEnabled=$true;Content='Close';IsChecked=$false;IsIndeterminate=$false;Visibility='Collapsed'}
}
$script:fields=@{SectionTemplatePath=[pscustomobject]@{Text=''}}
$controls.EditorStatus=[pscustomobject]@{Text=''}
$controls.EditorTab=[pscustomobject]@{IsSelected=$false}
$editorAst=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Editor-UI.ps1",[ref]$tokens,[ref]$errors)
$complete=$editorAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-EditorLoad'},$true)
. ([scriptblock]::Create($complete.Extent.Text))
function Set-EditorDocument($Document) { $script:loadedEditorDocument=$Document }
$controls.BuildLog=[pscustomobject]@{Text=''}
$controls.BuildLog | Add-Member ScriptMethod AppendText {param($text) $this.Text+=$text}
$controls.BuildLog | Add-Member ScriptMethod ScrollToEnd {}
$window=[pscustomobject]@{Closed=0;CleanExit=$false}
$window | Add-Member ScriptMethod Close {
    $args=[pscustomobject]@{Cancel=$false}
    & $script:closing $this $args
    if (-not $args.Cancel) { $this.Closed++; $this.CleanExit=($null -eq $script:job) }
}
$script:job=$null; $script:closeRequested=$false
& $click
Assert ($window.Closed -eq 1 -and $window.CleanExit) 'Close exits immediately while idle'
Invoke-BiosCaptionAction $window Close
Assert ($window.Closed -eq 2 -and $window.CleanExit) 'Custom caption Close uses the same immediate idle exit'
$key=[pscustomobject]@{Key='Escape';Handled=$false}
& $escape $window $key
Assert ($key.Handled -and $window.Closed -eq 3) 'Escape uses the idle close path'
$key=[pscustomobject]@{Key='Enter';Handled=$false}
& $escape $window $key
Assert (-not $key.Handled -and $window.Closed -eq 3) 'Other keys do not exit the builder'

foreach ($packageType in @('BIOS','Application','WindowsUpdate','Driver','Editor')) {
foreach ($fail in @($false,$true)) {
    $partial=Join-Path ([IO.Path]::GetTempPath()) ('BuilderClose-'+[guid]::NewGuid()+'.tmp')
    $started=New-Object Threading.ManualResetEventSlim($false)
    $release=New-Object Threading.ManualResetEventSlim($false)
    $worker=[PowerShell]::Create()
    $secret=if ($packageType -eq 'BIOS') { ConvertTo-SecureString 'inert test secret' -AsPlainText -Force } else { $null }
    try {
        $null=$worker.AddScript({param($started,$release,$partial,$fail,$packageType)
            $ErrorActionPreference='Stop'
            try {
                [IO.File]::WriteAllText($partial,'inert partial output')
                $started.Set()
                if (-not $release.Wait(10000)) { throw 'Test worker release timed out.' }
                if ($fail) { throw 'Inert build failure' }
                if ($packageType -eq 'Editor') { @{SourceKind='Script';Text='Inert document'} } else { [pscustomobject]@{PackageType=$packageType;OutputDirectory='completed-output';SHA256='inert';IntuneWinFile=''} }
            } finally { if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) } }
        }).AddArgument($started).AddArgument($release).AddArgument($partial).AddArgument($fail).AddArgument($packageType)
        $script:job=@{Worker=$worker;Handle=$worker.BeginInvoke();Secret=$secret;Queue=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')}
        if ($packageType -eq 'Editor') { $script:job.Kind='Editor';$script:job.TemplatePath='' }
        Assert ($started.Wait(5000)) 'Background build reached its active operation'
        $script:closeRequested=$false; $window.Closed=0; $window.CleanExit=$false
        $controls.BuildLog.Text=''; $controls.CloseButton.IsEnabled=$true
        & $click
        Assert ($script:closeRequested -and $window.Closed -eq 0 -and -not $controls.CloseButton.IsEnabled) 'Active build queues close without exiting or stopping the worker'
        $key=[pscustomobject]@{Key='Escape';Handled=$false}
        & $escape $window $key
        Invoke-BiosCaptionAction $window Close # Actual custom caption dispatch.
        Assert (([regex]::Matches($controls.BuildLog.Text,'Close requested')).Count -eq 1) 'Repeated Close/Escape/X queues only one request'
        & $tick
        Assert (-not $script:job.Handle.IsCompleted -and [IO.File]::Exists($partial) -and $window.Closed -eq 0) 'Pending build and partial output are untouched by close polling'
        $release.Set()
        Assert ($script:job.Handle.AsyncWaitHandle.WaitOne(5000)) 'Build and cleanup finish before UI completes the worker'
        & $tick
        Assert ($window.Closed -eq 1 -and $window.CleanExit -and $null -eq $script:job -and -not [IO.File]::Exists($partial)) 'Success or failure closes only after worker cleanup and disposal'
        if ($null -ne $secret) {
            $disposed=$false; try { $null=$secret.Copy() } catch [ObjectDisposedException] { $disposed=$true }
            Assert $disposed 'Worker password disposed before exit'
        } else { Assert ($window.CleanExit -and $null -eq $script:job) 'Application worker closes cleanly without a BIOS secret' }
        if ($fail) { Assert ($controls.BuildLog.Text -match 'FAILED:') 'Worker failure is recorded before queued close' }
        elseif ($packageType -eq 'Editor') { Assert ($controls.BuildLog.Text.Contains('Editor sections loaded') -and $null -ne $script:loadedEditorDocument) 'Editor load completes through the guarded background worker without reporting a built package' }
        else {
            Assert ($script:lastOutput -eq 'completed-output' -and $controls.BuildLog.Text -match 'Output: completed-output') 'Completed output retained and reported before queued close'
            if ($packageType -ne 'BIOS') { Assert ($controls.BuildLog.Text.Contains('PSADT ZIP SHA256:') -and -not $controls.BuildLog.Text.Contains('BIOS SHA256:')) 'Application completion does not display a BIOS hash label' }
        }
    } finally {
        $release.Set(); $worker.Dispose(); if ($null -ne $secret) { $secret.Dispose() }; $script:job=$null
        $started.Dispose(); $release.Dispose()
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
}
}
$timer=[pscustomobject]@{Stopped=$false}
$timer | Add-Member ScriptMethod Stop { $this.Stopped=$true }
$script:fields=@{}
foreach ($name in @('Password','PasswordConfirm')) {
    $script:fields[$name]=[pscustomobject]@{Cleared=$false}
    $script:fields[$name] | Add-Member ScriptMethod Clear { $this.Cleared=$true }
}
$script:editorColorTimer=[pscustomobject]@{}; $script:editorColorTimer|Add-Member ScriptMethod Stop {}
$script:editorBox=[pscustomobject]@{}; $script:editorBox|Add-Member ScriptMethod Dispose {}
& $onExit
Assert ($timer.Stopped -and $script:fields.Password.Cleared -and $script:fields.PasswordConfirm.Cleared) 'Dialog exit stops polling and clears both password boxes'
Write-Output "PASS: $count builder close assertions (actual UI callbacks and async worker; WPF controls mocked). Windows Close/Escape/X pilot still required."
