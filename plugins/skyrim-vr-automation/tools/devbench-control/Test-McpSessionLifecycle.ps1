# SPDX-License-Identifier: GPL-3.0-or-later
# Actual production session DELETE against isolated loopback fixtures only.
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$passed=0;$cases=@()
function Check-Lifecycle([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'))
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e)
Check-Lifecycle (@($e).Count -eq 0) 'production entry parses'
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Close-McpSession'},$true))
Check-Lifecycle ($nodes.Count -eq 1) 'exact production session close selected'
Invoke-Expression $nodes[0].Extent.Text
$headers=@{'Mcp-Session-Id'='fixture-owned-session';Accept='application/json'}
foreach($code in @(204,404,500)){
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
 $listener.Start();$port=$listener.LocalEndpoint.Port
 $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
 $job=Start-ThreadJob -ArgumentList $listener,$events,$code -ScriptBlock {
  param($Listener,$Events,$Code)
  $client=$null
  try{
   $client=$Listener.AcceptTcpClient();$client.ReceiveTimeout=3000;$client.SendTimeout=3000
   $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream)
   $first=$reader.ReadLine();$observed=@{}
   while(($line=$reader.ReadLine()) -ne '') {
    if($null -eq $line){throw 'Truncated HTTP fixture request'}
    $pair=$line.Split(':',2);$observed[$pair[0]]=$pair[1].Trim()
   }
   $Events.Enqueue([pscustomobject]@{first=$first;session=$observed['Mcp-Session-Id']})
   $crlf=[string][char]13+[char]10
   $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Code Fixture"+$crlf+'Content-Length: 0'+$crlf+'Connection: close'+$crlf+$crlf)
   $stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  }finally{if($client){$client.Dispose()};$Listener.Stop()}
 }
 try{
  $reply=Close-McpSession -Endpoint "http://127.0.0.1:$port/mcp" -Headers $headers -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
  $seen=@($events.ToArray())
  Check-Lifecycle ($seen.Count -eq 1 -and $seen[0].first -ceq 'DELETE /mcp HTTP/1.1' -and $seen[0].session -ceq 'fixture-owned-session') "$code sends one exact original-session DELETE"
  Check-Lifecycle ($reply.attempted -and $reply.statusCode -eq $code -and $reply.timeoutMilliseconds -gt 0 -and $reply.timeoutMilliseconds -le 2000) "$code preserves bounded HTTP receipt"
  $expectedState=switch($code){204 {'closed'} 404 {'already_absent'} 500 {'cleanup_failed'}}
  Check-Lifecycle ($reply.state -ceq $expectedState -and $reply.ok -eq ($code -ne 500) -and $reply.indeterminate -eq ($code -eq 500)) "$code truthful cleanup classification"
  $cases+=@{statusCode=$code;receipt=$reply}
 }finally{$listener.Stop();Stop-Job -Job $job;Remove-Job -Job $job -Force}
}
$expired=Close-McpSession -Endpoint 'http://127.0.0.1:1/mcp' -Headers $headers -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
Check-Lifecycle (-not $expired.attempted -and -not $expired.ok -and $expired.indeterminate -and $expired.state -ceq 'not_attempted_deadline_exhausted') 'expired admission refuses before network dispatch'
$absent=Close-McpSession -Endpoint 'http://127.0.0.1:1/mcp' -Headers @{} -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Check-Lifecycle (-not $absent.attempted -and $absent.ok -and $absent.state -ceq 'not_opened') 'no owned session admits no network dispatch'
@{ok=$true;passed=$passed;realHttpUsed=$true;liveRuntimeUsed=$false;closed204=$true;alreadyAbsent404=$true;failed500=$true;expiredRefused=$true;cases=$cases}|ConvertTo-Json -Depth 10 -Compress

