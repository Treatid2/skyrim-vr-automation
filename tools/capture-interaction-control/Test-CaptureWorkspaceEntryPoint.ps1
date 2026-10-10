# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
$root = Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('capture-workspace-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$capture = Join-Path $root 'capture-interaction-control'
$central = Join-Path $root 'devbench-control'
[IO.Directory]::CreateDirectory($capture) | Out-Null
[IO.Directory]::CreateDirectory($central) | Out-Null
foreach ($file in @('Invoke-CaptureInteraction.ps1','CaptureInteractionControl.psm1','actions.v1.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $capture
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control') -File) {
    if ($file.Extension -in @('.ps1','.psm1','.json')) { Copy-Item -LiteralPath $file.FullName -Destination $central }
}
$entry = Join-Path $capture 'Invoke-CaptureInteraction.ps1'
$shim = Join-Path $root 'fixture-service.ps1'
# Recording/input cleanup are synthetic. Game requests cross the REAL copied
# central entry and policy into a test-owned loopback MCP endpoint. Physical
# runtime identity alone is bypassed in that central fixture call, never policy.
$shimSource = @'
param($Command,$Tool,$ArgumentsJson,$RuntimePath,$ExpectedRuntimeIdentityJson,$ArtifactPath,$ExpectedArtifactSha256,$ExpectedBuildId,$WorkspaceManifestPath,[switch]$RequireSuccess,[switch]$Compact,[switch]$NoExit,[switch]$SkipRuntimeIdentityVerification)
$argsObject=$ArgumentsJson|ConvertFrom-Json
$fixture=Split-Path -Parent $RuntimePath
if($Tool -ceq 'game') {
    [IO.File]::AppendAllText((Join-Path $fixture 'forwarded.ndjson'),(@{workspace=$WorkspaceManifestPath;unproven=$false}|ConvertTo-Json -Compress)+[Environment]::NewLine)
    $parameters=@{Tool=$Tool;ArgumentsJson=$ArgumentsJson;RuntimePath=$RuntimePath;EvidenceDirectory=(Join-Path $fixture 'central-evidence');RequireSuccess=$true;MaxTransientRetries=0;RequestTimeoutSeconds=2;Compact=$true;NoExit=$true;SkipRuntimeIdentityVerification=$true}
    if($WorkspaceManifestPath){$parameters.WorkspaceManifestPath=$WorkspaceManifestPath}
    & (Join-Path $PSScriptRoot 'devbench-control/Invoke-DevBenchControl.ps1') call @parameters
    return
}
$identity=@{listenerPid=101;processPath='C:\fixture\SkyrimVR.exe';processStartTimeUtc='2026-10-10T01:00:00.0000000Z';buildId=('a'*64);artifactPath='C:\fixture\CommunityShaders.dll';artifactSha256=('b'*64)}
$value=if($Tool -ceq 'record' -and $argsObject.action -ceq 'start'){@{action='start';recording=$true;correlationId=$argsObject.correlationId}}else{@{action=$argsObject.action;recording=$false;path='fixture-recording.json'}}
@{ok=$true;runtimeIdentity=$identity;data=@{content=@($value)};errors=@()}|ConvertTo-Json -Depth 20 -Compress
'@
[IO.File]::WriteAllText($shim, $shimSource)
$listener = [Net.HttpListener]::new()
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$portProbe.Start(); $port = $portProbe.LocalEndpoint.Port; $portProbe.Stop()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$ready = [Threading.ManualResetEventSlim]::new($false)
$events = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$job = Start-ThreadJob -ArgumentList $listener,$ready,$events -ScriptBlock {
    param($Listener,$Ready,$Events)
    try {
        $Listener.Start(); $Ready.Set()
        while ($Listener.IsListening) {
            $context=$Listener.GetContext(); $response=$context.Response
            if($context.Request.HttpMethod -ceq 'DELETE') {$Events.Enqueue('delete');$body='{}'}
            else {
                $reader=[IO.StreamReader]::new($context.Request.InputStream)
                try{$rpc=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
                if($rpc.method -ceq 'notifications/initialized'){$response.StatusCode=204;$response.Close();continue}
                switch($rpc.method) {
                    initialize {$response.Headers.Add('Mcp-Session-Id','owned-fixture');$result=@{protocolVersion='2025-03-26';capabilities=@{};serverInfo=@{name='fixture';version='1'}}}
                    'tools/list' {$result=@{tools=@(@{name='game';inputSchema=@{}})}}
                    'tools/call' {
                        if($rpc.params.name -cne 'game'){throw 'Unexpected target tool'}
                        $Events.Enqueue('load')
                        $result=@{content=@(@{type='text';text=(@{action='load';queued=$true;name=$rpc.params.arguments.name}|ConvertTo-Json -Compress)});isError=$false}
                    }
                    default {throw "Unexpected fixture RPC $($rpc.method)"}
                }
                $body=@{jsonrpc='2.0';id=$rpc.id;result=$result}|ConvertTo-Json -Depth 20 -Compress
            }
            $bytes=[Text.Encoding]::UTF8.GetBytes($body);$response.ContentType='application/json';$response.ContentLength64=$bytes.Length
            $response.OutputStream.Write($bytes,0,$bytes.Length);$response.Close()
        }
    } finally {$Listener.Close();$Ready.Set()}
}
try {
    if(-not $ready.Wait(5000) -or $job.State -eq 'Failed'){throw 'Fixture listener did not start'}
    foreach($case in @('valid','missing','late-rebind','different-path','drift','deleted','bad-runtime-binding','incomplete-binding','wrong-name','wrong-dir','policy-main','malformed-start','oversize-start','incomplete-start','legacy')) {
        $fixture=Join-Path $root $case;[IO.Directory]::CreateDirectory($fixture)|Out-Null
        $runtime=Join-Path $fixture 'runtime.json';[IO.File]::WriteAllText($runtime,(@{port=$port}|ConvertTo-Json))
        $profile=Join-Path $fixture 'profile';$manifest=Join-Path $fixture 'workspace.json'
        $workspace=@{workspaceId='exact-task';profilePath=$profile;status='ready';savePolicy='VerifiedFixture';copiedVerifiedSaves=$true;saveFixture=@{loadName='ExactSave'}}
        if($case -ceq 'policy-main'){$workspace.savePolicy='MainMenuOnly'}
        if($case -ceq 'incomplete-start'){$workspace.Remove('workspaceId')}
        $original=$workspace|ConvertTo-Json -Depth 8
        if($case -ceq 'malformed-start'){$original='{invalid'}
        if($case -ceq 'oversize-start'){$original='x'*1048577}
        [IO.File]::WriteAllText($manifest,$original)
        $session=Join-Path $fixture 'session'
        $startParameters=@{SessionDirectory=$session;RuntimePath=$runtime;VisualMode='none';DevBenchScriptPath=$shim;Compact=$true;NoExit=$true}
        if($case -cnotin @('missing','late-rebind','legacy')){$startParameters.WorkspaceManifestPath=$manifest}
        $started=& $entry start @startParameters|ConvertFrom-Json -Depth 80
        if($case -cin @('malformed-start','oversize-start','incomplete-start')){
            Check (-not $started.ok -and -not (Test-Path -LiteralPath $session)) "$case refuses before recording/session creation"
            continue
        }
        Check ($started.ok) "$case fixture capture starts"
        $statePath=$started.data.statePath
        $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -Depth 80
        if($case -cnotin @('missing','late-rebind','legacy')){
            Check ($state.workspaceBinding.manifestSha256 -ceq (Get-FileHash $manifest).Hash -and $state.workspaceBinding.workspaceId -ceq 'exact-task') "$case persists exact content and workspace"
            Check ($state.workspaceBinding.runtimeIdentity.listenerPid -eq $state.runtimeIdentity.listenerPid) "$case binds accepting runtime"
        }
        if($case -ceq 'legacy'){$state.PSObject.Properties.Remove('workspaceBinding')}
        if($case -ceq 'bad-runtime-binding'){$state.workspaceBinding.runtimeIdentity.listenerPid=202}
        if($case -ceq 'incomplete-binding'){$state.workspaceBinding.PSObject.Properties.Remove('manifestBytes')}
        if($case -cin @('legacy','bad-runtime-binding','incomplete-binding')){[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 80))}
        if($case -ceq 'drift'){[IO.File]::WriteAllText($manifest,$original+' ')}
        if($case -ceq 'deleted'){Remove-Item -LiteralPath $manifest}
        $name=if($case -ceq 'wrong-name'){'WrongSave'}else{'ExactSave'}
        $dir=if($case -ceq 'wrong-dir'){Join-Path $fixture 'foreign'}else{Join-Path $profile 'saves'}
        $actParameters=@{SessionDirectory=$session;DirectTool='game';DirectArgumentsJson=(@{action='load';name=$name;dir=$dir}|ConvertTo-Json -Compress);DevBenchScriptPath=$shim;Compact=$true;NoExit=$true}
        if($case -ceq 'late-rebind'){$actParameters.WorkspaceManifestPath=$manifest}
        if($case -ceq 'different-path'){$other=Join-Path $fixture 'other.json';Copy-Item $manifest $other;$actParameters.WorkspaceManifestPath=$other}
        $events.Clear()
        $acted=& $entry act @actParameters|ConvertFrom-Json -Depth 80
        $loads=@($events.ToArray()|Where-Object {$_ -ceq 'load'}).Count
        $forwarded=Join-Path $fixture 'forwarded.ndjson'
        if($case -ceq 'valid'){
            Check ($acted.ok -and $loads -eq 1 -and $acted.data.action.receipt.result.queued) 'one exact load via copied capture and real central entry'
            $forward=Get-Content $forwarded -Raw|ConvertFrom-Json
            Check ($forward.workspace -ceq $manifest -and -not $forward.unproven) 'exact admitted workspace forwarded without policy bypass'
            Check (@($events.ToArray()|Where-Object {$_ -ceq 'delete'}).Count -eq 1) 'real central session finalizes exact owned MCP session'
        } else {
            Check (-not $acted.ok -and $loads -eq 0) "$case no load or replay"
            Check (Test-Path -LiteralPath (Join-Path $session 'actions.ndjson')) "$case failed action retained"
            if($case -cin @('missing','legacy','wrong-name','wrong-dir','policy-main')){
                $failure=$acted.data.action.receipt.controller.value
                Check (-not $failure.dispatchReached -and $failure.sessionCleanup.state -ceq 'not_opened') "$case real central policy refuses before transport"
            } else {
                Check (-not (Test-Path $forwarded) -and -not $acted.data.action.receipt.attempt.dispatchAttempted) "$case wrapper refuses before controller call"
            }
        }
        $stopped=& $entry stop -SessionDirectory $session -DevBenchScriptPath $shim -Compact -NoExit|ConvertFrom-Json -Depth 80
        Check ($stopped.ok -and $stopped.state -ceq 'stopped') "$case original cleanup remains available without workspace"
    }
    Check ($job.State -ne 'Failed') 'fixture listener completed without service failure'
} finally {$listener.Stop();Stop-Job $job;Remove-Job $job}
@{ok=$true;checks=$checks;root=$root;scope='copied capture public entry and real copied central game policy/MCP transport; synthetic record/input and test-owned loopback; no real game/SteamVR'}|ConvertTo-Json -Compress
