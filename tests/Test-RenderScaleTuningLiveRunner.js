// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const runnerSource = fs.readFileSync(
    path.join(repositoryRoot, "tools", "renderscale-tuning-live", "runner.js"), "utf8");
const runRenderScaleTuningLive = new Function(
    `${runnerSource}\nreturn runRenderScaleTuningLive;`)();
const buildId = "a".repeat(64);

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function envelope(value) {
    return { content: [{ type: "text", text: JSON.stringify(value) }] };
}

function named(name, value = 0) {
    return { name, value };
}

function publicProfile(method = "dlss", qualityMode = "native_aa", renderScaleMode = false) {
    return {
        method: named(method),
        qualityMode: named(qualityMode),
        renderScaleMode,
        dlssProfile: named("K"),
        fsrRuntime: named("fsr3"),
    };
}

function initialBoundary() {
    const profile = publicProfile();
    return {
        revision: 1,
        profile: {
            method: profile.method.name,
            qualityMode: profile.qualityMode.name,
            renderScaleMode: profile.renderScaleMode,
            dlssProfile: profile.dlssProfile.name,
            fsrRuntime: profile.fsrRuntime.name,
        },
    };
}

function flatProfile(target) {
    return {
        method: target.method,
        qualityMode: {
            native_aa: 0,
            hoshipa: 1,
            ultra_quality: 2,
            quality: 3,
            balanced: 4,
            performance: 5,
            ultra_performance: 6,
        }[target.qualityMode],
        renderScaleMode: target.renderScaleMode,
        dlssProfile: target.dlssProfile,
        fsrRuntime: target.fsrRuntime,
    };
}

function createMock(semanticFailureOrdinal, receiptTransform = null,
    scenarioTransform = null) {
    let revision = 1;
    let stressSession = 0;
    let stressActive = false;
    let cpuActive = false;
    let gpuActive = false;
    let textureActive = false;
    let probeActive = false;
    let transitionOrdinal = 0;
    let traceSession = 0;
    let traceActive = false;
    let traceRecords = [];
    const scenarioCalls = [];
    const stores = new Map();
    const notifications = [];

    function traceSummary() {
        return {
            active: traceActive,
            sessionID: traceSession,
            totalRecords: traceRecords.length,
            setConstantsCalls: traceRecords.length > 0 ? 1 : 0,
            evaluateCalls: traceRecords.length > 0 ? 1 : 0,
        };
    }

    function toolResult(step) {
        const args = step.args || {};
        if (step.label === "baseline-stress-start" || step.label === "measured-stress-start") {
            stressSession += 1;
            stressActive = true;
            return { status: { session: { id: stressSession, active: true } } };
        }
        if (args.action === "stop") {
            stressActive = false;
            return { status: { session: { id: stressSession, active: false } } };
        }
        if (args.action === "texture_lifetime_start") textureActive = true;
        if (args.action === "texture_lifetime_stop") textureActive = false;
        if (args.action === "probe_start") probeActive = true;
        if (args.action === "probe_stop") probeActive = false;
        if (args.action === "cpu_performance_stop") cpuActive = false;
        if (args.action === "gpu_performance_stop") gpuActive = false;
        if (args.action === "dlss_trace_status") {
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_reset") {
            traceSession += 1;
            traceActive = false;
            traceRecords = [];
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_start") {
            traceActive = true;
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_stop") {
            traceActive = false;
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_read") {
            return {
                action: args.action,
                capture: {
                    summary: traceSummary(),
                    records: traceRecords,
                    afterSequence: args.afterSequence,
                    limit: args.limit,
                },
            };
        }
        if (args.action === "status") {
            return {
                status: {
                    session: { id: stressSession, active: stressActive },
                    loadPresentationProbe: { active: probeActive },
                },
            };
        }
        if (args.action === "cpu_performance_status") {
            return { cpuPerformance: { active: cpuActive, sessionId: cpuActive ? 11 : 0 } };
        }
        if (args.action === "gpu_performance_status") return { capture: { active: gpuActive } };
        if (args.action === "texture_lifetime_status") return { capture: { active: textureActive } };
        if (step.label === "profile-apply") return { apply: { disposition: { name: "queued" } } };
        return {};
    }

    async function scenario(args) {
        scenarioCalls.push(args);
        const applyStep = args.steps.find((step) => step.label === "profile-apply");
        const waitStep = args.steps.find((step) => step.label === "qualification-wait");
        const firstMeasured = args.steps.some((step) =>
            step.label === "qualification-dispatch" && step.args.startPerformanceTelemetry === true);
        if (firstMeasured) {
            cpuActive = true;
            gpuActive = true;
        }
        if (applyStep && !args.steps.some((step) => step.label === "baseline-stress-start")) {
            transitionOrdinal += 1;
        }
        const results = args.steps.map((step) => {
            if (step.wait !== undefined) return { kind: "wait", ms: step.wait };
            if (step.label !== "qualification-wait") {
                return { label: step.label, result: toolResult(step) };
            }
            revision += 1;
            const target = applyStep.args.target;
            const profile = flatProfile(target);
            const renderWidth = target.renderScaleMode ? 100 : 200;
            const renderHeight = target.renderScaleMode ? 100 : 200;
            const proofKind = target.method === "dlss" || target.method === "fsr" ?
                "exact_vendor_evaluation" : "exact_native_presentation";
            const exactProof = () => ({
                proven: true,
                kind: proofKind,
                frame: 14,
                qpcTick: 14,
                method: target.method,
                qualityMode: profile.qualityMode,
                renderScaleMode: target.renderScaleMode,
                requestId: 9,
                transitionEpoch: 9,
                contractGeneration: 9,
                providerRuntimeGeneration: 11,
                resourcePublicationGeneration: 101,
                resourceRevision: 41,
                deviceIdentity: 100,
                renderWidth,
                renderHeight,
                displayWidth: 200,
                displayHeight: 200,
                compositorCycleToken: 22,
            });
            const semanticFailure = semanticFailureOrdinal > 0 &&
                ((transitionOrdinal - 1) % 33) + 1 === semanticFailureOrdinal;
            if (traceActive && target.method === "dlss") {
                traceRecords = [
                    { sequence: 1, eye: "left", qualityMode: profile.qualityMode },
                    { sequence: 2, eye: "right", qualityMode: profile.qualityMode },
                ];
            }
            return {
                label: step.label,
                result: {
                    schemaRevision: 14,
                    action: "qualification_wait",
                    transitionId: waitStep.args.transitionId,
                    ownerId: waitStep.args.ownerId,
                    satisfied: !semanticFailure,
                    outcome: semanticFailure ? "timeout" : "stable",
                    timing: { elapsedMs: 1, dispatchTick: 10, stableTick: 11 },
                    frames: { dispatch: 10, stable: 11 },
                    milestoneTimings: { presentationElapsedMs: 1, cleanupElapsedMs: 1 },
                    replacementTimeline: {
                        mutationExpectation: "required",
                        mutationExpectationReason: "physical_relatch_plan",
                        dispatch: {
                            tick: 10,
                            frame: 10,
                            presentationProof: {
                                proven: true,
                                kind: "exact_vendor_evaluation",
                                contractGeneration: 8,
                                leftEye: {
                                    frame: 10, compositorCycleToken: 20,
                                    transitionEpoch: 8, method: "dlss",
                                    path: "VendorEvaluated", generation: 8,
                                    deviceIdentity: 100, resourceRevision: 40,
                                },
                                rightEye: {
                                    frame: 10, compositorCycleToken: 20,
                                    transitionEpoch: 8, method: "dlss",
                                    path: "VendorEvaluated", generation: 8,
                                    deviceIdentity: 100, resourceRevision: 40,
                                },
                            },
                        },
                        lastPreMutation: {
                            tick: 11,
                            frame: 11,
                            presentationProof: {
                                proven: true,
                                kind: "exact_vendor_evaluation",
                                contractGeneration: 8,
                            },
                        },
                        firstPhysicalMutation: {
                            tick: 12,
                            frame: 12,
                            stressSessionId: stressSession,
                            qualificationTransitionId: waitStep.args.transitionId,
                            ownershipToken: 1,
                            replacementRequestId: 9,
                            replacementTransitionEpoch: 9,
                            replacementContractGeneration: 9,
                            replacementDeviceIdentity: 100,
                            physicalMutationStarted: true,
                            physicalMutationSource: "provider_invalidation",
                            selectedPresentationDisposition: "PresentationStretch",
                        },
                        firstPostMutation: {
                            tick: 13,
                            frame: 13,
                            selectedPresentationDisposition: "PresentationStretch",
                        },
                        firstNewGenerationProven: {
                            tick: 14,
                            frame: 14,
                            stressSessionId: stressSession,
                            qualificationTransitionId: waitStep.args.transitionId,
                            ownershipToken: 1,
                            presentationProof: exactProof(),
                        },
                        terminal: {
                            tick: 15,
                            frame: 15,
                            presentationProof: exactProof(),
                        },
                        mutationNotRequiredTerminalProof: null,
                    },
                    presentationCycleAudit: {
                        evidenceComplete: true,
                        retentionOverflow: false,
                        ownerTransitionId: waitStep.args.transitionId,
                        ownerToken: 1,
                        eyeObservations: 2,
                        partialEyeObservations: 0,
                        incompleteStereoCycles: 0,
                        firstExactNewGenerationCycles: 1,
                        violations: {
                            preMutationExactPresentationSuppressed: 0,
                            preMutationStretchWithoutMutation: 0,
                            postMutationOldGenerationPresented: 0,
                            postMutationUnprovenStereoSubmitted: 0,
                        },
                    },
                    phaseDurations: {
                        dispatchToBlockedOrPreparationMs: 1,
                        blockedOrPreparationToFirstPhysicalMutationMs: 1,
                        firstPhysicalMutationToFirstNewGenerationMs: 2,
                        firstNewGenerationToCleanupDrainedMs: 1,
                        presentationToStrictCompletionMs: 0,
                    },
                    presentationStable: true,
                    cleanupDrained: true,
                    outstandingCleanupDebt: {
                        engineTargetRetirement: { pending: false, pendingReleaseCount: 0 },
                        intermediateRetirement: { pendingSets: 0 },
                    },
                    baseline: { stressSessionId: stressSession },
                    upscalingSnapshot: {
                        stateRevision: revision,
                        activeOperationId: 0,
                        requested: profile,
                        effective: profile,
                        stable: profile,
                    },
                    observation: {
                        facts: {
                            stressSession: true,
                            exactCell: true,
                            loadedInWorld: true,
                            apiOperationClear: true,
                            physicalMutationClear: true,
                            terminalClear: true,
                        },
                    },
                },
            };
        });
        if (receiptTransform) {
            for (const entry of results) {
                if (entry.label === "qualification-wait") {
                    entry.result = receiptTransform(entry.result, {
                        transitionOrdinal,
                        baseline: args.steps.some((step) =>
                            step.label === "baseline-stress-start"),
                    });
                }
            }
        }
        const root = {
            ok: true,
            aborted: false,
            stepsRun: args.steps.length,
            results,
        };
        return envelope(scenarioTransform ?
            scenarioTransform(root, args, { transitionOrdinal }) : root);
    }

    return {
        context: {
            tools: {
                mcp__devbench_vr__scenario: scenario,
                mcp__devbench_vr__communityshaders_renderscale: async () =>
                    envelope({ qualification: { active: false, lastEvidence: null } }),
            },
            store: (key, value) => stores.set(key, value),
            notify: (value) => notifications.push(value),
        },
        scenarioCalls,
        stores,
        notifications,
    };
}

function assertQualificationTimeouts(scenarioCalls, matrix, variant) {
    let baselineWaiters = 0;
    let measuredWaiters = 0;
    for (const call of scenarioCalls) {
        const waiter = call.steps.find((step) => step.label === "qualification-wait");
        if (!waiter) continue;
        if (call.steps.some((step) => step.label === "baseline-stress-start")) {
            baselineWaiters += 1;
            assert(waiter.args.timeoutMs === matrix.completionTimeoutMilliseconds,
                `${variant} baseline waiter no longer uses the matrix deadline.`);
        } else if (call.steps.some((step) => step.label === "profile-apply")) {
            measuredWaiters += 1;
            assert(waiter.args.timeoutMs === matrix.completionTimeoutMilliseconds,
                `${variant} measured waiter no longer uses the matrix deadline.`);
        }
    }
    assert(baselineWaiters > 0, `${variant} did not execute a baseline waiter.`);
    assert(measuredWaiters > 0, `${variant} did not execute a measured waiter.`);
}

async function testNvidia() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-nvidia", "references", "matrix.v1.json")));
    const mock = createMock(3);
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "nvidia",
        runId: "nvidia-test",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {},
        matrix,
    });
    assert(result.ok === true && result.status === "COMPLETE", "NVIDIA mock run did not complete.");
    assertQualificationTimeouts(mock.scenarioCalls, matrix, "NVIDIA");
    assert(result.lanes[0].passes.length === 2, "NVIDIA mock did not run two passes.");
    assert(result.lanes[0].passes.every((pass) => pass.rows.length === 33), "NVIDIA mock row count is wrong.");
    assert(mock.notifications.length === 66, "NVIDIA progress count is wrong.");
    assert(mock.notifications.filter((row) => row.satisfied === false).length === 2,
        "NVIDIA semantic failures did not continue through both passes.");
    assert(mock.notifications.every((row) => row.evidenceVerdict === "PASS"),
        `Complete NVIDIA Task 2 evidence was not classified PASS: ${JSON.stringify(mock.notifications[0])}`);
    assert(mock.notifications.every((row) => row.renderVerdict ===
        (row.satisfied ? "PASS" : "FAIL")),
    "Render and evidence verdicts were not kept separate.");
    assert(mock.notifications.every((row) => row.dispatch_ &&
        row.last_pre_mutation_ && row.first_physical_mutation_ &&
        row.first_post_mutation_ && row.first_new_generation_proven_ && row.terminal_),
    "NVIDIA timeline facets were not projected independently.");
    assert(mock.notifications.every((row) =>
        row.last_pre_mutation_.proof_contract_generation === 8 &&
        row.first_new_generation_proven_.proof_contract_generation === 9),
    "NVIDIA old/new generations were flattened across facets.");
    assert(mock.notifications.every((row) => row.cleanupDrained === true),
        "Structured cleanup debt was not projected from cleanupDrained.");
    assert(mock.notifications.filter((row) => row.satisfied === true).every((row) =>
        row.presentationStretchTerminalRecovery === true),
        "Recovered stretch was misclassified from structured cleanup debt.");
    assert(mock.notifications.filter((row) => row.satisfied === false).every((row) =>
        row.presentationStretchTerminalRecovery === false),
        "Failed stretch was incorrectly projected as recovered.");
    assert(mock.stores.has("nvidia-test:nvidia:pass-2:transition-33"),
        "NVIDIA terminal receipt was not retained.");
    const expectedTraceRows = matrix.transitions.filter((row) =>
        matrix.destinations[row.destination].method === "dlss").length * 2;
    const retainedTraceRows = [...mock.stores.entries()].filter(([key, value]) =>
        key.includes(":transition-") && value.traceRead);
    assert(retainedTraceRows.length === expectedTraceRows,
        "NVIDIA per-row trace evidence count is wrong.");
    const tracedScenarios = mock.scenarioCalls.filter((call) =>
        call.steps.some((step) => step.label === "dlss-trace-read"));
    assert(tracedScenarios.length === expectedTraceRows,
        "NVIDIA bounded trace reads were not executed per DLSS row.");
    for (const call of tracedScenarios) {
        const tail = call.steps.slice(-2);
        assert(tail[0].label === "dlss-trace-stop" &&
            tail[1].label === "dlss-trace-read" &&
            tail[1].args.limit === matrix.traceReadLimit,
        "NVIDIA trace stop/read ordering or bound is wrong.");
    }
    for (const [, retained] of retainedTraceRows) {
        assert(retained.traceReset.action === "dlss_trace_reset",
            "NVIDIA trace reset receipt was not retained.");
        assert(retained.traceStart.action === "dlss_trace_start",
            "NVIDIA trace start receipt was not retained.");
        assert(retained.traceStop.action === "dlss_trace_stop",
            "NVIDIA trace stop receipt was not retained.");
        assert(retained.traceRead.action === "dlss_trace_read" &&
            retained.traceRead.capture.records.length === 2,
            "NVIDIA raw trace window was not retained.");
    }
}

async function testAmd() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-amd", "references", "matrix.v1.json")));
    const mock = createMock(0);
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "amd",
        runId: "amd-test",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {
            supportedFSRRuntimeMask: 1,
            fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: 1 }],
        },
        matrix,
    });
    assert(result.ok === true && result.status === "COMPLETE", "AMD mock run did not complete.");
    assertQualificationTimeouts(mock.scenarioCalls, matrix, "AMD");
    const fsr3 = result.lanes.find((lane) => lane.id === "explicit_fsr3");
    const fallback = result.lanes.find((lane) => lane.id === "fsr4_to_fsr3_fallback");
    assert(fsr3 && fsr3.passes.length === 2, "AMD FSR3 lane did not run two passes.");
    assert(fallback && fallback.passes.length === 2, "AMD fallback lane did not run two passes.");
    assert(fsr3.passes.every((pass) => pass.rows.length === 31), "AMD mock row count is wrong.");
    assert(fallback.passes.every((pass) => pass.rows.length === 31), "AMD fallback row count is wrong.");
    assert(mock.notifications.length === 124, "AMD progress count is wrong.");
    assert(mock.notifications.every((row) => row.evidenceVerdict === "PASS" &&
        row.dispatch_ && row.first_new_generation_proven_),
    "AMD did not receive the shared Task 2 evidence projection.");
    const capabilityEnvelope = mock.stores.get("amd-test:amd:dlss-trace-capability");
    assert(capabilityEnvelope, "AMD DLSS trace capability lifecycle was not retained.");
    const capability = JSON.parse(capabilityEnvelope.content[0].text);
    const capabilityResults = new Map(capability.results.map((entry) =>
        [entry.label, entry.result]));
    assert(capabilityResults.get("amd-dlss-trace-reset").action === "dlss_trace_reset",
        "AMD trace reset receipt was not retained.");
    assert(capabilityResults.get("amd-dlss-trace-start").action === "dlss_trace_start",
        "AMD trace start receipt was not retained.");
    assert(capabilityResults.get("amd-dlss-trace-stop").action === "dlss_trace_stop",
        "AMD trace stop receipt was not retained.");
    const capabilityRead = capabilityResults.get("amd-dlss-trace-read");
    assert(capabilityRead.action === "dlss_trace_read" &&
        capabilityRead.capture.records.length === 0 &&
        capabilityRead.capture.limit === matrix.traceReadLimit,
        "AMD capability trace raw window is not empty.");
    const amdTransitionTrace = mock.scenarioCalls.some((call) =>
        call.steps.some((step) => step.label === "dlss-trace-start"));
    assert(amdTransitionTrace === false, "AMD matrix started a per-row DLSS trace.");
}

async function testScenarioFailureRetention() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-nvidia", "references",
        "matrix.v1.json")));
    let injected = false;
    const mock = createMock(0, null, (root, args, state) => {
        if (injected || !args.steps.some((step) =>
            step.label === "profiler-clear-history") ||
            args.steps.some((step) => step.label === "baseline-stress-start") ||
            state.transitionOrdinal !== matrix.transitions.length + 1) {
            return root;
        }
        injected = true;
        const results = root.results.slice(0, 3);
        results[2] = {
            label: "profiler-clear-history",
            ok: false,
            error: "synthetic_profiler_failure",
            result: { ok: false, error: "synthetic_profiler_failure" },
        };
        return { ...root, ok: false, aborted: true, stepsRun: 3, results };
    });
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "nvidia",
        runId: "scenario-failure",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {},
        matrix,
    });
    assert(result.ok === false && result.status === "INTERRUPTED",
        "A failed scenario did not interrupt the live assay.");
    assert(result.lanes[0].passes[0].status === "COMPLETE" &&
        result.lanes[0].passes[0].rows.length === 33,
    "A completed pass was discarded by a later interruption.");
    const pass = result.lanes[0].passes[1];
    assert(pass.error === "transition_scenario_failed" && pass.failure &&
        pass.failure.failedStep === "profiler-clear-history" &&
        pass.failure.reportedError === "synthetic_profiler_failure" &&
        pass.failure.firstUnreportedStep === "qualification-dispatch",
    "The compact live failure omitted the producer-reported step or boundary.");
    const receiptKey =
        "scenario-failure:nvidia:pass-2:transition-1:scenario";
    const rawEnvelope = mock.stores.get(receiptKey);
    assert(rawEnvelope, "The exact failed scenario envelope was not retained.");
    const raw = JSON.parse(rawEnvelope.content[0].text);
    assert(raw.ok === false && raw.results[2].error ===
        "synthetic_profiler_failure",
    "The retained failed scenario envelope was rewritten.");
    const retained = mock.stores.get(
        "scenario-failure:nvidia:pass-2:transition-1");
    assert(retained.scenarioReceiptKey === receiptKey &&
        retained.scenario.failedStep === "profiler-clear-history",
    "The compact transition receipt is not linked to its exact scenario evidence.");
    assert(result.receiptKeys.includes(receiptKey) &&
        result.receiptKeys.includes(
            "scenario-failure:nvidia:pass-2:transition-1") &&
        result.receiptKeys.includes("scenario-failure:live-result"),
    "The interruption result omitted receipt keys needed for materialization.");
}

async function testInformationalReasonIsNotFailure() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-nvidia", "references",
        "matrix.v1.json")));
    let injected = false;
    const mock = createMock(0, null, (root, args, state) => {
        if (injected || state.transitionOrdinal !== 1) return root;
        const index = args.steps.findIndex((step) =>
            step.label === "profiler-clear-history");
        if (index < 0) return root;
        injected = true;
        root.results[index].result.reason = "history_already_empty";
        return root;
    });
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "nvidia",
        runId: "informational-reason",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {},
        matrix,
    });
    assert(result.ok === true && result.status === "COMPLETE",
        "A successful informational reason interrupted the assay.");
    const retained = mock.stores.get(
        "informational-reason:nvidia:pass-1:transition-1");
    const step = retained.scenario.reportedSteps.find((entry) =>
        entry.label === "profiler-clear-history");
    assert(step && step.failed === false && step.error === null &&
        retained.scenario.failedStep === null,
    "An informational reason fabricated a failed step.");
}

async function runNvidiaProjectionTransform(receiptTransform) {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-nvidia", "references", "matrix.v1.json")));
    const mock = createMock(0, receiptTransform);
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "nvidia",
        runId: `projection-${Date.now()}`,
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {},
        matrix,
    });
    assert(result.ok === true, "Projection test run did not complete.");
    return mock.notifications;
}

async function testEvidenceVerdicts() {
    const cancelledBeforeDispatch = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.replacementTimeline.dispatch = null;
                receipt.presentationCycleAudit.ownerTransitionId = 0;
                receipt.presentationCycleAudit.ownerToken = 0;
                receipt.presentationCycleAudit.eyeObservations = 0;
                receipt.presentationCycleAudit.evidenceComplete = true;
            }
            return receipt;
        });
    assert(cancelledBeforeDispatch.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.auditStorageComplete === true &&
        row.ownerCorrelatedAuditObserved === false &&
        row.transitionEvidenceComplete === false &&
        row.missingEvidence.includes("dispatch") &&
        row.missingEvidence.includes("authoritative_cycle_owner") &&
        row.missingEvidence.includes("authoritative_cycle_observations")),
    "Storage completeness was misreported as complete transition evidence.");

    const schema13 = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) receipt.schemaRevision = 13;
        return receipt;
    });
    assert(schema13.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.transitionEvidenceComplete === false &&
        row.missingEvidence.includes("authoritative_violation_schema")),
    "Pre-schema-14 counters were treated as current authoritative evidence.");

    const unpublishedBoundaryGeneration = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.replacementTimeline.firstPhysicalMutation
                    .replacementContractGeneration = 0;
            }
            return receipt;
        });
    assert(unpublishedBoundaryGeneration.every((row) =>
        row.evidenceVerdict === "PASS" &&
        !row.producerInvalidEvidence.includes(
            "physical_mutation_boundary_owner_mismatch") &&
        !row.producerInvalidEvidence.includes(
            "first_new_generation_owner_mismatch")),
    "An unpublished boundary generation did not correlate with its later proof.");

    const fixedNativeGenerationZero = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline &&
                receipt.upscalingSnapshot.stable.renderScaleMode === false) {
                receipt.replacementTimeline.firstPhysicalMutation
                    .replacementContractGeneration = 0;
                receipt.replacementTimeline.firstNewGenerationProven
                    .presentationProof.contractGeneration = 0;
                receipt.replacementTimeline.firstNewGenerationProven
                    .presentationProof.providerRuntimeGeneration = 0;
            }
            return receipt;
        });
    const fixedNativeRows = fixedNativeGenerationZero.filter((row) =>
        row.target.renderScaleMode === false);
    assert(fixedNativeRows.length > 0 && fixedNativeRows.every((row) =>
        row.evidenceVerdict === "PASS" &&
        row.producerInvalidEvidence.length === 0),
    "A fixed native target rejected its valid zero generation proof.");

    const scaledGenerationZero = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline &&
                receipt.upscalingSnapshot.stable.renderScaleMode === true) {
                receipt.replacementTimeline.firstPhysicalMutation
                    .replacementContractGeneration = 0;
                receipt.replacementTimeline.firstNewGenerationProven
                    .presentationProof.contractGeneration = 0;
            }
            return receipt;
        });
    const scaledRows = scaledGenerationZero.filter((row) =>
        row.target.renderScaleMode === true);
    assert(scaledRows.length > 0 && scaledRows.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.producerInvalidEvidence.includes(
            "first_new_generation_target_mismatch")),
    "A scaled target accepted a zero contract generation.");

    const publishedBoundaryGenerationMismatch = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.replacementTimeline.firstPhysicalMutation
                    .replacementContractGeneration = 8;
            }
            return receipt;
        });
    assert(publishedBoundaryGenerationMismatch.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.producerInvalidEvidence.includes(
            "first_new_generation_owner_mismatch")),
    "A published boundary generation mismatch was accepted.");

    const missingMutation = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) delete receipt.replacementTimeline.firstPhysicalMutation;
        return receipt;
    });
    assert(missingMutation.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.missingEvidence.includes("missing_required_mutation_boundary") &&
        row.first_physical_mutation_ === "not_exposed"),
    "Missing required mutation evidence was not INCONCLUSIVE.");

    const missingBoundaryWithCounters = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                delete receipt.replacementTimeline.firstPhysicalMutation;
                receipt.presentationCycleAudit.violations
                    .preMutationStretchWithoutMutation = 1;
                receipt.presentationCycleAudit.violations
                    .postMutationOldGenerationPresented = 1;
            }
            return receipt;
        });
    assert(missingBoundaryWithCounters.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.phaseCountersAuthoritative === false &&
        row.genuineInvariantViolations.length === 0),
    "Phase counters without a required boundary produced a false failure.");

    const notRequired = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.mutationExpectation = "not_required";
            receipt.replacementTimeline.mutationExpectationReason = "compatible_contract_reuse";
            delete receipt.replacementTimeline.firstPhysicalMutation;
            delete receipt.replacementTimeline.firstPostMutation;
            delete receipt.replacementTimeline.firstNewGenerationProven;
            receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof = {
                ...receipt.replacementTimeline.terminal,
            };
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.stressSessionId =
                receipt.baseline.stressSessionId;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.qualificationTransitionId =
                receipt.transitionId;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.ownershipToken =
                receipt.presentationCycleAudit.ownerToken;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementRequestId = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementTransitionEpoch = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementContractGeneration = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementDeviceIdentity = 100;
        }
        return receipt;
    });
    assert(notRequired.every((row) => row.evidenceVerdict === "PASS" &&
        row.mutationExpectation === "not_required" &&
        row.mutationNotRequiredProven === true &&
        row.first_physical_mutation_ === "not_required"),
    "Explicit mutation not_required was not accepted.");

    const nativeNotRequiredGenerationZero = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline &&
                receipt.upscalingSnapshot.stable.renderScaleMode === false) {
                receipt.replacementTimeline.mutationExpectation = "not_required";
                receipt.replacementTimeline.mutationExpectationReason =
                    "native_contract_reuse";
                delete receipt.replacementTimeline.firstPhysicalMutation;
                delete receipt.replacementTimeline.firstPostMutation;
                delete receipt.replacementTimeline.firstNewGenerationProven;
                receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
                receipt.replacementTimeline.terminal.presentationProof.contractGeneration = 0;
                receipt.replacementTimeline.terminal.presentationProof
                    .providerRuntimeGeneration = 0;
                receipt.replacementTimeline.mutationNotRequiredTerminalProof = {
                    ...receipt.replacementTimeline.terminal,
                    stressSessionId: receipt.baseline.stressSessionId,
                    qualificationTransitionId: receipt.transitionId,
                    ownershipToken: receipt.presentationCycleAudit.ownerToken,
                    replacementRequestId: 9,
                    replacementTransitionEpoch: 9,
                    replacementContractGeneration: 0,
                    replacementDeviceIdentity: 100,
                };
            }
            return receipt;
        });
    const nativeNotRequiredRows = nativeNotRequiredGenerationZero.filter((row) =>
        row.target.renderScaleMode === false);
    assert(nativeNotRequiredRows.length > 0 && nativeNotRequiredRows.every((row) =>
        row.evidenceVerdict === "PASS" && row.mutationNotRequiredProven === true &&
        row.first_physical_mutation_ === "not_required"),
    "A native not_required receipt rejected its valid zero generation proof.");

    const notRequiredWithoutReason = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.mutationExpectation = "not_required";
            receipt.replacementTimeline.mutationExpectationReason = "replacement_not_observed";
            delete receipt.replacementTimeline.firstPhysicalMutation;
            delete receipt.replacementTimeline.firstNewGenerationProven;
            receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof = {
                ...receipt.replacementTimeline.terminal,
            };
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.stressSessionId =
                receipt.baseline.stressSessionId;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.qualificationTransitionId =
                receipt.transitionId;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.ownershipToken =
                receipt.presentationCycleAudit.ownerToken;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementRequestId = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementTransitionEpoch = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementContractGeneration = 9;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof.replacementDeviceIdentity = 100;
        }
        return receipt;
    });
    assert(notRequiredWithoutReason.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.missingEvidence.includes("mutation_not_required_reason") &&
        row.first_physical_mutation_ === "not_exposed"),
    "Mutation not_required without an explicit reason was accepted.");

    const notRequiredWithoutProof = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.mutationExpectation = "not_required";
            receipt.replacementTimeline.mutationExpectationReason =
                "native_contract_reuse";
            delete receipt.replacementTimeline.firstPhysicalMutation;
            delete receipt.replacementTimeline.firstNewGenerationProven;
            receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
            delete receipt.replacementTimeline.mutationNotRequiredTerminalProof;
        }
        return receipt;
    });
    assert(notRequiredWithoutProof.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.missingEvidence.includes("mutation_not_required_terminal_proof") &&
        row.first_physical_mutation_ === "not_exposed"),
    `Mutation not_required without exact terminal proof was accepted: ${JSON.stringify(notRequiredWithoutProof[0])}`);

    const notRequiredFromAnotherOwner = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.mutationExpectation = "not_required";
            receipt.replacementTimeline.mutationExpectationReason =
                "native_contract_reuse";
            delete receipt.replacementTimeline.firstPhysicalMutation;
            delete receipt.replacementTimeline.firstPostMutation;
            delete receipt.replacementTimeline.firstNewGenerationProven;
            receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
            receipt.replacementTimeline.mutationNotRequiredTerminalProof = {
                ...receipt.replacementTimeline.terminal,
                stressSessionId: receipt.baseline.stressSessionId,
                qualificationTransitionId: receipt.transitionId + 1,
                ownershipToken: receipt.presentationCycleAudit.ownerToken,
                replacementRequestId: 9,
                replacementTransitionEpoch: 9,
                replacementContractGeneration: 9,
                replacementDeviceIdentity: 100,
            };
        }
        return receipt;
    });
    assert(notRequiredFromAnotherOwner.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.missingEvidence.includes("mutation_not_required_terminal_proof") &&
        row.mutationNotRequiredProven === false),
    "A not_required proof from another transition was accepted.");

    const unknown = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.mutationExpectation = "unknown";
            receipt.replacementTimeline.mutationExpectationReason =
                "replacement_not_observed";
            delete receipt.replacementTimeline.firstPhysicalMutation;
            delete receipt.replacementTimeline.firstNewGenerationProven;
            receipt.presentationCycleAudit.firstExactNewGenerationCycles = 0;
        }
        return receipt;
    });
    assert(unknown.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.first_physical_mutation_ === "not_exposed"),
    "Unknown mutation expectation did not remain INCONCLUSIVE.");

    const violated = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.presentationCycleAudit.violations.postMutationOldGenerationPresented = 1;
            receipt.presentationCycleAudit.violations.firstPostMutationOldGenerationPresented = {
                frame: 13,
                qpcTick: 13,
                disposition: "exact_vendor_evaluation",
                submitted: true,
                exactCurrent: true,
            };
        }
        return receipt;
    });
    assert(violated.every((row) => row.evidenceVerdict === "FAIL" &&
        row.phaseCountersAuthoritative === true &&
        row.invariantViolations.postMutationOldGenerationPresented === 1 &&
        row.genuineInvariantViolations.includes("postMutationOldGenerationPresented")),
    "Exact Task 2 violation was not classified FAIL.");

    const unownedViolation = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.firstPhysicalMutation.ownershipToken = 2;
            receipt.presentationCycleAudit.violations
                .postMutationOldGenerationPresented = 1;
            receipt.presentationCycleAudit.violations
                .firstPostMutationOldGenerationPresented = {
                    frame: 13,
                    qpcTick: 13,
                    disposition: "exact_vendor_evaluation",
                    submitted: true,
                };
        }
        return receipt;
    });
    assert(unownedViolation.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.phaseCountersAuthoritative === false &&
        row.phaseCounterAuthorityStatus === "MISMATCHED" &&
        row.phaseCounterAuthorityReasons.includes(
            "boundary_audit_token_mismatch") &&
        row.reportedInvariantViolations.includes(
            "postMutationOldGenerationPresented") &&
        row.genuineInvariantViolations.length === 0 &&
        row.producerInvalidEvidence.includes(
            "physical_mutation_boundary_owner_mismatch")),
    "An unowned phase counter was promoted into a false pipeline failure.");

    const missingFirstOffender = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.presentationCycleAudit.violations
                    .preMutationStretchWithoutMutation = 1;
            }
            return receipt;
        });
    assert(missingFirstOffender.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.phaseCounterAuthorityStatus === "INCOMPLETE" &&
        row.phaseCountersAuthoritative === false &&
        row.reportedInvariantViolations.includes(
            "preMutationStretchWithoutMutation") &&
        row.violationAuthority.preMutationStretchWithoutMutation.status ===
            "INCOMPLETE" &&
        row.genuineInvariantViolations.length === 0 &&
        row.producerInvalidEvidence.includes(
            "preMutationStretchWithoutMutation_first_offender_missing")),
    "A counter without its first-offender receipt became false evidence.");

    const preBoundaryConflict = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.presentationCycleAudit.violations
                    .preMutationStretchWithoutMutation = 1;
                receipt.presentationCycleAudit.violations
                    .firstPreMutationStretchWithoutMutation = {
                        frame: 11,
                        qpcTick: 13,
                        disposition: "presentation_stretch",
                        submitted: true,
                    };
            }
            return receipt;
        });
    assert(preBoundaryConflict.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.phaseCounterAuthorityStatus === "MISMATCHED" &&
        row.violationAuthority.preMutationStretchWithoutMutation.status ===
            "MISMATCHED" &&
        row.producerInvalidEvidence.includes(
            "preMutationStretchWithoutMutation_temporal_order_conflict")),
    "Conflicting pre-mutation clocks produced a false pipeline failure.");

    const matchedAndIncomplete = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.presentationCycleAudit.violations
                    .postMutationOldGenerationPresented = 1;
                receipt.presentationCycleAudit.violations
                    .firstPostMutationOldGenerationPresented = {
                        frame: 13,
                        qpcTick: 13,
                        disposition: "exact_vendor_evaluation",
                        submitted: true,
                    };
                receipt.presentationCycleAudit.violations
                    .preMutationStretchWithoutMutation = 1;
            }
            return receipt;
        });
    assert(matchedAndIncomplete.every((row) =>
        row.evidenceVerdict === "FAIL" &&
        row.phaseCounterAuthorityStatus === "INCOMPLETE" &&
        row.violationAuthority.postMutationOldGenerationPresented.status ===
            "MATCHED" &&
        row.violationAuthority.preMutationStretchWithoutMutation.status ===
            "INCOMPLETE" &&
        row.genuineInvariantViolations.includes(
            "postMutationOldGenerationPresented")),
    "One incomplete counter erased a different exact pipeline violation.");

    const qpcBeforeBoundary = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.presentationCycleAudit.violations.postMutationUnprovenStereoSubmitted = 1;
            receipt.presentationCycleAudit.violations.firstPostMutationUnprovenStereoSubmitted = {
                frame: 13,
                qpcTick: 11,
                disposition: "presentation_stretch",
                submitted: true,
            };
        }
        return receipt;
    });
    assert(qpcBeforeBoundary.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.temporallyImpossibleViolations.includes(
            "postMutationUnprovenStereoSubmitted") &&
        row.producerInvalidEvidence.includes(
            "postMutationUnprovenStereoSubmitted_temporal_order_conflict") &&
        row.violationAuthority.postMutationUnprovenStereoSubmitted.status ===
            "MISMATCHED"),
    "An offender QPC before the boundary was treated as a runtime failure.");

    const sameFrameEarlierQpc = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.presentationCycleAudit.violations
                    .postMutationUnprovenStereoSubmitted = 1;
                receipt.presentationCycleAudit.violations
                    .firstPostMutationUnprovenStereoSubmitted = {
                        frame: 12,
                        qpcTick: 11,
                        disposition: "presentation_stretch",
                        submitted: true,
                    };
            }
            return receipt;
        });
    assert(sameFrameEarlierQpc.every((row) =>
        row.evidenceVerdict === "INCONCLUSIVE" &&
        row.temporallyImpossibleViolations.includes(
            "postMutationUnprovenStereoSubmitted") &&
        row.producerInvalidEvidence.includes(
            "postMutationUnprovenStereoSubmitted_precedes_boundary") &&
        !row.producerInvalidEvidence.includes(
            "postMutationUnprovenStereoSubmitted_temporal_order_conflict")),
    "Same-frame earlier QPC evidence was misclassified as a clock conflict.");

    const sameFrameEqualQpc = await runNvidiaProjectionTransform(
        (receipt, context) => {
            if (!context.baseline) {
                receipt.presentationCycleAudit.violations
                    .postMutationUnprovenStereoSubmitted = 1;
                receipt.presentationCycleAudit.violations
                    .firstPostMutationUnprovenStereoSubmitted = {
                        frame: 12,
                        qpcTick: 12,
                        disposition: "presentation_stretch",
                        submitted: true,
                    };
            }
            return receipt;
        });
    assert(sameFrameEqualQpc.every((row) =>
        row.evidenceVerdict === "FAIL" &&
        row.genuineInvariantViolations.includes(
            "postMutationUnprovenStereoSubmitted")),
    "Same-frame equal QPC evidence was not classified at-or-after mutation.");

    const frameBeforeBoundary = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.presentationCycleAudit.violations.postMutationOldGenerationPresented = 1;
            receipt.presentationCycleAudit.violations.firstPostMutationOldGenerationPresented = {
                frame: 11,
                qpcTick: 13,
                disposition: "exact_vendor_evaluation",
                submitted: true,
            };
        }
        return receipt;
    });
    assert(frameBeforeBoundary.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.temporallyImpossibleViolations.includes(
            "postMutationOldGenerationPresented") &&
        row.producerInvalidEvidence.includes(
            "postMutationOldGenerationPresented_temporal_order_conflict")),
    "An offender frame before the boundary was treated as a runtime failure.");

    const proofDisagreement = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            delete receipt.replacementTimeline.firstNewGenerationProven;
        }
        return receipt;
    });
    assert(proofDisagreement.every((row) => row.evidenceVerdict === "INCONCLUSIVE" &&
        row.producerInvalidEvidence.includes(
            "first_exact_new_generation_proof_missing")),
    "Audit/timeline replacement proof disagreement was not producer-invalid.");

    const unprotectedPostBoundaryStretch = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.presentationCycleAudit.violations.postMutationUnprovenStereoSubmitted = 1;
            receipt.presentationCycleAudit.violations.firstPostMutationUnprovenStereoSubmitted = {
                frame: 13,
                qpcTick: 13,
                disposition: "presentation_stretch",
                submitted: true,
                exactReplacement: false,
            };
        }
        return receipt;
    });
    assert(unprotectedPostBoundaryStretch.every((row) => row.evidenceVerdict === "FAIL" &&
        row.genuineInvariantViolations.includes(
            "postMutationUnprovenStereoSubmitted")),
    "An unprotected post-boundary PresentationStretch was downgraded.");

    const wrongOrigin = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.lastPreMutation.preparationAdmission = {
                status: "not_applicable", reasonMask: 2,
            };
            receipt.replacementTimeline.lastPreMutation.replacementMutationAdmission = {
                status: "admitted", blocked: false, reasonMask: 0,
            };
        }
        return receipt;
    });
    assert(wrongOrigin.every((row) =>
        row.last_pre_mutation_.preparation_status === "not_applicable" &&
        row.last_pre_mutation_.mutation_admission_blocked === false),
    "Wrong-origin preparation was conflated with mutation blocking.");

    const nativeProof = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.replacementTimeline.firstNewGenerationProven.presentationProof.kind =
                "exact_native_presentation";
        }
        return receipt;
    });
    assert(nativeProof.every((row) =>
        row.first_new_generation_proven_.proof_kind === "exact_native_presentation"),
    "Native presentation proof was not retained in its own facet.");

    const partialEye = await runNvidiaProjectionTransform((receipt, context) => {
        if (!context.baseline) {
            receipt.presentationCycleAudit.partialEyeObservations = 1;
            receipt.presentationCycleAudit.incompleteStereoCycles = 1;
        }
        return receipt;
    });
    assert(partialEye.every((row) => row.evidenceVerdict === "PASS" &&
        row.invariantViolations.postMutationUnprovenStereoSubmitted === 0),
    "A partial eye observation was treated as submitted mixed stereo.");
}

Promise.all([testNvidia(), testAmd(), testEvidenceVerdicts(),
    testScenarioFailureRetention(), testInformationalReasonIsNotFailure()]).then(() => {
    process.stdout.write("Render-scale tuning live runner tests passed.\n");
}).catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
});
