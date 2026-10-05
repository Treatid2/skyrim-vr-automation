# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$checks=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
$root=Join-Path $FixtureRoot ('colour-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
foreach($mode in @('healthy','partial-page','compiler','schema-missing','lost-arm','lost-reset')){
    $dir=Join-Path $root $mode;New-Item -ItemType Directory -Path $dir|Out-Null
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $server=Start-ThreadJob -ArgumentList $listener,$mode,$PSScriptRoot,$events,$PID,$port -ScriptBlock {
        param($Listener,$Mode,$Source,$Events,$OwnerPid,$Port)
        $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
        $fixture=. (Join-Path $Source 'Test-ColourMeasurementWindow.ps1') -FixtureOnly -FixtureMode $Mode
        $binding=[pscustomobject]@{processSession='colour-calendar-fixture';pid=$OwnerPid;loadGeneration=1;cellFormId=7;globalFormIds=@(1,2,3,4,5,6)}
        $values=[pscustomobject]@{year=201;month=1;day=1;gameHour=12;daysPassed=1;calendarRate=20;engineMultiplier=1}
        $lease=$null;$restored=$false
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
                if($first.StartsWith('DELETE')){$Events.Enqueue([pscustomobject]@{method='DELETE';session=$headers['Mcp-Session-Id'];name=$null;arguments=$null})}
                else{
                    $rpc=(-join $buffer)|ConvertFrom-Json -Depth 40
                    $query=if($rpc.PSObject.Properties['params'] -and $rpc.params.PSObject.Properties['arguments']){$rpc.params.arguments}else{$null}
                    $name=if($rpc.PSObject.Properties['params'] -and $rpc.params.PSObject.Properties['name']){$rpc.params.name}else{$null}
                    $Events.Enqueue([pscustomobject]@{method=$rpc.method;name=$name;arguments=$query;session=$headers['Mcp-Session-Id']})
                    $result=@{}
                    switch($rpc.method){
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
                                if($query.action -ceq 'hold'){$lease=[pscustomobject]@{id='owned-colour-lease';owner=$query.owner;commandId=$query.commandId;binding=$binding;captured=$values;applied=$true}}
                                if($query.action -ceq 'release'){
                                    if($query.leaseId -cne $lease.id -or $query.owner -cne $lease.owner -or ($query.binding|ConvertTo-Json -Compress) -cne ($binding|ConvertTo-Json -Compress)){throw 'fixture foreign calendar release'}
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
                                try{$map=$query|ConvertTo-Json -Depth 30|ConvertFrom-Json -AsHashtable -Depth 30;$reply=& $fixture.Call $name $map ($query.action -cin @('set','arm','reset')) ([datetime]::UtcNow.AddSeconds(30));$payload=$reply.content[0]}
                                catch{$payload=@{error=$_.Exception.Message}}
                            }
                            $result=@{isError=$false;content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 40 -Compress)})}
                        }
                    }
                    if($status -cne '204 No Content'){$body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 50 -Compress}
                }
                $bytes=[Text.Encoding]::UTF8.GetBytes($body);$head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+[char]13+[char]10+$replyHeaders+'Content-Type: application/json'+[char]13+[char]10+'Content-Length: '+$bytes.Length+[char]13+[char]10+'Connection: close'+[char]13+[char]10+[char]13+[char]10)
                $stream.Write($head,0,$head.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            }finally{$client.Dispose()}
        }}catch{if($Listener.Server.IsBound){throw}}finally{$Listener.Stop()}
    }
    try{
        $fixture=& (Join-Path $PSScriptRoot 'Test-ColourMeasurementWindow.ps1') -FixtureOnly
        $plan=$fixture.Plan;$plan.capturesPerCondition=1
        $artifact=Join-Path $PSScriptRoot 'Test-ColourWindowEntryPoint.ps1'
        $runtime=Join-Path $dir 'runtime.json';@{port=$port;pid=$PID;buildId=$plan.expectedBuildId;artifactPath=$artifact;artifactSha256=(Get-FileHash $artifact).Hash}|ConvertTo-Json|Set-Content -LiteralPath $runtime
        $reply=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') colour-window -RuntimePath $runtime -ColourPlanJson ($plan|ConvertTo-Json -Depth 20 -Compress) -CalendarOwner fixture-owner -CalendarHoldMilliseconds 30000 -TimeoutSeconds 30 -MaxTransientRetries 0 -EvidenceDirectory $dir -NoExit -Compact|ConvertFrom-Json -Depth 80
        $reply|ConvertTo-Json -Depth 80|Set-Content -LiteralPath (Join-Path $dir 'result.json')
        Check ($reply.ok -eq ($mode -ceq 'healthy')) "$mode public outcome: $($reply.errors -join ';')"
        $all=@($events.ToArray())
        Check (@($all|Where-Object method -CEQ 'initialize').Count -eq 1) "$mode no session rebind"
        Check (@($all|Where-Object {$_.method -ceq 'tools/call' -and $_.session -cne 'colour-fixture'}).Count -eq 0) "$mode uses one actual session"
        Check ($all[-1].method -ceq 'DELETE' -and $reply.sessionCleanup.ok) "$mode session finalized separately"
        if($mode -ceq 'schema-missing'){Check (@($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'hold'}).Count -eq 0) 'schema refusal before hold'}else{
            Check $reply.data.restorationVerified "$mode calendar restoration independently verified"
            Check (@($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'hold'}).Count -eq 1 -and @($all|Where-Object {$_.name -ceq 'calendar' -and $_.arguments.action -ceq 'release'}).Count -eq 1) "$mode exact hold/release once"
            Check (@(Get-ChildItem -LiteralPath $dir -Filter 'colour-rpc.*.json' -File).Count -gt 0) "$mode immutable raw replies retained"
        }
        if($mode -ceq 'healthy'){Check ($reply.data.measurement.captures.Count -eq 3 -and @($reply.data.measurement.captures|ForEach-Object {$_.pages}).Count -eq 30) 'public three conditions/all30 pages complete'}
        if($mode -ceq 'partial-page'){Check ($reply.data.measurement.probeCleanup.verified -and -not $reply.data.measurement.captures[0].complete) 'partial capture and successful owned cleanup separate'}
        if($mode -cin @('lost-arm','lost-reset')){Check $reply.data.measurement.indeterminate 'lost mutation remains indeterminate';Check (@($all|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq $mode.Substring(5)}).Count -eq 1) 'lost mutation not replayed'}
    }finally{$listener.Stop();Stop-Job $server;Remove-Job $server}
}
[pscustomobject]@{ok=$true;checks=$checks;cases=6;root=$root;scope='test-owned loopback real public entry; no Skyrim or live mutation'}|ConvertTo-Json -Compress

