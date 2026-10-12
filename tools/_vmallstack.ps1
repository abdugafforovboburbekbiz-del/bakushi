param([Parameter(Mandatory=$true)][string]$Uri)
$ErrorActionPreference = "Stop"
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$Uri, $ct).GetAwaiter().GetResult() | Out-Null
function Send-Json([string]$json) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $seg = New-Object "System.ArraySegment[byte]" -ArgumentList @(,$bytes)
  $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
}
function Recv-All() {
  $out = New-Object System.Text.StringBuilder
  do {
    $buf = New-Object byte[] 262144
    $res = $ws.ReceiveAsync((New-Object "System.ArraySegment[byte]" -ArgumentList @(,$buf)), $ct).GetAwaiter().GetResult()
    [void]$out.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
  } while (-not $res.EndOfMessage)
  return $out.ToString()
}
Send-Json '{"jsonrpc":"2.0","id":"1","method":"getVM","params":{}}'
$vm = (Recv-All | ConvertFrom-Json).result
Write-Output ("isolate count: {0}" -f @($vm.isolates).Count)
foreach ($iso in @($vm.isolates)) {
  $pause = if ($iso.pauseEvent.kind) { $iso.pauseEvent.kind } else { "run" }
  Write-Output ("ISOLATE {0}  name={1}  pause={2}" -f $iso.id, $iso.name, $pause)
  Send-Json ('{"jsonrpc":"2.0","id":"2","method":"getStack","params":{"isolateId":"' + $iso.id + '"}}')
  $stk = (Recv-All | ConvertFrom-Json).result
  $i = 0
  foreach ($f in @($stk.frames)) {
    $fn = $f.function.name
    if ($f.function.dartOwner) { $fn = $f.function.dartOwner.name + "." + $fn }
    $loc = ""
    if ($f.location) { $loc = " @ " + $f.location.script.uri + ":" + $f.location.tokenPos }
    Write-Output ("    #{0} {1}{2}" -f $i, $fn, $loc)
    $i++
    if ($i -ge 12) { break }
  }
}
$ws.Dispose()
