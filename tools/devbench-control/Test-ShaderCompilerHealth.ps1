# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot,[string]$EntryCaseFilter,[switch]$ConsoleDispatch,[switch]$ExpectExpiredCleanupEvidence,[switch]$ProductionRetryDefaults)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw "FAIL: $Name" }; $passes.Add($Name) }
$argsMap=@{contractMajor=1;clientId='fixture';commandId='exact-command';action='snapshot';expectedBuildId='ad8-fixture'}
# Source-derived typed fixture, NOT a retained live snapshot.
$seed=[ordered]@{
    ok=$true; contract=@{name='csx.shader';major=1;minor=0;schemaRevision=1}
    command=@{action='snapshot';clientId='fixture';commandId='exact-command'}
    timestampUtc=[DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    server=@{component='CommunityShaders';buildId='ad8-fixture';sourceCommit='ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0';shaderCacheAbiId='abi';shaderCompilerIdentity='fxc';sessionId='shader-session';serviceSessionId='shader-session';manifestVerified=$false;manifestError=$null}
    result=@{status='success';snapshot=@{
        available=$true;stateRevision=3;capabilities=1
        customShaders=@{requested=$true;effective=$true;transitionPending=$false}
        diskCache=@{requested=$true;active=$true;held=$false;previousAvailable=$false;featureSetChanged=$false;featureSetRevertPending=$false}
        persistence=@{mutationBlocked=$false;saveLoadSafeModeActive=$false}
        compilation=@{active=$false;async=$true;skipUnchanged=$false;activeShaderCapture=$false;totalTasks=100;completedTasks=100;failedTasks=0;currentFailedShaders=0;memoryCacheHits=0;diskCacheHits=40;sourceCompiles=60;slowTasks=0;verySlowTasks=0;heavyTasksInFlight=0;foregroundThreadCount=2;backgroundThreadCount=1;statisticsText='fixture';recentFailures=@()}
        provenance=@{buildId='ad8-fixture';shaderCacheAbiId='abi';shaderCompilerIdentity='fxc'}
    }}
}
function Clone-Seed { $seed | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -Depth 30 -DateKind String }
$good=Clone-Seed
$original=$good | ConvertTo-Json -Depth 30 -Compress
$health=Get-DevBenchShaderCompilerHealth -Arguments $argsMap -Content @($good)
Check ($health.readQualified -and $health.admissible -and $health.state -ceq 'COMPILER_HEALTHY_AT_SNAPSHOT') 'source-derived complete healthy snapshot admitted'
Check (($good | ConvertTo-Json -Depth 30 -Compress) -ceq $original) 'classifier preserves untouched native receipt'
Check ((Get-DevBenchCallSemanticStatus -ToolName communityshaders.shader_api -Arguments $argsMap -Content @($good)).completionBasis -ceq 'read-schema-only') 'ordinary API success remains read-schema-only'
Check (Test-DevBenchReadOnlyRequest -ToolName communityshaders.shader_api -Arguments $argsMap) 'exact snapshot is read-only'
foreach ($action in @('execute','preflight','backgroundCompile','exportTrace','Snapshot','registry')) {
    $badArgs=$argsMap.Clone();$badArgs.action=$action
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.shader_api -Arguments $badArgs)) "$action not broadened by snapshot adapter"
}
$badArgs=$argsMap.Clone();$badArgs.mutation=@{action='clear_all_caches'}
Check (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.shader_api -Arguments $badArgs)) 'mutation-bearing snapshot arguments refused'
foreach ($case in @('active','outstanding','heavy','transition','disabled','zero','incoherent','failed712','historical','replay')) {
    $bad=Clone-Seed;$c=$bad.result.snapshot.compilation
    switch ($case) {
        active {$c.active=$true};outstanding {$c.completedTasks=99};heavy {$c.heavyTasksInFlight=1}
        transition {$bad.result.snapshot.customShaders.transitionPending=$true}
        disabled {$bad.result.snapshot.customShaders.requested=$false;$bad.result.snapshot.customShaders.effective=$false}
        zero {$c.totalTasks=0;$c.completedTasks=0}
        incoherent {$c.completedTasks=101}
        failed712 {$c.failedTasks=733;$c.currentFailedShaders=712;$c.totalTasks=833}
        historical {$c.recentFailures=@([pscustomobject]@{key='Lighting';path='Lighting.hlsl';error='cannot open Wetterness/PuddleMask.hlsli';epoch=1;frame=99})}
        replay {$bad.result | Add-Member idempotentReplay $true}
    }
    $h=Get-DevBenchShaderCompilerHealth -Arguments $argsMap -Content @($bad)
    Check ($h.readQualified -and -not $h.admissible) "$case valid diagnostic read is not healthy admission"
    $semantic=Get-DevBenchCallSemanticStatus -ToolName communityshaders.shader_api -Arguments $argsMap -Content @($bad)
    Check ($semantic.ok -and -not $semantic.compilerHealth.admissible) "$case API/read PASS is not compiler PASS"
}
foreach ($case in @('stringCounter','fractional','boolCounter','negative','overflow','missing','stringFlag','wrongService','arrayService','wrongBuild','wrongCommand','wrongSession','nestedError','outerError','multiple','missingFailures','tooManyFailures','stringReplay','stringMajor','foreignStatus','futureSchema')) {
    $bad=Clone-Seed;$content=@($bad)
    switch($case) {
        stringCounter {$bad.result.snapshot.compilation.totalTasks='100'}
        fractional {$bad.result.snapshot.compilation.completedTasks=99.5}
        boolCounter {$bad.result.snapshot.compilation.failedTasks=$false}
        negative {$bad.result.snapshot.compilation.currentFailedShaders=-1}
        overflow {$bad.result.snapshot.compilation.totalTasks=[decimal]::MaxValue}
        missing {$bad.result.snapshot.compilation.PSObject.Properties.Remove('active')}
        stringFlag {$bad.result.snapshot.available='true'}
        wrongService {$bad.contract.name='foreign'};arrayService {$bad.contract.name=@('csx.shader')}
        wrongBuild {$bad.server.buildId='foreign'};wrongCommand {$bad.command.commandId='foreign'}
        wrongSession {$bad.server.serviceSessionId='foreign'}
        nestedError {$bad.result.snapshot | Add-Member error 'failed'}
        outerError {$bad | Add-Member error 'failed'}
        multiple {$content=@($bad,$bad)}
        missingFailures {$bad.result.snapshot.compilation.PSObject.Properties.Remove('recentFailures')}
        tooManyFailures {$bad.result.snapshot.compilation.recentFailures=@(1..33)}
        stringReplay {$bad.result | Add-Member idempotentReplay 'false'}
        stringMajor {$bad.contract.major='1'};foreignStatus {$bad.result.status='failed'};futureSchema {$bad.contract.schemaRevision=2}
    }
    $h=Get-DevBenchShaderCompilerHealth -Arguments $argsMap -Content $content
    Check (-not $h.readQualified -and -not $h.admissible) "$case refuses malformed/foreign compiler evidence"
}
Check ((Test-DevBenchShaderCompilerWindow -Before $health -After $health).valid) 'unchanged admitted boundaries qualify bracket only'
$unavailable=Clone-Seed;$unavailable.ok=$false;$unavailable.PSObject.Properties.Remove('result')
$unavailable | Add-Member error ([pscustomobject]@{code='main_thread_dispatch_failed';message='main thread did not run within 5000ms';phase='admission';retryable=$true;field=$null;requestId=$null;details=[pscustomobject]@{}})
$unavailableHealth=Get-DevBenchShaderCompilerHealth -Arguments $argsMap -Content @($unavailable)
Check (-not $unavailableHealth.readQualified -and -not $unavailableHealth.admissible -and $unavailableHealth.state -ceq 'READ_UNAVAILABLE' -and $null -eq $unavailableHealth.compilation) 'main-thread read unavailable is not an invented compiler failure/counter snapshot'
Check ($unavailableHealth.unavailableEnvelopeQualified -and $unavailableHealth.nativeRetryable) 'strict native admission unavailable envelope qualifies without successful snapshot fields'
foreach($case in @('wrongClient','wrongAction','stringMajor','futureMinor','contractExtra','commandExtra','producerExtra','producerArray','sessionMismatch','boolProducer','missingErrorField','unknownCode','emptyMessage','arrayError','arrayDetails','populatedDetails','mutationField','mutationReceipt','stringReplay','contradictoryStatus')) {
    $bad=$unavailable|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30 -DateKind String
    switch($case) {
        wrongClient {$bad.command.clientId='wrong'};wrongAction {$bad.command.action='execute'}
        stringMajor {$bad.contract.major='1'};futureMinor {$bad.contract.minor=1}
        contractExtra {$bad.contract|Add-Member success $true}
        commandExtra {$bad.command|Add-Member contractMajor 1}
        producerExtra {$bad.server|Add-Member error 'contradiction'}
        producerArray {$bad.server=@($bad.server)}
        sessionMismatch {$bad.server.sessionId='different'}
        boolProducer {$bad.server.manifestVerified='false'}
        missingErrorField {$bad.error.PSObject.Properties.Remove('field')}
        unknownCode {$bad.error.code='unknown'};emptyMessage {$bad.error.message=''}
        arrayError {$bad.error=@($bad.error)}
        arrayDetails {$bad.error.details=@()}
        populatedDetails {$bad.error.details|Add-Member success $true}
        mutationField {$bad.error.field='mutation'};mutationReceipt {$bad.error.requestId='foreign-receipt'}
        stringReplay {$bad|Add-Member idempotentReplay 'false'}
        contradictoryStatus {$bad|Add-Member result ([pscustomobject]@{status='success'})}
    }
    $raw=$bad|ConvertTo-Json -Depth 30 -Compress
    $h=Get-DevBenchShaderCompilerHealth -Arguments $argsMap -Content @($bad)
    Check (-not $h.unavailableEnvelopeQualified -and -not $h.nativeRetryable -and -not $h.admissible -and $h.state -ceq 'INDETERMINATE') "$case terminal unavailable schema cannot gain retry classification"
    Check (($bad|ConvertTo-Json -Depth 30 -Compress) -ceq $raw -and $null -eq $h.compilation) "$case retains unavailable native bytes without successful counters"
}
foreach($case in @('session','build','revision','newTask','newCompile','cacheHit')) {
    $after=$health | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String
    switch($case) {session {$after.serviceSessionId='foreign'};build {$after.buildId='foreign'};revision {$after.stateRevision++};newTask {$after.compilation.totalTasks++};newCompile {$after.compilation.sourceCompiles++};cacheHit {$after.compilation.diskCacheHits++}}
    Check (-not (Test-DevBenchShaderCompilerWindow -Before $health -After $after).valid) "$case invalidates compiler evidence bracket"
}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('compiler-health-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$mixedUnavailableCases=@('wait-unavailable-command','wait-unavailable-build','wait-unavailable-session','wait-unavailable-schema','wait-unavailable-stale','wait-unavailable-future','wait-unavailable-extra','wait-unavailable-result','wait-unavailable-error-shape','wait-unavailable-replay','wait-unavailable-nonretryable')
foreach($case in (@('healthy','failed','pending','main-thread-unavailable','after-failed','after-unavailable','after-timeout','after-http503','after-session','after-task','mcp-error','schema-missing','no-guard','skip-refused','wait-initializing','wait-zero-timeout','wait-unavailable-timeout','wait-failed','wait-foreign-session','wait-malformed','wait-stale','wait-replay','wait-schema-missing','wait-skip-refused','wait-target-refused','wait-late','wait-listener-lost','wait-unavailable-healthy')+$mixedUnavailableCases)) {
    if($ConsoleDispatch -and $case -cnotin @('healthy','after-failed','after-unavailable','after-timeout','after-http503')){continue}
    if(-not $ConsoleDispatch -and $case -cin @('after-unavailable','after-timeout','after-http503')){continue}
    if($EntryCaseFilter -and $case -cne $EntryCaseFilter){continue}
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    $port=$listener.LocalEndpoint.Port
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $seedJson=$seed | ConvertTo-Json -Depth 30 -Compress
    $server=Start-ThreadJob -ArgumentList $listener,$case,$seedJson,$events,$PID,$port,$ConsoleDispatch.IsPresent -ScriptBlock {
        param($Listener,$Case,$SeedJson,$Events,$OwnerPid,$Port,$ConsoleDispatch)
        $ErrorActionPreference='Stop';$snapshots=0
        try {
            while($true) {
                $client=$Listener.AcceptTcpClient()
                try {
                    $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
                    $first=$reader.ReadLine();$length=0;$headers=@{}
                    while($null -ne ($line=$reader.ReadLine()) -and $line -ne '') {
                        $pair=$line.Split(':',2);$headers[$pair[0]]=$pair[1].Trim()
                        if($pair[0] -ieq 'Content-Length') {$length=[int]$pair[1]}
                    }
                    $buffer=[char[]]::new($length);$offset=0
                    while($offset -lt $length) {$n=$reader.Read($buffer,$offset,$length-$offset);if($n -eq 0){throw 'truncated fixture request'};$offset+=$n}
                    $replyHeaders='';$body='{}';$status='200 OK'
                    if($first.StartsWith('DELETE')) {$Events.Enqueue([pscustomobject]@{kind='delete'})}
                    else {
                        $rpc=(-join $buffer) | ConvertFrom-Json -Depth 30
                        $toolName=if($rpc.PSObject.Properties['params'] -and $rpc.params.PSObject.Properties['name']){$rpc.params.name}else{$null}
                        $Events.Enqueue([pscustomobject]@{kind=$rpc.method;tool=$toolName;session=$headers['Mcp-Session-Id']})
                        $result=@{}
                        switch($rpc.method) {
                            initialize {$lateReplyUtc=[DateTime]::UtcNow.AddMilliseconds(2050);$replyHeaders="Mcp-Session-Id: compiler-fixture" + [char]13 + [char]10;$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='fixture';version='ad8'}}}
                            'notifications/initialized' {$status='204 No Content';$body=''}
                            'tools/list' {
                                $enum=if($Case -cin @('schema-missing','wait-schema-missing')){@('registry')}else{@('registry','snapshot')}
                                $result=@{tools=@(@{name='inspect';inputSchema=@{}},@{name='console';inputSchema=@{}},@{name='fixture.target';inputSchema=@{}},@{name='communityshaders.shader_api';inputSchema=@{type='object';required=@('contractMajor','clientId','commandId','action');properties=@{contractMajor=@{type='integer';const=1};clientId=@{type='string'};commandId=@{type='string'};action=@{type='string';enum=$enum}}}})}
                            }
                            'tools/call' {
                                $payload=$SeedJson | ConvertFrom-Json -Depth 30
                                if($rpc.params.name -ceq 'inspect') {$payload=@{pid=$OwnerPid;exe='pwsh.exe';port=$Port;frame=100;lastTaskFrame=-1;pendingTasks=0;vr=$true}}
                                elseif($rpc.params.name -ceq 'fixture.target') {$Events.Enqueue([pscustomobject]@{kind='target'});$payload=@{ok=$true}}
                                elseif($rpc.params.name -ceq 'console') {$Events.Enqueue([pscustomobject]@{kind='target'});$payload=@{command=$rpc.params.arguments.command;queued=$true;capturing=$false}}
                                elseif($rpc.params.arguments.action -ceq 'registry') {$payload=@{ok=$true;server=$payload.server;result=@{service='csx.shader'}}}
                                else {
                                    $snapshots++;$Events.Enqueue([pscustomobject]@{kind='snapshot';commandId=$rpc.params.arguments.commandId})
                                    $payload.command=[pscustomobject]@{action=$rpc.params.arguments.action;clientId=$rpc.params.arguments.clientId;commandId=$rpc.params.arguments.commandId}
                                    $payload.timestampUtc=[DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                                    if($Case -ceq 'failed' -or ($Case -ceq 'after-failed' -and $snapshots -eq 2)) {$payload.result.snapshot.compilation.failedTasks=1;$payload.result.snapshot.compilation.currentFailedShaders=1}
                                    if($Case -ceq 'pending') {$payload.result.snapshot.compilation.active=$true}
                                    if($Case -ceq 'main-thread-unavailable') {$payload.ok=$false;$payload.PSObject.Properties.Remove('result');$payload | Add-Member error ([pscustomobject]@{code='main_thread_dispatch_failed';message='main thread did not run within 5000ms';retryable=$true;phase='admission';field=$null;requestId=$null;details=[pscustomobject]@{}})}
                                    if($Case -ceq 'after-unavailable' -and $snapshots -eq 2){$payload.ok=$false;$payload.PSObject.Properties.Remove('result');$payload|Add-Member error ([pscustomobject]@{code='main_thread_dispatch_failed';message='bounded post-dispatch read unavailable';retryable=$true;phase='admission';field=$null;requestId=$null;details=[pscustomobject]@{}})}
                                    if($Case -ceq 'after-timeout' -and $snapshots -eq 2){Start-Sleep -Milliseconds 1500}
                                    if($Case -ceq 'after-http503' -and $snapshots -eq 2){$status='503 Service Unavailable'}
                                    if($Case -ceq 'after-session' -and $snapshots -eq 2) {$payload.server.serviceSessionId='replaced';$payload.server.sessionId='replaced'}
                                    if($Case -ceq 'after-task' -and $snapshots -eq 2) {$payload.result.snapshot.compilation.totalTasks++;$payload.result.snapshot.compilation.completedTasks++}
                                    if($Case -ceq 'wait-zero-timeout' -or ($Case -ceq 'wait-initializing' -and $snapshots -eq 1)) {$payload.result.snapshot.compilation.totalTasks=0;$payload.result.snapshot.compilation.completedTasks=0}
                                    if($Case -ceq 'wait-initializing' -and $snapshots -eq 2) {$payload.result.snapshot.compilation.active=$true}
                                    if($Case -ceq 'wait-failed') {$payload.result.snapshot.compilation.failedTasks=1;$payload.result.snapshot.compilation.currentFailedShaders=1}
                                    if($Case -ceq 'wait-foreign-session') {$payload.server.sessionId='foreign';$payload.server.serviceSessionId='foreign'}
                                    if($Case -ceq 'wait-malformed') {$payload.result.snapshot.compilation.totalTasks='100'}
                                    if($Case -ceq 'wait-stale') {$payload.timestampUtc=[DateTimeOffset]::UtcNow.AddSeconds(-60).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
                                    if($Case -ceq 'wait-replay') {$payload.result|Add-Member idempotentReplay $true}
                                    if($Case -ceq 'wait-unavailable-timeout') {$payload.ok=$false;$payload.PSObject.Properties.Remove('result');$payload|Add-Member error ([pscustomobject]@{code='main_thread_dispatch_failed';message='bounded fixture read unavailable';retryable=$true;phase='admission';field=$null;requestId=$null;details=[pscustomobject]@{}})}
                                    if($Case.StartsWith('wait-unavailable-') -and $Case -cne 'wait-unavailable-timeout' -and $snapshots -eq 1) {
                                        $payload.command=[pscustomobject]@{action='snapshot';clientId=$rpc.params.arguments.clientId;commandId=$rpc.params.arguments.commandId}
                                        $payload.ok=$false;$payload.PSObject.Properties.Remove('result')
                                        $payload|Add-Member error ([pscustomobject]@{code='main_thread_dispatch_failed';message='bounded native admission unavailable';phase='admission';retryable=$true;field=$null;requestId=$null;details=[pscustomobject]@{}})
                                        switch($Case) {
                                            'wait-unavailable-command' {$payload.command.commandId='wrong-first-command'}
                                            'wait-unavailable-build' {$payload.server.buildId='wrong-first-build'}
                                            'wait-unavailable-session' {$payload.server.sessionId='foreign-first-session';$payload.server.serviceSessionId='foreign-first-session'}
                                            'wait-unavailable-schema' {$payload.contract.schemaRevision=2}
                                            'wait-unavailable-stale' {$payload.timestampUtc=[DateTimeOffset]::UtcNow.AddSeconds(-60).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
                                            'wait-unavailable-future' {$payload.timestampUtc=[DateTimeOffset]::UtcNow.AddSeconds(60).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
                                            'wait-unavailable-extra' {$payload|Add-Member success $true}
                                            'wait-unavailable-result' {$payload|Add-Member result ([pscustomobject]@{status='success'})}
                                            'wait-unavailable-error-shape' {$payload.error.retryable='true'}
                                            'wait-unavailable-replay' {$payload|Add-Member idempotentReplay $true}
                                            'wait-unavailable-nonretryable' {$payload.error.retryable=$false;$payload.error.phase='execution'}
                                        }
                                        $Events.Enqueue([pscustomobject]@{kind='firstUnavailable';payloadJson=($payload|ConvertTo-Json -Depth 30 -Compress)})
                                    }
                                    if($Case -ceq 'wait-late') {$remaining=($lateReplyUtc-[DateTime]::UtcNow).TotalMilliseconds;if($remaining -gt 0){Start-Sleep -Milliseconds ([int][Math]::Ceiling($remaining))}}
                                }
                                $result=@{isError=$Case -ceq 'mcp-error' -and $rpc.params.name -ceq 'communityshaders.shader_api' -and $rpc.params.arguments.action -ceq 'snapshot';content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 30 -Compress)})}
                            }
                        }
                        if($rpc.method -cne 'notifications/initialized') {$body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 40 -Compress}
                    }
                    $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                    $crlf=[string][char]13+[char]10
                    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status"+$crlf+"Content-Type: application/json"+$crlf+"Content-Length: $($bytes.Length)"+$crlf+$replyHeaders+"Connection: close"+$crlf+$crlf)
                    try{$stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}catch{if($Case -cne 'after-timeout'){throw}}
                    if($Case -ceq 'wait-listener-lost' -and $snapshots -gt 0) {$Listener.Stop();break}
                } finally {$client.Close()}
            }
        } finally {$Listener.Stop()}
    }
    try {
        $fixture=Join-Path $root $case;New-Item -ItemType Directory -Path $fixture|Out-Null
        $artifact=Join-Path $fixture 'fixture.dll';[IO.File]::WriteAllText($artifact,'not-a-native-artifact')
        $runtime=Join-Path $fixture 'runtime.json'
        @{port=$port;pid=$PID;buildId='ad8-fixture';artifactPath=$artifact;artifactSha256=(Get-FileHash $artifact -Algorithm SHA256).Hash}|ConvertTo-Json|Set-Content -LiteralPath $runtime
        $isWait=$case.StartsWith('wait-')
        $flags=@{}
        if($isWait) {
            $flags.Command='wait';$flags.Condition='compilerHealthy';$flags.PollMilliseconds=50
            $flags.TimeoutSeconds=if($case -ceq 'wait-late'){2}elseif($case -cin @('wait-zero-timeout','wait-unavailable-timeout')){3}else{10}
            if($case -ceq 'wait-skip-refused'){$flags.SkipRuntimeIdentityVerification=$true}
            if($case -ceq 'wait-target-refused'){$flags.Tool='fixture.target';$flags.ArgumentsJson='{}'}
        } else {
            $flags.Command='call';$flags.Tool='fixture.target';$flags.ArgumentsJson='{}';$flags.TimeoutSeconds=15
            if($ConsoleDispatch){$flags.Tool='console';$flags.ArgumentsJson='{"action":"exec","command":"coc QASmoke","capture":false}';$flags.TimeoutSeconds=20;if($case -ceq 'after-timeout'){$flags.RequestTimeoutSeconds=1}}
            if($case -cne 'no-guard'){$flags.RequireCompilerHealthy=$true}
            if($case -ceq 'skip-refused'){$flags.SkipRuntimeIdentityVerification=$true}
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        if(-not $ProductionRetryDefaults){$flags.MaxTransientRetries=0}
        $reply=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') -RuntimePath $runtime -EvidenceDirectory $fixture -Compact -NoExit @flags | ConvertFrom-Json -Depth 60
        $clock.Stop()
        $reply|ConvertTo-Json -Depth 60|Set-Content -LiteralPath (Join-Path $fixture 'result.json')
        $calls=@($events.ToArray());$targets=@($calls|Where-Object kind -eq 'target').Count
        if($isWait) {
            Check ($targets -eq 0 -and @($calls|Where-Object {$_.kind -ceq 'tools/call' -and $_.tool -cnotin @('inspect','communityshaders.shader_api')}).Count -eq 0) "$case wait issues no load/camera/target mutation"
            $snapshots=@($calls|Where-Object kind -eq 'snapshot')
            if($case -cin $mixedUnavailableCases) {
                Check (-not $reply.ok -and -not $reply.data.satisfied -and $reply.data.observation.terminalFailure -and $snapshots.Count -eq 1) "$case terminal first response cannot be replaced by hypothetical healthy second read"
                $firstUnavailable=@($calls|Where-Object kind -CEQ 'firstUnavailable')
                $retained=$reply.data.observation.compilerGuard.reply.rawResult.content[0].text
                Check ($firstUnavailable.Count -eq 1 -and $retained -ceq $firstUnavailable[0].payloadJson -and @($reply.data.observation.compilerGuard.reasons).Count -gt 0) "$case preserves exact first unavailable payload and refusal reasons"
            } elseif($case -ceq 'wait-unavailable-healthy') {
                Check ($reply.ok -and $reply.data.satisfied -and $snapshots.Count -eq 2) 'strict canonical unavailable may observe a fresh healthy snapshot within original deadline'
                Check (@($snapshots.commandId|Sort-Object -Unique).Count -eq 2 -and @($calls|Where-Object kind -CEQ 'initialize').Count -eq 1) 'canonical unavailable continuation uses fresh IDs in the original owned MCP session'
            } elseif($case -ceq 'wait-initializing') {
                Check ($reply.ok -and $reply.data.satisfied -and $snapshots.Count -eq 3 -and $reply.data.observation.compilerGuard.health.compilation.totalTasks -gt 0) 'wait admits zero-to-pending-to-healthy only after fresh positive tasks'
                Check (@($snapshots.commandId|Sort-Object -Unique).Count -eq 3) 'wait snapshot IDs never replay accepted reads or mutations'
                Check (@($calls|Where-Object kind -eq 'initialize').Count -eq 1) 'normal readiness wait retains one selected MCP session'
            } else {
                Check (-not $reply.ok) "$case wait refuses readiness"
                if($case -cin @('wait-zero-timeout','wait-unavailable-timeout')) {
                    $expected=if($case -ceq 'wait-zero-timeout'){'COMPILATION_UNPROVEN'}else{'READ_UNAVAILABLE'}
                    Check (-not $reply.data.satisfied -and $reply.data.observation.classification -ceq $expected -and $snapshots.Count -ge 1 -and $clock.Elapsed.TotalSeconds -lt 8) "$case bounded timeout preserves actionable non-failure diagnosis"
                } elseif($case -cin @('wait-failed','wait-foreign-session','wait-malformed','wait-stale','wait-replay')) {
                    Check ($reply.data.observation.terminalFailure -and $snapshots.Count -eq 1) "$case stops on first terminal snapshot rather than waiting for recovery"
                } elseif($case -ceq 'wait-schema-missing') {
                    Check ($reply.data.observation.terminalFailure -and $snapshots.Count -eq 0) 'wait missing snapshot capability refused without snapshot or target dispatch'
                } elseif($case -cin @('wait-skip-refused','wait-target-refused')) {
                    Check (@($calls|Where-Object kind -eq 'initialize').Count -eq 0) "$case rejected before session creation"
                } elseif($case -ceq 'wait-late') {
                    Check ($clock.Elapsed.TotalSeconds -lt 5 -and -not $reply.ok) 'late compiler read cannot become successful readiness beyond fixed budget'
                } elseif($case -ceq 'wait-listener-lost') {
                    Check (@($reply.errors|Where-Object {$_ -match 'runtime identity changed'}).Count -gt 0) 'listener loss across snapshot refuses ready identity'
                }
            }
        }
        elseif($case -cin @('healthy','no-guard')) {Check ($reply.ok -and $targets -eq 1) "$case production entry dispatches target exactly once"}
        else {Check (-not $reply.ok) "$case production entry refuses healthy promotion"}
        if($case -cin @('failed','pending','main-thread-unavailable','mcp-error','schema-missing','skip-refused')) {Check ($targets -eq 0 -and -not $reply.dispatchReached) "$case production entry proves zero target dispatch"}
        if($case -ceq 'main-thread-unavailable') {Check ($reply.data.compilerGuard.state -ceq 'READ_UNAVAILABLE' -and $reply.data.compilerGuard.reply.content[0].error.code -ceq 'main_thread_dispatch_failed' -and $null -eq $reply.data.compilerGuard.health.compilation) 'production entry retains native unavailable read without accepting counters or touching compile'}
        if($case -ceq 'mcp-error') {Check ($reply.data.compilerGuard.reply.rawResult.isError -and $null -eq $reply.data.compilerGuard.health) 'MCP error raw reply is retained without positive schema/counters'}
        if($case.StartsWith('after-')) {Check ($targets -eq 1 -and $reply.dispatchReached -and $reply.data.targetSemantic.ok -and -not $reply.data.healthyEvidenceAdmitted) "$case preserves completed target receipt without healthy promotion or replay"}
        if($ConsoleDispatch){
            Check ($reply.acceptedDataRetained -and $reply.responseDataRetained -and $targets -eq 1) "$case accepted dispatch remains retained despite later qualification"
            Check ($reply.data.dispatchEvidence.accepted -and -not $reply.data.dispatchEvidence.executionCompleted -and -not $reply.data.dispatchEvidence.arrivalProven -and -not $reply.data.dispatchEvidence.replayPermitted) "$case retained queue admission is not arrival/replay"
            Check ($reply.data.dispatchEvidence.receipt.command -ceq 'coc QASmoke' -and $reply.data.dispatchEvidence.receipt.queued -eq $true -and $reply.data.dispatchEvidence.receipt.capturing -eq $false) "$case exact native queue receipt retained"
            Check ($reply.data.compilerQualification.admitted -eq ($case -ceq 'healthy') -and -not $reply.data.compilerQualification.arrivalProven) "$case compiler qualification is separate"
            if($case -cin @('after-unavailable','after-timeout','after-http503')){Check (($null -eq $reply.data.compilerGuardAfter.health -or $null -eq $reply.data.compilerGuardAfter.health.compilation) -and $reply.data.compilerQualification.afterState -ceq 'READ_UNAVAILABLE') "$case no invented shader-failure counters"}
            if($ProductionRetryDefaults -and $case -cin @('after-timeout','after-http503')){
                Check (@($calls|Where-Object kind -ceq 'snapshot').Count -eq 2) "$case production retry defaults cannot replace first post-boundary read with later healthy data"
                Check ($reply.data.compilerGuardAfter.transportFailure.attempt -eq 1 -and $reply.data.compilerGuardAfter.transportFailure.recovery -ceq 'not-retried-boundary-read') "$case first boundary transport failure retained separately from accepted dispatch"
                Check (@($reply.transportRetries|Where-Object recovery -ceq 'not-retried-boundary-read').Count -eq 1) "$case terminal first-failure transport record retained"
            }
            if($case -cne 'healthy'){Check ($reply.semantic.outcome -ceq 'compiler-admission-invalidated' -and -not $reply.ok) "$case overall compiler gate remains failed"}
        }
        if($case -ceq 'healthy') {
            Check ($reply.runtimeIdentity.complete -and $reply.runtimeIdentity.verified -and $reply.data.healthyEvidenceAdmitted -and $reply.data.compilerWindow.valid) 'healthy entry binds real fixture listener/process/artifact with two compiler boundaries'
            $ids=@($calls|Where-Object kind -eq 'snapshot'|ForEach-Object commandId)
            Check ($ids.Count -eq 2 -and $ids[0] -cne $ids[1]) 'guard uses fresh non-replayed snapshot command IDs'
        }
        if($case -ceq 'wait-late' -and $ExpectExpiredCleanupEvidence){
            Check (-not $reply.ok -and $reply.semantic.outcome -ceq 'wait-timeout' -and -not $reply.sessionCleanup.ok -and -not $reply.sessionCleanup.attempted -and $reply.sessionCleanup.indeterminate) 'late read retains explicit unverified cleanup without deadline extension'
            Check (@($calls|Where-Object kind -eq 'delete').Count -eq 0 -and $reply.sessionCleanup.sessions.Count -eq 1 -and $reply.sessionCleanup.sessions[0].sessionId -ceq 'compiler-fixture' -and $reply.sessionCleanup.sessions[0].state -ceq 'not_attempted_deadline_exhausted' -and $reply.sessionCleanup.sessions[0].timeoutMilliseconds -eq 0) 'late cleanup starts no DELETE and binds exact expired session evidence'
        }elseif($case -cnotin @('skip-refused','wait-skip-refused','wait-target-refused','wait-listener-lost')) {Check ($reply.sessionCleanup.ok -and @($calls|Where-Object kind -eq 'delete').Count -eq 1) "$case closes one owned fixture MCP session"}
        $reply|ConvertTo-Json -Depth 60|Set-Content -LiteralPath (Join-Path $fixture 'result.json')
    } finally {$listener.Stop();Stop-Job $server;Remove-Job $server}
}
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);fixture=$root;scope='offline source-derived fixtures and test-owned loopback production entry; no Skyrim/live qualification'}|ConvertTo-Json -Depth 6

