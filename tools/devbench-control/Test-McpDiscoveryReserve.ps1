# SPDX-License-Identifier: GPL-3.0-or-later
# Source-retained discovery/cleanup/journal functions; POST and identity are
# synthetic deterministic boundaries. DELETE uses actual isolated loopback HTTP.
# Rebased fixture clock accelerates phase crossings; NOT a live20s timing claim.
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Source parse failed'}
foreach($name in @('Get-RequestTimeoutSeconds','Assert-OwnershipDiscoveryDeadline','Get-McpSessionHeaderValue','Invoke-McpRequest','Open-McpSession','Close-OwnedMcpSession','Close-AllMcpSessions','Close-McpSession','Write-TerminalInvocationEvidence')){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count-ne 1){throw "Ambiguous source boundary: $name"}
 . ([scriptblock]::Create($nodes[0].Extent.Text))
}
# Integrated contexts may use additional pure module predicates. Retain their
# exact definitions rather than dropping their guards or inventing fixtures.
$moduleText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DevBenchControl.psm1'))
$moduleAst=[Management.Automation.Language.Parser]::ParseInput($moduleText,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Module source parse failed'}
foreach($name in @('Test-DevBenchInitialMcpCapabilityMiss','Get-DevBenchMutationFailureDisposition')){
 if(-not $text.Contains($name)){continue}
 $nodes=@($moduleAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count-ne 1){throw "Ambiguous integrated module boundary: $name"}
 . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$start=$text.IndexOf('$operationDeadlineUtc = $operationStartedUtc.AddSeconds($TimeoutSeconds)')
$end=$text.IndexOf('$effectiveOperationTimeoutSeconds = $TimeoutSeconds',$start)
if($start-lt 0 -or $end-lt 0){throw 'Exact invocation deadline binding missing'}
$binding=[scriptblock]::Create($text.Substring($start,$end-$start))
$passed=0;$cases=@()
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw "FAIL: $Message"};$script:passed++}
function Invoke-FixturePhase([string]$Phase){
 $script:phaseCalls.Add($Phase)
 if($Phase-cne $script:boundary){return}
 $delay=switch($script:mode){'late-response'{1700}'close-expired'{3700}'total-expired'{4700}default{1}}
 Start-Sleep -Milliseconds $delay
 if($script:mode-ceq 'before-failure'){throw [TimeoutException]::new("Fixture $Phase failed before workflow cutoff")}
}
function Invoke-WebRequest {
 param([switch]$UseBasicParsing,$Method,$Uri,$Headers,$Body,$TimeoutSec)
 if($Method-cne 'Post' -or $Uri-cne $script:endpoint){throw 'Unexpected fixture request'}
 $payload=$Body|ConvertFrom-Json
 if($payload.method-ceq 'initialize'){
  $script:initializeCount++
  # Retain the exact production deadline derivation, with a synthetic clock
  # origin near the end of its20s budget rather than wasting17s per fixture.
  $script:operationStartedUtc=[DateTime]::UtcNow.AddSeconds(-15.5)
  . $script:binding
  foreach($variable in @('operationDeadlineUtc','totalInvocationDeadlineUtc','ownershipWorkflowDeadlineUtc','ownershipSessionCloseDeadlineUtc')){
   Set-Variable -Scope Script -Name $variable -Value (Get-Variable -Name $variable -ValueOnly)
  }
  $script:initialTotalDeadline=$script:totalInvocationDeadlineUtc
  return [pscustomobject]@{Headers=@{'Mcp-Session-Id'='original-fixture-session'};Content='{"jsonrpc":"2.0","result":{}}'}
 }
 if($Headers['Mcp-Session-Id']-cne 'original-fixture-session'){throw 'Wrong original session'}
 if($payload.method-ceq 'notifications/initialized'){Invoke-FixturePhase 'initialized';return [pscustomobject]@{Headers=@{};Content=''}}
 if($payload.method-ceq 'tools/list'){Invoke-FixturePhase 'tools-list';return [pscustomobject]@{Headers=@{};Content='{"jsonrpc":"2.0","result":{"tools":[]}}'}}
 throw 'Unexpected target dispatch/replay'
}
function Get-RuntimeIdentity {
 param($Runtime,$Headers,$Tools,[switch]$AllowDeferredBuildIdentity,[switch]$PropagateRetryable)
 Invoke-FixturePhase 'runtime-identity'
 return [pscustomobject]@{errors=@();complete=$true;verified=$true}
}
$Command='colour-baseline-window';$TimeoutSeconds=20;$RequestTimeoutSeconds=15
$SkipRuntimeIdentityVerification=$false;$MaxTransientRetries=4;$PollMilliseconds=50;$MaxPollMilliseconds=500
$script:requestTimeoutSecondsForRpc=15
foreach($boundary in @('initialized','tools-list','runtime-identity')){
 foreach($mode in @('healthy','before-failure','late-response','close-expired','total-expired')){
  $script:boundary=$boundary;$script:mode=$mode;$script:initializeCount=0
  $script:phaseCalls=[Collections.Generic.List[string]]::new()
  $ownedMcpSessions=[Collections.Generic.List[object]]::new()
  $transportRetries=[Collections.Generic.List[object]]::new()
  $operationStartedUtc=[DateTime]::UtcNow
  . $binding
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
  $endpoint="http://127.0.0.1:$($listener.LocalEndpoint.Port)/mcp"
  $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $job=Start-ThreadJob -ArgumentList $listener,$events -ScriptBlock{
   param($Listener,$Events)
   try{while($true){
    $client=$Listener.AcceptTcpClient()
    try{
     $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream)
     $first=$reader.ReadLine();$headers=@{}
     while(($line=$reader.ReadLine())-ne ''){if($null-eq $line){throw 'Truncated HTTP'};$pair=$line.Split(':',2);$headers[$pair[0]]=$pair[1].Trim()}
     $Events.Enqueue([pscustomobject]@{first=$first;session=$headers['Mcp-Session-Id'];utc=[DateTime]::UtcNow.ToString('o')})
     $crlf=[string][char]13+[char]10
     $bytes=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 204 No Content'+$crlf+'Content-Length: 0'+$crlf+'Connection: close'+$crlf+$crlf)
     $stream.Write($bytes,0,$bytes.Length);$stream.Flush()
    }finally{$client.Dispose()}
   }}catch{}finally{$Listener.Stop()}
  }
  try{
   $failure=$null;$session=$null
   try{$session=Open-McpSession -Runtime @{} }catch{$failure=$_.Exception.Message}
   $cleanup=Close-AllMcpSessions -DeadlineUtc $ownershipSessionCloseDeadlineUtc
   $before=@($events.ToArray())
   # Cached partial cleanup must be reused, never dispatched again.
   $again=Close-AllMcpSessions -DeadlineUtc $ownershipSessionCloseDeadlineUtc
   $delete=@($events.ToArray())
   $result=[pscustomobject]@{ok=($null-eq $failure);errors=@($failure);sessionCleanup=$cleanup;finalization=[pscustomobject]@{finalJournalAttempted=$false;finalJournalDisposition='not-attempted'}}
   $script:journalCount=0;$script:journalValue=$null
   $journalOk=Write-TerminalInvocationEvidence -Result $result -FailurePrefix 'fixture terminal' -WriteAction {$script:journalCount++;$script:journalValue=$result|ConvertTo-Json -Depth 40}
   Check ($initializeCount-eq 1 -and $ownedMcpSessions.Count-eq 1 -and $ownedMcpSessions[0].sessionId-ceq 'original-fixture-session') "$boundary/$mode one original issued session"
   Check (@($phaseCalls|Where-Object {$_-ceq $boundary}).Count-eq 1 -and $transportRetries.Count-eq 0) "$boundary/$mode no discovery retry"
   Check ($totalInvocationDeadlineUtc-eq $initialTotalDeadline -and $ownershipWorkflowDeadlineUtc-eq $totalInvocationDeadlineUtc.AddSeconds(-3) -and $ownershipSessionCloseDeadlineUtc-eq $totalInvocationDeadlineUtc.AddSeconds(-1)) "$boundary/$mode exact original reserve/no extension"
   Check ($before.Count-eq $delete.Count -and $delete.Count-le 1) "$boundary/$mode cached cleanup no second close"
   Check ($journalCount-le 1 -and $result.finalization.finalJournalAttempted-eq ($journalCount-eq 1)) "$boundary/$mode one truthful journal admission"
   if($mode-ceq 'healthy'){Check ($null-ne $session -and $null-eq $failure) "$boundary healthy session establishment"}else{
    Check ($null-eq $session -and -not [string]::IsNullOrWhiteSpace($failure)) "$boundary/$mode late/failed discovery not accepted"
    $partial=$cleanup.sessions[0].partialInitialization
    Check ($partial.phase-ceq $boundary -and -not $partial.replacementSessionOpened -and -not $partial.retryDispatched -and -not [string]::IsNullOrWhiteSpace($partial.error)) "$boundary/$mode partial phase/error retained"
    if($boundary-ceq 'tools-list' -and $mode-cne 'before-failure'){Check ($null-ne $partial.retainedResponse) "$mode late tools response retained"}
    if($boundary-ceq 'runtime-identity' -and $mode-cne 'before-failure'){Check ($null-ne $partial.runtimeIdentity -and $null-ne $partial.toolListResponse -and $null-ne $partial.initializeResponse) "$mode partial discovery observations retained"}
   }
   if($mode-in @('close-expired','total-expired')){
    Check ($delete.Count-eq 0 -and -not $cleanup.ok -and -not $cleanup.sessions[0].attempted -and $cleanup.sessions[0].state-ceq 'not_attempted_deadline_exhausted') "$boundary/$mode no DELETE admitted after T-1s"
   }else{
    Check ($delete.Count-eq 1 -and $delete[0].first.StartsWith('DELETE ') -and $delete[0].session-ceq 'original-fixture-session' -and $cleanup.ok) "$boundary/$mode real single exact original DELETE"
    Check ([DateTimeOffset]$cleanup.sessions[0].admittedUtc-lt [DateTimeOffset]$cleanup.sessions[0].deadlineUtc) "$boundary/$mode close admitted before cutoff"
   }
   if($mode-ceq 'total-expired'){Check ($journalCount-eq 0 -and -not $journalOk -and $result.finalization.finalJournalDisposition-ceq 'not-attempted-deadline-exhausted') "$boundary no journal after original T"}else{
    Check ($journalCount-eq 1 -and $journalOk -and $journalValue.Contains('sessionCleanup')) "$boundary/$mode retained cleanup in terminal journal"
   }
   $cases+=@{boundary=$boundary;mode=$mode;deleteCount=$delete.Count;journalCount=$journalCount;failure=$failure;cleanup=$cleanup;originalDeadlineUtc=$totalInvocationDeadlineUtc.ToString('o')}
  }finally{$listener.Stop();Stop-Job $job;Remove-Job $job -Force}
 }
}
@{ok=$true;passed=$passed;cases=$cases;sourceFunctionsRetained=$true;syntheticPostAndIdentity=$true;realLoopbackDelete=$true;fixtureClockRebased=$true;liveRuntimeUsed=$false;publicTwentySecondTimingClaimed=$false}|ConvertTo-Json -Depth 40 -Compress

