# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'CocStabilityControl.psm1'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocStabilityControl.ps1'
$configPath = Join-Path $PSScriptRoot 'protocol.v1.json'
Import-Module $modulePath -Force

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 30
$requiredPreparationEvents = @(
    'request_queued', 'admission_check', 'early_exit',
    'shader_cache_busy_wait', 'sss_raymarch_prewarm', 'ssgi_prewarm',
    'dlss_preparation', 'fsr_preparation', 'fsr4_preparation',
    'd3d_object_creation', 'total_preparation', 'request_to_prepared',
    'prepared_to_creator'
)
if (@($config.telemetry.preparation.eventNames).Count -ne
    $requiredPreparationEvents.Count -or
    @($requiredPreparationEvents | Where-Object {
            $_ -notin @($config.telemetry.preparation.eventNames)
        }).Count -ne 0) {
    throw 'The protocol config does not retain every preparation stage.'
}
$scenario = New-CocMeasuredScenario -ProtocolConfig $config `
    -ExpectedBuildId ('a' * 64) -OwnerId 'test-owner'
$steps = @($scenario.steps)
$statuses = @($steps | Where-Object label -match '^coc-\d{2}-status$')
$qualificationStatuses = @($steps | Where-Object label -like 'coc-*-qualification-status')
$dispatches = @($steps | Where-Object label -like 'coc-*-dispatch')
$waiters = @($steps | Where-Object label -like 'coc-*-wait')
$fixedWaitSteps = @($steps | Where-Object {
    $_ -is [Collections.IDictionary] -and $_.Contains('wait')
})

if ($scenario.async -ne $true -or $scenario.continueOnError -ne $false) {
    throw 'The measured scenario is not one async fail-fast control batch.'
}
if ($steps.Count -ne 102 -or $statuses.Count -ne 20 -or
    $qualificationStatuses.Count -ne 20 -or $dispatches.Count -ne 20 -or
    $waiters.Count -ne 20) {
    throw 'The measured scenario does not contain setup plus exactly 20 transitions.'
}
$telemetryDispatches = @($dispatches | Where-Object {
    $_.args.Contains('startPerformanceTelemetry') -and
    [bool]$_.args.startPerformanceTelemetry
})
if ($telemetryDispatches.Count -ne 1 -or
    -not [bool]$dispatches[0].args.startPerformanceTelemetry) {
    throw 'Only transition 1 may atomically start CPU and GPU telemetry.'
}
for ($index = 0; $index -lt 20; $index++) {
    $expectedCell = if ((($index + 1) % 2) -eq 1) {
        'WhiterunDragonsreach'
    } else {
        'WindhelmExterior01'
    }
    $offset = 2 + ($index * 5)
    if ([string]$steps[$offset + 2].label -ne [string]$dispatches[$index].label -or
        [string]$steps[$offset + 3].label -ne [string]$waiters[$index].label -or
        [string]$steps[$offset + 4].label -ne [string]$statuses[$index].label) {
        throw "Transition $($index + 1) does not execute its COC immediately before the bounded waiter."
    }
    if ([string]$dispatches[$index].args.action -ne 'qualification_dispatch' -or
        [string]$waiters[$index].args.action -ne 'qualification_wait') {
        throw "Transition $($index + 1) does not use the dispatch/wait action pair."
    }
    if ([string]$dispatches[$index].args.cocCellEditorId -ne $expectedCell) {
        throw "Transition $($index + 1) has the wrong exact COC target."
    }
    if ([int]$waiters[$index].args.timeoutMs -ne 30000 -or
        [string]$waiters[$index].args.milestone -ne 'strict') {
        throw "Transition $($index + 1) does not use the strict 30-second maximum waiter deadline."
    }
    if ($waiters[$index].args.Contains('target')) {
        throw "Transition $($index + 1) attempts to own the Stabilizer profile."
    }
}
if ($fixedWaitSteps.Count -ne 0) {
    throw 'The measured scenario contains a fixed wait before a COC dispatch.'
}

$results = [Collections.Generic.List[object]]::new()
for ($ordinal = 1; $ordinal -le 20; $ordinal++) {
    $results.Add([pscustomobject]@{
        label = "coc-$($ordinal.ToString('D2'))-wait"
        result = [pscustomobject]@{
            transitionId = $ordinal; ownerId = 'test-owner'
            presentationStable = $true; presentationElapsedMs = $ordinal * 2
            presentationElapsedFrames = $ordinal; presentationFailureMask = 0
            presentationFailureReasons = @(); cleanupDrained = $true
            cleanupElapsedMs = $ordinal * 3; cleanupElapsedFrames = $ordinal + 2
            cleanupFailureMask = 0; cleanupFailureReasons = @()
            strictSatisfied = $true; strictElapsedMs = $ordinal * 4
            strictElapsedFrames = $ordinal + 5; strictFailureMask = 0
            strictFailureReasons = @(); outstandingCleanupDebt = @()
            timing = [pscustomobject]@{ dispatchTick = $ordinal }
            frames = [pscustomobject]@{ dispatch = $ordinal }
            observation = [pscustomobject]@{
                physical = [pscustomobject]@{
                    stable = [pscustomobject]@{ transitionEpoch = 1000 + $ordinal }
                }
                diagnostics = [pscustomobject]@{
                    delta = [pscustomobject]@{ vendorFailures = 0; boundsMismatchFallbacks = 0 }
                }
                resourcePublication = [pscustomobject]@{
                    current = $true; currentGeneration = $ordinal; completedGeneration = $ordinal; publishedGeneration = $ordinal
                    expectedWidth = 1644; expectedHeight = 1826; publishedWidth = 1644; publishedHeight = 1826
                    complete = $true; deferredSetupAcknowledged = $true; deviceMatches = $true; contextMatches = $true
                }
            }
            producer = [pscustomobject]@{ buildId = ('a' * 64) }
        }
    })
    $results.Add([pscustomobject]@{
        label = "coc-$($ordinal.ToString('D2'))-status"
        result = [pscustomobject]@{
            status = [pscustomobject]@{
                preparation = [pscustomobject]@{
                    schemaVersion = 1; devBenchOnly = $true; active = $true
                    sessionId = 7; qpcFrequency = 10000000
                    retainedEvents = $ordinal; capacity = 512
                    overwrittenEvents = 0; coalescedEvents = 0
                    events = @([pscustomobject]@{
                            sequence = $ordinal; sessionId = 7
                            requestId = 2000 + $ordinal
                            transitionEpoch = 1000 + $ordinal
                            event = 'total_preparation'; outcome = 'ready'
                            occurrences = 1; reasons = @()
                            durationQpcTicks = 100; durationMs = 0.01
                            bytecodeCompilationMs = 0
                            d3dObjectCreationMs = 0
                        })
                }
            }
        }
    })
}
$analysis = Get-CocQualificationAnalysis -Scenario ([pscustomobject]@{
        results = @($results)
    }) -ProtocolConfig $config -ExpectedOwnerId 'test-owner'
if (-not $analysis.available -or -not $analysis.complete -or
    $analysis.transitions.Count -ne 20 -or
    $analysis.timings.strictFrames.p95 -ne 24 -or
    $analysis.transitions[0].cleanupTailFrames -ne 5 -or
    $analysis.totals.vendorFailures -ne 0 -or
    -not $analysis.transitions[0].resourcePublication.current -or
    $analysis.resourcePublication.availableSamples -ne 20 -or
    $analysis.resourcePublication.currentSamples -ne 20 -or
    $analysis.preparation.availableSamples -ne 20 -or
    $analysis.preparation.exactTransitionSamples -ne 20 -or
    $analysis.preparation.eventCount -ne 20 -or
    -not $analysis.transitions[0].preparation.stages.total_preparation.observed) {
    throw 'Strict milestone analysis did not retain the required timing and failure evidence.'
}

$missingLabelAnalysis = Get-CocQualificationAnalysis -Scenario (
    [pscustomobject]@{
        results = @([pscustomobject]@{
                label = 'unrelated-record'
                result = [pscustomobject]@{}
            })
    }
) -ProtocolConfig $config
if (-not $missingLabelAnalysis.available -or
    $missingLabelAnalysis.complete -or
    $missingLabelAnalysis.missingEvidence.Count -ne 40 -or
    $missingLabelAnalysis.transitions.Count -ne 20 -or
    @($missingLabelAnalysis.transitions | Where-Object receiptPresent).Count -ne 0) {
    throw 'Missing scenario labels did not remain absent receipt evidence.'
}
$partialDisposition = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        done = $true
        ok = $true
        results = @()
    }) -Analysis $missingLabelAnalysis
if ($partialDisposition.ok -or
    $partialDisposition.state -ne 'evidence-partial' -or
    $partialDisposition.evidenceComplete -or
    @($partialDisposition.errors).Count -ne 1) {
    throw 'Terminal execution with incomplete evidence was reported as qualified success.'
}

$missingStatusAnalysis = Get-CocQualificationAnalysis -Scenario (
    [pscustomobject]@{
        results = @($results | Where-Object { $_.label -ne 'coc-01-status' })
    }
) -ProtocolConfig $config -ExpectedOwnerId 'test-owner'
if ($missingStatusAnalysis.complete -or
    'coc-01-status' -notin @($missingStatusAnalysis.missingEvidence)) {
    throw 'A missing mandatory status receipt was accepted as complete evidence.'
}

$incompleteStatusResults = @($results | ForEach-Object {
        if ($_.label -eq 'coc-01-status') {
            [pscustomobject]@{ label = $_.label; result = [pscustomobject]@{} }
        } else { $_ }
    })
$incompleteStatusAnalysis = Get-CocQualificationAnalysis -Scenario (
    [pscustomobject]@{ results = $incompleteStatusResults }
) -ProtocolConfig $config -ExpectedOwnerId 'test-owner'
if ($incompleteStatusAnalysis.complete -or
    'coc-01-status.preparation' -notin @($incompleteStatusAnalysis.missingEvidence)) {
    throw 'Structurally incomplete status evidence was accepted as complete.'
}

$malformedReceiptResults = @($results | ConvertTo-Json -Depth 50 |
    ConvertFrom-Json -Depth 50)
$firstWait = $malformedReceiptResults | Where-Object label -eq 'coc-01-wait' |
    Select-Object -First 1
$firstWait.result.PSObject.Properties.Remove('observation')
$firstWait.result.transitionId = 'not-a-transition'
$malformedReceiptAnalysis = Get-CocQualificationAnalysis -Scenario (
    [pscustomobject]@{ results = $malformedReceiptResults }
) -ProtocolConfig $config -ExpectedOwnerId 'test-owner'
if ($malformedReceiptAnalysis.complete -or
    'coc-01-wait.transitionId' -notin @($malformedReceiptAnalysis.missingEvidence) -or
    'coc-01-wait.resourcePublication' -notin @($malformedReceiptAnalysis.missingEvidence)) {
    throw 'Missing observation or malformed transition identity escaped evidence classification.'
}

$unavailableDisposition = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        done = $true
        ok = $true
        results = @()
    }) -Analysis ([pscustomobject]@{
        available = $false
        reason = 'The scenario transcript has no result records.'
    })
if ($unavailableDisposition.ok -or
    $unavailableDisposition.state -ne 'evidence-partial' -or
    @($unavailableDisposition.errors)[0] -notlike '*no result records*') {
    throw 'Unavailable qualification analysis did not remain evidence-partial.'
}

$undetailedFailure = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        done = $true
        ok = $false
        results = @()
    }) -Analysis $missingLabelAnalysis
if ($undetailedFailure.ok -or $undetailedFailure.state -ne 'failed' -or
    [string]::IsNullOrWhiteSpace([string](@($undetailedFailure.errors)[0]))) {
    throw 'A failed scenario without an error property lost its failure detail.'
}
$completeDisposition = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        done = $true
        ok = $true
        results = @($results)
    }) -Analysis $analysis
if (-not $completeDisposition.ok -or
    $completeDisposition.state -ne 'complete' -or
    -not $completeDisposition.evidenceComplete) {
    throw 'A complete successful transcript was not accepted.'
}
$runningDisposition = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        done = $false
        ok = $true
        results = @()
    }) -Analysis $missingLabelAnalysis
if (-not $runningDisposition.ok -or $runningDisposition.state -ne 'running') {
    throw 'A running partial transcript was not preserved as provisional evidence.'
}

$ownershipConflict = Test-CocBaseline -Results @{
    state = [pscustomobject]@{ value = [pscustomobject]@{ playerLoaded = $true } }
    scene = [pscustomobject]@{ value = [pscustomobject]@{ cell = 'WindhelmExterior01' } }
    upscaling = [pscustomobject]@{ value = [pscustomobject]@{} }
    renderscale = [pscustomobject]@{
        value = [pscustomobject]@{
            status = [pscustomobject]@{
                session = [pscustomobject]@{ active = $true }
                cpuPerformance = [pscustomobject]@{ active = $false }
                gpuPerformance = [pscustomobject]@{ active = $false }
            }
        }
    }
    image = [pscustomobject]@{ value = [pscustomobject]@{} }
} -ExpectedCell 'WindhelmExterior01'
if (-not $ownershipConflict.ownershipConflict -or
    $ownershipConflict.ownershipConflicts.Count -ne 1 -or
    $ownershipConflict.ownershipConflicts[0] -notlike '*unowned stress*') {
    throw 'A foreign diagnostic session was not classified as an ownership conflict.'
}

$moduleScript = Get-Content -LiteralPath $modulePath -Raw
foreach ($required in @(
    "Get-CocPropertyValue -Value `$scene -Name 'cell'",
    "Get-CocPropertyValue -Value `$cell -Name 'editorId'",
    "Get-CocPropertyValue -Value `$state -Name 'playerLoaded'",
    'ConvertTo-CocBoolean',
    'if ($matches.Count -eq 0) { return $null }',
    'dispatch-claim-failed',
    'evidence-partial'
)) {
    if (-not $moduleScript.Contains($required, [StringComparison]::Ordinal)) {
        throw "COC stability module is missing safe optional-field handling: $required"
    }
}

$script = Get-Content -LiteralPath $scriptPath -Raw
foreach ($required in @(
    '[Diagnostics.Stopwatch]::GetTimestamp()',
    'New-CocDispatchClaim',
    "'baseline-complete'",
    "'deadline'",
    "-Tool 'communityshaders.menu'",
    "-Tool 'scenario'",
    'Start-ThreadJob',
    'CollectorStatePath',
    'expectedProcessStartTimeUtc',
    'dispatch-interrupted'
)) {
    if (-not $script.Contains($required, [StringComparison]::Ordinal)) {
        throw "COC stability controller is missing: $required"
    }
}

$controllerTokens = $null
$controllerParseErrors = $null
$controllerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$controllerTokens, [ref]$controllerParseErrors
)
if ($controllerParseErrors.Count -ne 0) {
    throw 'The COC stability controller does not parse.'
}
foreach ($functionName in @('Get-JobResult', 'Get-CocFixtureAnomalies')) {
    $functionAst = $controllerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
    if ($null -eq $functionAst) {
        throw "The controller helper is missing: $functionName"
    }
    Invoke-Expression $functionAst.ToString()
}

$emptyJob = $null
try {
    $emptyJob = Start-ThreadJob -ScriptBlock {}
    Wait-Job -Job $emptyJob | Out-Null
    $emptyJobResult = Get-JobResult $emptyJob
    if ($emptyJobResult.ok -or
        [string]::IsNullOrWhiteSpace([string]$emptyJobResult.error)) {
        throw 'A completed background job without output was accepted.'
    }
}
finally {
    if ($emptyJob) { Remove-Job -Job $emptyJob -Force }
}

$fixtureAnomalies = @(Get-CocFixtureAnomalies -Value ([pscustomobject]@{
            ready = $false
            persisted = $true
            promptRequired = $true
        }))
if ($fixtureAnomalies.Count -ne 3) {
    throw 'Independent prepare_coc defects were collapsed into one anomaly.'
}

$claimFixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-claim-' + [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $claimFixture | Out-Null
    $claimPath = Join-Path $claimFixture 'dispatch.claim'
    $firstClaim = New-CocDispatchClaim -Path $claimPath -Source 'first'
    $secondClaim = New-CocDispatchClaim -Path $claimPath -Source 'second'
    $failedClaim = New-CocDispatchClaim -Path $claimFixture -Source 'invalid'
    if (-not $firstClaim.ok -or $firstClaim.state -ne 'dispatch-claimed' -or
        -not $secondClaim.ok -or
        $secondClaim.state -ne 'dispatch-already-claimed' -or
        $failedClaim.ok -or $failedClaim.state -ne 'dispatch-claim-failed') {
        throw 'Dispatch claim outcomes do not distinguish ownership from I/O failure.'
    }
}
finally {
    if (Test-Path -LiteralPath $claimFixture -PathType Container) {
        Remove-Item -LiteralPath $claimFixture -Recurse -Force
    }
}

$invalidAcceptedFixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-stability-invalid-accepted-' + [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $invalidAcceptedFixture | Out-Null
    $invalidAcceptedPath = Join-Path $invalidAcceptedFixture 'state.json'
    [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-state-v1'
        outcome = 'scenario-accepted'
        endpoint = 'http://127.0.0.1:1/mcp'
        ownerId = 'invalid-owner'
        expectedPid = 0
        expectedProcessStartTimeUtc = $null
        protocolConfigPath = $configPath
        scenarioRunId = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidAcceptedPath -Encoding utf8
    $invalidAcceptedStatus = & $scriptPath status -StatePath $invalidAcceptedPath `
        -Compact -NoExit | ConvertFrom-Json -Depth 30
    if ($invalidAcceptedStatus.ok -or
        $invalidAcceptedStatus.state -ne 'journal-invalid' -or
        @($invalidAcceptedStatus.errors).Count -lt 3) {
        throw 'Malformed accepted state was not rejected before endpoint access.'
    }
}
finally {
    if (Test-Path -LiteralPath $invalidAcceptedFixture) {
        Remove-Item -LiteralPath $invalidAcceptedFixture -Recurse -Force
    }
}

$invalidProtocolFixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-stability-invalid-protocol-' + [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $invalidProtocolFixture | Out-Null
    $invalidProtocolPath = Join-Path $invalidProtocolFixture 'protocol.json'
    '{"schema":"unrelated-protocol"}' |
        Set-Content -LiteralPath $invalidProtocolPath -Encoding utf8
    $invalidProtocolStatePath = Join-Path $invalidProtocolFixture 'state.json'
    $currentStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-state-v1'
        outcome = 'scenario-accepted'
        endpoint = 'http://127.0.0.1:1/mcp'
        ownerId = 'invalid-protocol-owner'
        expectedPid = $PID
        expectedProcessStartTimeUtc = $currentStart
        protocolConfigPath = $invalidProtocolPath
        scenarioRunId = 1
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $invalidProtocolStatePath -Encoding utf8
    $invalidProtocolStatus = & $scriptPath status `
        -StatePath $invalidProtocolStatePath -Compact -NoExit |
        ConvertFrom-Json -Depth 30
    if ($invalidProtocolStatus.ok -or
        @($invalidProtocolStatus.errors)[0] -notlike '*schema is unsupported*') {
        throw 'Status did not reject an unrelated protocol schema before endpoint access.'
    }
}
finally {
    if (Test-Path -LiteralPath $invalidProtocolFixture) {
        Remove-Item -LiteralPath $invalidProtocolFixture -Recurse -Force
    }
}

$rejectedFixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-stability-rejected-' + [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $rejectedFixture | Out-Null
    $rejectedStatePath = Join-Path $rejectedFixture 'state.json'
    [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-state-v1'
        outcome = 'scenario-rejected'
        endpoint = 'http://127.0.0.1:1/mcp'
        ownerId = 'rejected-owner'
        protocolConfigPath = $configPath
        scenarioRunId = $null
        dispatchFailure = [pscustomobject]@{ error = 'fixture dispatch rejection' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rejectedStatePath -Encoding utf8
    $rejectedStatus = & $scriptPath status -StatePath $rejectedStatePath `
        -Compact -NoExit | ConvertFrom-Json -Depth 30
    if ($rejectedStatus.ok -or $rejectedStatus.state -ne 'failed' -or
        $null -ne $rejectedStatus.data.scenarioRunId -or
        $rejectedStatus.errors[0] -ne 'fixture dispatch rejection' -or
        $rejectedStatus.data.dispatchFailure.error -ne 'fixture dispatch rejection') {
        throw 'Rejected scenario status did not preserve the terminal dispatch failure.'
    }
}
finally {
    if (Test-Path -LiteralPath $rejectedFixture) {
        Remove-Item -LiteralPath $rejectedFixture -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $true
    exactTransitions = 20
    atomicPerformanceOrigin = $true
    monotonicIndependentWatchdog = $true
    exactlyOnceDispatchClaim = $true
    missingBaselineFieldsRemainAnomalies = $true
    missingScenarioLabelsRemainAbsent = $true
} | ConvertTo-Json
