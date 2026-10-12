param(
  [Parameter(Mandatory=$true)][string]$Uri,
  [string]$StackIsolateId = ""
)
$ErrorActionPreference = "Stop"
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$Uri, $ct).GetAwaiter().GetResult()
function Send-Json([string]$json) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $seg = New-Object "System.ArraySegment[byte]" -ArgumentList @(,$bytes)
  $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult()
}
function Recv-All() {
  $out = New-Object System.Text.StringBuilder
  do {
    $buf = New-Object byte[] 131072
    $res = $ws.ReceiveAsync((New-Object "System.ArraySegment[byte]" -ArgumentList @(,$buf)), $ct).GetAwaiter().GetResult()
    [void]$out.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
  } while (-not $res.EndOfMessage)
  return $out.ToString()
}
Send-Json '{"jsonrpc":"2.0","id":"1","method":"getVM","params":{}}'
$vm = (Recv-All | ConvertFrom-Json).result
Write-Output ("PID: {0} isolates:" -f $vm.pid)
foreach ($iso in $vm.isolates) {
  $pause = if ($iso.pauseEvent.kind) { $iso.pauseEvent.kind } else { "none" }
  Write-Output ("  {0}  name={1}  pauseEvent={2}" -f $iso.id, $iso.name, $pause)
}
if ($StackIsolateId -eq "") {
  foreach ($iso in $vm.isolates) {
    if ($iso.name -like "*main*" -or $iso.name -eq "main") { $StackIsolateId = $iso.id; break }
  }
}
if ($StackIsolateId -eq "") { Write-Output "NO-MAIN-ISOLATE"; exit 0 }
Send-Json ('{"jsonrpc":"2.0","id":"2","method":"getStack","params":{"isolateId":"' + $StackIsolateId + '"}}')
$stk = (Recv-All | ConvertFrom-Json).result
Write-Output ("stack for isolate {0}:" -f $StackIsolateId)
$i = 0
foreach ($f in $stk.frames) {
  $fn = $f.function.name
  if ($f.function.dartOwner) { $fn = $f.function.dartOwner.name + "." + $fn }
  $loc = ""
  if ($f.location) { $loc = "  @ " + $f.location.script.uri + ":" + $f.location.tokenPos }
  Write-Output ("  #{0} {1}{2}" -f $i, $fn, $loc)
  $i++
  if ($i -ge 40) { break }
}
$ws.Dispose()
