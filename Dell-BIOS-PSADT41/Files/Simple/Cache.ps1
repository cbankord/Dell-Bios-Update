# MedelaBIOS-FileVersion: 4.0.0
# The trusted Intune package is the source of truth. Tattoos identify versions;
# SHA256 detects drift. Neither is an Authenticode signature or trust bootstrap.
function Get-MedelaRoot { Join-Path $env:ProgramData 'Medela\DellBIOS' }
function Assert-NoCacheLinks([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not allowed in deployment paths.' }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }; $current=$parent
    }
}
function Assert-MedelaOwnedPath([string]$Path) {
    $trim=[char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $root=[IO.Path]::GetFullPath((Get-MedelaRoot)).TrimEnd($trim)
    $target=[IO.Path]::GetFullPath($Path).TrimEnd($trim)
    if (-not $target.Equals($root,[StringComparison]::OrdinalIgnoreCase) -and
        -not $target.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Permission changes are restricted to the DellBIOS folder and its contents. The shared Medela folder and sibling applications are not managed by this package.'
    }
}
function New-MedelaDirectoryAcl([bool]$UserReadable=$false) {
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $system=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($system)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    if ($UserReadable) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))) }
    return $acl
}
function New-MedelaCacheDirectory([string]$Path,$Acl) {
    Assert-MedelaOwnedPath $Path
    Assert-NoCacheLinks $Path
    # This Windows PowerShell/.NET Framework overload applies the protected ACL
    # at creation, rather than briefly inheriting the shared parent's grants.
    # Require the immediate parent so this call cannot create/ACL shared ancestors.
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Path)) -PathType Container)) { throw 'The cache directory parent must already exist.' }
    $null=[IO.Directory]::CreateDirectory($Path,$Acl)
}
function Set-MedelaOwnedAcl([string]$Path,$Acl) {
    Assert-MedelaOwnedPath $Path
    Assert-NoCacheLinks $Path
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-MedelaInheritedAcl([string]$Path,[bool]$IsDirectory) {
    Assert-MedelaOwnedPath $Path
    $child=if ($IsDirectory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $child.SetAccessRuleProtection($false,$false)
    $child.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
    Set-MedelaOwnedAcl $Path $child
}
function Protect-MedelaDirectory([string]$Path, [bool]$UserReadable=$false) {
    Assert-MedelaOwnedPath $Path
    Assert-NoCacheLinks $Path
    $acl=New-MedelaDirectoryAcl $UserReadable
    New-MedelaCacheDirectory $Path $acl
    Set-MedelaOwnedAcl $Path $acl
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        Set-MedelaInheritedAcl $item.FullName $item.PSIsContainer
    }
}
function Assert-MedelaSharedParent([string]$Path) {
    # Read only. Other applications own the shared folder's ACL. Child-only
    # grants do not apply here, and the DellBIOS child disables inheritance.
    $acl=Get-Acl -LiteralPath $Path
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18','S-1-5-32-544')) {
        throw "Shared Medela folder owner is $owner. Its permissions were left unchanged. SYSTEM code requires a location whose parent owner cannot replace its security; review another protected cache location with IT."
    }
    if ($acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) -match 'NO_ACCESS_CONTROL') {
        throw 'Shared Medela folder has an unrestricted DACL. Its permissions were left unchanged. This location cannot safely host the SYSTEM cache; review another protected location with IT.'
    }
    $replacementRights=[long][Security.AccessControl.FileSystemRights]'Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    $replacementRights=$replacementRights -bor 0x10000000 # Unmapped GENERIC_ALL.
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -or
            $rule.IdentityReference.Value -in @('S-1-5-18','S-1-5-32-544')) { continue }
        # CreateFiles/CreateDirectories/WriteAttributes alone do not authorize
        # replacing a protected child. Delete/WRITE_DAC/WRITE_OWNER do.
        if ([long]$rule.FileSystemRights -band $replacementRights) {
            throw ('Shared Medela folder grants replacement-related access to {0}: {1} (scope: this folder). Its permissions were left unchanged. The DellBIOS child ACL cannot remove this parent grant; review another protected cache location with IT.' -f $rule.IdentityReference.Value,$rule.FileSystemRights)
        }
    }
}
function Initialize-MedelaCache([string]$Root) {
    # Do not change the ACL of Medela itself or unrelated applications under it.
    Assert-MedelaOwnedPath $Root
    if ([IO.Path]::GetFullPath($Root).TrimEnd('\','/') -ine [IO.Path]::GetFullPath((Get-MedelaRoot)).TrimEnd('\','/')) { throw 'Initialize the configured DellBIOS root only.' }
    Assert-NoCacheLinks $Root
    $parent=[IO.Path]::GetDirectoryName($Root)
    # If missing, create the shared folder using normal inherited permissions.
    # Never call a hardening helper on it, even on a first installation.
    if (-not (Test-Path -LiteralPath $parent)) { $null=[IO.Directory]::CreateDirectory($parent) }
    Assert-NoCacheLinks $parent
    Assert-MedelaSharedParent $parent
    # Root contains only app-owned child folders; protected children have their
    # own ACL. Never recursively reset the private directories from this parent.
    $acl=New-MedelaDirectoryAcl $true
    New-MedelaCacheDirectory $Root $acl
    Set-MedelaOwnedAcl $Root $acl
    foreach ($name in @('Runtime','State','Recovery')) { Protect-MedelaDirectory (Join-Path $Root $name) }
    Protect-MedelaDirectory (Join-Path $Root 'UI') $true
}
function Get-FileTattoo([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $first=Get-Content -LiteralPath $Path -TotalCount 1
    if ($first -match '^(?:#|<!--) MedelaBIOS-FileVersion: (\d+\.\d+\.\d+(?:\.\d+)?)(?: -->)?$') { return [version]$Matches[1] }
    return $null
}
function Get-ManagedFileMap([string]$Files) {
    $map=[ordered]@{}
    foreach ($file in @('Common.ps1','Install-DellBIOS.ps1','Verify-AfterReboot.ps1')) { $map[$file]='Runtime/'+$file }
    foreach ($file in @('Cache.ps1','Deployment.ps1','Live.ps1','State.ps1','Safety.ps1','Scheduling.ps1','Policy.psd1')) { $map['Simple/'+$file]='Runtime/'+$file }
    foreach ($file in @('Show-BiosUI.ps1','Window.xaml','WindowChrome.ps1','Theme.xaml','Branding.psd1')) { $map['UI/'+$file]='UI/'+$file }
    $brand=Import-PowerShellDataFile (Join-Path $Files 'UI/Branding.psd1')
    foreach ($name in @('LogoFile','BannerFile')) {
        if ($brand[$name]) {
            $path=$brand[$name].Replace('\','/')
            if ($path -notmatch '^Assets/[A-Za-z0-9_-]+\.(png|jpg|jpeg)$') { throw 'Brand image must be a PNG/JPG filename inside UI/Assets.' }
            $map['UI/'+$path]='UI/'+$path
        }
    }
    if ($brand.ContainsKey('IconFile') -and $brand.IconFile) {
        $icon=$brand.IconFile.Replace('\','/')
        if ($icon -notmatch '^Assets/[A-Za-z0-9_-]+\.(png|ico)$') { throw 'Title-bar icon must be a local PNG/ICO asset.' }
        $map['UI/'+$icon]='UI/'+$icon
    }
    return $map
}
function New-RuntimeManifest([string]$Files) {
    $map=Get-ManagedFileMap $Files
    $filesList=@(foreach ($source in $map.Keys) {
        $path=Join-Path $Files $source
        Assert-NoCacheLinks $path
        $isText=[IO.Path]::GetExtension($path) -in @('.ps1','.psd1','.xaml')
        $version=if ($isText) { Get-FileTattoo $path } else { Get-FileTattoo (Join-Path $Files 'UI/Branding.psd1') }
        if ($null -eq $version) { throw "Missing file version tattoo: $source" }
        @{ Source=$source; Destination=$map[$source]; Version=$version.ToString(); SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    })
    @{Schema=1; Files=$filesList}
}
function Write-RuntimeManifest([string]$Files) {
    $manifest=New-RuntimeManifest $Files
    [IO.File]::WriteAllText((Join-Path $Files 'RuntimeManifest.json'),($manifest|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}
function Read-ApprovedRuntimeManifest([string]$Files) {
    # Rebuild the allowlist independently: manifests cannot inject paths or copy
    # BIOS passwords/configuration into the user-readable tree.
    $expected=New-RuntimeManifest $Files
    $supplied=Get-Content -LiteralPath (Join-Path $Files 'RuntimeManifest.json') -Raw | ConvertFrom-Json
    if ($supplied.Schema -ne 1 -or @($supplied.Files).Count -ne $expected.Files.Count) { throw 'Invalid runtime manifest.' }
    foreach ($file in $expected.Files) {
        $entry=@($supplied.Files | Where-Object Source -eq $file.Source)
        if ($entry.Count -ne 1 -or $entry[0].Destination -cne $file.Destination -or $entry[0].Version -ne $file.Version -or $entry[0].SHA256 -ne $file.SHA256) { throw "Package integrity mismatch: $($file.Source). Rebuild the manifest after approved edits/signing." }
    }
    return $expected
}
function Get-CacheUpdatePlan([string]$Files, [string]$Root) {
    $expected=Read-ApprovedRuntimeManifest $Files
    $installedPath=Join-Path $Root 'State/InstalledFiles.json'
    $installed=if (Test-Path -LiteralPath $installedPath) { Get-Content -LiteralPath $installedPath -Raw | ConvertFrom-Json } else { $null }
    $plan=@(foreach ($file in $expected.Files) {
        $destination=Join-Path $Root $file.Destination
        Assert-NoCacheLinks $destination
        $reason='Missing'; $current=$null
        if (Test-Path -LiteralPath $destination) {
            $current=Get-FileTattoo $destination
            if ([IO.Path]::GetExtension($destination) -in @('.png','.jpg','.jpeg','.ico') -and $null -ne $installed) {
                $record=@($installed.Files | Where-Object Destination -eq $file.Destination)
                if ($record.Count -eq 1) { $current=[version]$record[0].Version }
            }
            if ($null -ne $current -and $current -gt [version]$file.Version) { throw "Newer cached file found: $($file.Destination). Deploy the newer package; automatic downgrade is blocked." }
            $reason=if ($null -eq $current) {'Unversioned'} elseif ($current -lt [version]$file.Version) {'OlderVersion'} elseif ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $file.SHA256) {'HashMismatch'} else {'Current'}
        }
        @{Source=$file.Source; Destination=$file.Destination; Version=$file.Version; SHA256=$file.SHA256; Reason=$reason}
    })
    return ,$plan
}
function Update-MedelaCache([string]$Files, [string]$Root, $Plan, [scriptblock]$Log={param($Message)}) {
    # Caller holds package + firmware locks and has rejected pending firmware.
    # Stage/validate all needed bytes before replacing any live file. The marker
    # is committed last. No cached code executes after a failed partial refresh;
    # the next invocation repairs it from the trusted package.
    $staging=Join-Path $Root ('State/Incoming-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($staging)
    try {
        foreach ($file in $Plan | Where-Object Reason -ne 'Current') {
            $temp=Join-Path $staging $file.Destination
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($temp))
            Copy-Item -LiteralPath (Join-Path $Files $file.Source) -Destination $temp
            if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $file.SHA256) { throw 'Staged runtime integrity failure.' }
        }
        foreach ($file in $Plan | Where-Object Reason -ne 'Current') {
            $destination=Join-Path $Root $file.Destination
            Assert-NoCacheLinks $destination
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            # A temp file in the destination directory inherits its correct ACL.
            $temp=$destination+'.new'
            Copy-Item -LiteralPath (Join-Path $staging $file.Destination) -Destination $temp -Force
            if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temp,$destination,[NullString]::Value) }
            else { [IO.File]::Move($temp,$destination) }
            & $Log ('Cache refreshed: {0}; version={1}; reason={2}' -f $file.Destination,$file.Version,$file.Reason)
        }
        foreach ($file in $Plan) {
            if ((Get-FileHash -LiteralPath (Join-Path $Root $file.Destination) -Algorithm SHA256).Hash -ne $file.SHA256) { throw 'Installed runtime verification failed.' }
        }
        $marker=Join-Path $Root 'State/InstalledFiles.json'
        [IO.File]::WriteAllText(($marker+'.new'),(@{Schema=1; Files=@($Plan)}|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $marker) { [IO.File]::Replace(($marker+'.new'),$marker,[NullString]::Value) } else { [IO.File]::Move(($marker+'.new'),$marker) }
    } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
}
