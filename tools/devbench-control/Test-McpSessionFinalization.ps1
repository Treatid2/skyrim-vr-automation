# SPDX-License-Identifier: GPL-3.0-or-later
# Real public controller/finalization plus actual fractional HTTP DELETE.
# Discovery and Calendar workflow are synthetic boundaries, not scientific proof.
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[ValidateSet('healthy','half-second','one-and-half','reserve-exhausted','expired','journal-delay','journal-exception','journal-overrun','journal-expired','journal-admission-expired')][string[]]$FixtureModes=@('healthy','half-second','one-and-half','reserve-exhausted','expired','journal-delay','journal-exception','journal-overrun','journal-expired','journal-admission-expired'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$passed=0;$cases=@()
function Check-Finalization([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++}
$root=Join-Path $FixtureRoot ('mcp-finalization-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
 $sourceRoot=Join-Path $root 'source';[IO.Directory]::CreateDirectory($sourceRoot)|Out-Null
 foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1'))){Copy-Item -LiteralPath $file.FullName -Destination $sourceRoot}
 $schemaRoot=Join-Path $sourceRoot 'fixtures';[IO.Directory]::CreateDirectory($schemaRoot)|Out-Null
 foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -File -Filter '*.json')){Copy-Item -LiteralPath $file.FullName -Destination $schemaRoot}
 $entry=Join-Path $sourceRoot 'Invoke-DevBenchControl.ps1'
 $text=[IO.File]::ReadAllText($entry);$t=$null;$e=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e)
 if(@($e).Count){throw 'Production parse failed.'}
 $discoveryStub=@'
function Open-McpSession {
 param($Runtime,[switch]$AllowDeferredBuildIdentity)
 $h=@{'Mcp-Session-Id'='original-owned-session';Accept='application/json';'Content-Type'='application/json'}
 $ownedMcpSessions.Add([pscustomobject]@{sessionId='original-owned-session';headers=$h;openedUtc=[DateTime]::UtcNow.ToString('o');cleanup=$null})
 $calendar=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-calendar-schema.json') -Raw|ConvertFrom-Json -Depth 40
 $colour=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-colour-tools.v217.json') -Raw|ConvertFrom-Json -Depth 40
 [pscustomobject]@{headers=$h;tools=@($calendar)+@($colour);runtimeIdentity=[pscustomobject]@{complete=$true;verified=$true;listenerPid=12345;build=[pscustomobject]@{buildId=$colourPlan.expectedBuildId};process=[pscustomobject]@{startTimeUtc=[DateTime]::UtcNow.ToString('o')}}}
}
function Write-RuntimeEvidence {param($Binding) return $null}
'@
 $stubAst=[Management.Automation.Language.Parser]::ParseInput($discoveryStub,[ref]$t,[ref]$e)
 $replacements=@(foreach($name in @('Open-McpSession','Write-RuntimeEvidence')){
  $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  $stub=@($stubAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  if($node.Count -ne 1 -or $stub.Count -ne 1){throw 'Ambiguous discovery boundary.'}
  @{start=$node[0].Extent.StartOffset;length=$node[0].Extent.EndOffset-$node[0].Extent.StartOffset;text=$stub[0].Extent.Text}
 })
 foreach($r in ($replacements|Sort-Object start -Descending)){$text=$text.Remove($r.start,$r.length).Insert($r.start,$r.text)}
 # Instrument only the copied atomic writer. Terminal-write admission is
 # independently observed; the production helper and close path remain real.
 $atomic=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-JsonAtomic'},$true))
 if($atomic.Count -ne 1){throw 'Ambiguous atomic writer boundary.'}
 $atomicBody=$atomic[0].Extent.Text.Replace('function Write-JsonAtomic {','function Write-FixtureJsonAtomic {')
 $writer=@'
function Write-JsonAtomic {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
 $terminal=$Value -is [Collections.IDictionary] -and $Value.Contains('state') -and $Value.state -in @('completed','failed','guard-rejected','indeterminate')
 if($terminal){
  $case=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.txt') -Raw).Trim()
  $trace=Join-Path $PSScriptRoot 'journal-trace.ndjson'
  $record=@{state=$Value.state;startedUtc=[DateTime]::UtcNow.ToString('o');hasSessionCleanup=$Value.Contains('sessionCleanup')}
  [IO.File]::AppendAllText($trace,($record|ConvertTo-Json -Compress)+[Environment]::NewLine)
  if($case -in @('journal-delay','journal-exception')){Start-Sleep -Milliseconds 2000}
  if($case -ceq 'journal-overrun'){Start-Sleep -Milliseconds 3500}
 }
 Write-FixtureJsonAtomic -Path $Path -Value $Value
}
'@
 $text=$text.Replace($atomic[0].Extent.Text,$atomicBody+[Environment]::NewLine+$writer)
 $close=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Close-AllMcpSessions'},$true))
 if($close.Count -ne 1){throw 'Ambiguous owned-session finalizer boundary.'}
 $closeBody=$close[0].Extent.Text.Replace('function Close-AllMcpSessions {','function Close-FixtureAllMcpSessions {')
 $closeTrace=@'
function Close-AllMcpSessions {
 param([DateTime]$DeadlineUtc=[DateTime]::MaxValue)
 $receipt=Close-FixtureAllMcpSessions -DeadlineUtc $DeadlineUtc
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'close-trace.json'),(@{completedUtc=[DateTime]::UtcNow.ToString('o');receipt=$receipt}|ConvertTo-Json -Depth 20))
 return $receipt
}
'@
 $text=$text.Replace($close[0].Extent.Text,$closeBody+[Environment]::NewLine+$closeTrace)
 $admissionBoundary="if (`$finalizationReserveMilliseconds -gt 0 -and [DateTime]::UtcNow -ge `$totalInvocationDeadlineUtc) {"
 $admissionDelay=@'
if ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.txt') -Raw).Trim() -ceq 'journal-admission-expired') {
    while ([DateTime]::UtcNow -lt $totalInvocationDeadlineUtc.AddMilliseconds(1)) { Start-Sleep -Milliseconds 1 }
}
'@
 # Only the helper admission is delayed; this exposes the prior timestamp
 # sample/write-action race without any production timing hook.
 $text=$text.Replace($admissionBoundary,$admissionDelay+[Environment]::NewLine+$admissionBoundary)
 $semanticLine="`$semantic=[pscustomobject]@{known=`$true;ok=`$data.ok;outcome='calendar-window';guarded=`$false;transient=`$false;codes=@();states=@();reasons=@(`$data.errors);completionBasis=`$data.completionBasis}"
 if(-not $text.Contains($semanticLine)){throw 'Exact post-workflow boundary missing.'}
 $text=$text.Replace($semanticLine,$semanticLine+[Environment]::NewLine+"if ((Get-Content -LiteralPath (Join-Path `$PSScriptRoot 'case.txt') -Raw).Trim() -ceq 'journal-exception') { throw 'Synthetic post-workflow exception with partial evidence retained.' }")
 [IO.File]::WriteAllText($entry,$text,[Text.UTF8Encoding]::new($false))
 # Only this fixture's copied Calendar module changes. The production module is
 # unchanged and separately qualified by its existing positive/negative suites.
 $calendarStub=@'
function Invoke-DevBenchCalendarWindow {
 param($Owner,$Observations,$ColourPlan,[switch]$FixedAutoExposure,$CompilerGuard,$HoldMilliseconds,[DateTime]$DeadlineUtc,$ExpectedProcessId,$AssertSession,$Call)
 if(-not $FixedAutoExposure){throw 'Expected fixed-AE public path.'}
 $case=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.txt') -Raw
 # Public controller must have reduced this workflow deadline by the3s reserve.
 $original=$DeadlineUtc.AddMilliseconds(3000)
 $remain=switch($case){'expired' {-10} 'journal-expired' {-10} 'reserve-exhausted' {700} 'half-second' {1500} 'one-and-half' {2500} 'journal-delay' {3000} 'journal-exception' {3000} 'journal-overrun' {3000} 'journal-admission-expired' {3000} default {-1}}
 if($case -cne 'healthy'){
  $target=$original.AddMilliseconds(-$remain)
  while([DateTime]::UtcNow -lt $target){$ms=($target-[DateTime]::UtcNow).TotalMilliseconds;Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(50,$ms)))}
 }
 [pscustomobject]@{
  ok=$true;indeterminate=$false;errors=@();completionBasis='synthetic-calendar-readback-boundary'
  restorationVerified=$true
  lease=[pscustomobject]@{id='original-lease';owner=$Owner}
  measurement=[pscustomobject]@{raw='partial-raw-unmodified';captureId='original-capture';probeCleanup=[pscustomobject]@{verified=$true};colourCleanup=[pscustomobject]@{verified=$true}}
  calendarRelease=[pscustomobject]@{leaseId='original-lease';restored=$true}
 }
}
Export-ModuleMember -Function Invoke-DevBenchCalendarWindow
'@
 [IO.File]::WriteAllText((Join-Path $sourceRoot 'CalendarObservationWindow.psm1'),$calendarStub,[Text.UTF8Encoding]::new($false))
 $fixture=& (Join-Path $PSScriptRoot 'Test-FixedAEColourBaseline.ps1') -FixtureOnly -FixtureMode healthy
 $plan=$fixture.Plan;$plan.capturesPerCondition=1
 foreach($case in $FixtureModes){
  [IO.File]::WriteAllText((Join-Path $sourceRoot 'case.txt'),$case)
  $tracePath=Join-Path $sourceRoot 'journal-trace.ndjson'
  if(Test-Path -LiteralPath $tracePath){Remove-Item -LiteralPath $tracePath -Force}
  $dir=Join-Path $root $case;[IO.Directory]::CreateDirectory($dir)|Out-Null
  $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
  $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $job=Start-ThreadJob -ArgumentList $listener,$events,$case -ScriptBlock{
   param($Listener,$Events,$Case)
   try{
    while($true){
     $client=$Listener.AcceptTcpClient()
     try{
      $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream)
      $first=$reader.ReadLine();$headers=@{}
      while(($line=$reader.ReadLine()) -ne ''){if($null -eq $line){throw 'Truncated HTTP request.'};$pair=$line.Split(':',2);$headers[$pair[0]]=$pair[1].Trim()}
      $Events.Enqueue([pscustomobject]@{first=$first;session=$headers['Mcp-Session-Id'];receivedUtc=[DateTime]::UtcNow.ToString('o')})
      if($Case -in @('half-second','one-and-half')){Start-Sleep -Seconds 4}
      $crlf=[string][char]13+[char]10
      $bytes=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 204 No Content'+$crlf+'Content-Length: 0'+$crlf+'Connection: close'+$crlf+$crlf)
      try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}catch{}
     }finally{$client.Dispose()}
    }
   }catch{}finally{$Listener.Stop()}
  }
  try{
   $runtime=Join-Path $dir 'runtime.json';[IO.File]::WriteAllText($runtime,(@{port=$port}|ConvertTo-Json -Compress))
   $timer=[Diagnostics.Stopwatch]::StartNew()
   $raw=& $entry colour-baseline-window -RuntimePath $runtime -ColourPlanJson ($plan|ConvertTo-Json -Depth 30 -Compress) -CalendarOwner fixture-owner -CalendarHoldMilliseconds 20000 -TimeoutSeconds 20 -MaxTransientRetries 0 -EvidenceDirectory $dir -NoExit -Compact|Out-String
   $timer.Stop();$reply=$raw|ConvertFrom-Json -Depth 80
   $all=@($events.ToArray())
   $journal=@(if(Test-Path -LiteralPath $tracePath){Get-Content -LiteralPath $tracePath|ForEach-Object {$_|ConvertFrom-Json}})
   $closeTrace=Get-Content -LiteralPath (Join-Path $sourceRoot 'close-trace.json') -Raw|ConvertFrom-Json -Depth 20
   if(-not $reply.PSObject.Properties['finalization']){throw "Public path failed before finalization: $raw"}
   $cleanup=$reply.sessionCleanup.sessions[0]
   $deadline=([DateTimeOffset]$reply.finalization.originalDeadlineUtc).UtcDateTime
   Check-Finalization ($reply.operationTimeoutSeconds -eq 20 -and $reply.finalization.reserveMilliseconds -eq 3000) "$case original budget and reserved slice"
   Check-Finalization ($reply.data.measurement.raw -ceq 'partial-raw-unmodified' -and $reply.data.measurement.captureId -ceq 'original-capture' -and $reply.data.lease.id -ceq 'original-lease' -and $reply.data.restorationVerified) "$case partial and separate Calendar/probe custody evidence preserved"
   Check-Finalization (@($all|Where-Object {([DateTimeOffset]$_.receivedUtc).UtcDateTime -ge $deadline}).Count -eq 0) "$case no DELETE reaches handler after original deadline"
   if($case -in @('expired','journal-expired','reserve-exhausted')){
    Check-Finalization ($all.Count -eq 0 -and -not $cleanup.attempted -and -not $cleanup.ok -and $cleanup.state -ceq 'not_attempted_deadline_exhausted') "$case explicit unattempted close"
    Check-Finalization (-not $reply.ok -and $reply.indeterminate -and -not $reply.sessionCleanup.ok -and -not $reply.finalization.sessionClosureVerified) "$case no invented cleanup success"
   }else{
    Check-Finalization ($all.Count -eq 1 -and $all[0].first.StartsWith('DELETE ') -and $all[0].session -ceq 'original-owned-session' -and $cleanup.attempted) "$case exact single original-session DELETE"
    Check-Finalization (([DateTimeOffset]$cleanup.admittedUtc).UtcDateTime -lt ([DateTimeOffset]$cleanup.deadlineUtc).UtcDateTime) "$case dispatch admission before cutoff"
    if($case -in @('healthy','journal-delay','journal-exception','journal-overrun','journal-admission-expired')){
     Check-Finalization ($cleanup.ok -and $cleanup.state -ceq 'closed') "$case original session closed"
     if($case -ceq 'healthy'){Check-Finalization ($reply.ok -and $reply.evidenceJournalFinalized) 'healthy terminal outcome and journal'}
    }else{
     $maximum=if($case -ceq 'half-second'){500}else{1500}
     Check-Finalization ($cleanup.timeoutMilliseconds -gt 0 -and $cleanup.timeoutMilliseconds -le $maximum) "$case fractional timeout clipped to remaining allowance"
     Check-Finalization (-not $cleanup.ok -and $cleanup.state -ceq 'cleanup_timed_out' -and $reply.indeterminate -and -not $reply.ok) "$case cancellable slow HTTP remains unverified"
    }
   }
   Check-Finalization ($reply.finalization.finalJournalAttempted -eq ($journal.Count -gt 0)) "$case attempt flag matches independently observed atomic write admission"
   Check-Finalization ($journal.Count -le 1 -and @($journal|Where-Object {-not $_.hasSessionCleanup}).Count -eq 0) "$case at most one terminal journal, always containing session cleanup"
   if($journal.Count -and $all.Count){
    Check-Finalization (([DateTimeOffset]$journal[0].startedUtc).UtcDateTime -ge ([DateTimeOffset]$closeTrace.completedUtc).UtcDateTime) "$case terminal journal starts after original DELETE completes"
   }
   if($case -in @('journal-delay','journal-exception','journal-overrun')){
    Check-Finalization ($cleanup.timeoutMilliseconds -ge 1800 -and $cleanup.timeoutMilliseconds -le 2000) "$case full reserved DELETE allowance precedes local delay"
    Check-Finalization ($journal.Count -eq 1 -and $reply.data.measurement.probeCleanup.verified -and $reply.data.measurement.colourCleanup.verified -and $reply.data.calendarRelease.restored) "$case one terminal write and separate custody retained"
    if($case -ceq 'journal-exception'){Check-Finalization (-not $reply.ok -and @($reply.errors|Where-Object {$_ -like '*Synthetic post-workflow exception*'}).Count -eq 1 -and $journal[0].state -ceq 'failed') 'exception outcome retained after close-first finalization'}
   }
   if($case -in @('expired','journal-expired','journal-admission-expired')){
    Check-Finalization (-not $reply.finalization.finalJournalAttempted -and -not $reply.evidenceJournalFinalized -and $reply.originalDeadlineExceeded -and @($reply.evidenceWarnings).Count -gt 0) 'expired journal I/O refused with in-memory evidence'
    # This intentionally overrun Calendar boundary cannot meet a hard wall claim.
    # Quantify output overhead rather than granting/claiming an extended budget.
    Check-Finalization ($timer.Elapsed.TotalSeconds -le 20.6) 'expired path returns without a fresh2s wait; bounded observed JSON/scheduling overhead under600ms'
    if($case -ceq 'journal-admission-expired'){Check-Finalization ($all.Count -eq 1 -and $cleanup.ok -and $journal.Count -eq 0 -and $reply.data.measurement.probeCleanup.verified -and $reply.data.measurement.colourCleanup.verified -and $reply.data.calendarRelease.restored) 'deadline crossing at helper admission skips journal after verified close and preserves custody'}
   }elseif($case -ceq 'journal-overrun'){
    Check-Finalization ($reply.finalization.finalJournalAttempted -and -not $reply.evidenceJournalFinalized -and $reply.originalDeadlineExceeded -and -not $reply.ok -and $reply.indeterminate) 'admitted slow journal is unfinalized late evidence, not a reopened allowance'
    Check-Finalization ($timer.Elapsed.TotalSeconds -lt 21) 'cooperative filesystem delay overrun returns finitely without replay'
   }else{Check-Finalization ($timer.Elapsed.TotalSeconds -lt 20 -and -not $reply.originalDeadlineExceeded -and $reply.outputSerializationEvidence.withinOriginalDeadline) "$case total command including journal/JSON stays inside20s"}
   $cases+=@{case=$case;elapsedMilliseconds=$timer.Elapsed.TotalMilliseconds;deleteCount=$all.Count;terminalJournalWrites=$journal;cleanup=$cleanup;finalization=$reply.finalization;deadlineExceeded=$reply.originalDeadlineExceeded}
  }finally{$listener.Stop();Stop-Job -Job $job;Remove-Job -Job $job -Force}
 }
 @{ok=$true;passed=$passed;cases=$cases;liveRuntimeUsed=$false;nativeScientificWorkflowStubbed=$true;publicControllerFinalizationRetained=$true;realHttpCancellation=$true}|ConvertTo-Json -Depth 20 -Compress
}finally{
 $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved)).StartsWith('mcp-finalization-')){throw 'Refusing cleanup outside exact fixture root.'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

