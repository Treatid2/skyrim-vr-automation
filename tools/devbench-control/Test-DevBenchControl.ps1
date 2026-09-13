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
$neutralPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false; performanceEpoch = 7; physicalStateKnown = $true })
Assert-Test ($neutralPerformance.known -and $neutralPerformance.neutral -and $neutralPerformance.performanceEpoch -eq 7) 'proven disarmed standalone probe permits performance measurement'
$distortedPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $true; performanceEpoch = 8; physicalStateKnown = $true })
Assert-Test ($distortedPerformance.known -and -not $distortedPerformance.neutral -and $distortedPerformance.reason -eq 'intrusive-temporal-probe-armed') 'armed standalone probe rejects performance measurement'
$unprovenPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false; performanceEpoch = 9; physicalStateKnown = $false })
Assert-Test ($unprovenPerformance.known -and -not $unprovenPerformance.neutral -and $unprovenPerformance.reason -eq 'performance-physical-state-unproven') 'unproven physical cleanup fails closed'
$unknownPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false })
Assert-Test (-not $unknownPerformance.known -and -not $unknownPerformance.neutral -and $unknownPerformance.reason -eq 'performance-ownership-state-missing') 'registered legacy probe without ownership epoch fails closed'
$guardBefore = [pscustomobject]@{ applicable = $true; neutral = $true; performanceEpoch = 12; reason = 'intrusive-temporal-probe-disarmed' }
$guardAfter = [pscustomobject]@{ applicable = $true; neutral = $true; performanceEpoch = 12; reason = 'intrusive-temporal-probe-disarmed' }
$stableWindow = Test-DevBenchPerformanceWindow -Before $guardBefore -After $guardAfter
Assert-Test ($stableWindow.valid -and $stableWindow.sameEpoch) 'unchanged neutral probe epoch admits a measurement window'
$guardAfter.performanceEpoch = 13
$changedWindow = Test-DevBenchPerformanceWindow -Before $guardBefore -After $guardAfter
Assert-Test (-not $changedWindow.valid -and $changedWindow.reason -eq 'performance-probe-epoch-changed') 'arm/disarm activity invalidates a measurement window'
$schedulerOnly = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 2; result = [pscustomobject]@{ ok = $true; aborted = $false; stepsRun = 2397; elapsedMs = 161035 } })
Assert-Test (-not $schedulerOnly.known -and $schedulerOnly.ok -and $schedulerOnly.schedulerOnly -and $schedulerOnly.outcome -eq 'scheduler-complete-unverified') 'replay scheduler completion is not promoted to semantic success'
$verifiedReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 3; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = [pscustomobject]@{ ok = $true } })
Assert-Test ($verifiedReplay.known -and $verifiedReplay.ok -and -not $verifiedReplay.schedulerOnly) 'explicit replay postconditions establish semantic evidence'
$nullEvidenceReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 4; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; semantic = $null; assertions = @() })
Assert-Test (-not $nullEvidenceReplay.known -and $nullEvidenceReplay.schedulerOnly) 'null or empty outcome fields do not verify replay semantics'
$failedAssertionReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 5; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; assertions = @([pscustomobject]@{ passed = $false }) })
Assert-Test ($failedAssertionReplay.known -and -not $failedAssertionReplay.ok -and -not $failedAssertionReplay.schedulerOnly) 'explicit failed assertions reject replay semantics'
$falseOutcomeReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 6; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = $false })
Assert-Test (-not $falseOutcomeReplay.known -and $falseOutcomeReplay.schedulerOnly -and $falseOutcomeReplay.outcome -eq 'scheduler-complete-unverified') 'a false Boolean postcondition never verifies replay semantics'
$falseOutcomeArrayReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 7; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; outcomeChecks = @($false) })
Assert-Test (-not $falseOutcomeArrayReplay.known -and $falseOutcomeArrayReplay.schedulerOnly) 'an array containing only false outcomes never verifies replay semantics'
$neutralOutcomeReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 8; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = [pscustomobject]@{ failed = $false } })
Assert-Test (-not $neutralOutcomeReplay.known -and $neutralOutcomeReplay.schedulerOnly -and $neutralOutcomeReplay.explicitOutcomeEvidence.Count -eq 0 -and $neutralOutcomeReplay.rejectedOutcomeEvidence.Count -gt 0) 'a neutral failed-false outcome object remains unverified rather than becoming positive replay proof'
foreach ($mixedCase in @(
    [pscustomobject]@{ values = @($true, $false) },
    [pscustomobject]@{ values = @($false, $true) }
)) {
    $mixedOutcomeReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 9; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; outcomeChecks = $mixedCase.values })
    Assert-Test (-not $mixedOutcomeReplay.known -and $mixedOutcomeReplay.schedulerOnly -and $mixedOutcomeReplay.explicitOutcomeEvidence.Count -eq 0) 'mixed true/false replay evidence cannot be promoted in either order'
}
$nestedMixedReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 10; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; semantic = [pscustomobject]@{ checks = @([pscustomobject]@{ passed = $true }, $false) } })
Assert-Test (-not $nestedMixedReplay.known -and $nestedMixedReplay.schedulerOnly -and $nestedMixedReplay.rejectedOutcomeEvidence.Count -gt 0) 'nested mixed Boolean evidence cannot be neutralized by a positive sibling'
$crossContainerMixedReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 11; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = $false; assertions = @([pscustomobject]@{ passed = $true }) })
Assert-Test (-not $crossContainerMixedReplay.known -and $crossContainerMixedReplay.schedulerOnly -and $crossContainerMixedReplay.explicitOutcomeEvidence.Count -eq 0) 'a positive assertion cannot neutralize a false sibling outcome container'
$readOnlyInspect = Test-DevBenchReadOnlyRequest -ToolName inspect -Arguments @{ kind = 'scene' }
$readOnlyMenu = Test-DevBenchReadOnlyRequest -ToolName menu -Arguments @{ action = 'list' }
$mutatingMenu = Test-DevBenchReadOnlyRequest -ToolName menu -Arguments @{ action = 'open'; name = 'InventoryMenu' }
Assert-Test ($readOnlyInspect -and $readOnlyMenu -and -not $mutatingMenu) 'read-only request classification is explicit and action-sensitive'
$inspectSemantic = Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments @{ kind = 'state' } -Content @([pscustomobject]@{ playerLoaded = $true; frame = 42 })
Assert-Test ($inspectSemantic.known -and $inspectSemantic.ok -and $inspectSemantic.outcome -eq 'read-contract-satisfied') 'structured read-only responses satisfy RequireSuccess semantics'
$renderScaleSemantic = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.renderscale' -Arguments @{ action = 'status' } -Content @([pscustomobject]@{ action = 'status'; status = [pscustomobject]@{ controller = [pscustomobject]@{ state = 'Active'; revision = 42 } } })
Assert-Test ($renderScaleSemantic.known -and $renderScaleSemantic.ok -and $renderScaleSemantic.outcome -eq 'read-contract-satisfied') 'render-scale status recognizes its explicit structured read contract'
$renderScaleMissingStatus = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.renderscale' -Arguments @{ action = 'status' } -Content @([pscustomobject]@{ action = 'status' })
Assert-Test (-not $renderScaleMissingStatus.known) 'render-scale status rejects a response without structured status telemetry'
$renderScaleArrayStatus = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.renderscale' -Arguments @{ action = 'status' } -Content @([pscustomobject]@{ action = 'status'; status = [object[]]@() })
Assert-Test (-not $renderScaleArrayStatus.ok -and $renderScaleArrayStatus.outcome -ne 'read-contract-satisfied') 'render-scale status rejects an array replacing its required status object'
$screenshotCapabilities = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ schema = 'urn:csx:devbench:screenshot:1'; limits = [pscustomobject]@{ maximumSequenceFrames = 10000; maximumSequenceDurationMs = 3600000 } })
Assert-Test ($screenshotCapabilities.known -and $screenshotCapabilities.ok -and $screenshotCapabilities.outcome -eq 'read-contract-satisfied') 'screenshot capabilities recognize exact sequence limits as a read contract'
$screenshotFractionalLimit = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ schema = 'urn:csx:devbench:screenshot:1'; limits = [pscustomobject]@{ maximumSequenceFrames = 10000; maximumSequenceDurationMs = 3600000.5 } })
Assert-Test ($screenshotFractionalLimit.known -and -not $screenshotFractionalLimit.ok) 'screenshot capabilities reject a fractional sequence limit'
$screenshotBooleanLimit = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ schema = 'urn:csx:devbench:screenshot:1'; limits = [pscustomobject]@{ maximumSequenceFrames = $true; maximumSequenceDurationMs = 3600000 } })
Assert-Test ($screenshotBooleanLimit.known -and -not $screenshotBooleanLimit.ok) 'screenshot capabilities reject a Boolean sequence limit'
$screenshotNullLimit = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ schema = 'urn:csx:devbench:screenshot:1'; limits = [pscustomobject]@{ maximumSequenceFrames = 10000; maximumSequenceDurationMs = $null } })
Assert-Test ($screenshotNullLimit.known -and -not $screenshotNullLimit.ok) 'screenshot capabilities reject a null sequence limit without a strict-mode exception'
$screenshotGenericWrongSchema = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ ok = $true; schema = 'wrong'; limits = [pscustomobject]@{ maximumSequenceFrames = 10000; maximumSequenceDurationMs = 3600000 } })
Assert-Test ($screenshotGenericWrongSchema.known -and -not $screenshotGenericWrongSchema.ok) 'generic success cannot bypass the screenshot capabilities schema'
$screenshotGenericValid = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ ok = $true; schema = 'urn:csx:devbench:screenshot:1'; limits = [pscustomobject]@{ maximumSequenceFrames = 10000; maximumSequenceDurationMs = 3600000 } })
Assert-Test ($screenshotGenericValid.known -and $screenshotGenericValid.ok) 'generic success remains compatible with a valid screenshot capabilities contract'
$screenshotArrayLimits = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'capabilities' } -Content @([pscustomobject]@{ schema = 'urn:csx:devbench:screenshot:1'; limits = [object[]]@() })
Assert-Test ($screenshotArrayLimits.known -and -not $screenshotArrayLimits.ok -and $screenshotArrayLimits.reasons -match 'not a structured screenshot limits object') 'screenshot capabilities rejects an array replacing its limits object'
$screenshotRequest = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_get'; requestId = 'req-1' } -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ requestId = 'req-1'; state = 'completed'; terminal = $true } })
Assert-Test ($screenshotRequest.known -and $screenshotRequest.ok -and $screenshotRequest.outcome -eq 'read-contract-satisfied') 'screenshot request_get accepts one exact terminal request receipt through the real semantic classifier'
$screenshotRunningRequest = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_get'; requestId = 'req-1' } -Content @([pscustomobject]@{ requestId = 'req-1'; state = 'running'; terminal = $false })
Assert-Test ($screenshotRunningRequest.known -and $screenshotRunningRequest.ok) 'screenshot request_get accepts an exact nonterminal receipt for continued polling'
$screenshotMismatchedRequest = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_get'; requestId = 'req-1' } -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ requestId = 'foreign'; state = 'completed'; terminal = $true } })
Assert-Test ($screenshotMismatchedRequest.known -and -not $screenshotMismatchedRequest.ok -and $screenshotMismatchedRequest.reasons -match 'does not match') 'screenshot request_get rejects a foreign request identity despite generic success'
$screenshotFailedRequest = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_get'; requestId = 'req-1' } -Content @([pscustomobject]@{ ok = $false; retryable = $true; result = [pscustomobject]@{ requestId = 'req-1'; state = 'completed'; terminal = $true } })
Assert-Test ($screenshotFailedRequest.known -and -not $screenshotFailedRequest.ok -and $screenshotFailedRequest.transient) 'screenshot request_get never promotes retryable negative evidence to a valid receipt'
$screenshotStatus = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'status' } -Content @([pscustomobject]@{ feature = [pscustomobject]@{}; dispatcher = [pscustomobject]@{}; journal = [pscustomobject]@{} })
Assert-Test ($screenshotStatus.known -and $screenshotStatus.ok) 'screenshot status accepts its exact structured sections'
$screenshotSettings = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'settings_get' } -Content @([pscustomobject]@{ settingsSchemaVersion = 2; effective = [pscustomobject]@{}; persisted = [pscustomobject]@{} })
Assert-Test ($screenshotSettings.known -and $screenshotSettings.ok) 'screenshot settings_get accepts its versioned settings receipt'
$screenshotList = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_list' } -Content @([pscustomobject]@{ requests = [object[]]@(); retained = 0 })
Assert-Test ($screenshotList.known -and $screenshotList.ok) 'screenshot request_list accepts an empty bounded collection receipt'
$screenshotEvents = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'events_poll' } -Content @([pscustomobject]@{ events = [object[]]@(); oldestRetainedEventId = 1; latestEventId = 0; nextEventId = 0; cursorExpired = $false; moreAvailable = $false })
Assert-Test ($screenshotEvents.known -and $screenshotEvents.ok) 'screenshot events_poll accepts its exact cursor and collection receipt'
foreach ($readAction in @('status', 'settings_get', 'request_get', 'request_list', 'events_poll')) {
    $arguments = @{ action = $readAction }
    if ($readAction -eq 'request_get') { $arguments.requestId = 'req-1' }
    $emptyResult = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments $arguments -Content @([pscustomobject]@{ result = [object[]]@() })
    Assert-Test ($emptyResult.known -and -not $emptyResult.ok -and $emptyResult.reasons -match 'not a structured') "screenshot $readAction rejects an array replacing its result object"
}
$screenshotArraySection = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'status' } -Content @([pscustomobject]@{ feature = [object[]]@(); dispatcher = [pscustomobject]@{}; journal = [pscustomobject]@{} })
Assert-Test (-not $screenshotArraySection.ok) 'screenshot status rejects an array replacing a required section object'
foreach ($pair in @(
    @{ state = 'running'; terminal = $true },
    @{ state = 'queued'; terminal = $true },
    @{ state = 'completed'; terminal = $false },
    @{ state = 'invented'; terminal = $false }
)) {
    $contradictory = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_get'; requestId = 'req-1' } -Content @([pscustomobject]@{ requestId = 'req-1'; state = $pair.state; terminal = $pair.terminal })
    Assert-Test ($contradictory.known -and -not $contradictory.ok) "screenshot request_get rejects unsupported or contradictory state '$($pair.state)' / terminal '$($pair.terminal)'"
}
$negativeRetained = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'request_list' } -Content @([pscustomobject]@{ requests = [object[]]@(); retained = -1 })
Assert-Test (-not $negativeRetained.ok) 'screenshot request_list rejects a negative retained count'
foreach ($cursorName in @('oldestRetainedEventId', 'latestEventId', 'nextEventId')) {
    $cursorPayload = [ordered]@{ events = [object[]]@(); oldestRetainedEventId = 0; latestEventId = 0; nextEventId = 0; cursorExpired = $false; moreAvailable = $false }
    $cursorPayload[$cursorName] = -1
    $negativeCursor = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.screenshot' -Arguments @{ action = 'events_poll' } -Content @([pscustomobject]$cursorPayload)
    Assert-Test (-not $negativeCursor.ok) "screenshot events_poll rejects negative $cursorName"
}
$recordSemantic = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ action = 'start'; recording = $true; correlationId = 'capture-1' })
Assert-Test ($recordSemantic.known -and $recordSemantic.ok -and $recordSemantic.outcome -eq 'record-start-contract-satisfied') 'record start validates the running receipt and correlation identity'
$recordMismatch = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ action = 'start'; recording = $true; correlationId = 'other' })
Assert-Test ($recordMismatch.known -and -not $recordMismatch.ok) 'record start rejects a mismatched correlation identity'
$recordGenericMismatch = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ ok = $true; action = 'start'; recording = $true; correlationId = 'other' })
Assert-Test ($recordGenericMismatch.known -and -not $recordGenericMismatch.ok) 'generic success cannot bypass the record-start correlation contract'
$recordArrayStart = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content (,@([pscustomobject]@{ action = 'start'; recording = $true; correlationId = 'capture-1' }))
Assert-Test ($recordArrayStart.known -and -not $recordArrayStart.ok -and $recordArrayStart.reasons -match 'structured record start receipt') 'record start rejects a collection replacing its receipt object'
foreach ($malformedOk in @('false', 0, $null, [pscustomobject]@{ value = $false })) {
    $malformedRecord = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ ok = $malformedOk; action = 'start'; recording = $true; correlationId = 'capture-1' })
    Assert-Test ($malformedRecord.known -and -not $malformedRecord.ok -and $malformedRecord.reasons -match 'not Boolean') 'record start rejects a present malformed generic outcome indicator'
}
$recordStop = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ action = 'stop'; sampleCount = 12; path = 'recording.json' })
Assert-Test ($recordStop.known -and $recordStop.ok -and $recordStop.outcome -eq 'record-stop-contract-satisfied') 'record stop recognizes its exact persisted recording receipt without a generic ok field'
foreach ($malformedPath in @(
    [pscustomobject]@{ value = $false; name = 'Boolean false' },
    [pscustomobject]@{ value = $true; name = 'Boolean true' },
    [pscustomobject]@{ value = 42; name = 'numeric' },
    [pscustomobject]@{ value = [object[]]@(); name = 'array' },
    [pscustomobject]@{ value = [pscustomobject]@{ file = 'recording.json' }; name = 'object' },
    [pscustomobject]@{ value = $null; name = 'null' },
    [pscustomobject]@{ value = ''; name = 'empty string' },
    [pscustomobject]@{ value = '   '; name = 'whitespace string' }
)) {
    $malformedRecordStop = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ action = 'stop'; path = $malformedPath.value })
    Assert-Test ($malformedRecordStop.known -and -not $malformedRecordStop.ok -and $malformedRecordStop.reasons -match 'non-empty string') "record stop rejects a $($malformedPath.name) persisted locator"
}
$missingRecordStopPath = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ action = 'stop' })
Assert-Test ($missingRecordStopPath.known -and -not $missingRecordStopPath.ok -and $missingRecordStopPath.reasons -match 'non-empty string') 'record stop rejects a missing persisted locator'
$recordStopError = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ error = 'not recording'; state = 'idle' })
Assert-Test ($recordStopError.known -and -not $recordStopError.ok -and $recordStopError.reasons -match 'not recording') 'record stop preserves its structured not-recording diagnostic'
$recordStopErrors = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ action = 'stop'; path = 'recording.json'; errors = @('flush failed') })
Assert-Test ($recordStopErrors.known -and -not $recordStopErrors.ok -and $recordStopErrors.reasons -match 'flush failed') 'record stop rejects a non-empty errors array despite an exact stop path'
$recordStopFailedStatus = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'stop' } -Content @([pscustomobject]@{ action = 'stop'; path = 'recording.json'; status = 'failed' })
Assert-Test ($recordStopFailedStatus.known -and -not $recordStopFailedStatus.ok -and $recordStopFailedStatus.reasons -match 'failed') 'record stop rejects a scalar failed status despite an exact persisted path'
$vrReleaseInactive = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content @([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; stopped = $false; notActive = $true })
Assert-Test ($vrReleaseInactive.known -and $vrReleaseInactive.ok -and $vrReleaseInactive.outcome -eq 'vr-tracked-set-stop-contract-satisfied') 'VR releaseAll accepts an exact already-inactive receipt'
$vrReleaseInactivePending = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content @([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; notActive = $true; restorationPending = $true })
Assert-Test ($vrReleaseInactivePending.known -and -not $vrReleaseInactivePending.ok) 'VR releaseAll cannot use notActive to bypass pending restoration'
$vrReleaseRestored = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content @([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; stopped = $true; restored = $true; restorationPending = $false; owner = 'capture:1'; reason = 'releaseAll' })
Assert-Test ($vrReleaseRestored.known -and $vrReleaseRestored.ok) 'VR releaseAll accepts exact completed restoration evidence'
$vrReleasePending = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content @([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; stopped = $false; restored = $false; restorationPending = $true; owner = 'capture:1'; reason = 'releaseAll' })
Assert-Test ($vrReleasePending.known -and -not $vrReleasePending.ok -and $vrReleasePending.reasons.Count -eq 3) 'VR releaseAll rejects incomplete restoration evidence'
$vrReleaseForeign = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content @([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; stopped = $true; restored = $true; restorationPending = $false; owner = 'foreign'; reason = 'releaseAll' })
Assert-Test ($vrReleaseForeign.known -and -not $vrReleaseForeign.ok -and $vrReleaseForeign.reasons -match 'owner') 'VR releaseAll never accepts completed restoration attributed to another owner'
$vrReleaseArray = Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = 'capture:1' } -Content (,@([pscustomobject]@{ action = 'stop'; device = 'vrTrackedSet'; notActive = $true }))
Assert-Test ($vrReleaseArray.known -and -not $vrReleaseArray.ok -and $vrReleaseArray.reasons -match 'structured VR tracked-set stop receipt') 'VR releaseAll rejects a collection replacing its ownership receipt object'
$weatherSuccess = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = [pscustomobject]@{ action = 'execute' }; result = [pscustomobject]@{ status = 'success'; applied = $true; changed = $false } })
Assert-Test ($weatherSuccess.known -and $weatherSuccess.ok -and $weatherSuccess.outcome -eq 'weather-execute-contract-satisfied') 'weather execute requires and accepts explicit applied success even when the state was unchanged'
$weatherArrayCommand = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = @([pscustomobject]@{ action = 'execute' }); result = [pscustomobject]@{ status = 'success'; applied = $true } })
Assert-Test ($weatherArrayCommand.known -and -not $weatherArrayCommand.ok -and $weatherArrayCommand.reasons -match 'command.action') 'weather execute rejects a collection replacing its command object'
foreach ($guardStatus in @('preflight_required', 'preflight_expired', 'state_revision_mismatch')) {
    $weatherGuard = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = [pscustomobject]@{ action = 'execute' }; result = [pscustomobject]@{ status = $guardStatus; applied = $false; changed = $false } })
    Assert-Test ($weatherGuard.known -and -not $weatherGuard.ok -and $weatherGuard.guarded -and $weatherGuard.codes -contains $guardStatus) "weather execute rejects guarded non-applied status $guardStatus despite top-level ok"
}
$weatherNotApplied = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = [pscustomobject]@{ action = 'execute' }; result = [pscustomobject]@{ status = 'success'; applied = $false; changed = $false } })
Assert-Test ($weatherNotApplied.known -and -not $weatherNotApplied.ok -and $weatherNotApplied.outcome -eq 'weather-execute-contract-failed') 'weather execute never promotes status success without Boolean applied success'
$weatherNestedError = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = [pscustomobject]@{ action = 'execute' }; result = [pscustomobject]@{ status = 'success'; applied = $true; error = 'commit failed' } })
Assert-Test ($weatherNestedError.known -and -not $weatherNestedError.ok -and $weatherNestedError.reasons -match 'commit failed') 'weather execute rejects nested scalar failure evidence despite success and applied fields'
foreach ($malformedWeatherResult in @(
    [pscustomobject]@{ value = [object[]]@(); name = 'empty array' },
    [pscustomobject]@{ value = @([pscustomobject]@{ status = 'success'; applied = $true }); name = 'non-empty array' }
)) {
    $weatherArray = Get-DevBenchCallSemanticStatus -ToolName 'communityshaders.weather_api' -Arguments @{ action = 'execute' } -Content @([pscustomobject]@{ ok = $true; command = [pscustomobject]@{ action = 'execute' }; result = $malformedWeatherResult.value })
    Assert-Test ($weatherArray.known -and -not $weatherArray.ok -and $weatherArray.reasons -match 'not a structured weather execute result') "weather execute rejects a $($malformedWeatherResult.name) replacing the result object"
}
$loadSemantic = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ action = 'load'; name = 'Save-1'; queued = $true })
Assert-Test ($loadSemantic.known -and $loadSemantic.ok -and $loadSemantic.outcome -eq 'game-load-dispatch-queued' -and $loadSemantic.completionBasis -eq 'dispatch-only') 'game load recognizes an exact queued dispatch without claiming current-state completion'
$loadMismatch = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ action = 'load'; name = 'Save-2'; queued = $true })
Assert-Test ($loadMismatch.known -and -not $loadMismatch.ok -and $loadMismatch.outcome -eq 'game-load-dispatch-rejected') 'game load rejects a queued receipt for a different save'
$loadNotQueued = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ action = 'load'; name = 'Save-1'; queued = $false })
Assert-Test ($loadNotQueued.known -and -not $loadNotQueued.ok) 'game load never promotes a non-queued receipt'
$loadGenericSuccess = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ ok = $true; action = 'load'; name = 'Save-1'; queued = $true })
Assert-Test ($loadGenericSuccess.ok -and $loadGenericSuccess.outcome -eq 'game-load-dispatch-queued' -and $loadGenericSuccess.completionBasis -eq 'dispatch-only') 'generic success metadata cannot bypass or replace the exact load receipt classification'
$loadGenericMismatch = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ success = $true; action = 'load'; name = 'Save-2'; queued = $true })
Assert-Test (-not $loadGenericMismatch.ok -and $loadGenericMismatch.outcome -eq 'game-load-dispatch-rejected') 'generic success metadata cannot promote a mismatched save receipt'
$loadWrongAction = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ ok = $true; action = 'save'; name = 'Save-1'; queued = $true })
Assert-Test (-not $loadWrongAction.ok) 'game load rejects a generic-success receipt for the wrong action'
$loadTypedQueue = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ ok = $true; action = 'load'; name = 'Save-1'; queued = 1 })
Assert-Test (-not $loadTypedQueue.ok) 'game load requires Boolean true queue evidence'
$loadMissingRequestName = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load' } -Content @([pscustomobject]@{ ok = $true; action = 'load'; name = 'Save-1'; queued = $true })
Assert-Test (-not $loadMissingRequestName.ok) 'game load requires a nonempty requested save identity'
$loadScalarError = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ ok = $true; action = 'load'; name = 'Save-1'; queued = $true; error = 'queue rejected' })
Assert-Test (-not $loadScalarError.ok) 'game load preserves contradictory scalar error evidence'
$loadMultiple = Get-DevBenchCallSemanticStatus -ToolName game -Arguments @{ action = 'load'; name = 'Save-1' } -Content @([pscustomobject]@{ ok = $true; action = 'load'; name = 'Save-1'; queued = $true }, [pscustomobject]@{ ok = $true })
Assert-Test (-not $loadMultiple.ok) 'game load requires exactly one structured receipt even with generic success metadata'
$readFailure = Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments @{ kind = 'state' } -Content @([pscustomobject]@{ error = 'main thread busy' })
Assert-Test ($readFailure.known -and -not $readFailure.ok -and $readFailure.outcome -eq 'read-contract-failed') 'read-only adapters never promote a structured error to success'
$incompleteMenu = Get-DevBenchCallSemanticStatus -ToolName menu -Arguments @{ action = 'list' } -Content @([pscustomobject]@{ openMenus = @() })
Assert-Test (-not $incompleteMenu.known) 'read-only adapters require the tool-specific response shape'

$planFixture = Join-Path ([IO.Path]::GetTempPath()) "csx-render-map-plan-test-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $planFixture | Out-Null
    $registryPath = Join-Path $planFixture 'registry.json'
    $workloadPath = Join-Path $planFixture 'workload.json'
    $planPath = Join-Path $planFixture 'plan.json'
    [pscustomobject]@{
        ok = $true
        result = [pscustomobject]@{
            service = 'communityshaders.render_map'
            major = 1
            defaults = [pscustomobject]@{ fixedCatalogueBytes = 1000 }
            limits = [pscustomobject]@{
                maximumBytes = 100000; maximumDurationMs = 10000; maximumEvents = 10000; maximumFrames = 100
                maximumScopeDepth = 32; maximumGeometryObservations = 1000; maximumMaterialStateObservations = 1000
                maximumResourceObservations = 1000; maximumSceneObjectObservations = 1000; maximumShaderObservations = 1000
                maximumStageShaderObservations = 1000; maximumTargetBindingObservations = 1000; maximumTargetViewObservations = 1000
            }
        }
        server = [pscustomobject]@{ buildId = 'fixture-build' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $registryPath -Encoding utf8
    [pscustomobject]@{
        expectedDurationMs = 1000; expectedFrames = 4; expectedEvents = 100; expectedEventBytes = 10000; expectedScopeDepth = 3
        expectedObservations = [pscustomobject]@{ geometry = 10; materialState = 10; resource = 10; sceneObject = 10; shader = 10; stageShader = 10; targetBinding = 10; targetView = 10 }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $workloadPath -Encoding utf8
    $plannerPath = Join-Path $PSScriptRoot 'New-CSXRenderMapCapturePlan.ps1'
    $plan = & $plannerPath -RegistryPath $registryPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId fixture-command -OutputPath $planPath -HeadroomFactor 2 -NoExit -Compact | ConvertFrom-Json
    $planReceipt = Get-Content -LiteralPath $plan.receiptPath -Raw | ConvertFrom-Json
    Assert-Test ($plan.ok -and $plan.arguments.maxEvents -eq 200 -and $plan.arguments.maxBytes -eq 21000 -and (Test-Path -LiteralPath $plan.receiptPath -PathType Leaf) -and $planReceipt.service -eq 'communityshaders.render_map' -and $planReceipt.producerBuildId -eq 'fixture-build' -and $planReceipt.registrySha256 -eq (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash) 'render-map planner sizes every bound from workload plus headroom and retains an exact registry-bound receipt'
    $rawRegistryPath = Join-Path $planFixture 'raw-registry.json'
    $rawRegistry = (Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json).result
    $rawRegistry | Add-Member -NotePropertyName producerBuildId -NotePropertyValue 'fixture-build'
    $rawRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rawRegistryPath -Encoding utf8
    $rawPlan = & $plannerPath -RegistryPath $rawRegistryPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId raw-registry -OutputPath (Join-Path $planFixture 'raw-registry-plan.json') -NoExit -Compact | ConvertFrom-Json
    Assert-Test ($rawPlan.ok -and $rawPlan.arguments.contractMajor -eq 1) 'explicit raw-registry mode requires and preserves service, contract, and producer provenance'
    $oversizedPath = Join-Path $planFixture 'oversized.json'
    $oversizedWorkload = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
    $oversizedWorkload.expectedEvents = 6000
    $oversizedWorkload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $oversizedPath -Encoding utf8
    $refused = & $plannerPath -RegistryPath $registryPath -WorkloadPath $oversizedPath -ClientId fixture-client -CommandId oversized-command -OutputPath (Join-Path $planFixture 'oversized-plan.json') -HeadroomFactor 2 -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $refused.ok -and $null -eq $refused.arguments -and $refused.exceededCeilings.Count -ge 1) 'render-map planner refuses workload bounds beyond the live service ceilings'

    $failedRegistryPath = Join-Path $planFixture 'failed-registry.json'
    $failedRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $failedRegistry.ok = $false
    $failedRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $failedRegistryPath -Encoding utf8
    $failedRegistryPlan = & $plannerPath -RegistryPath $failedRegistryPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId failed-registry -OutputPath (Join-Path $planFixture 'failed-registry-plan.json') -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $failedRegistryPlan.ok -and $null -eq $failedRegistryPlan.arguments -and -not $failedRegistryPlan.receiptPublished) 'render-map planner rejects explicit registry-envelope failure before issuing start arguments'
    $innerFailurePath = Join-Path $planFixture 'inner-failed-registry.json'
    $innerFailure = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $innerFailure.result | Add-Member -NotePropertyName failed -NotePropertyValue $true
    $innerFailure | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $innerFailurePath -Encoding utf8
    $innerFailurePlan = & $plannerPath -RegistryPath $innerFailurePath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId inner-failed-registry -OutputPath (Join-Path $planFixture 'inner-failed-registry-plan.json') -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $innerFailurePlan.ok -and $null -eq $innerFailurePlan.arguments -and -not $innerFailurePlan.receiptPublished) 'render-map planner preserves explicit inner registry failure before issuing start arguments'

    foreach ($negativeStatus in @('producer_mismatch', 'idempotency_conflict')) {
        $negativeStatusPath = Join-Path $planFixture "$negativeStatus-registry.json"
        $negativeStatusRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $negativeStatusRegistry.result | Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{ name = $negativeStatus; value = 0 })
        $negativeStatusRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $negativeStatusPath -Encoding utf8
        $negativeStatusPlan = & $plannerPath -RegistryPath $negativeStatusPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId $negativeStatus -OutputPath (Join-Path $planFixture "$negativeStatus-plan.json") -NoExit -Compact | ConvertFrom-Json
        Assert-Test (-not $negativeStatusPlan.ok -and $null -eq $negativeStatusPlan.arguments -and -not $negativeStatusPlan.receiptPublished) "render-map planner rejects named negative status $negativeStatus"
    }

    foreach ($missingBinding in @('service', 'major', 'producerBuildId')) {
        $bindingPath = Join-Path $planFixture "missing-$missingBinding-registry.json"
        $bindingRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        if ($missingBinding -eq 'producerBuildId') {
            $bindingRegistry.server.PSObject.Properties.Remove('buildId')
        } else {
            $bindingRegistry.result.PSObject.Properties.Remove($missingBinding)
        }
        $bindingRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bindingPath -Encoding utf8
        $bindingPlan = & $plannerPath -RegistryPath $bindingPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId "missing-$missingBinding" -OutputPath (Join-Path $planFixture "missing-$missingBinding-plan.json") -NoExit -Compact | ConvertFrom-Json
        Assert-Test (-not $bindingPlan.ok -and $null -eq $bindingPlan.arguments) "render-map planner requires explicit registry $missingBinding binding"
    }

    foreach ($invalidScope in @($null, 0, -1, $true, 1.5)) {
        $scopePath = Join-Path $planFixture "scope-$([guid]::NewGuid().ToString('N')).json"
        $scopeWorkload = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
        $scopeWorkload.expectedScopeDepth = $invalidScope
        $scopeWorkload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scopePath -Encoding utf8
        $scopePlan = & $plannerPath -RegistryPath $registryPath -WorkloadPath $scopePath -ClientId fixture-client -CommandId invalid-scope -OutputPath "$scopePath.plan.json" -NoExit -Compact | ConvertFrom-Json
        Assert-Test (-not $scopePlan.ok -and $null -eq $scopePlan.arguments) 'render-map planner rejects a missing or malformed explicit scope estimate'
    }
    $explicitOnePath = Join-Path $planFixture 'scope-one.json'
    $explicitOne = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
    $explicitOne.expectedScopeDepth = 1
    $explicitOne | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $explicitOnePath -Encoding utf8
    $explicitOnePlan = & $plannerPath -RegistryPath $registryPath -WorkloadPath $explicitOnePath -ClientId fixture-client -CommandId explicit-one -OutputPath (Join-Path $planFixture 'scope-one-plan.json') -NoExit -Compact | ConvertFrom-Json
    Assert-Test ($explicitOnePlan.ok -and $explicitOnePlan.arguments.maxScopeDepth -eq 2) 'render-map planner accepts an explicitly stated scope depth of one'

    foreach ($invalidCase in @(
            [pscustomobject]@{ area = 'workload'; property = 'expectedEvents'; value = $true },
            [pscustomobject]@{ area = 'workload'; property = 'expectedFrames'; value = 1.5 },
            [pscustomobject]@{ area = 'limit'; property = 'maximumEvents'; value = $true },
            [pscustomobject]@{ area = 'limit'; property = 'maximumFrames'; value = 1.5 },
            [pscustomobject]@{ area = 'default'; property = 'fixedCatalogueBytes'; value = 1.5 }
        )) {
        $invalidRegistryPath = $registryPath
        $invalidWorkloadPath = $workloadPath
        if ($invalidCase.area -eq 'workload') {
            $invalidWorkloadPath = Join-Path $planFixture "invalid-$($invalidCase.property).json"
            $invalidWorkload = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
            $invalidWorkload.($invalidCase.property) = $invalidCase.value
            $invalidWorkload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidWorkloadPath -Encoding utf8
        } else {
            $invalidRegistryPath = Join-Path $planFixture "invalid-$($invalidCase.property)-registry.json"
            $invalidRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
            if ($invalidCase.area -eq 'limit') {
                $invalidRegistry.result.limits.($invalidCase.property) = $invalidCase.value
            } else {
                $invalidRegistry.result.defaults.($invalidCase.property) = $invalidCase.value
            }
            $invalidRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidRegistryPath -Encoding utf8
        }
        $invalidPlan = & $plannerPath -RegistryPath $invalidRegistryPath -WorkloadPath $invalidWorkloadPath -ClientId fixture-client -CommandId "invalid-$($invalidCase.property)" -OutputPath (Join-Path $planFixture "invalid-$($invalidCase.property)-plan.json") -NoExit -Compact | ConvertFrom-Json
        Assert-Test (-not $invalidPlan.ok -and $null -eq $invalidPlan.arguments) "render-map planner rejects malformed positive-integer field $($invalidCase.property)"
    }

    $allWorkloadNumbers = @('expectedDurationMs', 'expectedFrames', 'expectedEvents', 'expectedEventBytes', 'expectedScopeDepth')
    $allObservationNumbers = @('geometry', 'materialState', 'resource', 'sceneObject', 'shader', 'stageShader', 'targetBinding', 'targetView')
    foreach ($property in $allWorkloadNumbers + $allObservationNumbers) {
        foreach ($badValue in @($true, 1.5)) {
            $invalidWorkloadPath = Join-Path $planFixture "all-workload-$property-$([guid]::NewGuid().ToString('N')).json"
            $invalidWorkload = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
            if ($property -in $allObservationNumbers) {
                $invalidWorkload.expectedObservations.$property = $badValue
            } else {
                $invalidWorkload.$property = $badValue
            }
            $invalidWorkload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidWorkloadPath -Encoding utf8
            $invalidPlan = & $plannerPath -RegistryPath $registryPath -WorkloadPath $invalidWorkloadPath -ClientId fixture-client -CommandId all-workload-invalid -OutputPath "$invalidWorkloadPath.plan.json" -NoExit -Compact | ConvertFrom-Json
            Assert-Test (-not $invalidPlan.ok -and $null -eq $invalidPlan.arguments) "render-map planner rejects Boolean and fractional workload field $property"
        }
    }
    $allLimitNumbers = @(
        'maximumBytes', 'maximumDurationMs', 'maximumEvents', 'maximumFrames',
        'maximumScopeDepth', 'maximumGeometryObservations',
        'maximumMaterialStateObservations', 'maximumResourceObservations',
        'maximumSceneObjectObservations', 'maximumShaderObservations',
        'maximumStageShaderObservations', 'maximumTargetBindingObservations',
        'maximumTargetViewObservations'
    )
    foreach ($property in $allLimitNumbers) {
        foreach ($badValue in @($true, 1.5)) {
            $invalidRegistryPath = Join-Path $planFixture "all-limit-$property-$([guid]::NewGuid().ToString('N')).json"
            $invalidRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
            $invalidRegistry.result.limits.$property = $badValue
            $invalidRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidRegistryPath -Encoding utf8
            $invalidPlan = & $plannerPath -RegistryPath $invalidRegistryPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId all-limit-invalid -OutputPath "$invalidRegistryPath.plan.json" -NoExit -Compact | ConvertFrom-Json
            Assert-Test (-not $invalidPlan.ok -and $null -eq $invalidPlan.arguments) "render-map planner rejects Boolean and fractional registry ceiling $property"
        }
    }
    foreach ($badValue in @($true, 1.5)) {
        $invalidDefaultPath = Join-Path $planFixture "all-default-$([guid]::NewGuid().ToString('N')).json"
        $invalidDefault = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $invalidDefault.result.defaults.fixedCatalogueBytes = $badValue
        $invalidDefault | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidDefaultPath -Encoding utf8
        $invalidPlan = & $plannerPath -RegistryPath $invalidDefaultPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId all-default-invalid -OutputPath "$invalidDefaultPath.plan.json" -NoExit -Compact | ConvertFrom-Json
        Assert-Test (-not $invalidPlan.ok -and $null -eq $invalidPlan.arguments) 'render-map planner rejects Boolean and fractional fixed catalogue allocation'
    }

    $overflowPath = Join-Path $planFixture 'overflow-workload.json'
    $overflowWorkload = Get-Content -LiteralPath $workloadPath -Raw | ConvertFrom-Json
    $overflowWorkload.expectedEvents = [long]::MaxValue
    $overflowWorkload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overflowPath -Encoding utf8
    $overflowPlan = & $plannerPath -RegistryPath $registryPath -WorkloadPath $overflowPath -ClientId fixture-client -CommandId overflow -OutputPath (Join-Path $planFixture 'overflow-plan.json') -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $overflowPlan.ok -and $null -eq $overflowPlan.arguments) 'render-map planner rejects headroom arithmetic beyond its 64-bit bound'

    $hashFailurePath = Join-Path $planFixture 'hash-failure-plan.json'
    $hashFailure = & $plannerPath -RegistryPath $registryPath -WorkloadPath $workloadPath -ClientId fixture-client -CommandId hash-failure -OutputPath $hashFailurePath -InternalTestFailurePoint receipt-hash -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $hashFailure.ok -and $hashFailure.state -eq 'plan-finalization-error' -and $hashFailure.receiptPublished -and $hashFailure.receiptPath -eq $hashFailurePath -and $null -eq $hashFailure.receiptSha256 -and $null -eq $hashFailure.arguments -and (Test-Path -LiteralPath $hashFailurePath -PathType Leaf)) 'post-publication hash failure preserves the immutable receipt path without issuing arguments'
}
finally {
    if (Test-Path -LiteralPath $planFixture) { Remove-Item -LiteralPath $planFixture -Recurse -Force }
}

$ready = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test ($ready.ready -and -not $ready.retryable -and $ready.statePath -eq 'content.result.state') 'service readiness prefers result.state'
$waiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'compiling' } })
Assert-Test (-not $waiting.ready -and $waiting.retryable -and -not $waiting.terminalFailure) 'compiling service remains retryable'
$dispatchWaiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'main_thread_dispatch_failed'; retryable = $true } })
Assert-Test (-not $dispatchWaiting.ready -and $dispatchWaiting.retryable -and -not $dispatchWaiting.terminalFailure) 'explicitly retryable dispatch failure remains retryable'
$guarded = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } })
Assert-Test (-not $guarded.ready -and $guarded.terminalFailure) 'guard rejection terminates readiness wait'
$contradictoryReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $false; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test (-not $contradictoryReady.ready -and $contradictoryReady.terminalFailure) 'negative semantic evidence vetoes a simultaneously ready service state'
$retryableContradictoryReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $false; retryable = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test (-not $retryableContradictoryReady.ready -and $retryableContradictoryReady.retryable -and -not $retryableContradictoryReady.terminalFailure) 'retryability controls continued polling but never converts negative semantic evidence into readiness'
$nestedRetryableContradictoryReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ result = [pscustomobject]@{ state = 'ready'; error = [pscustomobject]@{ code = 'service_unavailable'; retryable = $true } } })
Assert-Test (-not $nestedRetryableContradictoryReady.ready -and $nestedRetryableContradictoryReady.retryable) 'nested retryable failure evidence vetoes an otherwise accepted readiness state'
foreach ($neutral in @(
    [pscustomobject]@{ retryable = $false },
    [pscustomobject]@{ failed = $false },
    [pscustomobject]@{ aborted = $false }
)) {
    $neutralReady = Test-DevBenchServiceReady -Content @($neutral)
    Assert-Test (-not $neutralReady.ready -and $neutralReady.semantic.known -and
        -not $neutralReady.semantic.affirmative) 'a negative-control flag alone never establishes service readiness'
}
$affirmativeReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true })
Assert-Test ($affirmativeReady.ready -and $affirmativeReady.semantic.affirmative) 'an explicitly successful probe remains affirmative readiness evidence'
$deadline = [DateTime]'2026-09-13T04:00:00Z'
Assert-Test (Test-DevBenchWaitDeadlineAcceptance -Satisfied $true -ObservedUtc $deadline.AddTicks(-1) -DeadlineUtc $deadline) 'a valid observation immediately before the absolute deadline may satisfy a wait'
Assert-Test (-not (Test-DevBenchWaitDeadlineAcceptance -Satisfied $true -ObservedUtc $deadline -DeadlineUtc $deadline)) 'an observation exactly at the absolute deadline cannot satisfy a wait'
Assert-Test (-not (Test-DevBenchWaitDeadlineAcceptance -Satisfied $true -ObservedUtc $deadline.AddTicks(1) -DeadlineUtc $deadline)) 'a late positive observation remains diagnostic evidence rather than wait success'
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
$inventoryDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory -DismissBlockingMenus @('InventoryMenu')
Assert-Test ($inventoryDismissal.permitted -and $inventoryDismissal.dismissMenus[0] -eq 'InventoryMenu') 'explicitly listed blocking menu permits bounded dismissal'
$unlistedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory
Assert-Test (-not $unlistedDismissal.permitted -and $unlistedDismissal.reason -eq 'unlisted-blocking-menu') 'menu dismissal remains opt-in'
$mixedMenus = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu', 'MapMenu'); messageBoxOpen = $false })
$mixedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $mixedMenus -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $mixedDismissal.permitted -and $mixedDismissal.retainedMenus[0] -eq 'MapMenu') 'unlisted blocking menus prevent partial dismissal'
$modalDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $modal -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $modalDismissal.permitted -and $modalDismissal.reason -eq 'message-box-requires-explicit-answer') 'message boxes are never auto-dismissed'

Assert-Test (Test-DevBenchInitialMcpCapabilityMiss -InitializeCompleted $false -IssuedSessionId '' -StatusCode 404) 'only an initial sessionless MCP 404 proves capability absence'
Assert-Test (-not (Test-DevBenchInitialMcpCapabilityMiss -InitializeCompleted $true -IssuedSessionId 'session-1' -StatusCode 404)) 'a post-initialization MCP 404 cannot authorize REST fallback'
Assert-Test (-not (Test-DevBenchInitialMcpCapabilityMiss -InitializeCompleted $false -IssuedSessionId '' -StatusCode 503)) 'a non-404 MCP initialization failure cannot authorize REST fallback'
$restDecodeFailure = Get-DevBenchRestMutationFailureDisposition -Mutation $true -RequestAttempted $true -ResponseReceived $true -StatusCode $null -Transient $false
Assert-Test ($restDecodeFailure.indeterminate -and $restDecodeFailure.reason -eq 'response-outcome-undecodable') 'an undecodable REST mutation response remains indeterminate after one dispatch'
$restConnectionFailure = Get-DevBenchRestMutationFailureDisposition -Mutation $true -RequestAttempted $true -ResponseReceived $false -StatusCode $null -Transient $false
Assert-Test ($restConnectionFailure.indeterminate -and $restConnectionFailure.reason -eq 'dispatch-outcome-unknown') 'an unclassified post-dispatch REST mutation failure remains indeterminate'
$restPreDispatchFailure = Get-DevBenchRestMutationFailureDisposition -Mutation $true -RequestAttempted $false -ResponseReceived $false -StatusCode $null -Transient $false
Assert-Test (-not $restPreDispatchFailure.indeterminate -and $restPreDispatchFailure.reason -eq 'pre-dispatch-failure') 'a pre-dispatch REST serialization failure is not falsely classified as possibly committed'
$restRejectedMutation = Get-DevBenchRestMutationFailureDisposition -Mutation $true -RequestAttempted $true -ResponseReceived $false -StatusCode 400 -Transient $false
Assert-Test (-not $restRejectedMutation.indeterminate -and $restRejectedMutation.definitiveHttpRejection) 'an observed non-transient HTTP rejection remains a definite failed mutation'

function New-TestUpscalingProfile([string]$Method = 'dlss', [bool]$RenderScale = $true) {
    [pscustomobject]@{
        method = [pscustomobject]@{ name = $Method; value = $(if ($Method -eq 'dlss') { 3 } elseif ($Method -eq 'fsr') { 2 } else { 1 }) }
        qualityMode = [pscustomobject]@{ name = $(if ($RenderScale) { 'hoshipa' } else { 'native_aa' }); value = $(if ($RenderScale) { 1 } else { 0 }) }
        renderScaleMode = $RenderScale
        dlssProfile = [pscustomobject]@{ name = 'K'; value = 1 }
        fsrRuntime = [pscustomobject]@{ name = 'fsr3'; value = 0 }
    }
}

function New-TestRenderScaleStatus([bool]$RenderScale = $true) {
    $eye = { param([uint32]$Frame) [pscustomobject]@{ frame = $Frame; evaluated = $true; valid = $true } }
    $presentationEye = { param([uint32]$Frame) [pscustomobject]@{ frame = $Frame; valid = $true; path = 'VendorEvaluated'; loadingOrMenuContext = $false; transitionCooldown = $false } }
    [pscustomobject]@{
        frame = 105
        upscalingSnapshot = [pscustomobject]@{ stateRevision = 12 }
        modeStatus = $(if ($RenderScale) { 'Active' } else { 'Disabled' })
        vendorWorkGate = [pscustomobject]@{
            active = $false; completedWorldFrame = $true; loadingMenu = $false; loadingPresentationActive = $false
            postLoadResetPending = $false; relatchQueued = $false; relatchInProgress = $false; relatchFramePending = $false
            relatchPostLoadSettle = $false; recoveryPending = $false; relatchPending = $false; profileTransitionPending = $false
        }
        fsrDispatch = [pscustomobject]@{
            actualDispatchBothEyesValid = $true; actualDispatchBackendConverged = $true; actualRuntimeFallbackObserved = $false
            shaderCompilationActive = $false; contractReady = $true; contractLifecyclePhase = 'Ready'
        }
        controller = [pscustomobject]@{
            state = $(if ($RenderScale) { 'Active' } else { 'Idle' })
            presentationPhase = $(if ($RenderScale) { 'released' } else { 'idle' })
            terminalFailureSignaled = $false; terminalDeviceLossSignaled = $false; unresolvedPhysicalMutationEpoch = 0
            targetEpoch = 7
            stable = [pscustomobject]@{ valid = $RenderScale; active = $RenderScale; contractGeneration = $(if ($RenderScale) { 4 } else { 0 }) }
            fidelity = [pscustomobject]@{
                active = $RenderScale; bothEyesValid = $RenderScale; evaluationEyeMask = $(if ($RenderScale) { 3 } else { 0 })
                invariantEyeMask = $(if ($RenderScale) { 3 } else { 0 }); lastMismatchMask = 0
                eyes = @((& $eye 105), (& $eye 105))
            }
            presentation = [pscustomobject]@{
                consecutiveBothEyesVendorFrames = $(if ($RenderScale) { 3 } else { 0 })
                eyes = @((& $presentationEye 105), (& $presentationEye 104))
            }
            postLoadRecovery = [pscustomobject]@{ active = $false }
            memoryTrim = [pscustomobject]@{ pending = $false }
            retirement = [pscustomobject]@{ pendingSets = 0; fencePending = $false; capacityBlocked = $false }
            engineTargetRetirement = [pscustomobject]@{ pending = $false }
            dlssLifecycle = [pscustomobject]@{ resourcesPresent = $true; readyForContract = $true; phase = 'Ready'; failures = 0 }
        }
    }
}

$renderProfile = New-TestUpscalingProfile
$renderSnapshot = [pscustomobject]@{
    stateRevision = 12
    profilePresence = 27; flags = 57; activeOperationId = 0
    transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
    renderScaleStatus = [pscustomobject]@{ name = 'active'; value = 5 }
    observedConditions = [pscustomobject]@{ names = @() }
    profiles = [pscustomobject]@{ requested = $renderProfile; effective = $renderProfile; stable = $renderProfile }
    dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2096; renderEyeHeight = 2328 }
}
$renderStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test ($renderStable.satisfied -and $renderStable.stereoEvidence -eq 'render_scale_fidelity') 'render-scale stability requires a latched coherent stereo contract'
$wrongScaledProfile = New-TestUpscalingProfile -Method 'fsr'
$wrongScaledTarget = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus) -ExpectedProfile $wrongScaledProfile
Assert-Test (-not $wrongScaledTarget.satisfied -and $wrongScaledTarget.reasons -contains 'effective scaled profile does not match the expected target') 'targeted scaled stability rejects a different effective profile'
$gatedStatus = New-TestRenderScaleStatus
$gatedStatus.vendorWorkGate.loadingMenu = $true
$renderGated = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $gatedStatus
Assert-Test (-not $renderGated.satisfied -and $renderGated.reasons -match 'loadingMenu') 'loading presentation prevents a stable render-scale verdict'

function New-TestNativeSnapshot {
    param(
        $RequestedProfile,
        $EffectiveProfile,
        $StableProfile,
        [ValidateSet('idle', 'active')][string]$TransitionState = 'idle',
        [int]$ProfilePresence = 11
    )
    if ($null -eq $RequestedProfile) { $RequestedProfile = New-TestUpscalingProfile -Method 'dlss' -RenderScale $false }
    if ($null -eq $EffectiveProfile) { $EffectiveProfile = $RequestedProfile }
    if ($null -eq $StableProfile) { $StableProfile = $EffectiveProfile }
    [pscustomobject]@{
        stateRevision = 12
        profilePresence = $ProfilePresence; flags = 1; activeOperationId = 0
        transitionState = [pscustomobject]@{ name = $TransitionState; value = $(if ($TransitionState -eq 'active') { 6 } else { 0 }) }
        renderScaleStatus = [pscustomobject]@{ name = 'disabled'; value = 0 }
        observedConditions = [pscustomobject]@{ names = @() }
        profiles = [pscustomobject]@{ requested = $RequestedProfile; effective = $EffectiveProfile; stable = $StableProfile }
        dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2468; renderEyeHeight = 2740 }
    }
}

$nativeProfile = New-TestUpscalingProfile -Method 'dlss' -RenderScale $false
$nativeStable = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeStable.satisfied -and $nativeStable.stereoEvidence -eq 'native_pipeline_frames') 'native-resolution stability uses converged profiles and advancing world frames'
$nativeTaaProfile = New-TestUpscalingProfile -Method 'taa' -RenderScale $false
$nativeProjectedNone = New-TestUpscalingProfile -Method 'none' -RenderScale $false
$nativeTaaSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeTaaStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeTaaStatus.controller.state = 'Active'
$nativeTaaStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeTaaSnapshot -RenderScaleStatus $nativeTaaStatus -ExpectedProfile $nativeTaaProfile
Assert-Test ($nativeTaaStable.satisfied -and $nativeTaaStable.expectedProfileMatches) 'targeted native TAA accepts its active native controller state without treating the render-scale projection as a profile mismatch'
$nativeWrongTargetSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeWrongTargetStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeWrongTargetStatus.controller.state = 'Active'
$nativeWrongTarget = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeWrongTargetSnapshot -RenderScaleStatus $nativeWrongTargetStatus -ExpectedProfile $nativeProjectedNone
Assert-Test (-not $nativeWrongTarget.satisfied -and $nativeWrongTarget.reasons -contains 'effective native profile does not match the expected target') 'targeted native stability rejects a different effective profile'
$nativeSplitSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeSplitStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeSplitStatus.controller.state = 'Idle'
$nativeSplitState = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSplitSnapshot -RenderScaleStatus $nativeSplitStatus -ExpectedProfile $nativeTaaProfile
Assert-Test (-not $nativeSplitState.satisfied -and $nativeSplitState.reasons -contains "native-resolution controller state is 'active/idle'") 'targeted native stability rejects split controller states'
$nativeFsrProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeFsrSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeFsrProfile -EffectiveProfile $nativeFsrProfile -StableProfile $nativeFsrProfile -ProfilePresence 27
$nativeFsrStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeFsrSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeFsrStable.satisfied -and $nativeFsrStable.method -eq 'fsr') 'native-resolution stability follows the effective method without prescribing DLSS or FSR'
$nativePhysicalStatus = New-TestRenderScaleStatus -RenderScale $false
$nativePhysicalStatus.controller.stable.active = $true
$nativePhysicalState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $nativePhysicalStatus
Assert-Test (-not $nativePhysicalState.satisfied -and $nativePhysicalState.reasons -contains 'an active physical render-scale contract remains for a native-resolution profile') 'native-resolution stability rejects a contradictory active physical contract'
$missingNativeStableActivity = New-TestRenderScaleStatus -RenderScale $false
$missingNativeStableActivity.controller.stable.PSObject.Properties.Remove('active')
$missingNativeStableActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $missingNativeStableActivity
Assert-Test (-not $missingNativeStableActivityState.satisfied -and $missingNativeStableActivityState.reasons -contains 'stable render-scale activity telemetry is missing for a native-resolution profile') 'native-resolution stability rejects missing physical contract activity telemetry'
$missingNativeFidelityActivity = New-TestRenderScaleStatus -RenderScale $false
$missingNativeFidelityActivity.controller.fidelity.PSObject.Properties.Remove('active')
$missingNativeFidelityActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $missingNativeFidelityActivity
Assert-Test (-not $missingNativeFidelityActivityState.satisfied -and $missingNativeFidelityActivityState.reasons -contains 'render-scale fidelity activity telemetry is missing for a native-resolution profile') 'native-resolution stability rejects missing fidelity activity telemetry'
$invalidNativeActivity = New-TestRenderScaleStatus -RenderScale $false
$invalidNativeActivity.controller.stable.active = 'false'
$invalidNativeActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $invalidNativeActivity
Assert-Test (-not $invalidNativeActivityState.satisfied -and $invalidNativeActivityState.reasons -contains 'stable render-scale activity telemetry has invalid type for a native-resolution profile') 'native-resolution stability rejects coerced physical contract activity telemetry'
$invalidCompletedFrame = New-TestRenderScaleStatus
$invalidCompletedFrame.vendorWorkGate.completedWorldFrame = 'false'
$invalidCompletedFrameState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $invalidCompletedFrame
Assert-Test (-not $invalidCompletedFrameState.satisfied -and $invalidCompletedFrameState.reasons -contains 'completed world-frame telemetry has invalid type') 'render-scale stability rejects truthy strings for completed world-frame authority'
$invalidRecoveryBoolean = New-TestRenderScaleStatus
$invalidRecoveryBoolean.controller.postLoadRecovery.active = 'false'
$invalidRecoveryBooleanState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $invalidRecoveryBoolean
Assert-Test (-not $invalidRecoveryBooleanState.satisfied -and $invalidRecoveryBooleanState.reasons -contains 'post-load render-scale recovery active telemetry has invalid type') 'render-scale stability rejects coerced nested recovery telemetry'
$invalidDimensionSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$invalidDimensionSnapshot.dimensions.displayEyeWidth = 'wide'
$invalidDimensionState = Test-DevBenchUpscalingStable -UpscalingSnapshot $invalidDimensionSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $invalidDimensionState.satisfied -and $invalidDimensionState.reasons -contains 'upscaling dimensions are not materialized') 'upscaling stability rejects nonnumeric dimensions without throwing'
$overflowDimensionSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$overflowDimensionSnapshot.dimensions.renderEyeHeight = [uint64]::MaxValue
$overflowDimensionState = Test-DevBenchUpscalingStable -UpscalingSnapshot $overflowDimensionSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $overflowDimensionState.satisfied -and $overflowDimensionState.reasons -contains 'upscaling dimensions are not materialized') 'upscaling stability rejects dimensions outside the UInt32 contract without throwing'
$mismatchedProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeMismatchSnapshot = New-TestNativeSnapshot -RequestedProfile $mismatchedProfile -EffectiveProfile $nativeProfile -StableProfile $nativeFsrProfile -ProfilePresence 27
$nativeMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeMismatchSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test (-not $nativeMismatch.satisfied -and $nativeMismatch.reasons -contains 'requested and effective profiles differ') 'native-resolution stability rejects profile divergence'
$statusProfileMismatch = New-TestRenderScaleStatus
$mismatchedPhysicalSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$mismatchedPhysicalSnapshot.renderScaleStatus = [pscustomobject]@{ name = 'disabled'; value = 0 }
$renderStatusMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $mismatchedPhysicalSnapshot -RenderScaleStatus $statusProfileMismatch
Assert-Test (-not $renderStatusMismatch.satisfied -and $renderStatusMismatch.reasons -contains 'render-scale status disagrees with the effective profile') 'physical render-scale status must agree with the effective profile'
$revisionMismatchStatus = New-TestRenderScaleStatus
$revisionMismatchStatus.upscalingSnapshot.stateRevision = 13
$revisionMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $revisionMismatchStatus
Assert-Test (-not $revisionMismatch.satisfied -and $revisionMismatch.reasons -contains 'upscaling and render-scale observations are not revision-correlated') 'cross-RPC upscaling evidence requires a shared state revision'
$invalidExpectedProfile = New-TestUpscalingProfile -RenderScale $false
$invalidExpectedProfile.renderScaleMode = 'false'
$invalidExpected = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false) -ExpectedProfile $invalidExpectedProfile
Assert-Test (-not $invalidExpected.satisfied -and $invalidExpected.reasons -contains 'the expected upscaling profile has invalid field types') 'expected profile boolean fields reject truthy strings'
$missingSnapshotFields = Test-DevBenchUpscalingStable -UpscalingSnapshot ([pscustomobject]@{}) -RenderScaleStatus ([pscustomobject]@{})
Assert-Test (-not $missingSnapshotFields.satisfied -and $missingSnapshotFields.reasons -contains 'render-scale controller telemetry is missing') 'missing optional snapshot fields fail closed without a strict-mode exception'
$partialRenderStatus = New-TestRenderScaleStatus
$partialRenderStatus.controller.PSObject.Properties.Remove('fidelity')
$partialRenderState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $partialRenderStatus
Assert-Test (-not $partialRenderState.satisfied -and $partialRenderState.reasons -contains 'render-scale fidelity telemetry is missing') 'partial active controller telemetry fails closed without a strict-mode exception'
$partialProfileSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$partialProfileSnapshot.profiles.effective.PSObject.Properties.Remove('qualityMode')
$partialProfileState = Test-DevBenchUpscalingStable -UpscalingSnapshot $partialProfileSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $partialProfileState.satisfied -and $partialProfileState.reasons -contains 'the effective upscaling profile has invalid field types') 'partial effective profiles fail closed without a strict-mode exception'

$requiredRecoveryTelemetry = @(
    [pscustomobject]@{ parent = 'postLoadRecovery'; field = 'active'; reason = 'post-load render-scale recovery active telemetry is missing' },
    [pscustomobject]@{ parent = 'memoryTrim'; field = 'pending'; reason = 'render-scale memory trim pending telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'pendingSets'; reason = 'render-scale retirement pending-set telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'fencePending'; reason = 'render-scale retirement fence telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'capacityBlocked'; reason = 'render-scale retirement capacity telemetry is missing' },
    [pscustomobject]@{ parent = 'engineTargetRetirement'; field = 'pending'; reason = 'engine render-target retirement pending telemetry is missing' }
)
foreach ($case in $requiredRecoveryTelemetry) {
    $partialStatus = New-TestRenderScaleStatus
    $partialStatus.controller.($case.parent).PSObject.Properties.Remove($case.field)
    $partialState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $partialStatus
    Assert-Test (-not $partialState.satisfied -and $partialState.reasons -contains $case.reason) "missing $($case.parent).$($case.field) telemetry fails closed"
}

$resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response ([pscustomobject]@{
        status = [pscustomobject]@{
            resourcePublication = [pscustomobject]@{
                current = $true; currentGeneration = 17; completedGeneration = 17; publishedGeneration = 17
                expectedWidth = 1644; expectedHeight = 1826; publishedWidth = 1644; publishedHeight = 1826
                complete = $true; deferredSetupAcknowledged = $true; deviceMatches = $true; contextMatches = $true
                evaluated = $true; present = $true; generationMatchesCurrent = $true
                generationMatchesCompleted = $true; dimensionsMatch = $true
            }
        }
    })
Assert-Test ($resourcePublication.available -and $resourcePublication.current -and
    $resourcePublication.currentGeneration -eq 17 -and $resourcePublication.completedGeneration -eq 17 -and
    $resourcePublication.publishedGeneration -eq 17 -and $resourcePublication.expectedWidth -eq 1644 -and
    $resourcePublication.expectedHeight -eq 1826 -and $resourcePublication.publishedWidth -eq 1644 -and
    $resourcePublication.publishedHeight -eq 1826 -and $resourcePublication.complete -and
    $resourcePublication.deferredSetupAcknowledged -and $resourcePublication.deviceMatches -and
    $resourcePublication.contextMatches -and $resourcePublication.missingFields.Count -eq 0) 'resource-publication telemetry retains generations, dimensions, setup, and D3D identity'
$missingPublication = Get-DevBenchResourcePublicationTelemetry -Response ([pscustomobject]@{ status = [pscustomobject]@{} })
Assert-Test (-not $missingPublication.available -and $missingPublication.missingFields -contains 'publishedGeneration') 'missing resource-publication telemetry remains explicit'

$preparationResponse = [pscustomobject]@{
    status = [pscustomobject]@{
        preparation = [pscustomobject]@{
            schemaVersion = 1; devBenchOnly = $true; active = $true
            sessionId = 9; qpcFrequency = 10000000; retainedEvents = 3
            capacity = 512; overwrittenEvents = 0; coalescedEvents = 2
            events = @(
                [pscustomobject]@{
                    sequence = 1; sessionId = 9; requestId = 17
                    transitionEpoch = 41; event = 'admission_check'
                    outcome = 'eligible'; occurrences = 1; reasons = @()
                    durationQpcTicks = 100; durationMs = 0.01
                    bytecodeCompilationMs = 0; d3dObjectCreationMs = 0
                },
                [pscustomobject]@{
                    sequence = 2; sessionId = 9; requestId = 17
                    transitionEpoch = 41; event = 'sss_raymarch_prewarm'
                    outcome = 'ready'; occurrences = 1; reasons = @()
                    durationQpcTicks = 500; durationMs = 0.05
                    bytecodeCompilationMs = 0.03; d3dObjectCreationMs = 0.02
                },
                [pscustomobject]@{
                    sequence = 3; sessionId = 9; requestId = 18
                    transitionEpoch = 42; event = 'total_preparation'
                    outcome = 'ready'; occurrences = 1; reasons = @()
                    durationQpcTicks = 900; durationMs = 0.09
                    bytecodeCompilationMs = 0.03; d3dObjectCreationMs = 0.02
                }
            )
        }
    }
}
$preparation = Get-DevBenchRenderScalePreparationTelemetry `
    -Response $preparationResponse -TransitionEpoch 41
Assert-Test ($preparation.available -and $preparation.filterApplied -and
    $preparation.sessionId -eq 9 -and $preparation.capacity -eq 512 -and
    $preparation.allEventCount -eq 3 -and $preparation.eventCount -eq 2 -and
    $preparation.stages.admission_check.observed -and
    $preparation.stages.sss_raymarch_prewarm.bytecodeCompilationMs.total -eq 0.03 -and
    -not $preparation.stages.total_preparation.observed -and
    $preparation.events[1].requestId -eq 17) 'preparation telemetry retains raw records, stage timings, and exact transition filtering'
foreach ($eventName in @(
    'request_queued', 'admission_check', 'early_exit',
    'shader_cache_busy_wait', 'sss_raymarch_prewarm', 'ssgi_prewarm',
    'dlss_preparation', 'fsr_preparation', 'fsr4_preparation',
    'd3d_object_creation', 'total_preparation', 'request_to_prepared',
    'prepared_to_creator'
)) {
    Assert-Test ($null -ne $preparation.stages.PSObject.Properties[$eventName]) `
        "preparation telemetry exposes the '$eventName' stage"
}
$missingPreparation = Get-DevBenchRenderScalePreparationTelemetry `
    -Response ([pscustomobject]@{ status = [pscustomobject]@{} })
Assert-Test (-not $missingPreparation.available -and
    $missingPreparation.missingFields -contains 'events') 'missing preparation telemetry remains explicit'
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
Assert-Test (Test-DevBenchExecutableIdentityMatch -Expected 'D:\SteamLibrary\steamapps\common\SkyrimVR\SkyrimVR.exe' -Actual 'SkyrimVR.exe') 'canonical runtime executable paths match the health basename'
Assert-Test (Test-DevBenchExecutableIdentityMatch -Expected 'SkyrimVR.exe' -Actual 'D:\SteamLibrary\steamapps\common\SkyrimVR\SkyrimVR.exe') 'health and process executable comparison is symmetric across path and basename forms'
Assert-Test (-not (Test-DevBenchExecutableIdentityMatch -Expected 'D:\SteamLibrary\steamapps\common\SkyrimVR\SkyrimVR.exe' -Actual 'OtherGame.exe')) 'different executable basenames remain rejected'
Assert-Test (-not (Test-DevBenchExecutableIdentityMatch -Expected 'D:\One\SkyrimVR.exe' -Actual 'E:\Two\SkyrimVR.exe')) 'two canonical executable paths must identify the same location'

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
$entryPointPath = Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'
$parseErrors = $null
$tokens = $null
$entryPointAst = [Management.Automation.Language.Parser]::ParseFile($entryPointPath, [ref]$tokens, [ref]$parseErrors)
$identityUtcAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-DevBenchRuntimeIdentityUtc' }, $true))[0]
Invoke-Expression $identityUtcAst.Extent.Text
$identityUtcText = ConvertTo-DevBenchRuntimeIdentityUtc '2026-09-11T00:00:41.0000000Z'
$identityUtcParsed = ConvertTo-DevBenchRuntimeIdentityUtc ([DateTime]'2026-09-11T00:00:41Z')
Assert-Test ($identityUtcText -ceq $identityUtcParsed) 'expected runtime start timestamps compare by normalized UTC instant after JSON parsing'
$dispatchProvenanceAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DevBenchDispatchProvenance' }, $true))[0]
Invoke-Expression $dispatchProvenanceAst.Extent.Text
$skippedDispatch = Get-DevBenchDispatchProvenance -InvocationRecord ([pscustomobject]@{ dispatchedUtc = $null }) -Data ([pscustomobject]@{ toolCallSkipped = $true }) -Semantic ([pscustomobject]@{ known = $true; ok = $false })
$acceptedDispatch = Get-DevBenchDispatchProvenance -InvocationRecord ([pscustomobject]@{ dispatchedUtc = [DateTime]::UtcNow.ToString('o') }) -Data ([pscustomobject]@{ content = @([pscustomobject]@{ ok = $true }) }) -Semantic ([pscustomobject]@{ known = $true; ok = $true })
$rejectedDispatch = Get-DevBenchDispatchProvenance -InvocationRecord ([pscustomobject]@{ dispatchedUtc = [DateTime]::UtcNow.ToString('o') }) -Data ([pscustomobject]@{ content = @([pscustomobject]@{ ok = $false }) }) -Semantic ([pscustomobject]@{ known = $true; ok = $false })
Assert-Test (-not $skippedDispatch.dispatchReached -and -not $skippedDispatch.responseDataRetained -and -not $skippedDispatch.acceptedDataRetained) 'guard and tool-unavailable branches retain known target non-dispatch provenance'
Assert-Test ($acceptedDispatch.dispatchReached -and $acceptedDispatch.responseDataRetained -and $acceptedDispatch.acceptedDataRetained -and -not $acceptedDispatch.semanticRejected) 'semantically accepted target data retains accepted dispatch authority'
Assert-Test ($rejectedDispatch.dispatchReached -and $rejectedDispatch.responseDataRetained -and -not $rejectedDispatch.acceptedDataRetained -and $rejectedDispatch.semanticRejected) 'semantically rejected target data remains evidence without becoming accepted authority'
$targetDispatchAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DevBenchTargetDispatch' }, $true))[0]
Invoke-Expression $targetDispatchAst.Extent.Text
$preTargetRecord = [ordered]@{ dispatchIntentUtc = $null; dispatchedUtc = $null }
$targetInvocations = 0
try {
    $null = Invoke-DevBenchTargetDispatch -InvocationRecord $preTargetRecord -PersistIntent { throw 'fixture dispatch-intent write failed' } -TargetAction { $script:targetInvocations++; 'unreachable' }
}
catch { $preTargetWriteError = $_.Exception.Message }
$preTargetProvenance = Get-DevBenchDispatchProvenance -InvocationRecord ([pscustomobject]$preTargetRecord) -Data $null -Semantic $null
Assert-Test ($preTargetWriteError -match 'dispatch-intent write failed' -and $targetInvocations -eq 0 -and
    [string]::IsNullOrWhiteSpace([string]$preTargetRecord.dispatchedUtc) -and -not $preTargetProvenance.dispatchReached) 'failed dispatch-intent persistence proves definite pre-target non-dispatch'
$attemptedRecord = [ordered]@{ dispatchIntentUtc = $null; dispatchedUtc = $null }
$targetInvocations = 0
try {
    $null = Invoke-DevBenchTargetDispatch -InvocationRecord $attemptedRecord -PersistIntent { $attemptedRecord.dispatchIntentUtc = [DateTime]::UtcNow.ToString('o') } -TargetAction { $script:targetInvocations++; throw 'fixture target lost response' }
}
catch { $attemptedError = $_.Exception.Message }
$attemptedProvenance = Get-DevBenchDispatchProvenance -InvocationRecord ([pscustomobject]$attemptedRecord) -Data $null -Semantic $null
Assert-Test ($attemptedError -match 'target lost response' -and $targetInvocations -eq 1 -and
    -not [string]::IsNullOrWhiteSpace([string]$attemptedRecord.dispatchIntentUtc) -and
    -not [string]::IsNullOrWhiteSpace([string]$attemptedRecord.dispatchedUtc) -and $attemptedProvenance.dispatchReached) 'entered target with a lost response remains an attempted unknown mutation'
$terminalWriterAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-TerminalInvocationEvidence' }, $true))[0]
Invoke-Expression $terminalWriterAst.Extent.Text
$headerReaderAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-McpSessionHeaderValue' }, $true))[0]
Invoke-Expression $headerReaderAst.Extent.Text
$missingHeader = Get-McpSessionHeaderValue -Response ([pscustomobject]@{ Headers = @{} })
$arrayHeader = Get-McpSessionHeaderValue -Response ([pscustomobject]@{ Headers = @{ 'Mcp-Session-Id' = @('owned-session', 'ignored') } })
Assert-Test ([string]::IsNullOrWhiteSpace($missingHeader) -and $arrayHeader -eq 'owned-session') 'session header lookup preserves missing-header parse failures and normalizes present array values'
$completedFixture = [pscustomobject][ordered]@{ ok = $true; transportOk = $true; semantic = [pscustomobject]@{ known = $true; ok = $true }; data = [pscustomobject]@{ value = 42 }; errors = @() }
$completionWriteSucceeded = Write-TerminalInvocationEvidence -Result $completedFixture -FailurePrefix 'fixture completion write failed' -WriteAction { throw 'fixture persistence fault' }
Assert-Test (-not $completionWriteSucceeded -and $completedFixture.ok -and $completedFixture.transportOk -and $completedFixture.data.value -eq 42 -and $completedFixture.evidenceWarnings[0] -match 'fixture persistence fault' -and -not $completedFixture.evidenceJournalFinalized) 'post-completion journal failure preserves the exact completed response and reports evidence loss'
Assert-Test ($entryPointText -notmatch '(?im)^\s*\$pid\s*=') 'entry point never assigns PowerShell reserved PID variable'
Assert-Test ($entryPointText -match '\$expectations\.buildId\s+-and\s+\$actualBuildId\s+-and') 'deferred build identity never compares a missing runtime build ID'
Assert-Test ($entryPointText -match '\$Command -eq ''wait'' -and \$statusCode -eq 404') 'transient MCP 404 recovery is restricted to bounded waits'
Assert-Test ($entryPointText -match 'full-runtime-rebind-required') 'bounded waits route invalidated MCP sessions through a full runtime rebind'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$RequirePerformanceNeutral\) -and -not \$semantic\.known') 'required semantic outcomes reject unknown responses'
Assert-Test ($entryPointText -match 'ok = \[bool\]\$observation\.satisfied') 'wait semantics retain the observed unsatisfied condition'
Assert-Test ($entryPointText -match '\$Command -eq ''call'' -and -not \$readOnlyCall -and -not \$runtimeIdentity\.complete') 'only mutation-capable calls require complete runtime identity'
Assert-Test ($entryPointText -match '\[string\]\$ExpectedRuntimeIdentityJson') 'controller accepts an exact prior runtime identity for pre-dispatch continuity'
Assert-Test ($entryPointText.IndexOf('Expected runtime identity is invalid:') -lt $entryPointText.IndexOf("Update-InvocationEvidence -State 'dispatching'")) 'runtime identity continuity is verified before mutation dispatch'
Assert-Test ($entryPointText -match 'if \(\$Command -eq ''call''\) \{[\s\S]{0,100}-not \$semantic\.known -or -not \$semantic\.ok') 'mutation-capable calls fail closed on unknown semantic outcomes'
Assert-Test ($entryPointText -match '\$Tool -eq ''communityshaders\.profiler''') 'profiler calls have an explicit semantic contract adapter'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''status''[\s\S]{0,180}\.status\.PSObject\.Properties\[''frame_count''\]') 'profiler status requires a frame-bearing status payload'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''enable''[\s\S]{0,160}\[bool\]\$profilerPayload\[0\]\.enabled') 'profiler enable requires observed enabled state'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''disable''[\s\S]{0,180}-not \[bool\]\$profilerPayload\[0\]\.enabled') 'profiler disable requires observed disabled state'
Assert-Test ($entryPointText -match 'outcome = ''profiler-contract-satisfied''') 'accepted profiler responses report their contract-specific outcome'
Assert-Test ($entryPointText -match 'Invoke-ToolRpc -Name \$Tool -Arguments \$arguments -Headers \$headers -Mutation:\(-not \$readOnlyCall\)') 'user calls carry their explicit retry-safety classification'
Assert-Test ($entryPointText -match 'not-retried-indeterminate') 'ambiguous mutation transport failures are not replayed'
Assert-Test ($entryPointText -match 'failureState = if \(\$outcomeIndeterminate\) \{ ''indeterminate'' \}' -and $entryPointText -match 'Update-InvocationEvidence -State \$failureState') 'indeterminate mutation outcomes are durably journaled'
Assert-Test ($entryPointText -match '-Semantic \$failureSemantic -Data \$failureData -Errors' -and $entryPointText -match 'else \{ \$semantic \}') 'post-dispatch failures preserve accepted data and semantics in the invocation journal when possible'
Assert-Test (
    $entryPointText -match 'acceptedDataRetained = \[bool\]\$dispatch\.acceptedDataRetained' -and
    $entryPointText -match 'responseDataRetained = \[bool\]\$dispatch\.responseDataRetained' -and
    $entryPointText -match 'data = \$failureData'
) 'post-dispatch failure envelopes retain accepted response data and expose its provenance'
Assert-Test ($entryPointText -match '\$headers = \$null[\s\S]{0,300}probeError') 'wait probe transport failures force full session and identity rebind'
Assert-Test ($entryPointText -match '-TimeoutSec \(Get-RequestTimeoutSeconds\)') 'wait requests consume only their remaining operation budget'
Assert-Test ($entryPointText -match '\$operationStartedUtc = \[DateTime\]::UtcNow' -and $entryPointText -match '\$operationDeadlineUtc = \$operationStartedUtc.AddSeconds\(\$TimeoutSeconds\)' -and $entryPointText -notmatch '\[Math\]::Min\(15,') 'blocking calls use the declared operation budget instead of a fixed 15-second transport cap'
Assert-Test ($entryPointText -notmatch 'Start-Sleep -Milliseconds \$currentDelay') 'wait poll delays cannot exceed the operation deadline'
Assert-Test ($entryPointText -match 'mcp-session-reinitialized') 'bounded waits reinitialize invalidated MCP sessions'
Assert-Test ($entryPointText -match '\[ValidateRange\(0, 1000\)\][\s\S]{0,80}\[int\]\$MaxSessionRebinds = 0' -and $entryPointText -match '\$MaxSessionRebinds -gt 0') 'bounded waits rely on the caller deadline by default and expose an optional explicit session-churn cap'
Assert-Test ($entryPointText -match '\[ValidateRange\(1, 3600\)\][\s\S]{0,80}\[int\]\$TimeoutSeconds = 30') 'readiness waits admit explicit task-proportional deadlines up to one hour'
Assert-Test ($entryPointText -match "outcome = 'wait-timeout'" -and $entryPointText -match 'lastSuccessfulObservation = \$lastSuccessfulWaitObservation') 'deadline expiry returns a structured timeout with the last successful state observation'
Assert-Test ($entryPointText -match "persistentSessionInvalidation\) \{ 'persistent-session-invalidated'" -and $entryPointText -match 'lastSuccessfulObservation = \$lastSuccessfulWaitObservation' -and $entryPointText -match 'Update-InvocationEvidence -State \$failureState .* -Data \$failureData') 'persistent session invalidation returns and journals a distinct state with the last successfully decoded observation'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$Command -eq ''wait''\)') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match 'function Close-McpSession') 'entry point defines deterministic MCP session cleanup'
Assert-Test ($entryPointText -match '-Method Delete') 'owned MCP sessions are closed through the server lifecycle endpoint'
Assert-Test ($entryPointText -match "state = 'already_absent'") 'an already-retired MCP session is a successful cleanup'
Assert-Test ($entryPointText -match 'Close-OwnedMcpSession -Endpoint \$endpoint -Headers \$sessionHeaders') 'partially opened MCP sessions are cleaned before rethrowing'
Assert-Test ($entryPointText -match 'Add-Member -NotePropertyName sessionCleanup') 'controller results preserve a structured session cleanup receipt'
Assert-Test ($entryPointText -match "clientInfo = @\{ name = 'DevBenchControl'; version = '1\.5' \}") 'MCP client identity records the timeout-envelope revision'
Assert-Test ($entryPointText -match '\[int\]\$RequestTimeoutSeconds = 15') 'controller exposes its default request timeout'
Assert-Test ($entryPointText -match '\$arguments\.ContainsKey\(''timeoutMs''\)') 'controller detects a server-owned timeout budget'
Assert-Test ($entryPointText -match 'Ceiling\(\$serverTimeoutMilliseconds / 1000\.0\)') 'controller converts the server budget without truncation'
Assert-Test ($entryPointText -match '\$serverTimeoutSeconds \+ 5') 'controller keeps a five-second receipt envelope beyond the server budget'
Assert-Test ($entryPointText -match 'function Set-ServerWaitBudgetAtDispatch' -and $entryPointText -match '\$script:operationDeadlineUtc = \$now.AddSeconds\(\$requiredOperationSeconds\)' -and $entryPointText -match 'Set-ServerWaitBudgetAtDispatch -Arguments \$Arguments') 'server-owned waits extend the actual operation deadline at dispatch'
Assert-Test ($entryPointText -match 'operationDeadlineUtc = \$script:operationDeadlineUtc.ToString') 'receipts expose the effective operation deadline'
Assert-Test ($entryPointText -match 'serverTimeoutDispatchRemainingSeconds') 'receipts expose the remaining dispatch allowance for a server-owned wait'
Assert-Test ($entryPointText -match 'function Close-AllMcpSessions') 'controller retains cleanup evidence for every issued MCP session'
Assert-Test ($entryPointText -match 'Close-McpSessionForRebind') 'session rebind requires a successful prior cleanup reconciliation'
Assert-Test ($entryPointText -match 'elseif \(\$Condition -eq ''upscalingStable''\)[\s\S]+?catch \{[\s\S]+?Close-McpSessionForRebind -Headers \$headers[\s\S]+?\$headers = \$null') 'upscalingStable discards retryably invalidated sessions before another observation'
Assert-Test ($entryPointText -match "DevBenchMcpSessionId" -and $entryPointText -match "returned malformed JSON") 'malformed initialization JSON preserves an already-issued MCP session identity'
Assert-Test ($entryPointText -match "DevBenchCleanupUncertain" -and $entryPointText -match 'refusing automatic rebind') 'uncertain partial-session cleanup is never classified for automatic rebind'
Assert-Test ($entryPointText -match "invocationRecord\['sessionCleanup'\]") 'final MCP cleanup evidence is written to the durable invocation journal'
Assert-Test ($entryPointText -match "Session cleanup evidence could not be journaled" -and $entryPointText -match 'evidenceJournalFinalized') 'a final journal failure is reported without suppressing the completed controller result'
Assert-Test ($entryPointText -match "outcome = 'tool-unavailable'" -and $entryPointText -match "codes = @\('tool_unavailable'\)") 'missing optional tools retain a structured unavailable outcome without dispatch'
Assert-Test ($entryPointText -match 'method = ''tools/list''[\s\S]{0,400}currentTools') 'performance boundaries refresh the live tool registry'
Assert-Test ($entryPointText -match 'function Invoke-ToolRpc[\s\S]{0,1200}Invoke-McpRequest' -and $entryPointText -match 'function Invoke-ToolRpc[\s\S]{0,500}Invoke-RestRequest') 'tool calls use the shared deadline-bounded request path for both negotiated transports'
Assert-Test ($entryPointText -match 'requestTimeoutSeconds = \$script:requestTimeoutSecondsForRpc') 'receipts expose the effective request timeout'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "classification = 'session-rebind-required'" -and $entryPointText -match "phase = 'discovery-identity-or-probe'") 'serviceReady carries transient discovery, identity, or probe exhaustion into the outer wait'
$fullWaitRecoveryTry = @($entryPointAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text -match 'Get-ToolDescriptors -Headers \$headers' -and
    $node.Body.Extent.Text -match 'Get-RuntimeIdentity -Runtime \$runtime' -and
    $node.Body.Extent.Text -match 'Invoke-ToolRpc -Name \$Tool' -and
    @($node.CatchClauses | Where-Object { $_.Body.Extent.Text -match 'Close-McpSessionForRebind -Headers \$headers' }).Count -eq 1
}, $true))
Assert-Test ($fullWaitRecoveryTry.Count -eq 1) 'tool discovery, post-registration identity, and the read-only readiness probe share one cleanup-qualified rebind boundary'
Assert-Test ($entryPointText -match 'Get-RuntimeIdentity[\s\S]+?catch \{\s*if \(Test-WaitRetryableException -Exception \$_\.Exception\) \{ throw \}') 'runtime identity preserves retryable health and producer-probe transport exceptions for the shared rebind state machine'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match "classification = 'late-positive-observation'" -and $entryPointText -match 'lateObservation = \$lateObservation' -and $entryPointText -match 'Test-DevBenchWaitDeadlineAcceptance') 'late positive observations are retained but cannot cross the absolute wait deadline as success'
Assert-Test ($entryPointText -match "phase = 'initialize'; recovery = 'outer-wait-retry'") 'wait initialization failures remain inside the outer timeout state machine'
Assert-Test ($entryPointText -match '\$null -eq \$headers') 'bounded waits establish or re-establish the MCP session inside the polling loop'
Assert-Test ($entryPointText -match 'function Open-DevBenchSession' -and $entryPointText -match "DevBenchMcpCapabilityAbsent" -and $entryPointText -match "recovery = 'rest-capability-negotiation'") 'transport negotiation falls back only after an explicitly classified initial MCP capability miss'
Assert-Test ($entryPointText -match '/api/tools' -and $entryPointText -match '/api/tool/\$escapedName') 'REST fallback uses DevBench discovery and exact tool endpoints'
Assert-Test ($entryPointText -match 'DevBench REST mutation transport failed after dispatch' -and $entryPointText -match 'DevBenchIndeterminateMutation') 'REST mutations preserve the no-replay indeterminate contract'
Assert-Test ($entryPointText -match 'transport = \$transport') 'runtime and invocation evidence identify the negotiated transport'
Assert-Test (([regex]::Matches($entryPointText, '\$AcceptAlreadyLoaded')).Count -eq 1 -and ([regex]::Matches($entryPointText, '\$LoadAlreadyQueued')).Count -eq 1 -and $entryPointText -notmatch '\$playerTransitionObserved') 'legacy load switches are accepted without retaining a transient load-edge dependency'
Assert-Test ($entryPointText -match 'Condition ''playerLoaded'' requires -ExpectedCell') 'playerLoaded requires an exact destination cell'
Assert-Test ($entryPointText -match 'elseif \(\$Condition -eq ''playerLoaded''\)[\s\S]+?kind = ''state''[\s\S]+?kind = ''scene''') 'playerLoaded polls authoritative player and scene state'
Assert-Test ($entryPointText -match 'completionBasis = ''current-state''') 'playerLoaded receipts identify state-based completion'
Assert-Test ($entryPointText -match 'satisfied = \[bool\]\$state\.playerLoaded -and \$cellMatches') 'playerLoaded requires loaded state in the expected cell'
Assert-Test ($entryPointText -match '\[string\[\]\]\$DismissBlockingMenus') 'menu recovery requires an explicit menu allowlist'
Assert-Test ($entryPointText -match 'action = ''close''; name = \$menuName') 'menu recovery uses the registered menu close action'
Assert-Test ($entryPointText -match '\[int\]\$MinimumMenuStableSeconds') 'menu recovery can require a continuous stable window'
Assert-Test ($entryPointText -match '\$menuStableSinceUtc = \$null') 'a blocking observation resets menu stabilization'
Assert-Test ($entryPointText -match '\[switch\]\$RequirePerformanceNeutral') 'performance calls expose an explicit fail-closed guard'
Assert-Test ($entryPointText -match "'skyrimvrupscaler\.temporalProbe'") 'performance guard queries the standalone probe owner'
Assert-Test ($entryPointText -match 'toolCallSkipped = \$true') 'distorted performance guard skips the requested tool call'
Assert-Test ($entryPointText -match 'Test-DevBenchPerformanceWindow') 'guarded calls verify the probe again after the requested tool returns'
Assert-Test ($entryPointText -match "outcome = 'guard-invalidated'") 'changed probe ownership invalidates completed measurement calls'

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
Assert-Test ($entryPointText -match "Condition 'upscalingStable' requires -ExpectedCell") 'upscalingStable cannot accept a stale source scene'
Assert-Test ($entryPointText -match '\[string\]\$ExpectedProfileJson') 'upscalingStable accepts a complete expected profile when a protocol needs target correlation'
Assert-Test ($entryPointText -match 'ExpectedProfileJson requires') 'upscalingStable rejects incomplete expected profile data'
Assert-Test ($entryPointText -match 'ExpectedProfile \$expectedUpscalingProfile') 'upscalingStable passes the expected profile into the stability predicate'
Assert-Test ($entryPointText -match "scene\.cell\.PSObject\.Properties\['editorId'\]") 'upscalingStable reads the structured live scene cell editor ID'
Assert-Test ($entryPointText -match '\$stableCandidateCount -ge \$StableSamples') 'upscalingStable requires consecutive stable observations'
Assert-Test ($entryPointText -match '\$stableFrameAdvance -ge \$MinimumStableFrameAdvance') 'upscalingStable requires advancing world frames'
Assert-Test ($entryPointText -match 'elapsedMs = \[Math\]::Round') 'bounded waits report measured elapsed time'

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) { exit 1 }
