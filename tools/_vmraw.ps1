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
Send-Json '{"jsonrpc":"2.0","id":"1","method":"getStack","params":{"isolateId":"isolates/460427110366023"}}'
$raw = Recv-All
if ($raw.Length -gt 4000) { $raw = $raw.Substring(0, 4000) }
Write-Output $raw
$ws.Dispose()
