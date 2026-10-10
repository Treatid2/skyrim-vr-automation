# SPDX-License-Identifier: GPL-3.0-or-later
# Real copied public entry/HTTP exception/journal/cleanup; isolated test server.
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$passed=0;$cases=@()
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw "FAIL: $Name"};$script:passed++}
$root=Join-Path $FixtureRoot ('http-failure-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
$copied=Join-Path $root 'source';[IO.Directory]::CreateDirectory($copied)|Out-Null
foreach($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1'))){Copy-Item -LiteralPath $f.FullName -Destination $copied}
# Replace only answering identity observation in the copied fixture; transport,
# initialization, mutation disposition, owned DELETE and terminal writer are real.
$entry=Join-Path $copied 'Invoke-DevBenchControl.ps1';$text=[IO.File]::ReadAllText($entry);$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e);if($e.Count){throw 'Source parse failed.'}
$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-RuntimeIdentity'},$true));if($node.Count -ne 1){throw 'Ambiguous identity boundary.'}
$stub=@'
function Get-RuntimeIdentity {
 param($Runtime,$Headers,$Tools,[switch]$AllowDeferredBuildIdentity,[switch]$PropagateRetryable)
 [pscustomobject]@{errors=@();missing=@();complete=$true;verified=$true;listenerPid=0;build=[pscustomobject]@{buildId='synthetic-fixture'};process=[pscustomobject]@{startTimeUtc=[DateTime]::UtcNow.ToString('o')}}
}
'@
$text=$text.Remove($node[0].Extent.StartOffset,$node[0].Extent.EndOffset-$node[0].Extent.StartOffset).Insert($node[0].Extent.StartOffset,$stub)
$writerNode=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-JsonAtomic'},$true));if($writerNode.Count -ne 1){throw 'Ambiguous writer boundary.'}
$originalWriter=$writerNode[0].Extent.Text.Replace('function Write-JsonAtomic {','function Write-FixtureJsonAtomic {')
$writer=@'
function Write-JsonAtomic {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
 if((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.txt') -Raw).Trim() -ceq 'journal-failure' -and $Value.state -ceq 'failed'){throw 'Synthetic terminal journal failure after original HTTP refusal.'}
 Write-FixtureJsonAtomic -Path $Path -Value $Value
}
'@
$text=$text.Replace($writerNode[0].Extent.Text,$originalWriter+[Environment]::NewLine+$writer)
[IO.File]::WriteAllText($entry,$text,[Text.UTF8Encoding]::new($false))
foreach($case in @('initialize503','html502','empty500','large503','secret403','initialized503','mutation503','rest503','wait503','journal-failure')){
 $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$portProbe.Start();$port=$portProbe.LocalEndpoint.Port;$portProbe.Stop()
 $ready=[Threading.ManualResetEventSlim]::new($false);$events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
 $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/")
 $server=Start-ThreadJob -ArgumentList $case,$ready,$events,$listener -ScriptBlock {
  param($Case,$Ready,$Events,$Listener)
  try{
   $Listener.Start();$Ready.Set()
   while($Listener.IsListening){
    $c=$Listener.GetContext();$q=$c.Request;$r=$c.Response;$r.ContentType='application/json';$r.Headers.Add('MCP-Protocol-Version','2025-03-26');$r.Headers.Add('Retry-After','1');$r.Headers.Add('Set-Cookie','PRIVATE_FIXTURE_COOKIE');$r.Headers.Add('X-Private-Diagnostic','PRIVATE_FIXTURE_HEADER')
    if($q.HttpMethod -ceq 'DELETE'){$Events.Enqueue([pscustomobject]@{kind='delete';session=$q.Headers['Mcp-Session-Id']});$body='{}'}
    elseif($q.Url.AbsolutePath -ceq '/api/tools'){$Events.Enqueue([pscustomobject]@{kind='rest-list'});$r.StatusCode=503;$body='{"error":"Too many sessions"}'}
    else{
     $reader=[IO.StreamReader]::new($q.InputStream);try{$rpc=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
     $Events.Enqueue([pscustomobject]@{kind=$rpc.method;session=$q.Headers['Mcp-Session-Id']})
     if($rpc.method -ceq 'initialize' -and $Case -notin @('initialized503','mutation503')){
      $r.StatusCode=switch($Case){'html502'{502}'empty500'{500}'secret403'{403}'rest503'{404}default{503}}
      $body=switch($Case){'html502'{'<html>service temporarily unavailable</html>'}'empty500'{''}'large503'{('z'*20000)}'secret403'{'{"error":"bad credential","access_token":"PRIVATE_BODY_TOKEN"}'}default{'{"error":"Too many sessions"}'}}
      if($Case -ceq 'html502'){$r.ContentType='text/html'}
     }
     elseif($rpc.method -ceq 'initialize'){$r.Headers.Add('Mcp-Session-Id','original-fixture-session');$body=@{jsonrpc='2.0';id=$rpc.id;result=@{protocolVersion='2025-03-26'}}|ConvertTo-Json -Compress}
     elseif($rpc.method -ceq 'notifications/initialized'){
      if($Case -ceq 'initialized503'){$r.StatusCode=503;$body='{"error":"Too many sessions"}'}else{$r.StatusCode=204;$body=''}
     }
     elseif($rpc.method -ceq 'tools/list'){$body=@{jsonrpc='2.0';id=$rpc.id;result=@{tools=@(@{name='fixture.mutate';inputSchema=@{type='object';properties=@{}}})}}|ConvertTo-Json -Depth 10 -Compress}
     elseif($rpc.method -ceq 'tools/call'){$r.StatusCode=503;$body='{"error":"Too many sessions"}'}
     else{throw 'Unexpected test request.'}
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes($body);$r.ContentLength64=$bytes.Length;if($bytes.Length){$r.OutputStream.Write($bytes,0,$bytes.Length)};$r.Close()
   }
  }finally{$Listener.Close();$Ready.Set()}
 }
 try{
  if(-not $ready.Wait(5000) -or $server.State -eq 'Failed'){throw 'Isolated fixture server failed.'}
  $dir=Join-Path $root $case;[IO.Directory]::CreateDirectory($dir)|Out-Null;$runtime=Join-Path $dir 'runtime.json';[IO.File]::WriteAllText($runtime,(@{port=$port}|ConvertTo-Json))
  [IO.File]::WriteAllText((Join-Path $copied 'case.txt'),$case)
  $params=@{RuntimePath=$runtime;EvidenceDirectory=$dir;TimeoutSeconds=8;RequestTimeoutSeconds=2;MaxTransientRetries=0;Compact=$true;NoExit=$true}
  if($case -ceq 'mutation503'){$params.Command='call';$params.Tool='fixture.mutate';$params.ArgumentsJson='{"action":"start"}'}
  elseif($case -ceq 'wait503'){$params.Command='wait';$params.Condition='toolAvailable';$params.Tool='fixture.mutate';$params.TimeoutSeconds=2;$params.PollMilliseconds=50;$params.MaxPollMilliseconds=50}
  else{$params.Command='list'}
  $result=& $entry @params|ConvertFrom-Json -Depth 60
  $journal=Get-Content -LiteralPath $result.invocationEvidencePath -Raw|ConvertFrom-Json -Depth 60
  $observed=@($events.ToArray());$records=@($result.httpFailureEvidence.records)
  if($case -ceq 'journal-failure'){
   Check (-not $result.ok -and -not $result.evidenceJournalFinalized -and @($result.evidenceWarnings).Count -gt 0) 'journal failure retains primary refusal and explicit persistence warning'
   Check ($records.Count -eq 1 -and $records[0].statusCode -eq 503 -and $journal.state -ceq 'preparing') 'failed journal leaves original prepared file/result refusal evidence, no false finalized claim'
  }else{
   Check (-not $result.ok -and $result.evidenceJournalFinalized) "$case refusal and terminal evidence survive"
   Check ($records.Count -gt 0 -and $records.Count -le 8 -and ($result.httpFailureEvidence|ConvertTo-Json -Depth 30 -Compress) -ceq ($journal.httpFailureEvidence|ConvertTo-Json -Depth 30 -Compress)) "$case original evidence equal in result/journal"
  }
  $json=$result.httpFailureEvidence|ConvertTo-Json -Depth 30 -Compress
  Check ($json -notmatch 'PRIVATE_FIXTURE|PRIVATE_BODY_TOKEN') "$case secret headers/body not published"
  Check (@($records|Where-Object {$_.extraRequest}).Count -eq 0) "$case evidence capture sends no request"
  if($case -ceq 'wait503'){
   Check ($result.state -ceq 'timeout' -and -not $result.data.satisfied -and @($observed|Where-Object kind -ceq 'delete').Count -eq 0) 'wait retains unsatisfied timeout/no unknown cleanup'
   Check ($result.httpFailureEvidence.observedCount -gt 8 -and $records.Count -eq 8 -and $records[0].observation -eq 1 -and $records[7].observation -eq $result.httpFailureEvidence.observedCount -and $result.httpFailureEvidence.omittedRecords -eq ($result.httpFailureEvidence.observedCount-8)) 'wait first/latest bounded omission proof'
  }elseif($case -ceq 'rest503'){
   Check ($records.Count -eq 2 -and $records[0].statusCode -eq 404 -and $records[1].statusCode -eq 503 -and @($observed|Where-Object kind -ceq 'rest-list').Count -eq 1) 'initial allowed404 and terminal REST503 both retained'
  }elseif($case -ceq 'mutation503'){
   Check ($result.indeterminate -and $result.dispatchReached -and -not $result.acceptedDataRetained -and @($observed|Where-Object kind -ceq 'tools/call').Count -eq 1) 'mutation failed-first stays indeterminate/one dispatch'
  }else{Check (@($observed|Where-Object kind -ceq 'initialize').Count -eq 1) "$case no new initialization for evidence"}
  if($case -in @('initialized503','mutation503')){Check ($result.sessionCleanup.ok -and @($observed|Where-Object { $_.kind -ceq 'delete' -and $_.session -ceq 'original-fixture-session'}).Count -eq 1) "$case exactly original owned session closed"}
  else{Check ($result.sessionCleanup.state -ceq 'not_opened') "$case no invented session cleanup"}
  $last=$records[-1]
  if($case -ceq 'large503'){Check ($last.omitted -and $last.omissionReason -ceq 'body-byte-cap' -and $last.retainedBytes -eq 16384 -and $null -eq $last.bodyText -and $null -ne $last.sourceSha256) 'large bounded prefix/full source hash, no fabricated complete text'}
  elseif($case -ceq 'secret403'){Check ($last.omitted -and $last.omissionReason -ceq 'potential-secret-body-withheld' -and $last.retainedBytes -eq 0 -and $null -ne $last.sourceSha256) 'potential credential body withheld with hash'}
  elseif($case -ceq 'empty500'){Check ($last.retainedBytes -eq 0 -and ($last.omissionReason -ceq 'error-details-unavailable' -or $last.sourceBytes -eq 0)) 'empty/absent buffered body truthfully represented'}
  else{Check ($last.retainedBytes -gt 0 -and $null -ne $last.bodyText -and $last.bodyText -match 'Too many sessions|service temporarily unavailable') "$case useful original text retained"}
  if($last.retainedBytes -gt 0){$b=[Convert]::FromBase64String($last.bodyBase64);Check ($b.Length -eq $last.retainedBytes -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b)) -ceq $last.retainedSha256) "$case bounded bytes independently hash verified"}
  $cases+=@{case=$case;httpRequests=$observed.Count;refusals=$result.httpFailureEvidence.observedCount;state=$result.state;cleanup=$result.sessionCleanup.state}
 }finally{$listener.Stop();$listener.Close();Wait-Job $server -Timeout 5|Out-Null;if($server.State -eq 'Running'){Stop-Job $server};Remove-Job $server;$ready.Dispose()}
}
# Pure collector edge cases from exact production AST; no socket/replay.
foreach($name in @('Get-HttpFailureEvidenceSnapshot','Retain-HttpFailureEvidence')){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));. ([scriptblock]::Create($nodes[0].Extent.Text))}
$httpFailureEvidence=[ordered]@{observedCount=0;maxRetained=8;records=[Collections.Generic.List[object]]::new()};$invocationRecord=$null
foreach($body in @(('x'*70000),('é'*10000),'{broken json','')){
 $ex=[InvalidOperationException]::new('Synthetic refusal');$ex|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=503;ReasonPhrase='Service Unavailable';Headers=@{};Content=[pscustomobject]@{Headers=@{}}})
 $err=[Management.Automation.ErrorRecord]::new($ex,'synthetic',[Management.Automation.ErrorCategory]::InvalidOperation,$null);$err.ErrorDetails=[Management.Automation.ErrorDetails]::new($body)
 Retain-HttpFailureEvidence -Failure $err -Uri 'http://127.0.0.1:1/mcp?private-query' -Method Post
 $r=(Get-HttpFailureEvidenceSnapshot).records[-1]
 Check ($r.endpoint -notmatch 'private-query' -and -not $r.extraRequest) 'pure collector omits URI query/no request'
 if($body.Length -gt 65536){Check ($r.omissionReason -ceq 'source-character-cap-privacy-unverified' -and $null -eq $r.sourceBytes -and $null -eq $r.sourceSha256 -and $r.retainedBytes -eq 0) 'source cap leaves full byte/hash/privacy unknown'}
 elseif($body -like 'é*'){Check ($r.sourceBytes -eq 20000 -and $r.retainedBytes -eq 16384 -and $r.omitted) 'UTF8 multibyte exact byte cap'}
 else{Check ($r.sourceBytes -eq [Text.Encoding]::UTF8.GetByteCount($body) -and -not $r.omitted) 'nonJSON/empty buffer is evidence, never semantic success'}
}
# Unknown transport/non-HTTP failure cannot invent response/body evidence.
$before=(Get-HttpFailureEvidenceSnapshot).observedCount
$err=[Management.Automation.ErrorRecord]::new([TimeoutException]::new('Synthetic transport timeout'),'timeout',[Management.Automation.ErrorCategory]::OperationTimeout,$null)
Retain-HttpFailureEvidence -Failure $err -Uri 'http://127.0.0.1:1/mcp' -Method Post
Check ((Get-HttpFailureEvidenceSnapshot).observedCount -eq $before) 'response-less timeout does not fabricate HTTP refusal'
# Unsupported response metadata cannot replace the original refusal.
$ex=[InvalidOperationException]::new('Original503');$ex|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=503})
$err=[Management.Automation.ErrorRecord]::new($ex,'metadata',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
Retain-HttpFailureEvidence -Failure $err -Uri 'http://127.0.0.1:1/mcp' -Method Post
$r=(Get-HttpFailureEvidenceSnapshot).records[-1]
Check ($r.statusCode -eq 503 -and $r.omissionReason -ceq 'metadata-capture-failed' -and $ex.Message -ceq 'Original503') 'metadata collection failure retains status/omission and original failure'
[pscustomobject]@{ok=$true;checks=$passed;cases=$cases;scope='copied public HTTP entry/journal/original cleanup plus exact collector AST; identity observation synthetic; isolated loopback fixture only';runtimeCalls=0;liveQualified=$false}|ConvertTo-Json -Depth 8
