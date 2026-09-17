# Rebuild the inert parameter-set fixture from reviewed upstream source files.
# Each version folder contains the two official public function source files.
# Parse only: never dot-source or execute the supplied framework.
param([Parameter(Mandatory=$true)][string]$SourceDirectory,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$contracts=[ordered]@{}
$releases=@(foreach($folder in Get-ChildItem -LiteralPath $SourceDirectory -Directory | Sort-Object Name) {
    if($folder.Name -notmatch '^4\.1\.\d+$'){continue}
    $commands=@(foreach($name in @('Start-ADTProcess','Start-ADTProcessAsUser')) {
        $path=Join-Path $folder.FullName ($name+'.ps1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Upstream source did not parse.'}
        $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($functions.Count -ne 1){throw 'Expected one upstream public function.'}
        $block=$functions[0].Body.ParamBlock
        $binding=$block.Attributes | Where-Object {$_.TypeName.FullName -eq 'CmdletBinding'}
        $default=($binding.NamedArguments | Where-Object ArgumentName -eq 'DefaultParameterSetName').Argument.SafeGetValue()
        $parameters=@(foreach($parameter in $block.Parameters) {
            $type=$parameter.Attributes | Where-Object {$_ -is [Management.Automation.Language.TypeConstraintAst]} | Select-Object -Last 1
            $sets=@(foreach($attribute in $parameter.Attributes | Where-Object {$_.TypeName.FullName -eq 'Parameter'}) {
                $set='__AllParameterSets';$mandatory=$false
                foreach($argument in $attribute.NamedArguments) {
                    if($argument.ArgumentName -eq 'ParameterSetName'){$set=$argument.Argument.SafeGetValue()}
                    if($argument.ArgumentName -eq 'Mandatory'){$mandatory=[bool]$argument.Argument.SafeGetValue()}
                }
                [ordered]@{Name=$set;Mandatory=$mandatory}
            })
            [ordered]@{
                Name=$parameter.Name.VariablePath.UserPath;Type=$type.TypeName.FullName
                RequiredIn=@($sets | Where-Object Mandatory | ForEach-Object {$_.Name})
                OptionalIn=@($sets | Where-Object {-not $_.Mandatory} | ForEach-Object {$_.Name})
            }
        })
        $contract=[ordered]@{DefaultParameterSet=$default;Parameters=$parameters}
        $hash=[Security.Cryptography.SHA256]::Create()
        try {$id=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($contract|ConvertTo-Json -Depth 10 -Compress))))).Replace('-','').ToLowerInvariant()}
        finally {$hash.Dispose()}
        if(-not $contracts.Contains($id)){$contracts[$id]=$contract}
        [ordered]@{
            Name=$name
            Source=('https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/blob/'+$folder.Name+'/src/PSAppDeployToolkit/Public/'+$name+'.ps1')
            Contract=$id
        }
    })
    [ordered]@{Version=$folder.Name;Commands=$commands}
})
if(-not $releases.Count){throw 'No reviewed 4.1 release source folders found.'}
$data=[ordered]@{Schema=1;Description='Upstream PSADT 4.1 public parameter metadata only. Identical contracts share a hash. No function bodies, defaults, validators or Windows code are executed.';Contracts=$contracts;Releases=$releases}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($data|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Write-Output ('Exported '+$releases.Count+' reviewed release contracts.')
