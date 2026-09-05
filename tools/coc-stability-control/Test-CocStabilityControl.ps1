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
    }) -ProtocolConfig $config
if (-not $analysis.available -or $analysis.transitions.Count -ne 20 -or
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
    $missingLabelAnalysis.transitions.Count -ne 20 -or
    @($missingLabelAnalysis.transitions | Where-Object receiptPresent).Count -ne 0) {
    throw 'Missing scenario labels did not remain absent receipt evidence.'
}

$moduleScript = Get-Content -LiteralPath $modulePath -Raw
foreach ($required in @(
    "Get-CocPropertyValue -Value `$scene -Name 'cell'",
    "Get-CocPropertyValue -Value `$cell -Name 'editorId'",
    "Get-CocPropertyValue -Value `$state -Name 'playerLoaded'",
    'ConvertTo-CocBoolean',
    'if ($matches.Count -eq 0) { return $null }'
)) {
    if (-not $moduleScript.Contains($required, [StringComparison]::Ordinal)) {
        throw "COC stability module is missing safe optional-field handling: $required"
    }
}

$script = Get-Content -LiteralPath $scriptPath -Raw
foreach ($required in @(
    '[Diagnostics.Stopwatch]::GetTimestamp()',
    '[IO.FileMode]::CreateNew',
    "'baseline-complete'",
    "'deadline'",
    "-Tool 'communityshaders.menu'",
    "-Tool 'scenario'",
    'Start-ThreadJob',
    'CollectorStatePath'
)) {
    if (-not $script.Contains($required, [StringComparison]::Ordinal)) {
        throw "COC stability controller is missing: $required"
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
