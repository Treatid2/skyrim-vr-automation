# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$passes=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('new-game-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Controller syntax error'}
$reader=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ListenerPid'},$true))[0]
Invoke-Expression $reader.Extent.Text
foreach($case in @('inspect','known-request','request','confirm','uncertain','foreign-id','error','negative','stale','bad-phase-schema','policy-main','policy-fixture','missing-manifest','bad-confirm','nested','request-503','confirm-503','default-inspect')) {
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
    $ready=[Threading.ManualResetEventSlim]::new($false)
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $identity=[hashtable]::Synchronized(@{pid=0})
    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$port/")
    $server=Start-ThreadJob -ArgumentList $port,$case,$ready,$events,$identity,$listener -ScriptBlock {
        param($Port,$Case,$Ready,$Events,$Identity,$Listener)
        $ErrorActionPreference='Stop'
        try {
            $Listener.Start();$Ready.Set()
            :requests while($Listener.IsListening) {
                $context=$Listener.GetContext();$request=$context.Request;$response=$context.Response;$response.ContentType='application/json'
                if($request.HttpMethod -eq 'DELETE'){$body='{}';$Events.Enqueue([pscustomobject]@{kind='delete'})}
                else {
                    $reader=[IO.StreamReader]::new($request.InputStream)
                    try{$rpc=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
                    if($rpc.method -ceq 'notifications/initialized'){$response.StatusCode=204;$response.Close();continue}
                    $result=@{}
                    switch($rpc.method) {
                        initialize {$response.Headers.Add('Mcp-Session-Id','new-game-fixture');$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='fixture';version='4407a937'}}}
                        'tools/list' {
                            $actions=if($Case -ceq 'stale'){@('load','save')}else{@('load','save','newGame')}
                            $phases=if($Case -ceq 'bad-phase-schema'){@('inspect')}else{@('inspect','request','confirm')}
                            $result=@{tools=@(@{name='inspect';inputSchema=@{}},@{name='scenario';inputSchema=@{}},@{name='game';inputSchema=@{type='object';properties=@{action=@{type='string';enum=$actions};phase=@{type='string';enum=$phases};requestId=@{type='string'};confirmNewGame=@{type='boolean'}}}})}
                        }
                        'tools/call' {
                            if($rpc.params.name -ceq 'inspect') {
                                $payload=@{pid=$Identity.pid;exe='fixture-http-listener';port=$Port;frame=1;lastTaskFrame=-1;pendingTasks=0;vr=$true}
                            }
                            else {
                                $Events.Enqueue([pscustomobject]@{kind='target';tool=$rpc.params.name;arguments=$rpc.params.arguments})
                                if($rpc.params.name -cne 'game'){throw 'Scenario must never dispatch New Game'}
                                if($Case -cin @('request-503','confirm-503')){$response.StatusCode=503;$body='{"error":"busy after dispatch"}';$bytes=[Text.Encoding]::UTF8.GetBytes($body);$response.ContentLength64=$bytes.Length;$response.OutputStream.Write($bytes,0,$bytes.Length);$response.Close();continue requests}
                                $phase=if($rpc.params.arguments.PSObject.Properties['phase']){$rpc.params.arguments.phase}else{'inspect'}
                                if($Case -cin @('inspect','default-inspect','stale')) {
                                    $payload=@{mainMenuOpen=$true;state='Main';moviePath='_root.MenuHolder.Menu_mc';pendingRequestId='';unresolvedRequestId='';newRequestsBlocked=$false;readyToRequest=$true;readyToConfirm=$false;selectedEntryId=0}
                                }
                                else {
                                    $payload=[ordered]@{requestId='exact-id';phase='requested';newRow=1;state='MainConfirm';accepted=$false;completed=$false;unresolvedDispatch=$false}
                                    if($phase -ceq 'confirm'){$payload.phase='dispatched';$payload.accepted=$true}
                                    if($Case -ceq 'uncertain'){$payload.phase='dispatchUncertain';$payload.unresolvedDispatch=$true;$payload.invalidationReason='expired'}
                                    if($Case -ceq 'foreign-id'){$payload.requestId='foreign-id'}
                                    if($Case -ceq 'negative'){$payload.error='native failure';$payload.ok=$true}
                                }
                            }
                            $result=@{isError=$Case -ceq 'error';content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 10 -Compress)})}
                        }
                        default {throw "Unexpected RPC: $($rpc.method)"}
                    }
                    $body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 20 -Compress
                }
                $bytes=[Text.Encoding]::UTF8.GetBytes($body);$response.ContentLength64=$bytes.Length;$response.OutputStream.Write($bytes,0,$bytes.Length);$response.Close()
            }
        }finally{$Listener.Close();$Ready.Set()}
    }
    try {
        if(-not $ready.Wait(5000) -or $server.State -eq 'Failed'){throw 'Fixture failed to start'}
        $ownerPid=Get-ListenerPid -Port $port;if($null -eq $ownerPid){throw 'Ambiguous fixture socket owner'};$identity.pid=[int]$ownerPid
        $fixture=Join-Path $root $case;New-Item -ItemType Directory -Path $fixture|Out-Null
        $runtime=Join-Path $fixture 'runtime.json';@{port=$port}|ConvertTo-Json|Set-Content -LiteralPath $runtime
        $manifest=Join-Path $fixture 'workspace.json'
        $policy=if($case -ceq 'policy-main'){'MainMenuOnly'}elseif($case -ceq 'policy-fixture'){'VerifiedFixture'}else{'FreshGame'}
        @{status='retained';savePolicy=$policy}|ConvertTo-Json|Set-Content -LiteralPath $manifest
        $requestArguments=[ordered]@{action='newGame';phase='request';requestId='exact-id'}
        if($case -cin @('inspect','stale')){$requestArguments=[ordered]@{action='newGame';phase='inspect'}}
        elseif($case -cin @('known-request','uncertain')){$requestArguments.phase='inspect'}
        elseif($case -cin @('confirm','confirm-503','bad-confirm')){$requestArguments.phase='confirm';$requestArguments.confirmNewGame=$case -cne 'bad-confirm'}
        elseif($case -ceq 'default-inspect'){$requestArguments=[ordered]@{action='newGame'}}
        $tool='game'
        if($case -ceq 'nested'){$requestArguments=@{steps=@(@{tool='game';args=$requestArguments})};$tool='scenario'}
        $parameters=@{Tool=$tool;ArgumentsJson=($requestArguments|ConvertTo-Json -Depth 15 -Compress);RuntimePath=$runtime;EvidenceDirectory=$fixture;RequestTimeoutSeconds=1;MaxTransientRetries=4;Compact=$true;NoExit=$true}
        if($case -cne 'missing-manifest'){$parameters.WorkspaceManifestPath=$manifest}
        # Mutation fixtures bypass ONLY physical build/artifact identity. Inspect
        # keeps production listener+typed-health verification, proving read mode.
        if($case -cnotin @('inspect','known-request','uncertain','stale','default-inspect')){$parameters.SkipRuntimeIdentityVerification=$true}
        $response=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') call @parameters|ConvertFrom-Json -Depth 50
        $observed=@($events.ToArray());$dispatches=@($observed|Where-Object kind -eq 'target')
        $expected=if($case -cin @('stale','bad-phase-schema','policy-main','policy-fixture','missing-manifest','bad-confirm','nested')){0}else{1}
        Check ($dispatches.Count -eq $expected) "$case dispatch count $expected (no replay or fallback)"
        Check ($server.State -ne 'Failed') "$case uses supported typed tool only"
        if($case -cin @('inspect','known-request','request','confirm','default-inspect')) {
            Check ($response.ok -and $response.transportOk -and $response.semantic.known) "$case qualifies through real public entrypoint"
            $basis=if($case -ceq 'confirm'){'dispatch-only'}elseif($case -cin @('request','known-request')){'staged-request'}else{'current-menu-state'}
            Check ($response.semantic.completionBasis -ceq $basis) "$case preserves phase-specific completion basis"
        }
        else {Check (-not $response.ok) "$case remains a structured failure"}
        if($case -cin @('stale','bad-phase-schema')){Check (@($response.errors|Where-Object {$_ -match 'toolSchemaUnresolved'}).Count -gt 0) "$case identifies current schema unresolved"}
        if($case -cin @('request-503','confirm-503')){Check ($response.indeterminate -and $dispatches.Count -eq 1) "$case retains uncertain dispatched operation rather than retry"}
        if($case -ceq 'uncertain'){Check ($response.semantic.newRequestsBlocked -and $response.semantic.unresolvedRequestId -ceq 'exact-id') 'known-ID expiry does not clear uncertainty barrier'}
        $journal=Get-Content -LiteralPath $response.invocationEvidencePath -Raw|ConvertFrom-Json -Depth 50
        if($case -cin @('inspect','known-request','uncertain','default-inspect')){Check ($journal.requestMode -ceq 'read-only') "$case has real read-only admission mode"}
        Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'game-launched'))) "$case never launches a game (fixture-only)"
    }finally{$listener.Close();Stop-Job $server;Remove-Job $server;$ready.Dispose()}
}
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);fixture=$root;liveValidated=$false}|ConvertTo-Json -Depth 5
