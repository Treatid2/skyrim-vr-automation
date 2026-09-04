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
    [string]$EvidenceLabel,
    [string]$ArtifactPath,
    [string]$WorkspaceManifestPath,
    [string]$ExpectedBuildId,
    [string]$ExpectedArtifactSha256,
    [ValidateSet('noBlockingMenu', 'mainMenuReady', 'playerLoaded', 'toolAvailable', 'serviceReady')]
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
    [string[]]$AllowedMainMenuMenus = @('HUD Menu', 'Main Menu', 'Mist Menu', 'Fader Menu'),
    [switch]$AcceptAlreadyLoaded,
    [switch]$AllowUnsafeTfc1,
    [switch]$AllowUnprovenGameMutation,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$argumentsJsonSupplied = $PSBoundParameters.ContainsKey('ArgumentsJson')
$endpoint = $null
$runtimeIdentity = $null
$transportRetries = [Collections.Generic.List[object]]::new()
$invocationEvidencePath = $null
$invocationRecord = $null
$operationDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force

function Get-RequestTimeoutSeconds {
    if ($null -eq $script:operationDeadlineUtc) { return $TimeoutSeconds }
    $remainingSeconds = ($script:operationDeadlineUtc - [DateTime]::UtcNow).TotalSeconds
    if ($remainingSeconds -lt 1) { throw [TimeoutException]::new('The DevBench operation deadline expired before another request could start.') }
    return [int][Math]::Max(1, [Math]::Min(600, [Math]::Ceiling($remainingSeconds)))
}

function Start-OperationDelay([int]$RequestedMilliseconds) {
    if ($RequestedMilliseconds -le 0) { return }
    if ($null -eq $script:operationDeadlineUtc) { Start-Sleep -Milliseconds $RequestedMilliseconds; return }
    $remainingMilliseconds = [long]($script:operationDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMilliseconds -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Min($RequestedMilliseconds, $remainingMilliseconds))
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -Depth 50
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-InvocationEvidenceDirectory {
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { return [IO.Path]::GetFullPath($EvidenceDirectory) }
    $localRoot = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
    return [IO.Path]::GetFullPath((Join-Path $localRoot 'SkyrimVRAutomation\evidence\devbench-control'))
}

function Initialize-InvocationEvidence {
    $resolved = Get-InvocationEvidenceDirectory
    New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    $rawLabel = if (-not [string]::IsNullOrWhiteSpace($EvidenceLabel)) { $EvidenceLabel } elseif ($Command -eq 'wait') { "$Command-$Condition-$Tool" } else { "$Command-$Tool" }
    $safeLabel = ($rawLabel -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = 'invocation' }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $script:invocationEvidencePath = Join-Path $resolved "devbench-invocation.$safeLabel.$stamp.$PID.json"
    $script:invocationRecord = [ordered]@{
        schemaVersion = 1
        state = 'preparing'
        command = $Command
        tool = $Tool
        condition = if ($Command -eq 'wait') { $Condition } else { $null }
        endpoint = $endpoint
        runtimePath = if ([string]::IsNullOrWhiteSpace($RuntimePath)) { $null } else { [IO.Path]::GetFullPath($RuntimePath) }
        runtimeSha256 = if (-not [string]::IsNullOrWhiteSpace($RuntimePath) -and (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { (Get-FileHash -LiteralPath $RuntimePath -Algorithm SHA256).Hash } else { $null }
        requestedArguments = if ($Command -eq 'call') { $ArgumentsJson } else { $null }
        requestedArgumentsSha256 = if ($Command -eq 'call') { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($ArgumentsJson))) } else { $null }
        commandId = $null
        workspaceManifestPath = if ([string]::IsNullOrWhiteSpace($WorkspaceManifestPath)) { $null } else { [IO.Path]::GetFullPath($WorkspaceManifestPath) }
        workspaceManifestSha256 = if (-not [string]::IsNullOrWhiteSpace($WorkspaceManifestPath) -and (Test-Path -LiteralPath $WorkspaceManifestPath -PathType Leaf)) { (Get-FileHash -LiteralPath $WorkspaceManifestPath -Algorithm SHA256).Hash } else { $null }
        preparedUtc = [DateTime]::UtcNow.ToString('o')
        dispatchedUtc = $null
        completedUtc = $null
        runtimeIdentity = $runtimeIdentity
        transportRetries = @()
        semantic = $null
        data = $null
        errors = @()
    }
    Write-JsonAtomic -Path $script:invocationEvidencePath -Value $script:invocationRecord
}

function Update-InvocationEvidence {
    param([Parameter(Mandatory)][string]$State, $Semantic = $null, $Data = $null, [string[]]$Errors = @())
    if ($null -eq $script:invocationRecord -or [string]::IsNullOrWhiteSpace($script:invocationEvidencePath)) { return }
    $script:invocationRecord.state = $State
    $script:invocationRecord.endpoint = $endpoint
    $script:invocationRecord.runtimeIdentity = $runtimeIdentity
    $script:invocationRecord.transportRetries = @($transportRetries)
    $script:invocationRecord.semantic = $Semantic
    $script:invocationRecord.data = $Data
    $script:invocationRecord.errors = @($Errors)
    if ($State -eq 'dispatching') { $script:invocationRecord.dispatchedUtc = [DateTime]::UtcNow.ToString('o') }
    if ($State -in @('completed', 'failed', 'guard-rejected', 'indeterminate')) { $script:invocationRecord.completedUtc = [DateTime]::UtcNow.ToString('o') }
    Write-JsonAtomic -Path $script:invocationEvidencePath -Value $script:invocationRecord
}

function Find-UnsafeTfc1 {
    param($Value, [string]$Path = '$')
    if ($Value -is [string]) {
        if (($Value.Trim() -replace '\s+', ' ') -match '^(?i:tfc 1)$') { return $Path }
        return $null
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $match = Find-UnsafeTfc1 -Value $Value[$key] -Path "$Path.$key"
            if ($match) { return $match }
        }
    }
    elseif ($Value -is [Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $Value) {
            $match = Find-UnsafeTfc1 -Value $item -Path "$Path[$index]"
            if ($match) { return $match }
            $index++
        }
    }
    return $null
}

function Get-GameMutationRequests {
    param([string]$ToolName, $Arguments, [string]$Path = '$')
    $requests = [Collections.Generic.List[object]]::new()
    if ($ToolName -eq 'game' -and $Arguments -is [Collections.IDictionary]) {
        $action = if ($Arguments.Contains('action')) { [string]$Arguments['action'] } else { '' }
        if ($action -in @('load', 'loadLast', 'save')) {
            $requests.Add([pscustomobject][ordered]@{ path = $Path; action = $action; arguments = $Arguments })
        }
        return @($requests)
    }
    if ($ToolName -eq 'console' -and $Arguments -is [Collections.IDictionary] -and $Arguments.Contains('command')) {
        $commandText = ([string]$Arguments['command']).Trim()
        if ($commandText -match '^(?i:(load|save))\s+(.+)$') {
            $requests.Add([pscustomobject][ordered]@{ path = $Path; action = $Matches[1].ToLowerInvariant(); arguments = [ordered]@{ action = $Matches[1].ToLowerInvariant(); name = $Matches[2].Trim() } })
        }
        return @($requests)
    }
    function Find-NestedGameMutation($Value, [string]$CurrentPath) {
        if ($Value -is [Collections.IDictionary]) {
            if ($Value.Contains('tool') -and [string]$Value['tool'] -eq 'game' -and $Value.Contains('args') -and $Value['args'] -is [Collections.IDictionary]) {
                $args = $Value['args']
                $action = if ($args.Contains('action')) { [string]$args['action'] } else { '' }
                if ($action -in @('load', 'loadLast', 'save')) {
                    $requests.Add([pscustomobject][ordered]@{ path = "$CurrentPath.args"; action = $action; arguments = $args })
                }
            }
            elseif ($Value.Contains('tool') -and [string]$Value['tool'] -eq 'console' -and $Value.Contains('args') -and $Value['args'] -is [Collections.IDictionary] -and $Value['args'].Contains('command')) {
                $commandText = ([string]$Value['args']['command']).Trim()
                if ($commandText -match '^(?i:(load|save))\s+(.+)$') {
                    $requests.Add([pscustomobject][ordered]@{ path = "$CurrentPath.args"; action = $Matches[1].ToLowerInvariant(); arguments = [ordered]@{ action = $Matches[1].ToLowerInvariant(); name = $Matches[2].Trim() } })
                }
            }
            foreach ($key in $Value.Keys) { Find-NestedGameMutation -Value $Value[$key] -CurrentPath "$CurrentPath.$key" }
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            $index = 0
            foreach ($item in $Value) {
                Find-NestedGameMutation -Value $item -CurrentPath "$CurrentPath[$index]"
                $index++
            }
        }
    }
    Find-NestedGameMutation -Value $Arguments -CurrentPath $Path
    return @($requests)
}

function Test-GameMutationPolicy {
    param([Parameter(Mandatory)]$Request)
    if ($AllowUnprovenGameMutation) { return [pscustomobject]@{ allowed = $true; override = $true; error = $null } }
    if ([string]::IsNullOrWhiteSpace($WorkspaceManifestPath)) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "DevBench game action '$($Request.action)' at $($Request.path) requires -WorkspaceManifestPath. Pass -AllowUnprovenGameMutation only when the caller explicitly accepts bypassing workspace save policy." }
    }
    $resolvedManifest = [IO.Path]::GetFullPath($WorkspaceManifestPath)
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "Workspace manifest does not exist: $resolvedManifest" }
    }
    try { $workspace = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json -Depth 50 } catch { return [pscustomobject]@{ allowed = $false; override = $false; error = "Workspace manifest is invalid JSON: $($_.Exception.Message)" } }
    $policy = if ($workspace.PSObject.Properties['savePolicy']) { [string]$workspace.savePolicy } else { '' }
    $workspaceStatus = if ($workspace.PSObject.Properties['status']) { [string]$workspace.status } else { '' }
    if ($workspaceStatus -notin @('ready', 'retained')) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "Workspace status '$workspaceStatus' is not authorized for a DevBench game mutation." }
    }
    if ($policy -in @('MainMenuOnly', 'FreshGame')) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "Workspace save policy '$policy' forbids DevBench game action '$($Request.action)' at $($Request.path)." }
    }
    if ($policy -ne 'VerifiedFixture') {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "Workspace save policy '$policy' is absent or unsupported; refusing DevBench game mutation." }
    }
    if ($Request.action -ne 'load') {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "VerifiedFixture authorizes only its exact declared load; action '$($Request.action)' is not permitted." }
    }
    $fixture = if ($workspace.PSObject.Properties['saveFixture']) { $workspace.saveFixture } else { $null }
    if (-not $workspace.PSObject.Properties['copiedVerifiedSaves'] -or -not [bool]$workspace.copiedVerifiedSaves) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = 'VerifiedFixture manifest does not prove that its declared save files were copied and verified.' }
    }
    $expectedName = if ($fixture -and $fixture.PSObject.Properties['loadName']) { [string]$fixture.loadName } else { '' }
    $actualName = if ($Request.arguments.Contains('name')) { [string]$Request.arguments['name'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($expectedName) -or -not [string]::Equals($actualName, $expectedName, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "VerifiedFixture load name mismatch at $($Request.path): requested '$actualName', expected '$expectedName'." }
    }
    if (-not $workspace.PSObject.Properties['profilePath'] -or [string]::IsNullOrWhiteSpace([string]$workspace.profilePath)) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = 'VerifiedFixture manifest does not declare its exact profile path.' }
    }
    $expectedDirectory = [IO.Path]::GetFullPath((Join-Path ([string]$workspace.profilePath) 'saves')).TrimEnd('\')
    $actualDirectory = if ($Request.arguments.Contains('dir') -and -not [string]::IsNullOrWhiteSpace([string]$Request.arguments['dir'])) { [IO.Path]::GetFullPath([string]$Request.arguments['dir']).TrimEnd('\') } else { '' }
    if (-not [string]::Equals($actualDirectory, $expectedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ allowed = $false; override = $false; error = "VerifiedFixture saves directory mismatch at $($Request.path): requested '$actualDirectory', expected '$expectedDirectory'." }
    }
    return [pscustomobject]@{ allowed = $true; override = $false; error = $null; policy = $policy; manifestPath = $resolvedManifest; loadName = $expectedName }
}

function Invoke-McpRequest {
    param([string]$Endpoint, [hashtable]$Headers, $Payload, [switch]$Mutation)
    $body = $Payload | ConvertTo-Json -Depth 30 -Compress
    $attempt = 0
    $delay = [Math]::Max(50, $PollMilliseconds)
    while ($true) {
        $attempt++
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body $body -TimeoutSec (Get-RequestTimeoutSeconds)
            return [pscustomobject]@{ response = $response; json = ($response.Content | ConvertFrom-Json -Depth 50); attempts = $attempt }
        }
        catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            $transient = $statusCode -in @(408, 429, 500, 502, 503, 504) -or
                ($Command -eq 'wait' -and $statusCode -eq 404) -or
                $_.Exception -is [System.TimeoutException] -or
                $_.Exception.Message -match 'timed out|temporarily unavailable|connection.*closed'
            if ($Mutation -and $transient) {
                $transportRetries.Add([pscustomobject][ordered]@{
                    attempt = $attempt; statusCode = $statusCode; delayMilliseconds = 0
                    recovery = 'not-retried-indeterminate'; message = $_.Exception.Message; timestampUtc = [DateTime]::UtcNow.ToString('o')
                })
                $indeterminate = [InvalidOperationException]::new('DevBench mutation transport failed after dispatch; the command may already have committed and was not replayed. Reconcile by commandId and runtime state before any retry.', $_.Exception)
                $indeterminate.Data['DevBenchIndeterminateMutation'] = $true
                throw $indeterminate
            }
            if ($Command -eq 'wait' -and $statusCode -eq 404 -and $Headers.ContainsKey('Mcp-Session-Id')) {
                $transportRetries.Add([pscustomobject][ordered]@{
                    attempt = $attempt; statusCode = $statusCode; delayMilliseconds = 0
                    recovery = 'full-runtime-rebind-required'; message = $_.Exception.Message; timestampUtc = [DateTime]::UtcNow.ToString('o')
                })
                throw
            }
            if (-not $transient -or $attempt -gt $MaxTransientRetries) { throw }
            $transportRetries.Add([pscustomobject][ordered]@{
                attempt = $attempt
                statusCode = $statusCode
                delayMilliseconds = $delay
                message = $_.Exception.Message
                timestampUtc = [DateTime]::UtcNow.ToString('o')
            })
            Start-OperationDelay -RequestedMilliseconds $delay
            $delay = [Math]::Min($MaxPollMilliseconds, $delay * 2)
        }
    }
}

function Invoke-ToolRpc {
    param([string]$Name, [hashtable]$Arguments, [hashtable]$Headers, [switch]$Mutation)
    $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $Headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments } } -Mutation:$Mutation
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

function Test-WaitRetryableException {
    param([Parameter(Mandatory)]$Exception)
    $message = [string]$Exception.Message
    $statusCode = $null
    try { $statusCode = [int]$Exception.Response.StatusCode } catch { $statusCode = $null }
    return $statusCode -in @(404, 429, 502, 503, 504) -or
        $message -match '\[(404|429|502|503|504)\]|timed out|temporarily unavailable|connection.*closed|connection.*refused|actively refused|main-thread task did not run|main thread busy'
}

function Open-McpSession($Runtime, [switch]$AllowDeferredBuildIdentity) {
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $initialize = Invoke-McpRequest -Endpoint $endpoint -Headers $baseHeaders -Payload @{
        jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'initialize'; params = @{
            protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'DevBenchControl'; version = '1.4' }
        }
    }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $sessionHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $sessionHeaders -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec (Get-RequestTimeoutSeconds) | Out-Null
    $listRpc = Invoke-McpRequest -Endpoint $endpoint -Headers $sessionHeaders -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
    if ($listRpc.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($listRpc.json.error | ConvertTo-Json -Compress)" }
    $sessionTools = @($listRpc.json.result.tools)
    $identity = $null
    if (-not $SkipRuntimeIdentityVerification) {
        $identity = Get-RuntimeIdentity -Runtime $Runtime -Headers $sessionHeaders -Tools $sessionTools -AllowDeferredBuildIdentity:$AllowDeferredBuildIdentity
        if ($identity.errors.Count -gt 0) { throw "DevBench runtime identity verification failed: $($identity.errors -join ' ')" }
    }
    return [pscustomobject][ordered]@{ headers = $sessionHeaders; tools = $sessionTools; runtimeIdentity = $identity; sessionId = $sessionId }
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
                    elseif ($payload.PSObject.Properties['server']) { $producer = $payload.server }
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
    elseif (
        $expectations.buildId -and
        $actualBuildId -and
        -not [string]::Equals(
            ([string]$actualBuildId).Trim(),
            ([string]$expectations.buildId).Trim(),
            [StringComparison]::OrdinalIgnoreCase)
    ) {
        $errors.Add("Expected CSX build ID '$($expectations.buildId)' differs from runtime build ID '$actualBuildId'.")
    }
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
    $rawLabel = if (-not [string]::IsNullOrWhiteSpace($EvidenceLabel)) {
        $EvidenceLabel
    } elseif ($Command -eq 'wait') {
        "$Command-$Condition-$Tool"
    } else {
        "$Command-$Tool"
    }
    $safeLabel = ($rawLabel -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = 'invocation' }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path = Join-Path $resolved "devbench-runtime-binding.$safeLabel.$stamp.$PID.json"
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
    Initialize-InvocationEvidence
    if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.' }
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
    $runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if (-not $runtime.PSObject.Properties['port']) { throw 'DevBench runtime metadata has no port.' }
    $endpoint = "http://127.0.0.1:$([int]$runtime.port)/mcp"
    $arguments = $null
    if ($Command -eq 'call') {
        if ([string]::IsNullOrWhiteSpace($Tool)) { throw 'Tool is required for call.' }
        try { $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        if ($arguments.Contains('commandId')) { $script:invocationRecord.commandId = [string]$arguments['commandId']; Write-JsonAtomic -Path $script:invocationEvidencePath -Value $script:invocationRecord }
        $unsafeTfc1Path = Find-UnsafeTfc1 -Value $arguments
        if ($unsafeTfc1Path -and -not $AllowUnsafeTfc1) {
            $message = "Unsafe Skyrim VR console command 'tfc 1' was found at $unsafeTfc1Path. It has a confirmed null-camera crash path; use a stationary scene without simulation freeze, or pass -AllowUnsafeTfc1 only for an explicitly accepted crash-risk experiment."
            Update-InvocationEvidence -State 'guard-rejected' -Errors @($message)
            throw $message
        }
        foreach ($gameRequest in @(Get-GameMutationRequests -ToolName $Tool -Arguments $arguments)) {
            $policyResult = Test-GameMutationPolicy -Request $gameRequest
            if (-not $policyResult.allowed) {
                Update-InvocationEvidence -State 'guard-rejected' -Errors @([string]$policyResult.error)
                throw [string]$policyResult.error
            }
        }
    }
    $headers = $null
    $tools = @()
    $evidencePath = $null
    if ($Command -ne 'wait') {
        $session = Open-McpSession -Runtime $runtime
        $headers = $session.headers
        $tools = @($session.tools)
        $runtimeIdentity = $session.runtimeIdentity
        if (-not $SkipRuntimeIdentityVerification) {
            if ($Command -eq 'call' -and -not $runtimeIdentity.complete) {
                throw "Mutation-capable DevBench calls require complete runtime identity. Missing: $($runtimeIdentity.missing -join ', ')."
            }
        }
        $evidencePath = Write-RuntimeEvidence $runtimeIdentity
    }

    $semantic = [pscustomobject][ordered]@{ known = $false; ok = $true; outcome = 'unknown'; guarded = $false; transient = $false; codes = @(); states = @(); reasons = @() }
    if ($Command -eq 'list') {
        if (-not [string]::IsNullOrWhiteSpace($ToolFilter)) { $tools = @($tools | Where-Object { $_.name -like "*$ToolFilter*" }) }
        $data = if ($NamesOnly) { [pscustomobject][ordered]@{ names = @($tools | ForEach-Object name); count = $tools.Count } } else { [pscustomobject][ordered]@{ tools = $tools } }
    }
    elseif ($Command -eq 'call') {
        if (@($tools | Where-Object name -eq $Tool).Count -ne 1) { throw "Tool '$Tool' is not present in the authoritative tools/list response." }
        Update-InvocationEvidence -State 'dispatching'
        $data = Invoke-ToolRpc -Name $Tool -Arguments $arguments -Headers $headers -Mutation
        $semantic = Get-DevBenchSemanticStatus -Content @($data.content)
        if ($Tool -eq 'communityshaders.profiler' -and -not $semantic.known) {
            $profilerPayload = @($data.content | Select-Object -First 1)
            if ($profilerPayload.Count -eq 1 -and -not $profilerPayload[0].PSObject.Properties['error']) {
                $requestedAction = [string]$arguments['action']
                $profilerSuccess =
                    ($requestedAction -eq 'status' -and $profilerPayload[0].PSObject.Properties['status'] -and $profilerPayload[0].status.PSObject.Properties['frame_count']) -or
                    ($requestedAction -eq 'enable' -and $profilerPayload[0].PSObject.Properties['enabled'] -and [bool]$profilerPayload[0].enabled) -or
                    ($requestedAction -eq 'disable' -and $profilerPayload[0].PSObject.Properties['enabled'] -and -not [bool]$profilerPayload[0].enabled)
                if ($profilerSuccess) {
                    $semantic.known = $true
                    $semantic.ok = $true
                    $semantic.outcome = 'profiler-contract-satisfied'
                    $semantic.reasons = @()
                }
            }
        }
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
        $requiredTool = if ($Condition -in @('noBlockingMenu', 'mainMenuReady')) { 'menu' } elseif ($Condition -eq 'playerLoaded') { 'inspect' } else { $null }
        $waitArguments = @{}
        $waitArgumentsResolved = $Condition -ne 'serviceReady'
        $serviceProbe = $null
        if ($Condition -eq 'serviceReady') {
            try { $waitArguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $script:operationDeadlineUtc = $deadline
        $attempts = 0
        $observation = $null
        $currentDelay = $PollMilliseconds
        $progress = [Collections.Generic.List[object]]::new()
        $lastProgressUtc = [DateTime]::MinValue
        $firstCpu = $null
        $lastCpu = $null
        $playerTransitionObserved = $false
        $playerInitialState = $null
        do {
            $attempts++
            if ($null -eq $headers) {
                try {
                    $session = Open-McpSession -Runtime $runtime -AllowDeferredBuildIdentity:($Condition -in @('toolAvailable', 'serviceReady'))
                    $headers = $session.headers
                    $tools = @($session.tools)
                    $runtimeIdentity = $session.runtimeIdentity
                    $evidencePath = Write-RuntimeEvidence $runtimeIdentity
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $transportRetries.Add([pscustomobject][ordered]@{
                        attempt = $attempts; phase = 'initialize'; recovery = 'outer-wait-retry'
                        delayMilliseconds = $currentDelay; message = $_.Exception.Message; timestampUtc = [DateTime]::UtcNow.ToString('o')
                    })
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $false; retryable = $true; phase = 'initialize'; classification = 'api-initializing-or-unavailable'
                        probeError = $_.Exception.Message
                    }
                    Start-OperationDelay -RequestedMilliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
            }
            if ($requiredTool -and @($tools | Where-Object name -eq $requiredTool).Count -ne 1) {
                try {
                    $currentList = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
                    if ($currentList.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($currentList.json.error | ConvertTo-Json -Compress)" }
                    $tools = @($currentList.json.result.tools)
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $headers = $null
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; phase = 'tools-list'; probeError = $_.Exception.Message }
                    Start-OperationDelay -RequestedMilliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
                if (@($tools | Where-Object name -eq $requiredTool).Count -ne 1) {
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; phase = 'tool-registration'; requiredTool = $requiredTool; authoritativeToolCount = $tools.Count }
                    Start-OperationDelay -RequestedMilliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
            }
            if ($Condition -in @('noBlockingMenu', 'mainMenuReady')) {
                try {
                    $menu = @(Invoke-ToolRpc -Name 'menu' -Arguments @{ action = 'list' } -Headers $headers).content | Select-Object -First 1
                    $observation = if ($Condition -eq 'mainMenuReady') {
                        Test-DevBenchMainMenuReady -MenuState $menu -AllowedMenus $AllowedMainMenuMenus
                    } else {
                        Test-DevBenchNoBlockingMenu -MenuState $menu -IgnoredMenus $IgnoredMenus
                    }
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $headers = $null
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; probeError = $_.Exception.Message }
                }
            }
            elseif ($Condition -eq 'playerLoaded') {
                try {
                    $state = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'state' } -Headers $headers).content | Select-Object -First 1
                    $loaded = [bool]$state.playerLoaded
                    if ($null -eq $playerInitialState) { $playerInitialState = $loaded }
                    if (-not $loaded) { $playerTransitionObserved = $true }
                    $fresh = [bool]$AcceptAlreadyLoaded -or $playerTransitionObserved
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $loaded -and $fresh; state = $state; retryable = $false; probeError = $null
                        initialPlayerLoaded = $playerInitialState; freshTransitionObserved = $playerTransitionObserved
                        acceptAlreadyLoaded = [bool]$AcceptAlreadyLoaded
                    }
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $headers = $null
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; state = $null; retryable = $true; probeError = $_.Exception.Message }
                }
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
                    try {
                        if (-not $waitArgumentsResolved) {
                            $targetDefinition = @($currentTools | Where-Object name -eq $Tool | Select-Object -First 1)[0]
                            $serviceProbe = Resolve-DevBenchServiceProbeArguments -ToolDefinition $targetDefinition -Arguments $waitArguments -ArgumentsSupplied:$argumentsJsonSupplied -ToolName $Tool
                            $waitArguments = $serviceProbe.arguments
                            $waitArgumentsResolved = $true
                        }
                        $toolResult = Invoke-ToolRpc -Name $Tool -Arguments $waitArguments -Headers $headers
                        $service = Test-DevBenchServiceReady -Content @($toolResult.content) -AcceptedStates $AcceptedState -RetryableStates $RetryableState
                    }
                    catch {
                        if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                        $headers = $null
                        $service = [pscustomobject][ordered]@{
                            ready = $false
                            retryable = $true
                            terminalFailure = $false
                            state = 'transport_retry'
                            statePath = $null
                            probeError = $_.Exception.Message
                            semantic = $null
                        }
                    }
                }

                $now = [DateTime]::UtcNow
                if (($now - $lastProgressUtc).TotalSeconds -ge 5 -or $progress.Count -eq 0) {
                    $listenerProcessId = if ($runtimeIdentity -and $runtimeIdentity.listenerPid) { [int]$runtimeIdentity.listenerPid } else { Get-ListenerPid ([int]$runtime.port) }
                    $processSample = $null
                    if ($listenerProcessId) {
                        $process = Get-Process -Id $listenerProcessId -ErrorAction SilentlyContinue
                        if ($process) {
                            $lastCpu = [double]$process.CPU
                            if ($null -eq $firstCpu) { $firstCpu = $lastCpu }
                            $processSample = [pscustomobject][ordered]@{ pid = $listenerProcessId; responding = $(try { [bool]$process.Responding } catch { $null }); cpuSeconds = $lastCpu; workingSetBytes = [long]$process.WorkingSet64 }
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
                    serviceProbe = $serviceProbe
                    classification = $classification
                    cpuDeltaSeconds = $cpuDelta
                    authoritativeToolCount = $currentTools.Count
                    progress = @($progress)
                }
                if ($service -and $service.terminalFailure) { break }
            }
            if ($observation.satisfied) { break }
            Start-OperationDelay -RequestedMilliseconds $currentDelay
            if ($Condition -in @('toolAvailable', 'serviceReady')) { $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2) }
        } while ([DateTime]::UtcNow -lt $deadline)
        $data = [pscustomobject][ordered]@{ condition = $Condition; satisfied = [bool]$observation.satisfied; attempts = $attempts; timeoutSeconds = $TimeoutSeconds; initialPollMilliseconds = $PollMilliseconds; maxPollMilliseconds = $MaxPollMilliseconds; observation = $observation }
        if ($observation.satisfied -and -not $SkipRuntimeIdentityVerification) { $evidencePath = Write-RuntimeEvidence $runtimeIdentity }
        $semantic = [pscustomobject][ordered]@{ known = $true; ok = [bool]$observation.satisfied; reasons = $(if ($observation.satisfied) { @() } else { @("Condition '$Condition' was not satisfied within $TimeoutSeconds seconds.") }) }
    }

    if ($RequireSuccess -and -not $semantic.known) {
        $semantic.outcome = 'unverified'
        $semantic.reasons = @($semantic.reasons) + 'RequireSuccess was requested, but the response did not provide a verified semantic outcome.'
    }
    $semanticFailure = if ($Command -eq 'call') { -not $semantic.known -or -not $semantic.ok } elseif ($RequireSuccess) { -not $semantic.known -or -not $semantic.ok } else { $semantic.known -and -not $semantic.ok -and $Command -eq 'wait' }
    $result = [pscustomobject][ordered]@{
        ok = -not $semanticFailure
        transportOk = $true
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $evidencePath
        invocationEvidencePath = $invocationEvidencePath
        semantic = $semantic
        transportRetries = @($transportRetries)
        data = $data
        errors = $(if ($semanticFailure) { @($semantic.reasons) } else { @() })
    }
    Update-InvocationEvidence -State 'completed' -Semantic $semantic -Data $data -Errors @($result.errors)
}
catch {
    $failureMessage = $_.Exception.Message
    $indeterminateMutation = [bool]$_.Exception.Data['DevBenchIndeterminateMutation']
    if ($invocationRecord -and $invocationRecord.state -ne 'guard-rejected') {
        try { Update-InvocationEvidence -State $(if ($indeterminateMutation) { 'indeterminate' } else { 'failed' }) -Errors @($failureMessage) } catch { $failureMessage = "$failureMessage Evidence update also failed: $($_.Exception.Message)" }
    }
    $result = [pscustomobject][ordered]@{
        ok = $false
        transportOk = $false
        state = if ($indeterminateMutation) { 'indeterminate-mutation' } else { 'failed' }
        indeterminate = $indeterminateMutation
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $invocationEvidencePath
        invocationEvidencePath = $invocationEvidencePath
        semantic = $null
        transportRetries = @($transportRetries)
        data = $null
        errors = @($failureMessage)
    }
}

$parameters = @{ InputObject = $result; Depth = 50 }
if ($Compact) { $parameters['Compress'] = $true }
ConvertTo-Json @parameters
if (-not $result.ok -and -not $NoExit) { exit $(if ($result.PSObject.Properties['indeterminate'] -and $result.indeterminate) { 3 } else { 2 }) }
