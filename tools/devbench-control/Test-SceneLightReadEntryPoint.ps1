# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-SceneLightReadEvidence.ps1'),[ref]$tokens,[ref]$errors)
$assignment=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'seed'},$true)
if($errors.Count -or -not $assignment){throw 'Exact source-derived seed assignment unavailable'}
. ([scriptblock]::Create($assignment.Extent.Text))
$seedJson=$seed|ConvertTo-Json -Depth 40 -Compress
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('scene-light-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
foreach($case in @('accepted','scope-mismatch','string-truncated','extension','mcp-error','read-only-identity')) {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    $port=$listener.LocalEndpoint.Port
    $events=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $server=Start-ThreadJob -ArgumentList $listener,$case,$events,$PID,$port,$seedJson -ScriptBlock {
        param($Listener,$Case,$Events,$OwnerPid,$Port,$SeedJson)
        $ErrorActionPreference='Stop'
        try { while($true) {
            $client=$Listener.AcceptTcpClient()
            try {
                $stream=$client.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
                $first=$reader.ReadLine();$length=0
                while($null -ne ($line=$reader.ReadLine()) -and $line -ne '') { $pair=$line.Split(':',2);if($pair[0] -ieq 'Content-Length'){$length=[int]$pair[1]} }
                $buffer=[char[]]::new($length);$offset=0
                while($offset -lt $length){$n=$reader.Read($buffer,$offset,$length-$offset);if($n -eq 0){throw 'truncated fixture request'};$offset+=$n}
                $extra='';$body='{}';$status='200 OK'
                if($first.StartsWith('DELETE')){$Events.Enqueue('delete')}
                else {
                    $rpc=(-join $buffer)|ConvertFrom-Json -Depth 40;$result=@{}
                    switch($rpc.method) {
                        initialize {$extra="Mcp-Session-Id: scene-light-fixture" + [char]13 + [char]10;$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='fixture';version='1'}}}
                        'notifications/initialized' {$status='204 No Content';$body=''}
                        'tools/list' {$result=@{tools=@(@{name='inspect';inputSchema=@{}},@{name='console-unused';inputSchema=@{}},@{name='communityshaders.shader_api';inputSchema=@{type='object';properties=@{action=@{type='string';enum=@('registry')}}}})}}
                        'tools/call' {
                            if($rpc.params.name -ceq 'inspect' -and $rpc.params.arguments.kind -ceq 'lights') {
                                $Events.Enqueue('dispatch')
                                $payload=$SeedJson|ConvertFrom-Json -Depth 40
                                if($Case -ceq 'scope-mismatch'){$payload.scope='ref'}
                                if($Case -ceq 'string-truncated'){$payload.truncated='false'}
                                if($Case -ceq 'extension'){$payload|Add-Member ok $true}
                            } elseif($rpc.params.name -ceq 'inspect') {$payload=@{ok=$true;pid=$OwnerPid;exe='pwsh.exe';port=$Port;frame=100;lastTaskFrame=-1;pendingTasks=0;vr=$true}}
                            else {$payload=@{ok=$true;server=@{component='CommunityShaders';buildId='scene-light-fixture';sourceCommit=('a'*40);shaderCacheAbiId='fixture';serviceSessionId='fixture'}}}
                            $result=@{isError=($Case -ceq 'mcp-error' -and $rpc.params.name -ceq 'inspect' -and $rpc.params.arguments.kind -ceq 'lights');content=@(@{type='text';text=($payload|ConvertTo-Json -Depth 40 -Compress)})}
                        }
                    }
                    if($rpc.method -cne 'notifications/initialized'){$body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 45 -Compress}
                }
                $bytes=[Text.Encoding]::UTF8.GetBytes($body);$crlf=[string][char]13+[char]10
                $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status"+$crlf+"Content-Type: application/json"+$crlf+"Content-Length: $($bytes.Length)"+$crlf+$extra+"Connection: close"+$crlf+$crlf)
                $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            } finally {$client.Close()}
        }} finally {$Listener.Stop()}
    }
    try {
        $fixture=Join-Path $root $case;[IO.Directory]::CreateDirectory($fixture)|Out-Null
        $artifact=Join-Path $fixture 'fixture.dll';[IO.File]::WriteAllText($artifact,'not-native')
        $runtime=Join-Path $fixture 'runtime.json'
        $metadata=@{port=$port;pid=$PID;buildId='scene-light-fixture'}
        if($case -cne 'read-only-identity'){$metadata.artifactPath=$artifact;$metadata.artifactSha256=(Get-FileHash $artifact).Hash}
        [IO.File]::WriteAllText($runtime,($metadata|ConvertTo-Json))
        $reply=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') call -Tool inspect -ArgumentsJson '{"kind":"lights","scope":"scene","limit":40}' -RuntimePath $runtime -EvidenceDirectory $fixture -RequireSuccess -TimeoutSeconds 15 -MaxTransientRetries 0 -NoExit -Compact | ConvertFrom-Json -Depth 80
        $calls=@($events.ToArray());$count=@($calls|Where-Object {$_ -ceq 'dispatch'}).Count
        Check ($reply.sessionCleanup.ok -and @($calls|Where-Object {$_ -ceq 'delete'}).Count -eq 1) "$case exact owned session closed"
        if($case -cin @('accepted','read-only-identity')) {
            Check ($reply.ok -and $count -eq 1 -and $reply.dispatchReached) 'actual controller admits one bounded read'
            Check (-not $reply.semantic.visibleIlluminationProven -and -not $reply.semantic.wholeSceneCoverageProven -and $reply.semantic.completionBasis -ceq 'bounded-read-only') 'public result preserves bounded admission meaning'
            Check ($reply.runtimeIdentity.verified -and ($reply.runtimeIdentity.complete -eq ($case -ceq 'accepted'))) 'read-only identity still verified without mutation provenance bypass'
        }
        else {Check (-not $reply.ok -and $count -eq 1 -and $reply.dispatchReached) "$case refuses and never replays"}
        Check (Test-Path -LiteralPath $reply.invocationEvidencePath -PathType Leaf) "$case journal retained"
        [IO.File]::WriteAllText((Join-Path $fixture 'result.json'),($reply|ConvertTo-Json -Depth 80))
    } finally {$listener.Stop();Stop-Job $server;Remove-Job $server}
}
[pscustomobject]@{ok=$true;checks=$checks;fixture=$root;scope='actual public controller, test-owned loopback; no Skyrim/runtime deployment'}|ConvertTo-Json -Compress
