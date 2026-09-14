# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'CocStabilityControl.psm1'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocStabilityControl.ps1'
$configPath = Join-Path $PSScriptRoot 'protocol.v1.json'
Import-Module $modulePath -Force

$moduleTokens = $null
$moduleParseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors
)
if ($moduleParseErrors.Count -ne 0) {
    throw 'The COC stability module does not parse.'
}
foreach ($functionName in @('Get-CocMcpResultContent', 'Get-CocHealthValue')) {
    $functionAst = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
    if ($null -eq $functionAst) {
        throw "The COC stability module helper is missing: $functionName"
    }
    Invoke-Expression $functionAst.ToString()
}

foreach ($invalidCall in @(
        [pscustomobject]@{},
        [pscustomobject]@{ json = [pscustomobject]@{} },
        [pscustomobject]@{ json = [pscustomobject]@{ result = $null } },
        [pscustomobject]@{
            json = [pscustomobject]@{ result = [pscustomobject]@{} }
        }
    )) {
    try {
        Get-CocMcpResultContent -Call $invalidCall -Context 'test health' | Out-Null
        throw 'A malformed MCP response shape was accepted.'
    }
    catch {
        if ($_.Exception.Message -notlike 'test health returned no *') { throw }
    }
}
foreach ($invalidContent in @(
        'not-an-array',
        [pscustomobject]@{ type = 'text'; text = '{}' },
        @([pscustomobject]@{ text = '{}' }),
        @($null)
    )) {
    try {
        Get-CocMcpResultContent -Call ([pscustomobject]@{
                json = [pscustomobject]@{
                    result = [pscustomobject]@{ content = $invalidContent }
                }
            }) -Context 'test content' | Out-Null
        throw 'Malformed MCP content was accepted.'
    }
    catch {
        if ($_.Exception.Message -notlike 'test content returned *content*') { throw }
    }
}
try {
    Get-CocMcpResultContent -Call ([pscustomobject]@{
            json = [pscustomobject]@{
                result = [pscustomobject]@{
                    isError = $true
                    content = @([pscustomobject]@{ type = 'text'; text = 'health failed' })
                }
            }
        }) -Context 'test health' | Out-Null
    throw 'An MCP error result was accepted.'
}
catch {
    if ($_.Exception.Message -ne 'test health reported an error result: health failed') {
        throw
    }
}
$healthValue = Get-CocHealthValue -Content @([pscustomobject]@{
        type = 'text'; text = '{"pid":42}'
    })
if ([int]$healthValue.pid -ne 42) {
    throw 'A valid health payload did not round-trip.'
}
foreach ($invalidHealthContent in @(
        @(),
        @([pscustomobject]@{ type = 'image'; data = 'ignored' }),
        @([pscustomobject]@{ type = 'text'; text = 'not-json' })
    )) {
    try {
        Get-CocHealthValue -Content $invalidHealthContent | Out-Null
        throw 'A malformed health payload was accepted.'
    }
    catch {
        if ($_.Exception.Message -notlike 'DevBench health call returned * JSON text payload.') {
            throw
        }
    }
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 30
$protocolRaw = [IO.File]::ReadAllText($configPath)
$protocolSnapshot = New-CocProtocolSnapshot -ProtocolJson $protocolRaw
$snapshotConfig = Get-CocProtocolFromSnapshot `
    -Encoding $protocolSnapshot.encoding -Sha256 $protocolSnapshot.sha256 `
    -Bytes $protocolSnapshot.bytes
if ([string]$snapshotConfig.schema -ne 'csx-coc-stability-protocol-v1') {
    throw 'The immutable protocol snapshot did not round-trip.'
}
$tamperedBytes = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($protocolRaw + ' ')
)
try {
    Get-CocProtocolFromSnapshot -Encoding $protocolSnapshot.encoding `
        -Sha256 $protocolSnapshot.sha256 -Bytes $tamperedBytes | Out-Null
    throw 'Tampered protocol bytes retained the admitted digest.'
} catch {
    if ($_.Exception.Message -notlike '*digest does not match*') { throw }
}
foreach ($badEndpoint in @(
        'http://127.0.0.1:8922/mcp',
        'http://127.0.0.1:8921/other',
        'http://localhost:8921/mcp',
        'http://192.0.2.1:8921/mcp'
    )) {
    try {
        Assert-CocCanonicalEndpoint -Endpoint $badEndpoint | Out-Null
        throw "Noncanonical endpoint was accepted: $badEndpoint"
    } catch {
        if ($_.Exception.Message -notlike '*only accepts the registered*') { throw }
    }
}
$exactStart = (Get-Process -Id $PID).StartTime.ToUniversalTime()
try {
    Assert-CocProcessLifetime -ProcessId $PID `
        -ExpectedStartTimeUtc $exactStart.AddMilliseconds(1).ToString('o')
    throw 'A near-time replacement process was accepted.'
} catch {
    if ($_.Exception.Message -notlike '*no longer denotes*') { throw }
}
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
    $dispatchIndex = [Array]::IndexOf(
        @($steps | ForEach-Object { [string]$_.label }),
        [string]$dispatches[$index].label
    )
    if ($dispatchIndex -lt 0 -or
        [string]$steps[$dispatchIndex + 1].label -ne [string]$waiters[$index].label -or
        [string]$steps[$dispatchIndex + 2].label -ne [string]$statuses[$index].label) {
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
    }) -ProtocolConfig $config -ExpectedOwnerId 'test-owner' `
    -ExpectedBuildId ('a' * 64)
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

foreach ($requiredField in @($config.qualification.receiptFields)) {
    $fieldFixture = @($results | ConvertTo-Json -Depth 50 |
        ConvertFrom-Json -Depth 50)
    $fieldWait = $fieldFixture | Where-Object label -eq 'coc-01-wait' |
        Select-Object -First 1
    $fieldWait.result.PSObject.Properties.Remove([string]$requiredField)
    $fieldAnalysis = Get-CocQualificationAnalysis -Scenario (
        [pscustomobject]@{ results = $fieldFixture }
    ) -ProtocolConfig $config -ExpectedOwnerId 'test-owner' `
        -ExpectedBuildId ('a' * 64)
    if ($fieldAnalysis.complete -or
        "coc-01-wait.$requiredField" -notin @($fieldAnalysis.missingEvidence)) {
        throw "Missing mandatory receipt field was accepted: $requiredField"
    }
}

$duplicateAnalysis = Get-CocQualificationAnalysis -Scenario ([pscustomobject]@{
        results = @($results) + @($results[0])
    }) -ProtocolConfig $config -ExpectedOwnerId 'test-owner' `
    -ExpectedBuildId ('a' * 64)
if ($duplicateAnalysis.complete -or
    'coc-01-wait.duplicate' -notin @($duplicateAnalysis.missingEvidence)) {
    throw 'A duplicate scenario label was accepted as unambiguous evidence.'
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
if ([string]$steps[0].label -ne 'coc-01-qualification-status' -or
    [string]$steps[1].label -ne 'coc-01-begin' -or
    [string]$steps[2].label -ne 'stress-reset' -or
    [string]$steps[3].label -ne 'stress-start' -or
    [string]$steps[2].args.ownerId -ne 'test-owner' -or
    [string]$steps[3].args.ownerId -ne 'test-owner') {
    throw 'Server-side qualification ownership is not established before diagnostic mutation.'
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
$missingDoneDisposition = Get-CocScenarioDisposition -Scenario ([pscustomobject]@{
        ok = $true
        results = @($results)
    }) -Analysis $analysis
if ($missingDoneDisposition.ok -or
    $missingDoneDisposition.state -ne 'evidence-partial') {
    throw 'A scenario without an explicit Boolean done field was accepted.'
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
$nullSceneBaseline = Test-CocBaseline -Results @{
    state = [pscustomobject]@{ value = [pscustomobject]@{ playerLoaded = $true } }
    scene = [pscustomobject]@{ value = $null }
    upscaling = [pscustomobject]@{ value = [pscustomobject]@{} }
    renderscale = [pscustomobject]@{ value = [pscustomobject]@{} }
    image = [pscustomobject]@{ value = [pscustomobject]@{} }
} -ExpectedCell 'WindhelmExterior01'
if ($nullSceneBaseline.acceptable -or
    ($nullSceneBaseline.reasons -join ' | ') -notlike "*baseline 'scene' application value is missing or null*") {
    throw 'A null application-level scene result did not become an attributable baseline rejection.'
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
$semanticDecisionIndex = $script.IndexOf('$baselineVerdict = Test-CocBaseline', [StringComparison]::Ordinal)
$finalDecisionTimestampIndex = $script.IndexOf('$baselineDecisionTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()', $semanticDecisionIndex, [StringComparison]::Ordinal)
if ($semanticDecisionIndex -lt 0 -or $finalDecisionTimestampIndex -le $semanticDecisionIndex) {
    throw 'The final baseline deadline timestamp does not include semantic baseline evaluation.'
}
foreach ($required in @(
    '[Diagnostics.Stopwatch]::GetTimestamp()',
    'New-CocDispatchClaim',
    "'baseline-complete'",
    'baseline admission deadline expired',
    'protocolSha256',
    'Assert-CocCanonicalEndpoint',
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
foreach ($forbidden in @('$watchdogJob', '$earlyJob', "'deadline'")) {
    if ($script.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "COC stability controller retains unsafe deadline dispatch: $forbidden"
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
foreach ($functionName in @(
        'Get-JobResult', 'Get-CocFixtureAnomalies',
        'Test-CocBaselineAdmissionTiming'
    )) {
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
$validFixtureAnomalies = @(Get-CocFixtureAnomalies -Value ([pscustomobject]@{
            ready = $true; persisted = $false; promptRequired = $false
        }))
if ($validFixtureAnomalies.Count -ne 0) {
    throw 'A correctly typed affirmative prepare_coc gate was rejected.'
}
foreach ($invalidFixture in @(
        [pscustomobject]@{ ready = 'false'; persisted = $false; promptRequired = $false },
        [pscustomobject]@{ ready = $true; persisted = $null; promptRequired = $false },
        [pscustomobject]@{ ready = $true; persisted = $false; promptRequired = $null }
    )) {
    $invalidFixtureAnomalies = @(Get-CocFixtureAnomalies -Value $invalidFixture)
    if ($invalidFixtureAnomalies.Count -ne 1 -or
        $invalidFixtureAnomalies[0] -notlike '*non-null Boolean*') {
        throw 'A malformed or null prepare_coc gate was not rejected explicitly.'
    }
}

$timelyTiming = [ordered]@{
    state = [pscustomobject]@{ completedTimestamp = 90 }
    scene = [pscustomobject]@{ completedTimestamp = 91 }
}
$timelyAdmission = Test-CocBaselineAdmissionTiming -Timing $timelyTiming `
    -DueTimestamp 100 -DecisionTimestamp 99 -ExpectedCount 2
if (-not $timelyAdmission.acceptable) {
    throw 'A wholly timely baseline was rejected by the admission clock.'
}
$lateTiming = [ordered]@{
    state = [pscustomobject]@{ completedTimestamp = 90 }
    scene = [pscustomobject]@{ completedTimestamp = 101 }
}
$lateAdmission = Test-CocBaselineAdmissionTiming -Timing $lateTiming `
    -DueTimestamp 100 -DecisionTimestamp 101 -ExpectedCount 2
if ($lateAdmission.acceptable -or $lateAdmission.lateResults[0] -ne 'scene' -or
    -not $lateAdmission.decisionLate) {
    throw 'A baseline completing across its admission deadline was accepted.'
}
$lateDecision = Test-CocBaselineAdmissionTiming -Timing $timelyTiming `
    -DueTimestamp 100 -DecisionTimestamp 101 -ExpectedCount 2
if ($lateDecision.acceptable -or -not $lateDecision.decisionLate) {
    throw 'A late final baseline admission decision was accepted.'
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
    $invalidProtocolRaw = '{"schema":"unrelated-protocol"}'
    $invalidProtocolBytes = [Text.Encoding]::UTF8.GetBytes($invalidProtocolRaw)
    [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-state-v1'
        outcome = 'scenario-accepted'
        endpoint = 'http://127.0.0.1:8921/mcp'
        ownerId = 'invalid-protocol-owner'
        expectedPid = $PID
        expectedProcessStartTimeUtc = $currentStart
        expectedBuildId = ('a' * 64)
        protocolConfigPath = $invalidProtocolPath
        protocolEncoding = 'utf8-base64'
        protocolSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($invalidProtocolBytes)
        ).ToLowerInvariant()
        protocolBytes = [Convert]::ToBase64String($invalidProtocolBytes)
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
        baseline = [pscustomobject]@{ state = [pscustomobject]@{ ok = $true } }
        baselineVerdict = [pscustomobject]@{ acceptable = $true }
        baselineTiming = [pscustomobject]@{ state = [pscustomobject]@{ completedTimestamp = 1 } }
        fixtureFailure = [pscustomobject]@{ effect = 'unknown'; error = 'fixture dispatch rejection' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rejectedStatePath -Encoding utf8
    $rejectedStatus = & $scriptPath status -StatePath $rejectedStatePath `
        -Compact -NoExit | ConvertFrom-Json -Depth 30
    if ($rejectedStatus.ok -or $rejectedStatus.state -ne 'failed' -or
        $null -ne $rejectedStatus.data.scenarioRunId -or
        $rejectedStatus.errors[0] -ne 'fixture dispatch rejection' -or
        $rejectedStatus.data.dispatchFailure.error -ne 'fixture dispatch rejection' -or
        -not $rejectedStatus.data.baselineVerdict.acceptable -or
        $rejectedStatus.data.fixtureFailure.effect -ne 'unknown' -or
        $null -eq $rejectedStatus.data.baselineTiming.state) {
        throw 'Rejected scenario status did not preserve the terminal dispatch failure.'
    }
}
finally {
    if (Test-Path -LiteralPath $rejectedFixture) {
        Remove-Item -LiteralPath $rejectedFixture -Recurse -Force
    }
}

# Exercise the actual run coordinator with controlled module and evidence-controller
# dependencies. The production coordinator source is copied byte-for-byte; only
# its external tool provider is replaced in the isolated fixture module.
$coordinatorFixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-stability-coordinator-' + [Guid]::NewGuid().ToString('N')
)
$fixtureMarker = Join-Path $coordinatorFixture 'prepare-called.txt'
$scenarioMarker = Join-Path $coordinatorFixture 'scenario-called.txt'
$environmentNames = @(
    'CSX_COC_TEST_STATE', 'CSX_COC_TEST_SCENE', 'CSX_COC_TEST_UPSCALING',
    'CSX_COC_TEST_RENDERSCALE', 'CSX_COC_TEST_IMAGE',
    'CSX_COC_TEST_FIXTURE_MARKER', 'CSX_COC_TEST_SCENARIO_MARKER',
    'CSX_COC_TEST_PID', 'CSX_COC_TEST_START'
)
$priorEnvironment = @{}
foreach ($name in $environmentNames) { $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $fixtureToolRoot = Join-Path $coordinatorFixture 'tools'
    $fixtureCocRoot = Join-Path $fixtureToolRoot 'coc-stability-control'
    $fixtureDevBenchRoot = Join-Path $fixtureToolRoot 'devbench-control'
    $fixtureEvidenceRoot = Join-Path $fixtureToolRoot 'coc-evidence-control'
    New-Item -ItemType Directory -Path $fixtureCocRoot, $fixtureDevBenchRoot, $fixtureEvidenceRoot -Force | Out-Null
    Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $fixtureCocRoot 'Invoke-CocStabilityControl.ps1')
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $fixtureCocRoot 'protocol.v1.json')
    Copy-Item -LiteralPath $modulePath -Destination (Join-Path $fixtureCocRoot 'CocStabilityControl.psm1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\devbench-control\DevBenchControl.psm1') `
        -Destination (Join-Path $fixtureDevBenchRoot 'DevBenchControl.psm1')

    $fixtureModulePath = Join-Path $fixtureCocRoot 'CocStabilityControl.psm1'
    $fixtureModuleSource = [IO.File]::ReadAllText($fixtureModulePath)
    $fixtureModuleTokens = $null
    $fixtureModuleErrors = $null
    $fixtureModuleAst = [Management.Automation.Language.Parser]::ParseInput(
        $fixtureModuleSource, [ref]$fixtureModuleTokens, [ref]$fixtureModuleErrors
    )
    $fixtureInvokeAst = $fixtureModuleAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-CocMcpTool'
        }, $true)
    if ($fixtureModuleErrors.Count -ne 0 -or $null -eq $fixtureInvokeAst) {
        throw 'Could not create the controlled coordinator module fixture.'
    }
    $stubInvoke = @'
function Invoke-CocMcpTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [int]$TimeoutSeconds = 20,
        [int]$ExpectedProcessId,
        [string]$ExpectedProcessStartTimeUtc,
        [string]$ExpectedBuildId
    )
    $decode = {
        param([string]$Name)
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
            [Environment]::GetEnvironmentVariable($Name)
        )) | ConvertFrom-Json -Depth 100
    }
    $value = if ($Tool -eq 'inspect' -and [string]$Arguments.kind -eq 'state') {
        & $decode 'CSX_COC_TEST_STATE'
    } elseif ($Tool -eq 'inspect' -and [string]$Arguments.kind -eq 'scene') {
        & $decode 'CSX_COC_TEST_SCENE'
    } elseif ($Tool -eq 'communityshaders.upscaling_api') {
        & $decode 'CSX_COC_TEST_UPSCALING'
    } elseif ($Tool -eq 'communityshaders.renderscale') {
        & $decode 'CSX_COC_TEST_RENDERSCALE'
    } elseif ($Tool -eq 'communityshaders.screenshot') {
        & $decode 'CSX_COC_TEST_IMAGE'
    } elseif ($Tool -eq 'communityshaders.menu') {
        [IO.File]::WriteAllText([Environment]::GetEnvironmentVariable('CSX_COC_TEST_FIXTURE_MARKER'), 'called')
        throw 'synthetic prepare_coc failure'
    } elseif ($Tool -eq 'scenario') {
        [IO.File]::WriteAllText([Environment]::GetEnvironmentVariable('CSX_COC_TEST_SCENARIO_MARKER'), 'called')
        [pscustomobject]@{ accepted = $true; runId = 99 }
    } else {
        throw "Unexpected controlled tool call: $Tool"
    }
    return [pscustomobject][ordered]@{
        tool = $Tool; sessionId = 'controlled-test'; content = @($value)
        value = $value; rawResult = [pscustomobject]@{ content = @($value) }
    }
}
'@
    $fixtureModuleSource = $fixtureModuleSource.Substring(0, $fixtureInvokeAst.Extent.StartOffset) +
        $stubInvoke + $fixtureModuleSource.Substring($fixtureInvokeAst.Extent.EndOffset)
    [IO.File]::WriteAllText($fixtureModulePath, $fixtureModuleSource, [Text.UTF8Encoding]::new($false))

    $evidenceStub = @'
param([string]$Command, [string]$StatePath, [switch]$Compact, [switch]$NoExit)
[pscustomobject][ordered]@{
    ok = $true; state = 'armed-attached'; errors = @()
    data = [pscustomobject][ordered]@{
        targetPids = @([int][Environment]::GetEnvironmentVariable('CSX_COC_TEST_PID'))
        targetStartedUtc = [Environment]::GetEnvironmentVariable('CSX_COC_TEST_START')
    }
} | ConvertTo-Json -Depth 10 -Compress
'@
    [IO.File]::WriteAllText(
        (Join-Path $fixtureEvidenceRoot 'Invoke-CocEvidenceControl.ps1'),
        $evidenceStub,
        [Text.UTF8Encoding]::new($false)
    )

    $devBenchTestPath = Join-Path $PSScriptRoot '..\devbench-control\Test-DevBenchControl.ps1'
    $devBenchTokens = $null
    $devBenchErrors = $null
    $devBenchAst = [Management.Automation.Language.Parser]::ParseFile(
        $devBenchTestPath, [ref]$devBenchTokens, [ref]$devBenchErrors
    )
    foreach ($helperName in @('New-TestUpscalingProfile', 'New-TestRenderScaleStatus')) {
        $helperAst = $devBenchAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $helperName
            }, $true)
        if ($null -eq $helperAst) { throw "Controlled coordinator fixture lacks $helperName." }
        Invoke-Expression $helperAst.ToString()
    }
    $renderProfile = New-TestUpscalingProfile
    $renderSnapshot = [pscustomobject]@{
        stateRevision = 12; profilePresence = 27; flags = 57; activeOperationId = 0
        transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
        renderScaleStatus = [pscustomobject]@{ name = 'active'; value = 5 }
        observedConditions = [pscustomobject]@{ names = @() }
        profiles = [pscustomobject]@{ requested = $renderProfile; effective = $renderProfile; stable = $renderProfile }
        dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2096; renderEyeHeight = 2328 }
    }
    $renderStatus = New-TestRenderScaleStatus
    $renderStatus | Add-Member -NotePropertyName session -NotePropertyValue ([pscustomobject]@{ active = $false }) -Force
    $renderStatus | Add-Member -NotePropertyName cpuPerformance -NotePropertyValue ([pscustomobject]@{ active = $false }) -Force
    $renderStatus | Add-Member -NotePropertyName gpuPerformance -NotePropertyValue ([pscustomobject]@{ active = $false }) -Force
    $payloads = @{
        CSX_COC_TEST_STATE = [pscustomobject]@{ playerLoaded = $true }
        CSX_COC_TEST_SCENE = [pscustomobject]@{ cell = 'WindhelmExterior01' }
        CSX_COC_TEST_UPSCALING = $renderSnapshot
        CSX_COC_TEST_RENDERSCALE = [pscustomobject]@{ status = $renderStatus }
        CSX_COC_TEST_IMAGE = [pscustomobject]@{ requestId = 'controlled-baseline-image' }
    }
    foreach ($entry in $payloads.GetEnumerator()) {
        $json = $entry.Value | ConvertTo-Json -Depth 100 -Compress
        [Environment]::SetEnvironmentVariable($entry.Key, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    }
    [Environment]::SetEnvironmentVariable('CSX_COC_TEST_FIXTURE_MARKER', $fixtureMarker)
    [Environment]::SetEnvironmentVariable('CSX_COC_TEST_SCENARIO_MARKER', $scenarioMarker)
    $expectedCollectorStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    [Environment]::SetEnvironmentVariable('CSX_COC_TEST_PID', [string]$PID)
    [Environment]::SetEnvironmentVariable('CSX_COC_TEST_START', $expectedCollectorStart)

    $controlledController = Join-Path $fixtureCocRoot 'Invoke-CocStabilityControl.ps1'
    $controlledEvidenceTool = Join-Path $fixtureEvidenceRoot 'Invoke-CocEvidenceControl.ps1'
    $collectorProbe = & $controlledEvidenceTool status -StatePath (Join-Path $coordinatorFixture 'collector.json') -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    $probeTargets = @($collectorProbe.data.targetPids)
    $probeStart = if ($collectorProbe.data.targetStartedUtc -is [DateTime]) {
        $collectorProbe.data.targetStartedUtc.ToUniversalTime().ToString('o')
    } else { [string]$collectorProbe.data.targetStartedUtc }
    if (-not [bool]$collectorProbe.ok -or $probeTargets.Count -ne 1 -or
        [int]$probeTargets[0] -ne $PID -or $probeStart -cne $expectedCollectorStart) {
        throw "Controlled evidence stub mismatch: ok=$([bool]$collectorProbe.ok) count=$($probeTargets.Count) pid=$([int]$probeTargets[0]) expectedPid=$PID start=<$probeStart> expectedStart=<$expectedCollectorStart>."
    }
    $controlledEvidence = Join-Path $coordinatorFixture 'prepare-failure-evidence'
    New-Item -ItemType Directory -Path $controlledEvidence | Out-Null
    $controlledResult = & $controlledController run -ExpectedPid $PID -ExpectedBuildId ('a' * 64) `
        -CollectorStatePath (Join-Path $coordinatorFixture 'collector.json') -EvidenceRoot $controlledEvidence `
        -BaselineDeadlineMs 10000 -Compact -NoExit | ConvertFrom-Json -Depth 100
    if ([string]::IsNullOrWhiteSpace([string]$controlledResult.data.statePath)) {
        throw "Controlled prepare_coc run produced no state path: $($controlledResult | ConvertTo-Json -Depth 30 -Compress)"
    }
    $controlledState = Get-Content -LiteralPath $controlledResult.data.statePath -Raw | ConvertFrom-Json -Depth 100
    if ($controlledResult.ok -or $controlledResult.state -ne 'blocked-awaiting-user' -or
        $controlledState.outcome -ne 'fixture-call-failed' -or
        $controlledState.fixtureFailure.error -ne 'synthetic prepare_coc failure' -or
        @($controlledState.baseline.PSObject.Properties).Count -ne 5 -or
        -not (Test-Path -LiteralPath $fixtureMarker -PathType Leaf) -or
        (Test-Path -LiteralPath $scenarioMarker -PathType Leaf)) {
        throw 'The actual coordinator did not terminalize a prepare_coc exception with retained baseline and zero scenario submission.'
    }

    [IO.File]::Delete($fixtureMarker)
    $nullSceneJson = 'null'
    [Environment]::SetEnvironmentVariable('CSX_COC_TEST_SCENE', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nullSceneJson)))
    $nullEvidence = Join-Path $coordinatorFixture 'null-scene-evidence'
    New-Item -ItemType Directory -Path $nullEvidence | Out-Null
    $nullResult = & $controlledController run -ExpectedPid $PID -ExpectedBuildId ('a' * 64) `
        -CollectorStatePath (Join-Path $coordinatorFixture 'collector.json') -EvidenceRoot $nullEvidence `
        -BaselineDeadlineMs 10000 -Compact -NoExit | ConvertFrom-Json -Depth 100
    if ([string]::IsNullOrWhiteSpace([string]$nullResult.data.statePath)) {
        throw "Controlled null-scene run produced no state path: $($nullResult | ConvertTo-Json -Depth 30 -Compress)"
    }
    $nullState = Get-Content -LiteralPath $nullResult.data.statePath -Raw | ConvertFrom-Json -Depth 100
    if ($nullResult.ok -or $nullState.outcome -ne 'dispatch-interrupted' -or
        ($nullState.baselineVerdict.reasons -join ' | ') -notlike '*scene*missing or null*' -or
        (Test-Path -LiteralPath $fixtureMarker -PathType Leaf) -or
        (Test-Path -LiteralPath $scenarioMarker -PathType Leaf)) {
        throw 'The actual coordinator did not retain a null scene application value as a terminal pre-fixture rejection.'
    }
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name])
    }
    if (Test-Path -LiteralPath $coordinatorFixture -PathType Container) {
        Remove-Item -LiteralPath $coordinatorFixture -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $true
    exactTransitions = 20
    atomicPerformanceOrigin = $true
    failClosedBaselineDeadline = $true
    exactlyOnceDispatchClaim = $true
    missingBaselineFieldsRemainAnomalies = $true
    missingScenarioLabelsRemainAbsent = $true
} | ConvertTo-Json
