# MedelaBIOS-FileVersion: 4.0.0
# Shared presentation helpers only: never launch firmware, write state or restart.
function Read-BiosWindowIcon([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or
        [IO.Path]::GetExtension($Path) -notin @('.png','.ico')) { throw 'Choose a local PNG or ICO title-bar icon.' }
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw 'Title-bar icon must be a file no larger than 1 MB.' }
    $image=New-Object Windows.Media.Imaging.BitmapImage
    $image.BeginInit(); $image.CacheOption='OnLoad'; $image.UriSource=New-Object uri($item.FullName,[UriKind]::Absolute); $image.EndInit()
    if ($image.PixelWidth -gt 1024 -or $image.PixelHeight -gt 1024) { throw 'Title-bar icon dimensions must not exceed 1024 by 1024.' }
    $image.Freeze() # Release input file; never hold an icon open during packaging.
    return $image
}
function Get-BiosBrandIconPath([string]$Root,$Brand) {
    if (-not $Brand.ContainsKey('IconFile') -or -not $Brand.IconFile) { return '' }
    $relative=$Brand.IconFile.Replace('\','/')
    if ($relative -notmatch '^Assets/[A-Za-z0-9_-]+\.(png|ico)$') { throw 'Title-bar icon must be a local Assets PNG/ICO file.' }
    return Join-Path $Root $relative
}
function Invoke-BiosCaptionAction($Window,[ValidateSet('Minimize','Maximize','Close')][string]$Action) {
    switch ($Action) {
        Minimize { $Window.WindowState='Minimized' }
        Maximize { $Window.WindowState=if ($Window.WindowState -eq 'Maximized') {'Normal'} else {'Maximized'} }
        Close { $Window.Close() } # Always passes through the host's Closing guard.
    }
}
function Set-BiosWindowBounds($Window,$Area) {
    $width=[math]::Max(240,$Area.Width-24);$height=[math]::Max(240,$Area.Height-24)
    $Window.MinWidth=[math]::Min($Window.MinWidth,$width);$Window.MinHeight=[math]::Min($Window.MinHeight,$height)
    $Window.Width=[math]::Min($Window.Width,$width);$Window.Height=[math]::Min($Window.Height,$height)
}
function Initialize-BiosWindowChrome($Window,[string]$ThemePath,$Brand,[string]$IconPath='') {
    # Native WindowChrome caption/resize hit testing lives in the host XAML.
    # No transparency/DragMove emulation, global hooks or forced termination.
    [xml]$theme=Get-Content -LiteralPath $ThemePath -Raw
    $reader=New-Object Xml.XmlNodeReader $theme
    try { $resources=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $Window.Resources.MergedDictionaries.Add($resources)
    $converter=New-Object Windows.Media.BrushConverter
    foreach ($pair in @(@('AccentColor','AccentBrush'),@('BackgroundColor','BackgroundBrush'),@('SurfaceColor','SurfaceBrush'),@('TextColor','TextBrush'),@('MutedColor','MutedBrush'))) {
        $Window.Resources[$pair[1]]=$converter.ConvertFromString($Brand[$pair[0]])
    }
    if ([Windows.SystemParameters]::HighContrast) {
        foreach ($key in @('BackgroundBrush','SurfaceBrush')) {$Window.Resources[$key]=[Windows.SystemColors]::WindowBrush}
        foreach ($key in @('TextBrush','MutedBrush','BorderBrush','ErrorBrush')) {$Window.Resources[$key]=[Windows.SystemColors]::WindowTextBrush}
        $Window.Resources['AccentBrush']=[Windows.SystemColors]::HighlightBrush
        $Window.Resources['AccentTextBrush']=[Windows.SystemColors]::HighlightTextBrush
    }
    $Window.Icon=if ($IconPath) {Read-BiosWindowIcon $IconPath} else {$Window.FindResource('DefaultAppIcon')}
    foreach ($action in @('Minimize','Maximize','Close')) {
        $button=$Window.FindName('Caption'+$action)
        if ($null -eq $button) { throw 'Custom window caption is incomplete.' }
        $button.Tag=@{Window=$Window;Action=$action}
        $button.Add_Click({param($sender,$eventArgs) Invoke-BiosCaptionAction $sender.Tag.Window $sender.Tag.Action})
    }
    $Window.Add_StateChanged({param($sender,$eventArgs)
        $button=$sender.FindName('CaptionMaximize')
        $label=if ($sender.WindowState -eq 'Maximized') {'Restore window'} else {'Maximize window'}
        $button.Content=if ($sender.WindowState -eq 'Maximized') {[string][char]0x2750} else {[string][char]0x25A1}
        $button.ToolTip=$label
        [Windows.Automation.AutomationProperties]::SetName($button,$label)
    })
    Set-BiosWindowBounds $Window ([Windows.SystemParameters]::WorkArea)
}
