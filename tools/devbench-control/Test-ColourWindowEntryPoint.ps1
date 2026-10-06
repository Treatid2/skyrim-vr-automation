# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[switch]$FixedAutoExposure,[string[]]$FixtureModes)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$checks=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
$root=Join-Path $FixtureRoot ('colour-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$modes=if($FixedAutoExposure){@('healthy','healthy-false','ae-mismatch','hdr-mismatch','foreign-revision','telemetry-unavailable','telemetry-malformed','page-telemetry-unavailable','partial-page','compiler','schema-missing','lost-arm','lost-reset','burnin-incomplete','budget-incomplete','foreign-cell','session-retired')}else{@('healthy','partial-page','compiler','schema-missing','lost-arm','lost-reset','string-page-generation','native-failure','burnin-incomplete','session-retired')}
if($FixtureModes){if(@($FixtureModes|Where-Object {$_ -cnotin $modes}).Count){throw 'Unknown public fixture case'};$modes=@($FixtureModes)}
foreach($mode in $modes){
    $dir=Join-Path $root $mode;New-Item -ItemType Directory -Path $dir|Out-Null
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $server=Start-ThreadJob -ArgumentList $listener,$mode,$PSScriptRoot,$events,$PID,$port,[bool]$FixedAutoExposure -ScriptBlock {
        param($Listener,$Mode,$Source,$Events,$OwnerPid,$Port,$Baseline)
        $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
        $fixture=. (Join-Path $Source $(if($Baseline){'Test-FixedAEColourBaseline.ps1'}else{'Test-ColourMeasurementWindow.ps1'})) -FixtureOnly -FixtureMode $Mode
        $binding=[pscustomobject]@{processSession='colour-calendar-fixture';pid=$OwnerPid;loadGeneration=1;cellFormId=7;globalFormIds=@(1,2,3,4,5,6)}
        $values=[pscustomobject]@{year=201;month=1;day=1;gameHour=12;daysPassed=1;calendarRate=20;engineMultiplier=1}
        $lease=$null;$restored=$false
        $armCount=0;$eighthNativeComplete=$false;$calendarRemainingBeforeRetirement=-1;$retired=$false
        $schemas=Get-Content -LiteralPath (Join-Path $Source 'fixtures/native-colour-tools.v217.json') -Raw|ConvertFrom-Json -Depth 30
        $calendarSchema=Get-Content -LiteralPath (Join-Path $Source 'fixtures/native-calendar-schema.json') -Raw|ConvertFrom-Json -Depth 30
        try{while($true){
            $client=$Listener.AcceptTcpClient()
            try{
                $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
                $first=$reader.ReadLine();$length=0;$headers=@{}
                while($null -ne ($line=$reader.ReadLine()) -and $line -ne ''){$pair=$line.Split(':',2);$headers[$pair[0]]=$pair[1].Trim();if($pair[0] -ieq 'Content-Length'){$length=[int]$pair[1]}}
                $buffer=[char[]]::new($length);$offset=0
                while($offset -lt $length){$n=$reader.Read($buffer,$offset,$length-$offset);if($n -eq 0){throw 'fixture truncated request'};$offset+=$n}
                $replyHeaders='';$body='{}';$status='200 OK'
                if($first.StartsWith('DELETE')){
                    if($retired){$status='404 Not Found'}
                    $Events.Enqueue([pscustomobject]@{method='DELETE';session=$headers['Mcp-Session-Id'];name=$null;arguments=$null;httpStatus=$status})
                }
                else{
                    $rpc=(-join $buffer)|ConvertFrom-Json -Depth 40
                    $query=if($rpc.PSObject.Properties['params'] -and $rpc.params.PSObject.Properties['arguments']){$rpc.params.arguments}else{$null}
                    $name=if($rpc.PSObject.Properties['params'] -and $rpc.params.PSObject.Properties['name']){$rpc.params.name}else{$null}
                    # Retire before handler entry at the pre-page calendar boundary,
                    # after eighth native completion, colour status and its post-read
                    # calendar boundary have all returned successfully.
                    if($Mode -ceq 'session-retired' -and $name -ceq 'calendar' -and $query.action -ceq 'status' -and $calendarRemainingBeforeRetirement -ge 0){
                        if($calendarRemainingBeforeRetirement -eq 0){$retired=$true}else{$calendarRemainingBeforeRetirement--}
                    }
                    if($retired){$status='404 Not Found'}
                    $Events.Enqueue([pscustomobject]@{method=$rpc.method;name=$name;arguments=$query;session=$headers['Mcp-Session-Id'];httpStatus=$status})
                    $result=@{}
                    if(-not $retired){switch($rpc.method){
                        'initialize'{$replyHeaders='Mcp-Session-Id: colour-fixture'+[char]13+[char]10;$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='colour-test';version='217'}}}
                        'notifications/initialized'{$status='204 No Content';$body=''}
                        'tools/list'{
                            $available=if($Mode -ceq 'schema-missing'){@($schemas|Where-Object name -CNE 'communityshaders.colour_pipeline_probe')}else{@($schemas)}
                            $result=@{tools=@($calendarSchema)+$available+@(@{name='inspect';inputSchema=@{}},@{name='communityshaders.shader_api';inputSchema=@{required=@('contractMajor','clientId','commandId','action');properties=@{contractMajor=@{type='integer';const=1};clientId=@{type='string'};commandId=@{type='string'};action=@{type='string';enum=@('registry','snapshot')}}}})}
                        }
                        'tools/call'{
                            if($headers['Mcp-Session-Id'] -cne 'colour-fixture'){throw 'fixture wrong session'}
                            if($name -ceq 'inspect'){$payload=@{pid=$OwnerPid;exe='pwsh.exe';port=$Port;frame=1;lastTaskFrame=-1;pendingTasks=0;vr=$true}}
                            elseif($name -ceq 'calendar'){
                                if($Mode -ceq 'foreign-cell' -and $armCount -gt 0){$binding.cellFormId=8}
                                if($query.action -ceq 'hold'){$lease=[pscustomobject]@{id='owned-colour-lease';owner=$query.owner;commandId=$query.commandId;binding=($binding|ConvertTo-Json|ConvertFrom-Json);captured=$values;applied=$true}}
                                if($query.action -ceq 'release'){
                                    if($query.leaseId -cne $lease.id -or $query.owner -cne $lease.owner -or ($query.binding|ConvertTo-Json -Compress) -cne ($lease.binding|ConvertTo-Json -Compress)){throw 'fixture foreign calendar release'}
                                    $restored=$true
                                }
                                $active=$null -ne $lease -and -not $restored
                                $v=$values|ConvertTo-Json|ConvertFrom-Json;if($active){$v.calendarRate=0}
                                $payload=@{ok=$true;action=$query.action;status=$(if($query.action -ceq 'hold'){'held'}elseif($query.action -ceq 'release'){'released'}else{'observed'});schemaVersion=1;plugin='devbench';binding=$binding;readbackFresh=$true;available=$true;worldLoaded=$true;values=$v;outstanding=$active;leaseActive=$active;expiryDue=$false;cleanupPending=$false;holdValid=$active;serviceStopping=$false;restored=$restored;lastTransition=@{ok=$true;status='released';restored=$restored}}
                                if($lease){$payload.lease=$lease}
                            }
                            elseif($name -ceq 'communityshaders.shader_api'){
                                $producer=@{component='CommunityShaders';buildId=$fixture.Plan.expectedBuildId;sourceCommit=$fixture.Producer.sourceCommit;shaderCacheAbiId='abi';shaderCompilerIdentity='fxc';sessionId='fixture-shader';serviceSessionId='fixture-shader';manifestVerified=$false;manifestError=$null}
                                if($query.action -ceq 'registry'){$payload=@{ok=$true;server=$producer;result=@{service='csx.shader'}}}
                                else{
                                    $payload=@{ok=$true;contract=@{name='csx.shader';major=1;minor=0;schemaRevision=1};command=$query;timestampUtc=[datetimeoffset]::UtcNow.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ');server=$producer;result=@{status='success';snapshot=@{available=$true;stateRevision=1;capabilities=1;customShaders=@{requested=$true;effective=$true;transitionPending=$false};diskCache=@{requested=$true;active=$true;held=$false;previousAvailable=$false;featureSetChanged=$false;featureSetRevertPending=$false};persistence=@{mutationBlocked=$false;saveLoadSafeModeActive=$false};compilation=@{active=$false;async=$true;skipUnchanged=$false;activeShaderCapture=$false;totalTasks=10;completedTasks=10;failedTasks=$(if($Mode -ceq 'compiler'){1}else{0});currentFailedShaders=0;memoryCacheHits=0;diskCacheHits=0;sourceCompiles=10;slowTasks=0;verySlowTasks=0;heavyTasksInFlight=0;foregroundThreadCount=2;backgroundThreadCount=1;statisticsText='fixture';recentFailures=@()};provenance=@{buildId=$fixture.Plan.expectedBuildId;shaderCacheAbiId='abi';shaderCompilerIdentity='fxc'}}}}
                                }
                            }else{
                                try{
                                    $map=$query|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable -Depth 30
                                    $reply=& $fixture.Call $name $map ($query.action -cin @('set','arm','reset')) ([datetime]::UtcNow.AddSeconds(30));$payload=$reply.content[0]
                                    if($Mode -ceq 'foreign-cell' -and $name -ceq 'communityshaders.colour_pipeline_probe' -and $query.action -ceq 'arm'){$armCount++}
                                    if($Mode -ceq 'session-retired'){
                                        if($name -ceq 'communityshaders.colour_pipeline_probe' -and $query.action -ceq 'arm'){$armCount++}
                                        if($name -ceq 'communityshaders.colour_pipeline_probe' -and $query.action -ceq 'status' -and $armCount -eq 8 -and $payload.state -ceq 'complete'){$eighthNativeComplete=$true}
                                        if($name -ceq 'communityshaders.fsr_color_contract' -and $query.action -ceq 'status' -and $eighthNativeComplete -and $calendarRemainingBeforeRetirement -lt 0){$calendarRemainingBeforeRetirement=1}
                                    }
                                }
                                catch{$payload=@{error=$_.Exception.Message}}
                            }
                            $result=@{isError=$false;content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 40 -Compress)})}
                        }
                    }}
                    if($status -ceq '200 OK'){$body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 50 -Compress}
                }
                $bytes=[Text.Encoding]::UTF8.GetBytes($body);$head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+[char]13+[char]10+$replyHeaders+'Content-Type: application/json'+[char]13+[char]10+'Content-Length: '+$bytes.Length+[char]13+[char]10+'Connection: close'+[char]13+[char]10+[char]13+[char]10)
                $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            }finally{$client.Dispose()}
        }}catch{if($Listener.Server.IsBound){throw}}finally{$Listener.Stop()}
    }
    try{
        $fixture=& (Join-Path $PSScriptRoot $(if($FixedAutoExposure){'Test-FixedAEColourBaseline.ps1'}else{'Test-ColourMeasurementWindow.ps1'})) -FixtureOnly -FixtureMode $mode
        $plan=$fixture.Plan;$plan.capturesPerCondition=1
        if($FixedAutoExposure -and $mode -cin @('healthy','healthy-false','session-retired')){$plan.capturesPerCondition=16}
        if($FixedAutoExposure){$plan.burnIn.maximumElapsedMilliseconds=4000}
        if($mode -ceq 'session-retired' -and -not $FixedAutoExposure){$plan.capturesPerCondition=4;$plan.minimumElapsedMillisecondsBetweenCaptureArms=1}
        if($mode -ceq 'budget-incomplete'){$plan.capturesPerCondition=16;$plan.minimumElapsedMillisecondsBetweenCaptureArms=10000}
        # The real public transport refuses to start an RPC with less than1s
        # remaining; allow startup matching, then reject stagnant frame evidence.
        if($mode -ceq 'burnin-incomplete'){$plan.burnIn=@{minimumElapsedMilliseconds=10;minimumObservedCpuFrameIdAdvancePerEye=1;minimumDistinctFreshSuccessfulBothEyeObservations=2;maximumElapsedMilliseconds=4000}}
        $artifact=Join-Path $PSScriptRoot 'Test-ColourWindowEntryPoint.ps1'
        $runtime=Join-Path $dir 'runtime.json';@{port=$port;pid=$PID;buildId=$plan.expectedBuildId;artifactPath=$artifact;artifactSha256=(Get-FileHash $artifact).Hash}|ConvertTo-Json|Set-Content -LiteralPath $runtime
        $command=if($FixedAutoExposure){'colour-baseline-window'}else{'colour-window'}
        $seconds=if($FixedAutoExposure -and $mode -cin @('healthy','healthy-false','session-retired')){180}else{30}
        $reply=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') $command -RuntimePath $runtime -ColourPlanJson ($plan|ConvertTo-Json -Depth 20 -Compress) -CalendarOwner fixture-owner -CalendarHoldMilliseconds ($seconds*1000) -TimeoutSeconds $seconds -MaxTransientRetries 0 -EvidenceDirectory $dir -NoExit -Compact|ConvertFrom-Json -Depth 80
        $reply|ConvertTo-Json -Depth 80|Set-Content -LiteralPath (Join-Path $dir 'result.json')
        Check ($reply.ok -eq ($mode -cin @('healthy','healthy-false'))) "$mode public outcome: $($reply.errors -join ';')"
        $all=@($events.ToArray())
        Check (@($all|Where-Object method -CEQ 'initialize').Count -eq 1) "$mode no session rebind"
        Check (@($all|Where-Object {$_.method -ceq 'tools/call' -and $_.session -cne 'colour-fixture'}).Count -eq 0) "$mode uses one actual session"
        Check ($all[-1].method -ceq 'DELETE' -and $reply.sessionCleanup.ok) "$mode session finalized separately"
        if($FixedAutoExposure){Check (@($all|Where-Object {$_.name -ceq 'communityshaders.fsr_color_contract' -and $_.arguments.action -cne 'status'}).Count -eq 0) "$mode ZERO public colour writes"}
        if($mode -cin @('schema-missing','budget-incomplete')){Check (@($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'hold'}).Count -eq 0) 'schema/budget refusal before hold'}else{
            Check ($reply.data.restorationVerified -eq ($mode -cne 'session-retired')) "$mode calendar restoration independently reported"
            Check (@($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'hold'}).Count -eq 1 -and @($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'release'}).Count -eq 1) "$mode exact hold/release once"
            Check (@(Get-ChildItem -LiteralPath $dir -Filter 'colour-rpc.*.json' -File).Count -gt 0) "$mode immutable raw replies retained"
        }
        if($mode -cin @('healthy','healthy-false')){ $count=if($FixedAutoExposure){16}else{3};Check ($reply.data.measurement.captures.Count -eq $count -and @($reply.data.measurement.captures|ForEach-Object {$_.pages}).Count -eq 10*$count) 'public full capture/page inventory complete'}
        if($mode -ceq 'session-retired'){
            $m=$reply.data.measurement;$captures=@($m.captures);$last=$captures[-1]
            Check ($reply.indeterminate -and $m.indeterminate) 'session loss retains indeterminate custody'
            Check ($captures.Count -eq 8 -and @($captures|Where-Object {$_.complete -and $_.resetVerified}).Count -eq 7 -and @($captures|ForEach-Object {$_.pages}).Count -eq 70) 'seven fully collected captures preserved'
            Check ($last.armReply.content[0].accepted -and $last.generation -eq 15 -and $last.status.state -ceq 'complete' -and $last.status.queuedStageEyeSlots -eq 10 -and $last.status.mappedStageEyeSlots -eq 10) 'eighth accepted native-complete capture preserved'
            Check ($last.pages.Count -eq 0 -and -not $last.complete -and -not $last.resetVerified -and $m.retainedProbe.captureId -ceq $last.captureId -and $m.retainedProbe.generation -eq $last.generation) 'no page or reset qualification after eighth native completion'
            Check (@($all|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq 'arm'}).Count -eq 8 -and @($all|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq 'reset'}).Count -eq 7 -and @($all|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq 'read'}).Count -eq 70) 'no arm reset or page replay'
            $expectedConditions=if($FixedAutoExposure){1}else{2};$expectedSets=if($FixedAutoExposure){0}else{2}
            Check ($m.conditions.Count -eq $expectedConditions -and @($all|Where-Object {$_.name -ceq 'communityshaders.fsr_color_contract' -and $_.arguments.action -ceq 'set'}).Count -eq $expectedSets) 'no successor on condition or speculative AE compensation'
            Check ($m.probeCleanup.attempted -and -not $m.probeCleanup.verified -and -not $m.colourCleanup.attempted -and -not $m.colourCleanup.verified) 'unresolved probe forbids speculative AE restoration'
            $failures=@($all|Where-Object httpStatus -CEQ '404 Not Found')
            $firstFailure=$failures[0];$prior=$all[[Array]::IndexOf($all,$firstFailure)-1]
            Check ($firstFailure.name -ceq 'calendar' -and $firstFailure.arguments.action -ceq 'status' -and $prior.name -ceq 'calendar' -and $prior.arguments.action -ceq 'status' -and $prior.httpStatus -ceq '200 OK') 'retirement occurs after successful post-colour calendar boundary'
            Check (@($failures|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'release'}).Count -eq 1 -and $all[-1].httpStatus -ceq '404 Not Found' -and $reply.sessionCleanup.sessions[0].state -ceq 'already_absent') 'original release 404 and absent session never imply restored custody'
        }
        if($mode -ceq 'burnin-incomplete'){
            Check ($reply.data.measurement.captures.Count -eq 0 -and $reply.data.measurement.conditions.Count -eq 1) 'public burn-in failure stops all arms/next conditions'
            Check ($reply.data.measurement.conditions[0].nativeDispatchMatched -and $reply.data.measurement.conditions[0].burnIn.failureCode -ceq 'burn-in-incomplete') 'public typed dispatch versus coverage failure distinction'
            Check ($reply.data.measurement.colourCleanup.verified -and -not $reply.indeterminate) 'public same-session requested-AE verification and calendar cleanup remain determinate'
        }
        if($mode -cin @('partial-page','string-page-generation','native-failure')){Check ($reply.data.measurement.probeCleanup.verified -and -not $reply.data.measurement.captures[0].complete) 'partial/malformed/failed capture and successful owned cleanup separate'}
        if($mode -ceq 'native-failure'){
            Check (($reply.errors -join ';') -cmatch 'Native colour probe capture failed: the captured frame did not contain every required stage and eye' -and ($reply.errors -join ';') -cmatch 'queuedStageEyeSlots=6/10; mappedStageEyeSlots=0') 'public terminal diagnostic retains exact native failure and slot counts'
            Check ($reply.data.measurement.captures[0].status.state -ceq 'failed' -and -not $reply.indeterminate) 'known native failure remains determinate after owned restoration'
        }
        if($mode -cin @('lost-arm','lost-reset')){Check $reply.data.measurement.indeterminate 'lost mutation remains indeterminate';Check (@($all|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq $mode.Substring(5)}).Count -eq 1) 'lost mutation not replayed'}
    }finally{$listener.Stop();Stop-Job $server;Remove-Job $server}
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$modes.Count;fixedAutoExposure=[bool]$FixedAutoExposure;root=$root;scope='test-owned loopback real public entry; no Skyrim or live mutation'}|ConvertTo-Json -Compress
