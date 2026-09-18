# Exercise actual folder-selection/review callbacks with inert Windows dialog edges.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaOutputTests-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($temp)
$oldData=$env:ProgramData
if (-not $env:ProgramData) { $env:ProgramData=$temp }
$count=0
function Check($Condition,$Name) { $script:count++; if (-not $Condition) { throw "FAIL: $Name" } }
try {
    . "$root/Builder/Build-Package.ps1"
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$root/Builder/Start-PackageBuilder.ps1",[ref]$tokens,[ref]$errors)
    foreach ($name in @('Select-BuilderOutputFolder','Update-Review')) {
        $function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $browse=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$browse' -and $n.Member.Value -eq 'Add_Click'},$true).Arguments[0].ScriptBlock.GetScriptBlock()
    $script:form=New-PackageBuildSettings
    function Get-FormSettings { return $script:form }
    $controls=@{BuildLog=[pscustomobject]@{Text=''};ReviewText=[pscustomobject]@{Text=''}}
    $window=[pscustomobject]@{Name='inert builder'}
    Update-Review
    Check ($controls.ReviewText.Text.Contains('Choose an output folder above before building.')) 'Empty destination produces an explicit review instruction'
    $script:form.OutputRoot=$temp
    Update-Review
    Check ($controls.ReviewText.Text.Contains('Output folder: '+$temp)) 'Review shows selected folder'
    Check ($controls.ReviewText.Text.Contains('Source + Intune scripts (.intunewin tool not selected)')) 'Review separates destination from output contents'
    $script:form.ContentPrepTool='inert tool'
    Update-Review
    Check ($controls.ReviewText.Text.Contains('Output contents: Source + Intune scripts + .intunewin')) 'Optional package mode does not hide selected location'

    function New-Object {
        param([string]$TypeName,[object[]]$ArgumentList)
        switch ($TypeName) {
            'Windows.Forms.FolderBrowserDialog' {
                $script:dialog=[pscustomobject]@{Description='';ShowNewFolderButton=$false;SelectedPath='';InitialPath='';Owner=$null;Disposed=$false}
                $script:dialog | Add-Member ScriptMethod ShowDialog {
                    param($owner)
                    $this.Owner=$owner; $this.InitialPath=$this.SelectedPath
                    if ($script:dialogThrows) { throw 'Inert dialog failure' }
                    $this.SelectedPath=$script:nextPath
                    return $script:dialogResult
                }
                $script:dialog | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
                return $script:dialog
            }
            'Windows.Forms.NativeWindow' {
                $script:owner=[pscustomobject]@{Handle=0;Released=$false}
                $script:owner | Add-Member ScriptMethod AssignHandle {param($handle) $this.Handle=$handle}
                $script:owner | Add-Member ScriptMethod ReleaseHandle { $this.Released=$true }
                return $script:owner
            }
            'Windows.Interop.WindowInteropHelper' { return [pscustomobject]@{Handle=123} }
            default { throw "Unexpected boundary: $TypeName" }
        }
    }
    try {
        $sender=[pscustomobject]@{Tag=@{Type='Folder';Control=[pscustomobject]@{Text=$temp}}}
        $script:nextPath=Join-Path $temp 'Chosen Output'; $script:dialogResult='OK'; $script:dialogThrows=$false
        & $browse $sender $null
        Check ($sender.Tag.Control.Text -eq $script:nextPath) 'Accepted picker result updates actual output field'
        Check ($dialog.InitialPath -eq $temp -and $dialog.ShowNewFolderButton) 'Picker starts at current folder and permits creating a folder'
        Check ($dialog.Owner -eq $owner -and $owner.Handle -eq 123) 'Native picker receives builder owner handle'
        Check ($dialog.Disposed -and $owner.Released) 'Dialog and temporary owner are released after selection'
        $script:dialogResult='Cancel'; $script:nextPath='must not replace selection'
        $previous=$sender.Tag.Control.Text
        & $browse $sender $null
        Check ($sender.Tag.Control.Text -eq $previous) 'Cancel retains an existing destination'
        Check ($dialog.Disposed -and $owner.Released) 'Cancel still disposes picker resources'
        $sender.Tag.Control.Text=''
        & $browse $sender $null
        Check ($sender.Tag.Control.Text -eq '') 'Cancel with no prior choice does not silently use Documents'
        $sender.Tag.Control.Text=$previous; $script:dialogThrows=$true
        & $browse $sender $null
        Check ($sender.Tag.Control.Text -eq $previous -and $controls.BuildLog.Text.Contains('Type an existing local folder')) 'Picker failure preserves selection and offers manual entry'
        Check ($dialog.Disposed -and $owner.Released) 'Picker failure disposes resources'
    } finally { Remove-Item Function:New-Object }
    [xml]$xml=Get-Content "$root/Builder/Window.xaml" -Raw
    $panel=$xml.SelectSingleNode("//*[@*[local-name()='Name']='OutputPanel']")
    $tab=$panel.ParentNode.ParentNode.ParentNode
    Check ($tab.LocalName -eq 'TabItem' -and $tab.Header -eq '4  Build') 'Destination is on the Build screen before review and build'
    Check ($xml.DocumentElement.Title -eq 'PSADT Deployment Builder v4.2' -and (Import-PowerShellDataFile "$root/Builder/Branding.psd1").AppTitle -eq $xml.DocumentElement.Title) 'Default caption and branded title identify v4.2'
    Write-Output "PASS: $count builder output assertions. Actual selection/review callbacks; native folder picker and WPF require Windows pilot."
} finally { $env:ProgramData=$oldData; Remove-Item -LiteralPath $temp -Recurse -Force }
