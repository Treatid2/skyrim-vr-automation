# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$seed=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-calendar-status.schema1.json') -Raw
$checks=0
function Check([bool]$Good,[string]$Label){if(-not $Good){throw $Label};$script:checks++}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('calendar-status-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
foreach($case in @('accepted','stale','unavailable','mcp-error','missing-artifact','historical-failure','foreign-pid','foreign-session')) {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    $port=$listener.LocalEndpoint.Port
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $server=Start-ThreadJob -ArgumentList $listener,$case,$events,$PID,$port,$seed -ScriptBlock {
        param($Listener,$Case,$Events,$OwnerPid,$Port,$Seed)
        $ErrorActionPreference='Stop'
        try {while($true){
            $client=$Listener.AcceptTcpClient()
            try {
                $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
                $first=$reader.ReadLine();$length=0
                while($null -ne ($line=$reader.ReadLine()) -and $line -ne ''){$pair=$line.Split(':',2);if($pair[0] -ieq 'Content-Length'){$length=[int]$pair[1]}}
                $buffer=[char[]]::new($length);$offset=0
                while($offset -lt $length){$n=$reader.Read($buffer,$offset,$length-$offset);if($n -eq 0){throw 'Truncated fixture request'};$offset+=$n}
                $extra='';$body='{}';$status='200 OK'
                if($first.StartsWith('DELETE')){$Events.Enqueue('delete')}
                else {
                    $rpc=(-join $buffer)|ConvertFrom-Json -Depth 40;$result=@{}
                    switch($rpc.method){
                        initialize {$extra="Mcp-Session-Id: calendar-status-fixture"+[char]13+[char]10;$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='fixture';version='1'}}}
                        'notifications/initialized' {$status='204 No Content';$body=''}
                        'tools/list' {$result=@{tools=@(@{name='inspect';inputSchema=@{}},@{name='calendar';inputSchema=@{type='object';required=@('action');properties=@{action=@{type='string';enum=@('status','hold','release')}}}},@{name='communityshaders.shader_api';inputSchema=@{type='object';properties=@{action=@{type='string';enum=@('registry')}}}})}}
                        'tools/call' {
                            if($rpc.params.name -ceq 'calendar'){
                                $Events.Enqueue('dispatch:'+($rpc.params.arguments|ConvertTo-Json -Compress))
                                $payload=$Seed|ConvertFrom-Json -Depth 30
                                $payload.binding.pid=$OwnerPid
                                $payload.binding.processSession='{0}:{1:X16}' -f $OwnerPid, ((Get-Process -Id $OwnerPid).StartTime.ToUniversalTime().ToFileTimeUtc())
                                if($Case -ceq 'foreign-pid'){$payload.binding.pid=82384;$payload.binding.processSession='82384:01DD586E0A0FCA50'}
                                if($Case -ceq 'foreign-session'){$payload.binding.processSession='{0}:01DD586E0A0FCA50' -f $OwnerPid}
                                if($Case -ceq 'stale'){$payload.readbackFresh=$false}
                                if($Case -ceq 'unavailable'){$payload.available=$false;$payload.values=$null}
                                if($Case -ceq 'historical-failure'){$payload.lastTransition.ok=$false;$payload.lastTransition.status='restore_failed'}
                            }elseif($rpc.params.name -ceq 'inspect'){$payload=@{ok=$true;pid=$OwnerPid;exe='pwsh.exe';port=$Port;frame=100;lastTaskFrame=-1;pendingTasks=0;vr=$true}}
                            else{$payload=@{ok=$true;server=@{component='CommunityShaders';buildId='calendar-status-fixture';sourceCommit=('a'*40);shaderCacheAbiId='fixture';serviceSessionId='fixture'}}}
                            $result=@{isError=($Case -ceq 'mcp-error' -and $rpc.params.name -ceq 'calendar');content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 40 -Compress)})}
                        }
                    }
                    if($rpc.method -cne 'notifications/initialized'){$body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 45 -Compress}
                }
                $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
                $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status"+$crlf+"Content-Type: application/json"+$crlf+"Content-Length: $($bytes.Length)"+$crlf+$extra+"Connection: close"+$crlf+$crlf)
                $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            }finally{$client.Close()}
        }}finally{$Listener.Stop()}
    }
    try {
        $fixture=Join-Path $root $case;[IO.Directory]::CreateDirectory($fixture)|Out-Null
        $artifact=Join-Path $fixture 'fixture.dll';[IO.File]::WriteAllText($artifact,'not-native')
        $runtime=Join-Path $fixture 'runtime.json';$metadata=@{port=$port;pid=$PID;buildId='calendar-status-fixture'}
        if($case -cne 'missing-artifact'){$metadata.artifactPath=$artifact;$metadata.artifactSha256=(Get-FileHash $artifact).Hash}
        [IO.File]::WriteAllText($runtime,($metadata|ConvertTo-Json))
        $reply=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') call -Tool calendar -ArgumentsJson '{"action":"status"}' -RuntimePath $runtime -EvidenceDirectory $fixture -RequireSuccess -TimeoutSeconds 15 -MaxTransientRetries 0 -NoExit -Compact | ConvertFrom-Json -Depth 80
        $calls=@($events.ToArray());$dispatches=@($calls|Where-Object {$_.StartsWith('dispatch:')})
        Check ($reply.sessionCleanup.ok -and @($calls|Where-Object {$_ -ceq 'delete'}).Count -eq 1) "$case owned session cleanup"
        if($case -ceq 'missing-artifact'){
            Check (-not $reply.ok -and $dispatches.Count -eq 0 -and -not $reply.dispatchReached) 'Missing artifact identity must refuse before calendar dispatch'
        }else{
            Check ($dispatches.Count -eq 1 -and $dispatches[0] -ceq 'dispatch:{"action":"status"}' -and $reply.dispatchReached) "$case exactly one status call, no mutation/replay"
            Check $reply.runtimeIdentity.complete "$case complete original artifact admission"
            if($case -cin @('accepted','historical-failure')){
                Check ($reply.ok -and $reply.semantic.completionBasis -ceq 'read-schema-only' -and $reply.semantic.runtimeBindingChecked -and $null -ne $reply.semantic.qualifiedCalendarStatus) "$case public current-bound read qualifies"
                Check (-not $reply.semantic.qualifiedCalendarStatus.restored) "$case no restoration inferred"
            }else{Check (-not $reply.ok) "$case public read must fail"}
        }
        Check (Test-Path -LiteralPath $reply.invocationEvidencePath -PathType Leaf) "$case journal retained"
        [IO.File]::WriteAllText((Join-Path $fixture 'result.json'),($reply|ConvertTo-Json -Depth 80))
    }finally{$listener.Stop();Stop-Job $server;Remove-Job $server}
}
[pscustomobject]@{ok=$true;checks=$checks;fixture=$root;scope='Actual controller entry point, test-owned loopback only; no Skyrim/SteamVR';cases=8}|ConvertTo-Json -Compress
