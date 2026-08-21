# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'call', 'wait')]
    [string]$Command = 'list',
    [string]$Tool,
    [string]$ArgumentsJson = '{}',
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$ToolFilter,
    [switch]$NamesOnly,
    [switch]$RequireSuccess,
    [switch]$SkipRuntimeIdentityVerification,
    [string]$EvidenceDirectory,
    [string]$ArtifactPath,
    [string]$ExpectedBuildId,
    [string]$ExpectedArtifactSha256,
    [ValidateSet('noBlockingMenu', 'playerLoaded', 'toolAvailable', 'serviceReady')]
    [string]$Condition = 'noBlockingMenu',
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 30,
    [ValidateRange(50, 5000)]
    [int]$PollMilliseconds = 250,
    [ValidateRange(0, 10)]
    [int]$MaxTransientRetries = 4,
    [ValidateRange(50, 5000)]
    [int]$MaxPollMilliseconds = 5000,
    [string[]]$AcceptedState = @('ready', 'idle', 'available', 'completed', 'success', 'ok'),
    [string[]]$RetryableState = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running'),
    [string]$ExpectedErrorCode,
    [string]$ProgressLogPath,
    [string[]]$IgnoredMenus = @('HUD Menu'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$endpoint = $null
$runtimeIdentity = $null
$transportRetries = [Collections.Generic.List[object]]::new()
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force

function Invoke-McpRequest {
    param([string]$Endpoint, [hashtable]$Headers, $Payload)
    $body = $Payload | ConvertTo-Json -Depth 30 -Compress
    $attempt = 0
    $delay = [Math]::Max(50, $PollMilliseconds)
    while ($true) {
        $attempt++
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body $body -TimeoutSec 15
            return [pscustomobject]@{ response = $response; json = ($response.Content | ConvertFrom-Json -Depth 50); attempts = $attempt }
        }
        catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            $transient = $statusCode -in @(429, 502, 503, 504) -or $_.Exception -is [System.TimeoutException] -or $_.Exception.Message -match 'timed out|temporarily unavailable|connection.*closed'
            if (-not $transient -or $attempt -gt $MaxTransientRetries) { throw }
            $transportRetries.Add([pscustomobject][ordered]@{
                attempt = $attempt
                statusCode = $statusCode
                delayMilliseconds = $delay
                message = $_.Exception.Message
                timestampUtc = [DateTime]::UtcNow.ToString('o')
            })
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min($MaxPollMilliseconds, $delay * 2)
        }
    }
}

function Invoke-ToolRpc {
    param([string]$Name, [hashtable]$Arguments, [hashtable]$Headers)
    $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $Headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments } }
    if ($rpc.json.PSObject.Properties['error']) { throw "DevBench tools/call failed: $($rpc.json.error | ConvertTo-Json -Compress)" }
    if ($rpc.json.result.PSObject.Properties['isError'] -and $rpc.json.result.isError) {
        $message = ($rpc.json.result.content | ForEach-Object { $_.text }) -join "`n"
        throw "DevBench tool '$Name' failed: $message"
    }
    $parsed = @()
    foreach ($item in @($rpc.json.result.content)) {
        if ($item.type -eq 'text') {
            try { $parsed += ,($item.text | ConvertFrom-Json -Depth 50) } catch { $parsed += ,([string]$item.text) }
        }
        else { $parsed += ,$item }
    }
    return [pscustomobject][ordered]@{ tool = $Name; content = $parsed; rawResult = $rpc.json.result }
}

function Get-ListenerPid([int]$Port) {
    $records = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $records = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') } | Select-Object -ExpandProperty OwningProcess -Unique)
        }
        catch { $records = @() }
    }
    if ($records.Count -eq 0) {
        $pattern = "^\s*TCP\s+(127\.0\.0\.1|\[::1\]):$Port\s+.*LISTENING\s+(?<pid>\d+)\s*$"
        $records = @(netstat -ano | ForEach-Object { if ($_ -match $pattern) { [int]$Matches.pid } } | Sort-Object -Unique)
    }
    if ($records.Count -ne 1) { return $null }
    return [int]$records[0]
}

function Get-RuntimeIdentity($Runtime, [hashtable]$Headers, [object[]]$Tools, [switch]$AllowDeferredBuildIdentity) {
    $expectations = Get-DevBenchRuntimeExpectations -Runtime $Runtime
    if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) { $expectations.artifactPath = [IO.Path]::GetFullPath($ArtifactPath) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedBuildId)) { $expectations.buildId = $ExpectedBuildId }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedArtifactSha256)) { $expectations.artifactSha256 = $ExpectedArtifactSha256 }
    $listenerPid = Get-ListenerPid $expectations.port
    $inspectAvailable = @($Tools | Where-Object name -eq 'inspect').Count -eq 1
    $health = $null
    $errors = [Collections.Generic.List[string]]::new()
    if ($inspectAvailable) {
        try { $health = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'health' } -Headers $Headers).content | Select-Object -First 1 }
        catch { $errors.Add($_.Exception.Message) }
    }
    else { $errors.Add("The authoritative tool list does not expose 'inspect' for process identity verification.") }
    if ($null -eq $listenerPid) { $errors.Add("Could not prove one loopback listener owner for port $($expectations.port).") }
    if ($health -and $listenerPid -and [int]$health.pid -ne $listenerPid) { $errors.Add("DevBench health PID $($health.pid) differs from listener PID $listenerPid.") }
    if ($null -ne $expectations.pid -and $listenerPid -and $expectations.pid -ne $listenerPid) { $errors.Add("Runtime metadata PID $($expectations.pid) differs from listener PID $listenerPid.") }
    if ($null -ne $expectations.pid -and $health -and $expectations.pid -ne [int]$health.pid) { $errors.Add("Runtime metadata PID $($expectations.pid) differs from DevBench health PID $($health.pid).") }
    if ($expectations.exe -and $health -and [string]$health.exe -ne $expectations.exe) { $errors.Add("Runtime metadata executable '$($expectations.exe)' differs from DevBench health executable '$($health.exe)'.") }
    $processIdentity = $null
    if ($listenerPid) {
        try {
            $process = Get-Process -Id $listenerPid -ErrorAction Stop
            $processIdentity = [pscustomobject][ordered]@{
                pid = $listenerPid
                name = $process.ProcessName
                path = $(try { $process.Path } catch { $null })
                startTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                responding = $(try { [bool]$process.Responding } catch { $null })
            }
        }
        catch { $errors.Add("Could not inspect DevBench listener process PID ${listenerPid}: $($_.Exception.Message)") }
    }

    $registrySources = [Collections.Generic.List[object]]::new()
    $producers = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Tools | Where-Object { $_.name -like 'communityshaders.*_api' } | Sort-Object name)) {
        $candidateError = $null
        $producer = $null
        foreach ($action in @('registry', 'capabilities')) {
            try {
                $arguments = @{ contractMajor = 1; clientId = 'devbench-runtime-identity'; commandId = "identity-$([guid]::NewGuid().ToString('N'))"; action = $action }
                $payload = @(Invoke-ToolRpc -Name ([string]$candidate.name) -Arguments $arguments -Headers $Headers).content | Select-Object -First 1
                if ($payload) {
                    if ($payload.PSObject.Properties['producer']) { $producer = $payload.producer }
                    elseif ($payload.PSObject.Properties['registry'] -and $payload.registry.PSObject.Properties['producer']) { $producer = $payload.registry.producer }
                    elseif ($payload.PSObject.Properties['result'] -and $payload.result.PSObject.Properties['producer']) { $producer = $payload.result.producer }
                }
                if ($producer) { break }
            }
            catch { $candidateError = $_.Exception.Message }
        }
        if ($producer) { $producers.Add($producer) }
        $registrySources.Add([pscustomobject][ordered]@{ tool = [string]$candidate.name; producer = $producer; error = $candidateError })
    }
    $buildIds = @($producers | ForEach-Object { if ($_.PSObject.Properties['buildId']) { [string]$_.buildId } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($buildIds.Count -gt 1) { $errors.Add("CSX service registries disagree on build ID: $($buildIds -join ', ')") }
    $actualBuildId = if ($buildIds.Count -eq 1) { $buildIds[0] } else { $null }
    $build = [pscustomobject][ordered]@{ buildId = $actualBuildId; producers = @($producers); sources = @($registrySources) }
    if ($expectations.buildId -and -not $actualBuildId -and -not $AllowDeferredBuildIdentity) { $errors.Add('A build ID expectation was supplied but no CSX service registry exposed a producer build ID.') }
    elseif ($expectations.buildId -and $actualBuildId -ne $expectations.buildId) { $errors.Add("Expected CSX build ID '$($expectations.buildId)' differs from runtime build ID '$actualBuildId'.") }
    $artifact = $null
    if ($expectations.artifactPath) {
        $resolvedArtifact = [IO.Path]::GetFullPath($expectations.artifactPath)
        if (-not (Test-Path -LiteralPath $resolvedArtifact -PathType Leaf)) { $errors.Add("Expected deployed artifact does not exist: $resolvedArtifact") }
        else {
            $actualSha = (Get-FileHash -LiteralPath $resolvedArtifact -Algorithm SHA256).Hash
            $artifact = [pscustomobject][ordered]@{ path = $resolvedArtifact; sha256 = $actualSha; bytes = [long](Get-Item -LiteralPath $resolvedArtifact).Length }
            if ($expectations.artifactSha256 -and $actualSha -ne $expectations.artifactSha256) { $errors.Add("Expected artifact SHA-256 '$($expectations.artifactSha256)' differs from deployed artifact SHA-256 '$actualSha'.") }
        }
    }
    elseif ($expectations.artifactSha256) { $errors.Add('An artifact SHA-256 expectation requires artifactPath/dllPath or -ArtifactPath.') }
    $missing = [Collections.Generic.List[string]]::new()
    if (-not $listenerPid) { $missing.Add('pid') }
    if (-not $processIdentity -or -not $processIdentity.path) { $missing.Add('process.path') }
    if (-not $actualBuildId) { $missing.Add('buildId') }
    if (-not $artifact) { $missing.Add('artifact.path+sha256') }
    return [pscustomobject][ordered]@{
        verified = $errors.Count -eq 0 -and $null -ne $listenerPid -and $null -ne $health
        complete = $missing.Count -eq 0
        expectations = $expectations
        listenerPid = $listenerPid
        process = $processIdentity
        health = $health
        build = $build
        artifact = $artifact
        missing = @($missing)
        errors = @($errors)
        verifiedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-RuntimeEvidence($Binding) {
    if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { return $null }
    $resolved = [IO.Path]::GetFullPath($EvidenceDirectory)
    New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    $path = Join-Path $resolved 'devbench-runtime-binding.json'
    [pscustomobject][ordered]@{
        schemaVersion = 1
        runtimePath = [IO.Path]::GetFullPath($RuntimePath)
        runtimeSha256 = (Get-FileHash -LiteralPath $RuntimePath -Algorithm SHA256).Hash
        endpoint = $endpoint
        identity = $Binding
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

try {
    if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.' }
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
    $runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if (-not $runtime.PSObject.Properties['port']) { throw 'DevBench runtime metadata has no port.' }
    $endpoint = "http://127.0.0.1:$([int]$runtime.port)/mcp"
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $initialize = Invoke-McpRequest -Endpoint $endpoint -Headers $baseHeaders -Payload @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
            protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'DevBenchControl'; version = '1.1' }
        }
    }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $headers = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec 15 | Out-Null

    $listRpc = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
    if ($listRpc.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($listRpc.json.error | ConvertTo-Json -Compress)" }
    $tools = @($listRpc.json.result.tools)
    if (-not $SkipRuntimeIdentityVerification) {
        $deferBuildIdentity = $Command -eq 'wait' -and $Condition -in @('toolAvailable', 'serviceReady')
        $runtimeIdentity = Get-RuntimeIdentity -Runtime $runtime -Headers $headers -Tools $tools -AllowDeferredBuildIdentity:$deferBuildIdentity
        if ($runtimeIdentity.errors.Count -gt 0) { throw "DevBench runtime identity verification failed: $($runtimeIdentity.errors -join ' ')" }
    }
    $evidencePath = Write-RuntimeEvidence $runtimeIdentity

    $semantic = [pscustomobject][ordered]@{ known = $false; ok = $true; outcome = 'unknown'; guarded = $false; transient = $false; codes = @(); states = @(); reasons = @() }
    if ($Command -eq 'list') {
        if (-not [string]::IsNullOrWhiteSpace($ToolFilter)) { $tools = @($tools | Where-Object { $_.name -like "*$ToolFilter*" }) }
        $data = if ($NamesOnly) { [pscustomobject][ordered]@{ names = @($tools | ForEach-Object name); count = $tools.Count } } else { [pscustomobject][ordered]@{ tools = $tools } }
    }
    elseif ($Command -eq 'call') {
        if ([string]::IsNullOrWhiteSpace($Tool)) { throw 'Tool is required for call.' }
        if (@($tools | Where-Object name -eq $Tool).Count -ne 1) { throw "Tool '$Tool' is not present in the authoritative tools/list response." }
        try { $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        $data = Invoke-ToolRpc -Name $Tool -Arguments $arguments -Headers $headers
        $semantic = Get-DevBenchSemanticStatus -Content @($data.content)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedErrorCode)) {
            $matched = @($semantic.codes | Where-Object { $_ -eq $ExpectedErrorCode }).Count -gt 0
            $semantic | Add-Member -NotePropertyName expectedErrorCode -NotePropertyValue $ExpectedErrorCode -Force
            $semantic | Add-Member -NotePropertyName expectedErrorMatched -NotePropertyValue $matched -Force
            if ($matched) {
                $semantic.ok = $true
                $semantic.outcome = 'expected-guard'
                $semantic.reasons = @()
            }
        }
    }
    else {
        if ($Condition -in @('toolAvailable', 'serviceReady') -and [string]::IsNullOrWhiteSpace($Tool)) { throw "Condition '$Condition' requires -Tool." }
        $requiredTool = if ($Condition -eq 'noBlockingMenu') { 'menu' } elseif ($Condition -eq 'playerLoaded') { 'inspect' } else { $null }
        if ($requiredTool -and @($tools | Where-Object name -eq $requiredTool).Count -ne 1) { throw "Condition '$Condition' requires missing tool '$requiredTool'." }
        $waitArguments = @{}
        if ($Condition -eq 'serviceReady') {
            try { $waitArguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $attempts = 0
        $observation = $null
        $currentDelay = $PollMilliseconds
        $progress = [Collections.Generic.List[object]]::new()
        $lastProgressUtc = [DateTime]::MinValue
        $firstCpu = $null
        $lastCpu = $null
        do {
            $attempts++
            if ($Condition -eq 'noBlockingMenu') {
                $menu = @(Invoke-ToolRpc -Name 'menu' -Arguments @{ action = 'list' } -Headers $headers).content | Select-Object -First 1
                $observation = Test-DevBenchNoBlockingMenu -MenuState $menu -IgnoredMenus $IgnoredMenus
            }
            elseif ($Condition -eq 'playerLoaded') {
                $state = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'state' } -Headers $headers).content | Select-Object -First 1
                $observation = [pscustomobject][ordered]@{ satisfied = [bool]$state.playerLoaded; state = $state }
            }
            else {
                $currentList = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
                if ($currentList.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($currentList.json.error | ConvertTo-Json -Compress)" }
                $currentTools = @($currentList.json.result.tools)
                $toolPresent = @($currentTools | Where-Object name -eq $Tool).Count -eq 1
                if ($toolPresent -and -not $SkipRuntimeIdentityVerification) {
                    $refreshedIdentity = Get-RuntimeIdentity -Runtime $runtime -Headers $headers -Tools $currentTools
                    if ($refreshedIdentity.errors.Count -gt 0) { throw "DevBench runtime identity verification failed after target registration: $($refreshedIdentity.errors -join ' ')" }
                    $runtimeIdentity = $refreshedIdentity
                }
                $service = $null
                if ($Condition -eq 'serviceReady' -and $toolPresent) {
                    $toolResult = Invoke-ToolRpc -Name $Tool -Arguments $waitArguments -Headers $headers
                    $service = Test-DevBenchServiceReady -Content @($toolResult.content) -AcceptedStates $AcceptedState -RetryableStates $RetryableState
                }

                $now = [DateTime]::UtcNow
                if (($now - $lastProgressUtc).TotalSeconds -ge 5 -or $progress.Count -eq 0) {
                    $pid = if ($runtimeIdentity -and $runtimeIdentity.listenerPid) { [int]$runtimeIdentity.listenerPid } else { Get-ListenerPid ([int]$runtime.port) }
                    $processSample = $null
                    if ($pid) {
                        $process = Get-Process -Id $pid -ErrorAction SilentlyContinue
                        if ($process) {
                            $lastCpu = [double]$process.CPU
                            if ($null -eq $firstCpu) { $firstCpu = $lastCpu }
                            $processSample = [pscustomobject][ordered]@{ pid = $pid; responding = $(try { [bool]$process.Responding } catch { $null }); cpuSeconds = $lastCpu; workingSetBytes = [long]$process.WorkingSet64 }
                        }
                    }
                    $logSample = $null
                    if (-not [string]::IsNullOrWhiteSpace($ProgressLogPath)) {
                        $resolvedLog = [IO.Path]::GetFullPath($ProgressLogPath)
                        if (Test-Path -LiteralPath $resolvedLog -PathType Leaf) {
                            $item = Get-Item -LiteralPath $resolvedLog
                            $logSample = [pscustomobject][ordered]@{ path = $resolvedLog; bytes = [long]$item.Length; lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o'); tail = @(Get-Content -LiteralPath $resolvedLog -Tail 5) }
                        }
                    }
                    $progress.Add([pscustomobject][ordered]@{ timestampUtc = $now.ToString('o'); toolCount = $currentTools.Count; targetPresent = $toolPresent; process = $processSample; log = $logSample })
                    while ($progress.Count -gt 120) { $progress.RemoveAt(0) }
                    $lastProgressUtc = $now
                }
                $cpuDelta = if ($null -ne $firstCpu -and $null -ne $lastCpu) { [Math]::Round($lastCpu - $firstCpu, 3) } else { $null }
                $classification = if ($toolPresent) { if ($Condition -eq 'serviceReady' -and -not $service.ready) { 'service-registered-not-ready' } else { 'service-ready' } } elseif ($null -ne $cpuDelta -and $cpuDelta -gt 1) { 'api-waiting-behind-initialization' } else { 'api-absent-or-not-registered' }
                $observation = [pscustomobject][ordered]@{
                    satisfied = if ($Condition -eq 'toolAvailable') { $toolPresent } else { $toolPresent -and $service.ready }
                    tool = $Tool
                    toolPresent = $toolPresent
                    service = $service
                    classification = $classification
                    cpuDeltaSeconds = $cpuDelta
                    authoritativeToolCount = $currentTools.Count
                    progress = @($progress)
                }
                if ($service -and $service.terminalFailure) { break }
            }
            if ($observation.satisfied) { break }
            Start-Sleep -Milliseconds $currentDelay
            if ($Condition -in @('toolAvailable', 'serviceReady')) { $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2) }
        } while ([DateTime]::UtcNow -lt $deadline)
        $data = [pscustomobject][ordered]@{ condition = $Condition; satisfied = [bool]$observation.satisfied; attempts = $attempts; timeoutSeconds = $TimeoutSeconds; initialPollMilliseconds = $PollMilliseconds; maxPollMilliseconds = $MaxPollMilliseconds; observation = $observation }
        if ($observation.satisfied -and -not $SkipRuntimeIdentityVerification) { $evidencePath = Write-RuntimeEvidence $runtimeIdentity }
        $semantic = [pscustomobject][ordered]@{ known = $true; ok = [bool]$observation.satisfied; reasons = $(if ($observation.satisfied) { @() } else { @("Condition '$Condition' was not satisfied within $TimeoutSeconds seconds.") }) }
    }

    $semanticFailure = $RequireSuccess -and $semantic.known -and -not $semantic.ok
    $result = [pscustomobject][ordered]@{
        ok = -not $semanticFailure
        transportOk = $true
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $evidencePath
        semantic = $semantic
        transportRetries = @($transportRetries)
        data = $data
        errors = $(if ($semanticFailure) { @($semantic.reasons) } else { @() })
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        ok = $false
        transportOk = $false
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $null
        semantic = $null
        transportRetries = @($transportRetries)
        data = $null
        errors = @($_.Exception.Message)
    }
}

$parameters = @{ InputObject = $result; Depth = 50 }
if ($Compact) { $parameters['Compress'] = $true }
ConvertTo-Json @parameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
