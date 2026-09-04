# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) { if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) } }

$success = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'success'; value = 0 } })
Assert-Test ($success.known -and $success.ok) 'semantic status recognizes a successful API payload'
$conflict = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'idempotency_conflict'; value = 12 } })
Assert-Test ($conflict.known -and -not $conflict.ok) 'semantic status rejects a non-success API payload'
$scenario = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ ok = $false; aborted = $true })
Assert-Test ($scenario.known -and -not $scenario.ok -and $scenario.reasons.Count -eq 2) 'semantic status preserves scenario failure reasons'
$producerMismatch = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch'; message = 'wrong build' } })
Assert-Test ($producerMismatch.known -and -not $producerMismatch.ok -and $producerMismatch.guarded -and $producerMismatch.outcome -eq 'guard-rejected') 'producer mismatch is a known guarded rejection'
$transient = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ result = [pscustomobject]@{ state = 'service_unavailable' } })
Assert-Test ($transient.transient -and $transient.states -contains 'service_unavailable') 'transient service state is classified recursively'
$unknown = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ playerLoaded = $true })
Assert-Test (-not $unknown.known -and $unknown.ok) 'unclassified content remains transport-successful'
$schedulerOnly = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 2; result = [pscustomobject]@{ ok = $true; aborted = $false; stepsRun = 2397; elapsedMs = 161035 } })
Assert-Test (-not $schedulerOnly.known -and $schedulerOnly.ok -and $schedulerOnly.schedulerOnly -and $schedulerOnly.outcome -eq 'scheduler-complete-unverified') 'replay scheduler completion is not promoted to semantic success'
$verifiedReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 3; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = [pscustomobject]@{ ok = $true } })
Assert-Test ($verifiedReplay.known -and $verifiedReplay.ok -and -not $verifiedReplay.schedulerOnly) 'explicit replay postconditions establish semantic evidence'
$nullEvidenceReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 4; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; semantic = $null; assertions = @() })
Assert-Test (-not $nullEvidenceReplay.known -and $nullEvidenceReplay.schedulerOnly) 'null or empty outcome fields do not verify replay semantics'
$failedAssertionReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 5; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; assertions = @([pscustomobject]@{ passed = $false }) })
Assert-Test ($failedAssertionReplay.known -and -not $failedAssertionReplay.ok -and -not $failedAssertionReplay.schedulerOnly) 'explicit failed assertions reject replay semantics'

$ready = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test ($ready.ready -and -not $ready.retryable -and $ready.statePath -eq 'content.result.state') 'service readiness prefers result.state'
$waiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'compiling' } })
Assert-Test (-not $waiting.ready -and $waiting.retryable -and -not $waiting.terminalFailure) 'compiling service remains retryable'
$dispatchWaiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'main_thread_dispatch_failed'; retryable = $true } })
Assert-Test (-not $dispatchWaiting.ready -and $dispatchWaiting.retryable -and -not $dispatchWaiting.terminalFailure) 'explicitly retryable dispatch failure remains retryable'
$guarded = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } })
Assert-Test (-not $guarded.ready -and $guarded.terminalFailure) 'guard rejection terminates readiness wait'
$inspectReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ playerLoaded = $true; cell = 'Whiterun' })
Assert-Test (-not $inspectReady.ready -and $inspectReady.probeReturnedContent -and -not $inspectReady.semantic.known) 'a successful unclassified response never proves service readiness'
$textUnknown = Test-DevBenchServiceReady -Content @('answered')
Assert-Test (-not $textUnknown.ready -and $textUnknown.probeReturnedContent -and -not $textUnknown.semantic.known) 'arbitrary non-empty text never proves service readiness'
$emptyUnknown = Test-DevBenchServiceReady -Content @()
Assert-Test (-not $emptyUnknown.ready -and -not $emptyUnknown.probeReturnedContent) 'empty unknown content never proves service readiness'

$hudOnly = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test $hudOnly.satisfied 'HUD-only menu state is non-blocking'
$inventory = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu'); messageBoxOpen = $false })
Assert-Test (-not $inventory.satisfied -and $inventory.blockingMenus[0] -eq 'InventoryMenu') 'non-HUD menus remain blocking'
$modal = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $true })
Assert-Test (-not $modal.satisfied) 'message boxes remain blocking'
$mainReady = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'Main Menu'); messageBoxOpen = $false })
Assert-Test $mainReady.satisfied 'mainMenuReady represents the normal main-menu state without treating Main Menu as blocking'
$mainVrReady = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('Main Menu', 'Mist Menu', 'Fader Menu'); messageBoxOpen = $false })
Assert-Test $mainVrReady.satisfied 'mainMenuReady accepts the normal Skyrim VR mist and fader overlays'
$mainMissing = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test (-not $mainMissing.satisfied) 'mainMenuReady requires the main menu rather than accepting gameplay'
$mainObscured = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'Main Menu', 'MessageBoxMenu'); messageBoxOpen = $true })
Assert-Test (-not $mainObscured.satisfied -and $mainObscured.unexpectedMenus -contains 'MessageBoxMenu') 'mainMenuReady rejects modal or unexpected overlays'

$expectations = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921; pid = 123; exe = 'SkyrimVR.exe'; buildId = 'build-1'; dllPath = 'C:\Test\CommunityShaders.dll'; artifactSha256 = 'ABC' })
Assert-Test ($expectations.port -eq 8921 -and $expectations.pid -eq 123 -and $expectations.exe -eq 'SkyrimVR.exe') 'runtime expectations preserve process identity fields'
Assert-Test ($expectations.buildId -eq 'build-1' -and $expectations.artifactPath -like '*CommunityShaders.dll' -and $expectations.artifactSha256 -eq 'ABC') 'runtime expectations preserve build and deployed artifact identity'
$legacy = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921 })
Assert-Test ($null -eq $legacy.pid -and $null -eq $legacy.exe) 'legacy port-only runtime metadata remains supported'

$versionedTool = [pscustomobject]@{
    name = 'communityshaders.profiler'
    inputSchema = [pscustomobject]@{
        type = 'object'
        required = @('contractMajor', 'clientId', 'commandId', 'action')
        properties = [pscustomobject]@{
            contractMajor = [pscustomobject]@{ type = 'integer'; const = 1 }
            action = [pscustomobject]@{ type = 'string'; enum = @('registry', 'status', 'start') }
        }
    }
}
$autoProbe = Resolve-DevBenchServiceProbeArguments -ToolDefinition $versionedTool -Arguments @{} -ArgumentsSupplied:$false -ToolName $versionedTool.name
Assert-Test ($autoProbe.source -eq 'schema-registry-envelope' -and $autoProbe.arguments.action -eq 'registry' -and $autoProbe.arguments.contractMajor -eq 1) 'serviceReady synthesizes a non-mutating registry envelope for versioned tools'
Assert-Test ($autoProbe.arguments.clientId -eq 'devbench-control-service-ready' -and $autoProbe.arguments.commandId -like 'service-ready-*') 'synthesized service probes carry stable client and unique command identities'
$explicitProbeRejected = $false
try { $null = Resolve-DevBenchServiceProbeArguments -ToolDefinition $versionedTool -Arguments @{ action = 'start' } -ArgumentsSupplied:$true -ToolName $versionedTool.name }
catch { $explicitProbeRejected = $_.Exception.Message -match 'does not accept explicit' }
Assert-Test $explicitProbeRejected 'serviceReady rejects explicit arguments that could dispatch mutation on every poll'
$simpleTool = [pscustomobject]@{ name = 'simple'; inputSchema = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} } }
$simpleProbe = Resolve-DevBenchServiceProbeArguments -ToolDefinition $simpleTool -Arguments @{} -ArgumentsSupplied:$false -ToolName $simpleTool.name
Assert-Test ($simpleProbe.source -eq 'schema-empty-valid' -and $simpleProbe.arguments.Count -eq 0) 'schema-valid empty probes remain empty'

$entryPointText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') -Raw
Assert-Test ($entryPointText -notmatch '(?im)^\s*\$pid\s*=') 'entry point never assigns PowerShell reserved PID variable'
Assert-Test ($entryPointText -match '\$expectations\.buildId\s+-and\s+\$actualBuildId\s+-and') 'deferred build identity never compares a missing runtime build ID'
Assert-Test ($entryPointText -match '\$Command -eq ''wait'' -and \$statusCode -eq 404') 'transient MCP 404 recovery is restricted to bounded waits'
Assert-Test ($entryPointText -match 'full-runtime-rebind-required') 'bounded waits route invalidated MCP sessions through a full runtime rebind'
Assert-Test ($entryPointText -match 'if \(\$RequireSuccess\) \{ -not \$semantic\.known -or -not \$semantic\.ok \}') 'RequireSuccess rejects unknown as well as failed semantic outcomes'
Assert-Test ($entryPointText -match '\$semantic\.known -and -not \$semantic\.ok -and \$Command -eq ''wait''') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match '\$Command -eq ''call'' -and -not \$runtimeIdentity\.complete') 'mutation-capable calls require complete runtime identity'
Assert-Test ($entryPointText -match 'if \(\$Command -eq ''call''\) \{ -not \$semantic\.known -or -not \$semantic\.ok \}') 'mutation-capable calls fail closed on unknown semantic outcomes'
Assert-Test ($entryPointText -match '\$Tool -eq ''communityshaders\.profiler''') 'profiler calls have an explicit semantic contract adapter'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''status''[\s\S]{0,180}\.status\.PSObject\.Properties\[''frame_count''\]') 'profiler status requires a frame-bearing status payload'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''enable''[\s\S]{0,160}\[bool\]\$profilerPayload\[0\]\.enabled') 'profiler enable requires observed enabled state'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''disable''[\s\S]{0,180}-not \[bool\]\$profilerPayload\[0\]\.enabled') 'profiler disable requires observed disabled state'
Assert-Test ($entryPointText -match 'outcome = ''profiler-contract-satisfied''') 'accepted profiler responses report their contract-specific outcome'
Assert-Test ($entryPointText -match 'Invoke-ToolRpc -Name \$Tool -Arguments \$arguments -Headers \$headers -Mutation') 'user calls are explicitly classified as mutations'
Assert-Test ($entryPointText -match 'not-retried-indeterminate') 'ambiguous mutation transport failures are not replayed'
Assert-Test ($entryPointText -match 'Update-InvocationEvidence -State \$\(if \(\$indeterminateMutation\) \{ ''indeterminate'' \}') 'indeterminate mutation outcomes are durably journaled'
Assert-Test ($entryPointText -match '\$headers = \$null[\s\S]{0,300}probeError') 'wait probe transport failures force full session and identity rebind'
Assert-Test ($entryPointText -match '-TimeoutSec \(Get-RequestTimeoutSeconds\)') 'wait requests consume only their remaining operation budget'
Assert-Test ($entryPointText -match '\$operationDeadlineUtc = \[DateTime\]::UtcNow.AddSeconds\(\$TimeoutSeconds\)' -and $entryPointText -notmatch '\[Math\]::Min\(15,') 'blocking calls use the declared operation budget instead of a fixed 15-second transport cap'
Assert-Test ($entryPointText -notmatch 'Start-Sleep -Milliseconds \$currentDelay') 'wait poll delays cannot exceed the operation deadline'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "state = 'transport_retry'") 'serviceReady carries transient probe exhaustion into the outer wait'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match "phase = 'initialize'; recovery = 'outer-wait-retry'") 'wait initialization failures remain inside the outer timeout state machine'
Assert-Test ($entryPointText -match '\$null -eq \$headers') 'bounded waits establish or re-establish the MCP session inside the polling loop'
Assert-Test ($entryPointText -match '\[switch\]\$AcceptAlreadyLoaded') 'playerLoaded exposes an explicit compatibility opt-out for freshness'
Assert-Test ($entryPointText -match '\$playerTransitionObserved') 'playerLoaded requires an observed unloaded-to-loaded transition by default'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('devbench-control-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $runtimePath = Join-Path $fixture 'runtime.json'
    [IO.File]::WriteAllText($runtimePath, '{"port":65534}', [Text.UTF8Encoding]::new($false))
    $entryPoint = Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'
    $guardResult = & $entryPoint call -Tool scenario -ArgumentsJson '{"steps":[{"consoleCommand":"tfc 1"}]}' -RuntimePath $runtimePath -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $guardResult.ok -and $guardResult.errors[0] -match 'confirmed null-camera crash path') 'tfc 1 is rejected before transport dispatch'
    Assert-Test (Test-Path -LiteralPath $guardResult.invocationEvidencePath -PathType Leaf) 'guard rejection preserves a durable invocation journal'
    $guardEvidence = Get-Content -LiteralPath $guardResult.invocationEvidencePath -Raw | ConvertFrom-Json
    Assert-Test ($guardEvidence.state -eq 'guard-rejected' -and $null -eq $guardEvidence.dispatchedUtc) 'guard evidence proves no request was dispatched'

    $missingRuntime = Join-Path $fixture 'missing-runtime.json'
    $failedResult = & $entryPoint list -RuntimePath $missingRuntime -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $failedResult.ok -and (Test-Path -LiteralPath $failedResult.invocationEvidencePath -PathType Leaf)) 'pre-dispatch failures return durable evidence'
    $failedEvidence = Get-Content -LiteralPath $failedResult.invocationEvidencePath -Raw | ConvertFrom-Json
    Assert-Test ($failedEvidence.state -eq 'failed' -and $failedEvidence.errors.Count -eq 1) 'failed invocation journal preserves its terminal error'

    $freshManifest = Join-Path $fixture 'fresh-workspace.json'
    [pscustomobject]@{ status = 'ready'; savePolicy = 'FreshGame'; profilePath = (Join-Path $fixture 'profile'); saveFixture = $null } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $freshManifest -Encoding utf8
    $freshResult = & $entryPoint call -Tool game -ArgumentsJson '{"action":"load","name":"Save 3"}' -RuntimePath $runtimePath -WorkspaceManifestPath $freshManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $freshResult.ok -and $freshResult.errors[0] -match "FreshGame.*forbids") 'FreshGame policy rejects a direct save load before dispatch'
    $consoleLoadResult = & $entryPoint call -Tool console -ArgumentsJson '{"command":"load Save 3"}' -RuntimePath $runtimePath -WorkspaceManifestPath $freshManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $consoleLoadResult.ok -and $consoleLoadResult.errors[0] -match "FreshGame.*forbids") 'console load rerouting cannot bypass workspace save policy'

    $verifiedManifest = Join-Path $fixture 'verified-workspace.json'
    [pscustomobject]@{ status = 'ready'; savePolicy = 'VerifiedFixture'; profilePath = (Join-Path $fixture 'profile'); copiedVerifiedSaves = $true; saveFixture = [pscustomobject]@{ loadName = 'Breezehome 003' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedManifest -Encoding utf8
    $mismatchResult = & $entryPoint call -Tool scenario -ArgumentsJson '{"steps":[{"tool":"game","args":{"action":"load","name":"Other Save"}}]}' -RuntimePath $runtimePath -WorkspaceManifestPath $verifiedManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $mismatchResult.ok -and $mismatchResult.errors[0] -match 'load name mismatch') 'nested scenario loads must match the exact VerifiedFixture selector'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) { exit 1 }
