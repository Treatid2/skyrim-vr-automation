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
$inventoryDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory -DismissBlockingMenus @('InventoryMenu')
Assert-Test ($inventoryDismissal.permitted -and $inventoryDismissal.dismissMenus[0] -eq 'InventoryMenu') 'explicitly listed blocking menu permits bounded dismissal'
$unlistedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory
Assert-Test (-not $unlistedDismissal.permitted -and $unlistedDismissal.reason -eq 'unlisted-blocking-menu') 'menu dismissal remains opt-in'
$mixedMenus = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu', 'MapMenu'); messageBoxOpen = $false })
$mixedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $mixedMenus -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $mixedDismissal.permitted -and $mixedDismissal.retainedMenus[0] -eq 'MapMenu') 'unlisted blocking menus prevent partial dismissal'
$modalDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $modal -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $modalDismissal.permitted -and $modalDismissal.reason -eq 'message-box-requires-explicit-answer') 'message boxes are never auto-dismissed'

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
    profilePresence = 27; flags = 57; activeOperationId = 0
    transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
    renderScaleStatus = [pscustomobject]@{ name = 'active'; value = 5 }
    observedConditions = [pscustomobject]@{ names = @() }
    profiles = [pscustomobject]@{ requested = $renderProfile; effective = $renderProfile; stable = $renderProfile }
    dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2096; renderEyeHeight = 2328 }
}
$renderStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test ($renderStable.satisfied -and $renderStable.stereoEvidence -eq 'render_scale_fidelity') 'render-scale stability requires a latched coherent stereo contract'
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
$mismatchedProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeMismatchSnapshot = New-TestNativeSnapshot -RequestedProfile $mismatchedProfile -EffectiveProfile $nativeProfile -StableProfile $nativeFsrProfile -ProfilePresence 27
$nativeMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeMismatchSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test (-not $nativeMismatch.satisfied -and $nativeMismatch.reasons -contains 'requested and effective profiles differ') 'native-resolution stability rejects profile divergence'
$missingSnapshotFields = Test-DevBenchUpscalingStable -UpscalingSnapshot ([pscustomobject]@{}) -RenderScaleStatus ([pscustomobject]@{})
Assert-Test (-not $missingSnapshotFields.satisfied -and $missingSnapshotFields.reasons -contains 'render-scale controller telemetry is missing') 'missing optional snapshot fields fail closed without a strict-mode exception'

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
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$RequirePerformanceNeutral\) -and -not \$semantic\.known') 'required semantic outcomes reject unknown responses'
Assert-Test ($entryPointText -match 'ok = \[bool\]\$observation\.satisfied') 'wait semantics retain the observed unsatisfied condition'
Assert-Test ($entryPointText -match '\$Command -eq ''call'' -and -not \$runtimeIdentity\.complete') 'mutation-capable calls require complete runtime identity'
Assert-Test ($entryPointText -match 'if \(\$Command -eq ''call''\) \{[\s\S]{0,100}-not \$semantic\.known -or -not \$semantic\.ok') 'mutation-capable calls fail closed on unknown semantic outcomes'
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
Assert-Test ($entryPointText -match 'mcp-session-reinitialized') 'bounded waits reinitialize invalidated MCP sessions'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$Command -eq ''wait''\)') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match 'function Close-McpSession') 'entry point defines deterministic MCP session cleanup'
Assert-Test ($entryPointText -match '-Method Delete') 'owned MCP sessions are closed through the server lifecycle endpoint'
Assert-Test ($entryPointText -match "state = 'already_absent'") 'an already-retired MCP session is a successful cleanup'
Assert-Test ($entryPointText -match 'Close-McpSession -Endpoint \$endpoint -Headers \$sessionHeaders') 'partially opened MCP sessions are cleaned before rethrowing'
Assert-Test ($entryPointText -match 'Add-Member -NotePropertyName sessionCleanup') 'controller results preserve a structured session cleanup receipt'
Assert-Test ($entryPointText -match "clientInfo = @\{ name = 'DevBenchControl'; version = '1\.5' \}") 'MCP client identity records the timeout-envelope revision'
Assert-Test ($entryPointText -match '\[int\]\$RequestTimeoutSeconds = 15') 'controller exposes its default request timeout'
Assert-Test ($entryPointText -match '\$arguments\.ContainsKey\(''timeoutMs''\)') 'controller detects a server-owned timeout budget'
Assert-Test ($entryPointText -match 'Ceiling\(\$serverTimeoutMilliseconds / 1000\.0\)') 'controller converts the server budget without truncation'
Assert-Test ($entryPointText -match '\$serverTimeoutSeconds \+ 5') 'controller keeps a five-second receipt envelope beyond the server budget'
Assert-Test ($entryPointText -match 'function Invoke-ToolRpc[\s\S]{0,300}Invoke-McpRequest') 'tool calls use the shared deadline-bounded request path'
Assert-Test ($entryPointText -match 'requestTimeoutSeconds = \$script:requestTimeoutSecondsForRpc') 'receipts expose the effective request timeout'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "state = 'transport_retry'") 'serviceReady carries transient probe exhaustion into the outer wait'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match "phase = 'initialize'; recovery = 'outer-wait-retry'") 'wait initialization failures remain inside the outer timeout state machine'
Assert-Test ($entryPointText -match '\$null -eq \$headers') 'bounded waits establish or re-establish the MCP session inside the polling loop'
Assert-Test ($entryPointText -match '\[switch\]\$AcceptAlreadyLoaded') 'playerLoaded exposes an explicit compatibility opt-out for freshness'
Assert-Test ($entryPointText -match '\$playerTransitionObserved') 'playerLoaded requires an observed unloaded-to-loaded transition by default'
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
