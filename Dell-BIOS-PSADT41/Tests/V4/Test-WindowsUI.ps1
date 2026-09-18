# Windows-only native WPF smoke check. Briefly displays inert windows.
# Does not load deployment logic, create tasks, stage firmware or request restart.
# Run as a standard user: powershell.exe -NoProfile -STA -File .\Tests\V4\Test-WindowsUI.ps1
# Optional -IconPath validates a real PNG/ICO used in your pilot.
#requires -Version 5.1
param([string]$IconPath='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this Windows-only check in Windows PowerShell 5.1 with -STA.'
}
if([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {throw 'Run in the signed-in user session.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,WindowsFormsIntegration,System.Windows.Forms
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not ('Medela.EditorV44.RenderScope' -as [type])) { Add-Type -Path "$root/Builder/Editor-Rendering.cs" }
. "$root/Files/UI/WindowChrome.ps1"
$count=0
function Check($Value,$Name){$script:count++;if(-not $Value){throw "FAIL: $Name"}}
function Click-Caption($Window,$Name) {
    $button=$Window.FindName($Name)
    $button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
}
foreach($folder in @('Builder','Files/UI')) {
    $window=$null
    try {
        [xml]$xml=Get-Content "$root/$folder/Window.xaml" -Raw
        $reader=New-Object Xml.XmlNodeReader $xml
        try {$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
        $brand=Import-PowerShellDataFile "$root/$folder/Branding.psd1"
        $window.Title=$brand.AppTitle+' (inert UI smoke check)'
        Initialize-BiosWindowChrome $window "$root/Files/UI/Theme.xaml" $brand $IconPath
        $window.Show();$window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        Check ($null -ne $window.Icon) "$folder icon loads"
        Check ($null -ne [Windows.Shell.WindowChrome]::GetWindowChrome($window)) "$folder native WindowChrome attaches"
        foreach($name in @('CaptionMinimize','CaptionMaximize','CaptionClose')) {
            $button=$window.FindName($name)
            Check ($null -ne $button.Template -and [Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($button)) "$folder $name resolves its template and caption hit testing"
            Check ([Windows.Automation.AutomationProperties]::GetName($button).Length -gt 0) "$folder $name has an accessible name"
        }
        if ($folder -eq 'Builder') {
            $window.FindName('EditorTab').IsSelected=$true
            $hostControl=$window.FindName('EditorHost');$box=New-Object Windows.Forms.RichTextBox
            $box.AccessibleName='PowerShell section editor';$box.Text='Write-Output "Inert preview"'
            $hostControl.Child=$box
            Check ($hostControl.Child.Text.Contains('Inert preview')) 'Inline native text editor attaches to WPF host'
            Check ($window.FindName('EditorMode').SelectedIndex -eq 0) 'Default authoring view is PSADT'
            foreach ($name in @('EditorOpenScript','EditorEditScript','EditorSaveScript','EditorSaveScriptAs','EditorCloseScript')) {
                Check ($null -ne $window.FindName($name)) "$name is present in the native editor window"
            }
            $window.UpdateLayout();$box.WordWrap=$false
            $original=(1..80|ForEach-Object {"# line $_`n"}) -join ''
            $box.Text=$original;$box.ClearUndo();$box.Select($box.TextLength,0);$box.SelectedText='# user edit'
            $edited=$box.Text;$selection=$box.SelectionStart;$box.ScrollToCaret()
            $top=$box.GetCharIndexFromPosition((New-Object Drawing.Point(1,1)))
            $scope=[Medela.EditorV44.RenderScope]::Begin($box.Handle)
            try {
                $box.SelectAll();$box.SelectionColor=[Drawing.Color]::DarkGreen
                $box.Select(0,0);$box.ScrollToCaret() # Force a scroll change during coloring.
                $box.Select($selection,0)
            } finally { $scope.Dispose() }
            Check ($box.Text -ceq $edited -and $box.SelectionStart -eq $selection) 'Native coloring preserves text and selection'
            Check ($box.GetCharIndexFromPosition((New-Object Drawing.Point(1,1))) -eq $top) 'Native coloring restores scroll position'
            Check $box.CanUndo 'Coloring retains the user text undo history'
            $box.Undo();Check ($box.Text -ceq $original) 'Undo removes the user edit instead of syntax colors'
            $box.Redo();Check ($box.Text -ceq $edited) 'Redo restores the user edit after highlighting'
        }
        Click-Caption $window CaptionMaximize
        Check ($window.WindowState -eq 'Maximized') "$folder maximize click works"
        Check ([Windows.Automation.AutomationProperties]::GetName($window.FindName('CaptionMaximize')) -eq 'Restore window') "$folder restore label updates"
        Click-Caption $window CaptionMaximize
        Check ($window.WindowState -eq 'Normal') "$folder restore click works"
        Click-Caption $window CaptionMinimize
        Check ($window.WindowState -eq 'Minimized' -and $window.IsLoaded) "$folder minimize keeps the window loaded"
        $window.WindowState='Normal'
        # Verify routed caption Close reaches the host Closing guard.
        $window.Tag=@{Guard=$true;ClosingSeen=$false;ClosedSeen=$false}
        $window.Add_Closing({param($sender,$event) $sender.Tag.ClosingSeen=$true;if($sender.Tag.Guard){$event.Cancel=$true}})
        $window.Add_Closed({param($sender,$event) $sender.Tag.ClosedSeen=$true})
        Click-Caption $window CaptionClose
        Check ($window.Tag.ClosingSeen -and -not $window.Tag.ClosedSeen) "$folder Close respects a cancellation guard"
        $window.Tag.Guard=$false;Click-Caption $window CaptionClose
        Check $window.Tag.ClosedSeen "$folder Close exits when permitted"
    } finally {
        if($null -ne $window -and $window.IsLoaded) {if($null -ne $window.Tag){$window.Tag.Guard=$false};$window.Close()}
        if ($folder -eq 'Builder' -and $null -ne $box) { $box.Dispose() }
    }
}
Write-Output "PASS: $count Windows WPF smoke assertions. Manual DPI, keyboard, screen-reader and live SYSTEM/device pilots still required."
