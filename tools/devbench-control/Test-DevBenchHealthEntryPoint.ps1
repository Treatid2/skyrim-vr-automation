# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = [Collections.Generic.List[string]]::new()
function Assert-Entry([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
$root = Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('health-entry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$tokens = $null; $parseErrors = $null
$controllerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Controller parse failure.' }
$listenerReader = @($controllerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ListenerPid'},$true))[0]
Invoke-Expression $listenerReader.Extent.Text
# Exercise the real public controller against a test-owned loopback server,
# including initialize, health, cleanup and outer wait. No Skyrim is contacted.
foreach ($case in @('retry-then-ready','refresh-retry','terminal','malformed','mcp-error','mcp-retry','cleanup-failure','exhausted')) {
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $portProbe.Start(); $port = $portProbe.LocalEndpoint.Port; $portProbe.Stop()
    $ready = [Threading.ManualResetEventSlim]::new($false)
    $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $identity = [hashtable]::Synchronized(@{ pid = 0 })
    $listener = [Net.HttpListener]::new(); $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $server = Start-ThreadJob -ArgumentList $port,$case,$ready,$events,$identity,$listener -ScriptBlock {
        param($Port,$Case,$Ready,$Events,$Identity,$Listener)
        $ErrorActionPreference = 'Stop'
        $healthCalls = 0; $sessions = 0
        try {
            $listener.Start(); $Ready.Set()
            while ($listener.IsListening) {
                $context = $listener.GetContext(); $request = $context.Request; $response = $context.Response
                $response.ContentType = 'application/json'
                if ($request.HttpMethod -eq 'DELETE') {
                    $Events.Enqueue([pscustomobject]@{ kind = 'delete'; session = $request.Headers['Mcp-Session-Id'] })
                    $response.StatusCode = if ($Case -eq 'cleanup-failure') { 500 } else { 200 }
                    $body = '{}'
                }
                else {
                    $reader = [IO.StreamReader]::new($request.InputStream)
                    try { $rpc = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                    $Events.Enqueue([pscustomobject]@{ kind = $rpc.method; session = $request.Headers['Mcp-Session-Id'] })
                    if ($rpc.method -eq 'notifications/initialized') { $response.StatusCode = 204; $response.Close(); continue }
                    $result = @{}
                    switch ($rpc.method) {
                        initialize { $sessions++; $response.Headers.Add('Mcp-Session-Id',"health-fixture-$sessions"); $result = @{ protocolVersion = '2025-03-26'; capabilities = @{}; serverInfo = @{ name = 'fixture'; version = '1' } } }
                        'tools/list' { $result = @{ tools = @(@{ name = 'inspect'; inputSchema = @{} },@{ name = 'fixture.target'; inputSchema = @{} }) } }
                        'tools/call' {
                            if ($rpc.params.name -ne 'inspect' -or $rpc.params.arguments.kind -ne 'health') { throw 'Unexpected target dispatch.' }
                            $healthCalls++
                            $health = [ordered]@{ pid = $Identity.pid; exe = 'fixture-http-listener'; port = $Port; frame = 1; lastTaskFrame = -1; pendingTasks = 0; vr = $true }
                            $negative = ($Case -in @('retry-then-ready','mcp-retry') -and $healthCalls -eq 1) -or ($Case -eq 'refresh-retry' -and $healthCalls -eq 2) -or $Case -in @('cleanup-failure','exhausted')
                            if ($negative) { $health.ok = $false; $health.retryable = $true; $health.error = 'main_thread_busy' }
                            if ($Case -eq 'terminal') { $health.ok = $false; $health.retryable = $false; $health.code = 'timed out' }
                            if ($Case -eq 'malformed') { $health.ok = 'false'; $health.retryable = $true; $health.code = 'timed out' }
                            $result = @{ isError = $Case -eq 'mcp-error' -or ($Case -eq 'mcp-retry' -and $healthCalls -eq 1); content = @(@{ type = 'text'; text = ($health | ConvertTo-Json -Compress) }) }
                        }
                        default { throw "Unexpected RPC $($rpc.method)" }
                    }
                    $body = @{ jsonrpc = '2.0'; id = $rpc.id; result = $result } | ConvertTo-Json -Depth 20 -Compress
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body); $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes,0,$bytes.Length); $response.Close()
            }
        }
        finally { $listener.Close(); $Ready.Set() }
    }
    try {
        if (-not $ready.Wait(5000) -or $server.State -eq 'Failed') { throw "Fixture server startup failed: $(Receive-Job $server -ErrorAction SilentlyContinue)" }
        # Windows HttpListener uses HTTP.sys, so its socket owner is the kernel
        # listener, not this test host. Keep the production listener guard real.
        $ownerPid = Get-ListenerPid -Port $port
        if ($null -eq $ownerPid) { throw 'Fixture listener owner is ambiguous.' }
        $identity.pid = [int]$ownerPid
        $fixture = Join-Path $root $case; New-Item -ItemType Directory -Path $fixture | Out-Null
        $runtimePath = Join-Path $fixture 'runtime.json'
        @{ port = $port } | ConvertTo-Json | Set-Content -LiteralPath $runtimePath
        $started = [DateTime]::UtcNow
        $response = & (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') wait -Condition toolAvailable -Tool fixture.target -RuntimePath $runtimePath -EvidenceDirectory $fixture -TimeoutSeconds 3 -RequestTimeoutSeconds 1 -PollMilliseconds 50 -MaxPollMilliseconds 50 -MaxTransientRetries 0 -Compact -NoExit | ConvertFrom-Json -Depth 50
        $elapsed = ([DateTime]::UtcNow - $started).TotalSeconds
        $journal = Get-Content -LiteralPath $response.invocationEvidencePath -Raw | ConvertFrom-Json -Depth 50
        $observed = @($events.ToArray()); $initializations = @($observed | Where-Object kind -eq 'initialize').Count
        $deletes = @($observed | Where-Object kind -eq 'delete').Count
        Assert-Entry ($deletes -ge 1) "$case closes its test-owned MCP sessions"
        if ($case -in @('retry-then-ready','refresh-retry','mcp-retry')) {
            Assert-Entry ($response.ok -and $initializations -eq 2) "$case succeeds through the real bounded identity rebind"
            $firstDelete = [Array]::FindIndex($observed,[Predicate[object]]{ param($entry) $entry.kind -eq 'delete' })
            $lastInitialize = [Array]::FindLastIndex($observed,[Predicate[object]]{ param($entry) $entry.kind -eq 'initialize' })
            Assert-Entry ($firstDelete -ge 0 -and $firstDelete -lt $lastInitialize) "$case proves cleanup precedes replacement session"
            Assert-Entry (-not $journal.identityHealthFailedProbe.qualified -and $journal.identityHealthProbe.qualified) "$case retains failed health after later successful admission"
        }
        else {
            Assert-Entry (-not $response.ok -and -not $journal.identityHealthProbe.qualified) "$case refuses identity admission"
            if ($case -ne 'exhausted') { Assert-Entry ($initializations -eq 1) "$case is not reclassified by transient-looking message text" }
        }
        if ($case -eq 'mcp-error') {
            Assert-Entry ($journal.identityHealthProbe.rawResult.isError -and $journal.identityHealthProbe.rawResult.content[0].text -ceq ($journal.identityHealthProbe.parsedContent[0] | ConvertTo-Json -Compress)) 'decoded MCP tool-error raw bytes reach the public invocation journal'
        }
        if ($case -eq 'exhausted') { Assert-Entry ($elapsed -lt 8 -and $initializations -gt 1) 'legitimate transient health cannot extend the public wait deadline indefinitely' }
        Assert-Entry (@($observed | Where-Object kind -eq 'tools/call').Count -ge 1 -and $server.State -ne 'Failed') "$case dispatches only fixture health probes, never the target action"
    }
    finally { $listener.Close(); Stop-Job $server; Remove-Job $server; $ready.Dispose() }
}
[pscustomobject]@{ ok = $true; tests = $passes.Count; passes = @($passes); fixture = $root } | ConvertTo-Json -Depth 5
