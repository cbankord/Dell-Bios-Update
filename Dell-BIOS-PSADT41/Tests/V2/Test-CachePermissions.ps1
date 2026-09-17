# Actual shared-parent guard and cache initialization with real inert directories.
# Windows ACL objects/native writes are modeled; this is not an NTFS access test.
$ErrorActionPreference='Stop'; Set-StrictMode -Version 3
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Files/Simple/Cache.ps1"
$count=0
function Check($Value,$Name) { $script:count++; if (-not $Value) { throw "FAIL: $Name" } }
function Reject([scriptblock]$Body,$Name) {
    $message=''; try { &$Body } catch { $message=$_.Exception.Message }
    Check (-not [string]::IsNullOrEmpty($message)) $Name
    return $message
}
function New-TestAcl([string]$Owner='S-1-5-18') {
    $acl=[pscustomobject]@{Owner=$Owner;Protected=$false;Sddl='D:';Rules=[Collections.Generic.List[object]]::new()}
    $acl | Add-Member ScriptMethod GetOwner {param($Type) [pscustomobject]@{Value=$this.Owner}}
    $acl | Add-Member ScriptMethod GetAccessRules {param($Explicit,$Inherited,$Type) $this.Rules.ToArray()}
    $acl | Add-Member ScriptMethod GetSecurityDescriptorSddlForm {param($Sections) $this.Sddl}
    $acl | Add-Member ScriptMethod SetOwner {param($Identity) $this.Owner=$Identity.Value}
    $acl | Add-Member ScriptMethod SetAccessRuleProtection {param($Protected,$Preserve) $this.Protected=$Protected}
    $acl | Add-Member ScriptMethod AddAccessRule {param($Rule) $this.Rules.Add($Rule)}
    return $acl
}
function New-TestRule([string]$Sid='S-1-5-32-545',$Rights='ReadAndExecute',
    [Security.AccessControl.PropagationFlags]$Propagation='None',[string]$Type='Allow') {
    $mask=if ($Rights -is [string]) { [Enum]::Parse([Security.AccessControl.FileSystemRights],$Rights) } else { [Enum]::ToObject([Security.AccessControl.FileSystemRights],[int]$Rights) }
    [pscustomobject]@{IdentityReference=[pscustomobject]@{Value=$Sid};FileSystemRights=$mask;PropagationFlags=$Propagation;AccessControlType=$Type;InheritanceFlags='ContainerInherit,ObjectInherit'}
}
# Model only Windows security constructors; execute the real ACL construction,
# directory traversal, path boundary and parent grant selection code.
function New-Object {
    param([string]$TypeName,[object[]]$ArgumentList)
    switch ($TypeName) {
        'Security.AccessControl.DirectorySecurity' { New-TestAcl }
        'Security.AccessControl.FileSecurity' { New-TestAcl }
        'Security.Principal.SecurityIdentifier' { [pscustomobject]@{Value=[string]$ArgumentList[0]} }
        'Security.AccessControl.FileSystemAccessRule' {
            New-TestRule $ArgumentList[0].Value $ArgumentList[1] $ArgumentList[3] $ArgumentList[4]
        }
        default { Microsoft.PowerShell.Utility\New-Object @PSBoundParameters }
    }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MedelaPermissions-'+[guid]::NewGuid())
$parent=Join-Path $temp 'Medela'; $script:cacheRoot=Join-Path $parent 'DellBIOS'
function Get-MedelaRoot { $script:cacheRoot }
$script:acls=@{}; $script:writes=[Collections.Generic.List[string]]::new()
$script:creates=[Collections.Generic.List[object]]::new()
function Get-Acl { param($LiteralPath) if (-not $script:acls.ContainsKey($LiteralPath)) { throw 'Missing test ACL' }; $script:acls[$LiteralPath] }
function Set-Acl { param($LiteralPath,$AclObject) $script:writes.Add($LiteralPath); $script:acls[$LiteralPath]=$AclObject }
$nativeCreate=${function:New-MedelaCacheDirectory}
function New-MedelaCacheDirectory {
    param($Path,$Acl)
    # Simulate Directory.CreateDirectory(path, security) only. Scope is also
    # tested directly against the unmodified native wrapper below.
    $script:creates.Add([pscustomobject]@{Path=$Path;Acl=$Acl})
    $null=[IO.Directory]::CreateDirectory($Path)
}
try {
    $sibling=Join-Path $parent 'OtherApplication'
    $null=[IO.Directory]::CreateDirectory($sibling)
    $siblingFile=Join-Path $sibling 'settings.txt'
    [IO.File]::WriteAllText($siblingFile,'retain other application content')
    $siblingHash=(Get-FileHash $siblingFile).Hash
    $shared=New-TestAcl
    $shared.Rules.Add((New-TestRule -Rights Write))
    $shared.Rules.Add((New-TestRule -Sid 'S-1-1-0' -Rights FullControl -Propagation InheritOnly))
    $script:acls[$parent]=$shared
    $script:acls[$sibling]=New-TestAcl 'S-1-5-21-1-2-3-1001'
    $script:acls[$sibling].Rules.Add((New-TestRule -Rights Modify))
    $parentBefore=$shared|ConvertTo-Json -Depth 5
    $siblingBefore=$script:acls[$sibling]|ConvertTo-Json -Depth 5
    Initialize-MedelaCache $script:cacheRoot
    Check (($shared|ConvertTo-Json -Depth 5) -ceq $parentBefore) 'Shared parent ownership and permission entries are untouched'
    Check (($script:acls[$sibling]|ConvertTo-Json -Depth 5) -ceq $siblingBefore -and (Get-FileHash $siblingFile).Hash -eq $siblingHash) 'Sibling permissions and bytes are untouched'
    Check ($script:writes.Count -eq 5 -and -not $script:writes.Contains($parent) -and -not $script:writes.Contains($sibling)) 'Only DellBIOS and its four owned folders receive ACL writes'
    Check ($script:creates.Count -eq 5 -and @($script:creates|Where-Object {-not $_.Acl.Protected}).Count -eq 0) 'New owned directories receive protected ACLs at creation'
    foreach ($name in @('Runtime','State','Recovery','UI')) {
        $acl=$script:acls[(Join-Path $script:cacheRoot $name)]
        $users=@($acl.Rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'})
        $expected=if ($name -eq 'UI') {$users.Count -eq 1 -and $users[0].FileSystemRights -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute} else {$users.Count -eq 0}
        Check ($expected -and $acl.Protected -and $acl.Owner -eq 'S-1-5-18') "Actual $name ACL construction has the intended user boundary"
    }
    # A second initialization resets only descendants of owned folders.
    $ownedFile=Join-Path $script:cacheRoot 'Runtime/old.ps1'
    [IO.File]::WriteAllText($ownedFile,'inert cached script')
    $script:writes.Clear()
    Initialize-MedelaCache $script:cacheRoot
    Check ($script:writes.Contains($ownedFile) -and @($script:writes|Where-Object {-not $_.StartsWith($script:cacheRoot)}).Count -eq 0) 'Recursive child ACL maintenance remains inside DellBIOS'
    Check (($shared|ConvertTo-Json -Depth 5) -ceq $parentBefore -and ($script:acls[$sibling]|ConvertTo-Json -Depth 5) -ceq $siblingBefore) 'Repeated initialization preserves shared and sibling ACLs'

    foreach ($rights in @('ReadAndExecute','CreateFiles','CreateDirectories','WriteAttributes','WriteExtendedAttributes','Write')) {
        $shared.Rules.Clear(); $shared.Rules.Add((New-TestRule -Rights $rights))
        Assert-MedelaSharedParent $parent
        Check $true "Nonreplacement parent grant accepted: $rights"
    }
    foreach ($flags in @('InheritOnly','InheritOnly,NoPropagateInherit')) {
        $shared.Rules.Clear(); $shared.Rules.Add((New-TestRule -Rights FullControl -Propagation $flags))
        Assert-MedelaSharedParent $parent
        Check $true "Child-only full-control grant accepted: $flags"
    }
    $shared.Rules.Clear(); $shared.Rules.Add((New-TestRule -Rights FullControl -Type Deny))
    Assert-MedelaSharedParent $parent
    Check $true 'Deny entries are not mistaken for parent grants'
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $shared.Owner=$sid; $shared.Rules.Clear(); $shared.Rules.Add((New-TestRule -Sid $sid -Rights FullControl))
        Assert-MedelaSharedParent $parent
        Check $true "Trusted SYSTEM/Administrators owner and grants accepted: $sid"
    }
    foreach ($rights in @('Delete','DeleteSubdirectoriesAndFiles','ChangePermissions','TakeOwnership','Modify','FullControl',268435456)) {
        $shared.Rules.Clear(); $shared.Rules.Add((New-TestRule -Rights $rights))
        $script:writes.Clear(); $before=$shared|ConvertTo-Json -Depth 5
        $message=Reject {Initialize-MedelaCache $script:cacheRoot} "Parent replacement grant blocks cache initialization: $rights"
        Check ($message.Contains('S-1-5-32-545') -and $message.Contains('left unchanged') -and $script:writes.Count -eq 0 -and ($shared|ConvertTo-Json -Depth 5) -ceq $before) 'Unsafe parent diagnostic identifies trustee without modifying permissions'
    }
    $shared.Rules.Clear(); $shared.Owner='S-1-5-21-1-2-3-1001'
    $null=Reject {Initialize-MedelaCache $script:cacheRoot} 'Untrusted parent owner still blocks privileged caching'
    $shared.Owner='S-1-5-18'; $shared.Sddl='D:NO_ACCESS_CONTROL'
    $null=Reject {Initialize-MedelaCache $script:cacheRoot} 'Null/unrestricted parent DACL is rejected'
    $shared.Sddl='D:'
    foreach ($outside in @($parent,$sibling,($script:cacheRoot+'-other'),(Join-Path $script:cacheRoot '../OtherApplication'))) {
        $null=Reject {Set-MedelaOwnedAcl $outside (New-TestAcl)} 'ACL setter refuses shared, sibling, prefix and traversal paths'
        $null=Reject {&$nativeCreate $outside (New-TestAcl)} 'Native directory creation wrapper refuses paths outside DellBIOS'
        $null=Reject {Protect-MedelaDirectory $outside} 'Recursive permission helper refuses paths outside DellBIOS'
    }
    $null=Reject {Initialize-MedelaCache (Join-Path $script:cacheRoot 'Runtime')} 'Initializer refuses to reinterpret an owned subfolder as the cache root'
    Check ($script:writes.Count -eq 0) 'Rejected paths never reach the native ACL writer'

    # A missing shared parent is created with normal inherited permissions; it
    # must never pass through either cache permission helper.
    $newParent=Join-Path $temp 'Fresh/Medela'; $script:cacheRoot=Join-Path $newParent 'DellBIOS'
    $script:acls[$newParent]=New-TestAcl
    $script:acls[$newParent].Rules.Add((New-TestRule -Rights CreateDirectories))
    $script:writes.Clear(); $script:creates.Clear()
    Initialize-MedelaCache $script:cacheRoot
    Check ((Test-Path $newParent) -and -not $script:writes.Contains($newParent) -and @($script:creates|Where-Object Path -eq $newParent).Count -eq 0) 'Fresh shared parent is never explicitly hardened or assigned an owner'
    Write-Output "PASS: $count cache permission assertions. Actual guard/init/path logic; modeled Windows ACL boundary. NTFS/PS5.1 integration still requires a Windows pilot."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
