# Framed, bounded local IPC; shared by broker and unprivileged UI.
function Read-PipeBytes($Pipe, [int]$Count) {
    $buffer = New-Object byte[] $Count
    $offset = 0
    $deadline = [datetime]::UtcNow.AddSeconds(2)
    while ($offset -lt $Count) {
        $task = $Pipe.ReadAsync($buffer, $offset, $Count - $offset)
        $remaining = [int][Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
        if (-not $task.Wait($remaining) -or $task.Result -eq 0) { throw 'Local communication timed out.' }
        $offset += $task.Result
    }
    return ,$buffer
}
function Read-PipeMessage($Pipe) {
    $length = [BitConverter]::ToInt32((Read-PipeBytes $Pipe 4), 0)
    if ($length -lt 2 -or $length -gt 16384) { throw 'Invalid message size.' }
    [Text.Encoding]::UTF8.GetString((Read-PipeBytes $Pipe $length))
}
function Write-PipeMessage($Pipe, $Message) {
    $data = [Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Depth 5 -Compress))
    if ($data.Length -gt 16384) { throw 'Message too large.' }
    $header = [BitConverter]::GetBytes([int]$data.Length)
    if (-not $Pipe.WriteAsync($header, 0, 4).Wait(2000)) { throw 'Local communication timed out.' }
    if (-not $Pipe.WriteAsync($data, 0, $data.Length).Wait(2000)) { throw 'Local communication timed out.' }
}
function ConvertTo-PlainHashtable($Object) {
    $hash = @{}
    foreach ($property in $Object.PSObject.Properties) { $hash[$property.Name] = $property.Value }
    $hash
}

function ConvertFrom-SchedulerJson([string]$Json) {
    # PS 7.5+ can auto-convert date strings; keep the 5.1 wire/state string contract.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String -ErrorAction Stop
    }
    return ConvertFrom-Json -InputObject $Json -ErrorAction Stop
}
