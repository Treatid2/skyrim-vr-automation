// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const {
    collectTracePages,
    deploymentVerification,
    finalizeEvidence,
} = require("../tools/renderscale-tuning-finalizer/finalizer.js");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function tracePage(buildId, sessionId, afterSequence, records, moreAvailable,
    maximum = 256) {
    const lastReturnedSequence = records.length > 0 ?
        records[records.length - 1].current.sequence : afterSequence;
    return {
        action: "dlss_trace_read",
        producer: { buildId },
        capture: {
            afterSequence,
            availableFromSequence: 1,
            lastReturnedSequence,
            latestSequence: 600,
            limit: maximum,
            moreAvailable,
            requestedSequenceOverwritten: false,
            records,
            summary: { sessionID: sessionId },
        },
    };
}

function records(first, count) {
    return Array.from({ length: count }, (_, index) => ({
        current: { sequence: first + index },
    }));
}

async function testBoundedPaging() {
    const buildId = "a".repeat(64);
    const source = records(1, 600);
    const calls = [];
    const result = await collectTracePages({
        expectedBuildId: buildId,
        expectedSessionId: 17,
        schema: { maximum: 256 },
        readPage: async (args) => {
            calls.push(args);
            const pageRecords = source.slice(args.afterSequence,
                args.afterSequence + args.limit);
            return tracePage(buildId, 17, args.afterSequence, pageRecords,
                args.afterSequence + pageRecords.length < source.length,
                args.limit);
        },
    });
    assert(calls.length === 3, "Trace records were not read in bounded pages.");
    assert(calls.every((call) => call.limit === 256),
        "The producer maximum was not respected.");
    assert(result.records.length === 600,
        "Paged trace collection omitted records.");
    assert(result.records.every((record, index) =>
        record.current.sequence === index + 1),
    "Paged trace collection reordered or duplicated records.");
}

async function expectPagingFailure(change, expectedError) {
    const buildId = "b".repeat(64);
    let call = 0;
    try {
        await collectTracePages({
            expectedBuildId: buildId,
            schema: { maximum: 256 },
            readPage: async (args) => {
                call += 1;
                const page = tracePage(buildId, 9, args.afterSequence,
                    call === 1 ? records(1, 256) : records(257, 4), call === 1);
                return change(page, call);
            },
        });
        throw new Error("Expected paging validation to fail.");
    } catch (error) {
        assert(error.message === expectedError,
            `Expected ${expectedError}, received ${error.message}.`);
    }
}

async function testPagingValidation() {
    await expectPagingFailure((page, call) => {
        if (call === 2) page.capture.records[0].current.sequence = 256;
        return page;
    }, "trace_sequence_duplicate");
    await expectPagingFailure((page, call) => {
        if (call === 2) page.capture.records[0].current.sequence = 258;
        return page;
    }, "trace_sequence_gap");
    await expectPagingFailure((page, call) => {
        if (call === 2) page.capture.requestedSequenceOverwritten = true;
        return page;
    }, "trace_requested_sequence_overwritten");
    await expectPagingFailure((page, call) => {
        if (call === 2) page.capture.summary.sessionID = 10;
        return page;
    }, "trace_session_changed");
    await expectPagingFailure((page, call) => {
        if (call === 2) page.producer.buildId = "c".repeat(64);
        return page;
    }, "trace_build_changed");
}

async function testPagingResume() {
    const buildId = "d".repeat(64);
    const first = tracePage(buildId, 22, 0, records(1, 256), true);
    const preserved = [];
    try {
        await collectTracePages({
            expectedBuildId: buildId,
            schema: { maximum: 256 },
            readPage: async () => ({ ...tracePage(buildId, 23, 256,
                records(257, 1), false) }),
            existingPages: [first],
            preservePage: async (page) => preserved.push(page),
        });
        throw new Error("Expected session validation to fail.");
    } catch (error) {
        assert(error.message === "trace_session_changed",
            "Unexpected resume validation error.");
    }
    assert(preserved.length === 1,
        "The rejected producer receipt was not preserved.");
    const resumed = await collectTracePages({
        expectedBuildId: buildId,
        schema: { maximum: 256 },
        existingPages: [first],
        readPage: async () => tracePage(buildId, 22, 256,
            records(257, 44), false),
    });
    assert(resumed.records.length === 300 &&
        resumed.records[299].current.sequence === 300,
    "Valid preserved pages could not resume after a validation error.");
}

function sha(file) {
    return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function retained(boundary, violation, identity = {}, nonStable = false) {
    const runId = identity.runId || "nvidia-test-run";
    const buildId = identity.buildId || "e".repeat(64);
    return {
        variant: identity.variant || (runId.startsWith("amd-") ? "amd" : "nvidia"),
        analysisSentinel: {
            falseValue: false,
            zeroValue: 0,
            nullValue: null,
            emptyArray: [],
            emptyObject: {},
            "slash/key~": "retained",
        },
        waiter: {
            schemaRevision: 14,
            transitionId: 101,
            satisfied: !nonStable,
            ownerId: `${runId}-owner`,
            baseline: { stressSessionId: 7 },
            producer: { buildId },
            presentationStable: !nonStable,
            cleanupDrained: !nonStable,
            milestoneTimings: {
                presentation: {
                    observed: !nonStable,
                    frame: nonStable ? 0 : 12,
                    elapsedMs: nonStable ? 0 : 2.5,
                },
            },
            target: { method: "none", qualityMode: 0, renderScaleMode: false },
            replacementTimeline: {
                mutationExpectation: "required",
                dispatch: {
                    tick: 100,
                    frame: 10,
                    presentationProof: {
                        proven: true,
                        kind: "exact_native_presentation",
                        leftEye: {
                            frame: 10,
                            qpcTick: 100,
                            transitionEpoch: 8,
                            generation: 8,
                            resourceRevision: 40,
                            method: "none",
                            backend: "none",
                            path: "NativeOriginal",
                        },
                        rightEye: {
                            frame: 10,
                            qpcTick: 100,
                            transitionEpoch: 8,
                            generation: 8,
                            resourceRevision: 40,
                            method: "none",
                            backend: "none",
                            path: "NativeOriginal",
                        },
                    },
                },
                ...(boundary ? { firstPhysicalMutation: {
                    tick: 110,
                    frame: 11,
                    physicalMutationStarted: true,
                    physicalMutationSource: "engine_target_creator",
                } } : { firstPhysicalMutation: null }),
                terminal: {
                    tick: 120,
                    frame: 12,
                    presentationProof: {
                        proven: true,
                        kind: "exact_native_presentation",
                        leftEye: {
                            frame: 12,
                            qpcTick: 120,
                            transitionEpoch: 9,
                            generation: 9,
                            resourceRevision: 41,
                            method: "none",
                            backend: "none",
                            path: "NativeOriginal",
                        },
                        rightEye: {
                            frame: 12,
                            qpcTick: 120,
                            transitionEpoch: 9,
                            generation: 9,
                            resourceRevision: 41,
                            method: "none",
                            backend: "none",
                            path: "NativeOriginal",
                        },
                    },
                },
            },
            upscalingSnapshot: {
                stateRevision: 8,
                stable: { method: "none", qualityMode: 0, renderScaleMode: false },
            },
            presentationCycleAudit: {
                evidenceComplete: true,
                retentionOverflow: false,
                ownerTransitionId: 101,
                ownerToken: 1,
                eyeObservations: 2,
                violations: {
                    preMutationExactPresentationSuppressed: 0,
                    preMutationStretchWithoutMutation: violation ? 1 : 0,
                    postMutationOldGenerationPresented: violation ? 1 : 0,
                    postMutationUnprovenStereoSubmitted: 0,
                },
            },
            diagnostics: {
                delta: {
                    presentation: {
                        maximumStretchFramesBaseline: 3,
                        maximumStretchFramesCurrent: 3,
                        stretchCompletedEpisodes: 1,
                        stretchCompletedFrames: 2,
                    },
                },
            },
        },
        projection: {
            renderVerdict: nonStable ? "FAIL" : "PASS",
            nonStableNote: nonStable ? {
                status: "not_stable",
                deadlineMilliseconds: 20000,
                outcome: "timeout",
                timedOutMilestone: "strict",
                presentationDisposition: "PresentationStretch",
                leftEyePath: "PresentationStretch",
                rightEyePath: "PresentationStretch",
                controllerState: "Stabilizing",
                presentationPhase: "awaiting_stereo",
                failureCodes: ["active:vendor_presentation_not_stable"],
            } : null,
            evidenceVerdict: violation ? "FAIL" : "PASS",
            task2Verdict: violation ? "FAIL" : "PASS",
            presentationStretchSelected: true,
            presentationStretchTerminalRecovery: !nonStable,
            missingEvidence: [],
            invariantViolations: {
                preMutationStretchWithoutMutation: violation ? 1 : 0,
                postMutationOldGenerationPresented: violation ? 1 : 0,
            },
            genuineInvariantViolations: violation ?
                ["postMutationOldGenerationPresented"] : [],
        },
    };
}

function writeJson(file, value) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function writeDeploymentVerification(root, buildId) {
    const retainedManifest = path.join(root, "raw", "startup",
        "deployment-manifest.json");
    writeJson(retainedManifest, { buildId,
        artifact: { sha256: "a".repeat(64), sizeBytes: 1 } });
    writeJson(path.join(root, "raw", "startup", "deployment-verification.json"), {
        schemaVersion: "renderscale-tuning-deployment-verification-v1",
        buildId,
        artifact: { fileName: "CommunityShaders.dll", bytes: 1,
            sha256: "a".repeat(64) },
        manifest: { fileName: "CSX.BuildManifest.json",
            path: "raw/startup/deployment-manifest.json",
            sha256: sha(retainedManifest) },
        manifestVerified: true,
    });
}

function testDeploymentVerification() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "rst-deployment-"));
    const buildId = "f".repeat(64);
    try {
        const artifactPath = path.join(root, "CommunityShaders.dll");
        const manifestPath = path.join(root, "CSX.BuildManifest.json");
        fs.writeFileSync(artifactPath, "verified-artifact");
        writeJson(manifestPath, {
            buildId,
            artifact: {
                fileName: path.basename(artifactPath),
                sizeBytes: fs.statSync(artifactPath).size,
                sha256: sha(artifactPath),
            },
        });
        const result = deploymentVerification(root, buildId, {
            artifactPath, manifestPath,
        });
        assert(result.complete === true && result.artifactSha256 ===
            sha(artifactPath) && fs.existsSync(path.join(root, result.receipt)) &&
            fs.existsSync(path.join(root, "raw", "startup",
                "deployment-manifest.json")),
        "Deployment verification did not retain portable artifact proof.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function createEvidenceRoot(variant = "nvidia", nonStable = false) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "rst-finalizer-"));
    const runId = `${variant}-test-run`;
    const buildId = "e".repeat(64);
    writeJson(path.join(root, "summary.json"), {
        runId,
        generatedUtc: "2026-08-30T20:00:00.000Z",
        build: { buildId },
        counts: { transitionsDispatched: 2 },
    });
    writeDeploymentVerification(root, buildId);
    if (variant === "amd") {
        writeJson(path.join(root, "raw", "live-result.json"), {
            ok: true,
            status: "COMPLETE",
            variant,
            runId,
            traceCapability: { status: "supported" },
            lanes: [],
        });
    }
    writeJson(path.join(root, "raw", "pass-1", "transitions", "01",
        "retained.json"), retained(false, true, { runId, buildId, variant }));
    writeJson(path.join(root, "raw", "pass-1", "transitions", "02",
        "retained.json"), retained(true, true, { runId, buildId, variant }, nonStable));
    return root;
}

function createBaselineOnlyEvidenceRoot(variant) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "rst-finalizer-baseline-"));
    const runId = `${variant}-baseline-run`;
    const buildId = "b".repeat(64);
    writeJson(path.join(root, "raw", "live-result.json"), {
        ok: false,
        status: "INTERRUPTED",
        variant,
        runId,
        lanes: [{ id: variant, status: "INTERRUPTED",
            passes: [{ pass: 1, status: "INTERRUPTED",
                error: "baseline_failed" }] }],
    });
    writeDeploymentVerification(root, buildId);
    writeJson(path.join(root, "raw", "pass-1", "baseline", "baseline.json"), {
        ok: true,
        results: [{
            label: "qualification-wait",
            result: {
                action: "qualification_wait",
                ownerId: `${runId}-${variant}-1-1-b-owner`,
                producer: { buildId },
                baseline: { stressSessionId: 1 },
                outcome: "timeout",
                satisfied: false,
            },
        }],
    });
    return { root, runId, buildId };
}

function testBaselineOnlyInterruptedFinalization() {
    for (const [variant, expectedRows] of [["nvidia", 66], ["amd", 186]]) {
        const evidence = createBaselineOnlyEvidenceRoot(variant);
        try {
            const options = { ...evidence, variant, expectedRows,
                generatedUtc: "2026-08-31T01:00:00.000Z" };
            let result = finalizeEvidence(options);
            assert(result.summary.assayExecution.status === "INTERRUPTED" &&
                result.summary.assayExecution.transitionsDispatched === 0 &&
                result.summary.assayExecution.expectedTransitions === expectedRows,
            `${variant} baseline-only execution count was not retained.`);
            assert(result.summary.render.verdict === "INCONCLUSIVE" &&
                result.summary.reporting.status === "INCOMPLETE" &&
                result.summary.reporting.reasons.includes(
                    "baseline_only_interrupted"),
            `${variant} baseline-only verdict separation is wrong.`);
            assert(result.summary.memoryConfirmation.passesCompleted === 0 &&
                result.summary.memoryConfirmation.verdict ===
                    "repeat_not_completed" &&
                result.summary.memoryConfirmation.unavailableBoundaries.length === 6,
            `${variant} baseline-only memory status is incomplete.`);
            const reportText = fs.readFileSync(path.join(evidence.root,
                "report.md"), "utf8");
            assert(reportText.includes(`Transitions dispatched: **0/${expectedRows}**`) &&
                reportText.includes("Memory confirmation: **repeat_not_completed**"),
            `${variant} baseline-only report is incomplete.`);
            const outputs = ["report.md", "summary.json", "transitions.csv",
                "evidence-values.csv", "receipt-index.json"];
            const firstHashes = outputs.map((name) =>
                sha(path.join(evidence.root, name)));
            result = finalizeEvidence(options);
            const secondHashes = outputs.map((name) =>
                sha(path.join(evidence.root, name)));
            assert(JSON.stringify(firstHashes) === JSON.stringify(secondHashes),
                `${variant} baseline-only finalization is not deterministic.`);
        } finally {
            fs.rmSync(evidence.root, { recursive: true, force: true });
        }
    }
}

function testPartialInterruptedFinalization() {
    const root = createEvidenceRoot("nvidia");
    const runId = "nvidia-test-run";
    const buildId = "e".repeat(64);
    try {
        const failure = {
            phase: "response",
            receiptKey: `${runId}:nvidia:pass-2:transition-1:scenario`,
            ok: false,
            aborted: true,
            stepsRun: 3,
            expectedSteps: 7,
            reportedError: "profiler_timeout",
            failedStep: "profiler-clear-history",
            firstUnreportedStep: "qualification-dispatch",
            recovery: {
                decision: {
                    satisfied: false,
                    reasons: ["waiter_not_satisfied",
                        "safe_terminal:active_operation_not_clear"],
                },
                apply: { present: true, accepted: true },
                waiter: { present: true, satisfied: false },
                safeTerminal: { satisfied: false,
                    reasons: ["active_operation_not_clear"] },
            },
        };
        writeJson(path.join(root, "raw", "live-result.json"), {
            ok: false, status: "INTERRUPTED", variant: "nvidia", runId,
            lanes: [{ id: "nvidia", status: "INTERRUPTED", passes: [
                { pass: 1, status: "COMPLETE", rows: [{ ordinal: 1 },
                    { ordinal: 2 }] },
                { pass: 2, status: "INTERRUPTED", rows: [],
                    error: "transition_scenario_failed", failure },
            ] }],
        });
        writeJson(path.join(root, "raw", "pass-2", "transitions", "01",
            "retained.json"), {
            variant: "nvidia",
            scenarioReceiptKey: failure.receiptKey,
            scenario: failure,
            waiter: null,
            projection: null,
        });
        writeJson(path.join(root, "raw", "pass-2", "transitions", "01",
            "scenario.json"), {
            ok: false, aborted: true, stepsRun: 3,
            results: [{ label: "transition-wait", result: { ok: true } },
                { label: "qualification-begin", result: { ok: true } },
                { label: "profiler-clear-history", ok: false,
                    error: "profiler_timeout" }],
        });
        const result = finalizeEvidence({ root, variant: "nvidia", runId,
            buildId, expectedRows: 4,
            generatedUtc: "2026-08-31T05:00:00.000Z" });
        assert(result.summary.assayExecution.status === "INTERRUPTED" &&
            result.summary.assayExecution.transitionsDispatched === 2 &&
            result.summary.transitions.length === 2,
        "A partial interruption discarded completed rows or counted an undispatched row.");
        assert(result.summary.assayExecution.interruption.failure.failedStep ===
            "profiler-clear-history" &&
            result.summary.assayExecution.interruption
                .undispatchedTransitionReceipts.length === 1,
        "The failed scenario diagnostic was not retained in the offline summary.");
        assert(result.summary.assayExecution.interruption.error ===
            "transition_scenario_failed" &&
            result.summary.assayExecution.interruption.failure.recovery
                .decision.reasons.includes("waiter_not_satisfied"),
        "The interrupted pass error or compact recovery decision was lost.");
        assert(result.index.files.some((entry) =>
            entry.path.endsWith("pass-2/transitions/01/scenario.json")),
        "The raw failed scenario was omitted from the receipt index.");
        const reportText = fs.readFileSync(path.join(root, "report.md"), "utf8");
        assert(reportText.includes("transition_scenario_failed") &&
            reportText.includes("profiler-clear-history") &&
            reportText.includes(failure.receiptKey) &&
            reportText.includes("waiter_not_satisfied") &&
            reportText.includes("safe_terminal:active_operation_not_clear"),
        "The interrupted report omitted the exact error, step, receipt, or recovery reason.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testOfflineFinalization() {
    const root = createEvidenceRoot("nvidia", true);
    try {
        const secondPath = path.join(root, "raw", "pass-1", "transitions",
            "02", "retained.json");
        const secondReceipt = JSON.parse(fs.readFileSync(secondPath, "utf8"));
        secondReceipt.waiter.diagnostics.delta.presentation = {
            maximumStretchFramesBaseline: 13,
            maximumStretchFramesCurrent: 13,
            stretchCompletedEpisodes: 2,
            stretchCompletedFrames: 11,
        };
        writeJson(secondPath, secondReceipt);
        const options = { root, variant: "nvidia", runId: "nvidia-test-run",
            buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" };
        let result = finalizeEvidence(options);
        assert(result.summary.assayExecution.status === "COMPLETE",
            "Completed assay execution was rewritten.");
        assert(result.summary.render.verdict === "FAIL",
            "The non-stable transition was not retained as a render failure.");
        assert(result.summary.task2Evidence.mode === "per_transition" &&
            result.summary.task2Evidence.aggregateVerdict === "NOT_COMPUTED" &&
            result.summary.task2Evidence.counts.FAIL === 1 &&
            result.summary.task2Evidence.counts.INCONCLUSIVE === 1,
        "Task 2 evidence was aggregated instead of retained per transition.");
        assert(!Object.hasOwn(result.summary, "evidenceVerdict") &&
            !Object.hasOwn(result.summary, "task2Verdict") &&
            !Object.hasOwn(result.summary, "overallVerdict"),
        "Legacy aggregate verdict fields were retained.");
        assert(result.summary.reporting.status === "COMPLETE",
            "Complete preserved receipts did not finalize.");
        assert(result.summary.stabilityNotes.count === 1 &&
            result.summary.stabilityNotes.transitions[0]
                .presentationDisposition === "PresentationStretch",
        "The non-stable transition note was not summarized.");
        assert(result.summary.presentationStretchAnomalies.selected === 2 &&
            result.summary.presentationStretchAnomalies.recoveredPass === 1 &&
            result.summary.presentationStretchAnomalies.unrecovered === 1 &&
            result.summary.presentationStretchAnomalies.transitions[0]
                .consecutiveFrames === 2,
        "Presentation-stretch anomalies were not summarized from receipts.");
        const first = result.summary.transitions[0];
        assert(first.presentationStretchSelected === true &&
            first.presentationStretchConsecutiveFrames === 2 &&
            first.presentationStretchRecovered === true &&
            first.presentationStretchRecoveryFrame === 12 &&
            first.presentationStretchRecoveryElapsedMs === 2.5,
        "Recovered presentation-stretch detail was not materialized.");
        assert(result.summary.transitions[1]
            .presentationStretchConsecutiveFrames === "not_exposed",
        "An inexact multi-episode stretch maximum was fabricated.");
        assert(first.task2Verdict === "INCONCLUSIVE" &&
            first.task2MissingEvidence.includes(
                "missing_required_mutation_boundary") &&
            first.phaseCountersAuthoritative === false,
        "Missing required mutation boundary was not INCONCLUSIVE.");
        assert(result.summary.transitions[1].task2Verdict === "FAIL",
            "Post-boundary violation was downgraded.");
        assert(first.diagnostics.boundaryExposed === false &&
            first.diagnostics.dispatchLeft.generation === 8 &&
            first.diagnostics.terminalLeft.generation === 9 &&
            first.diagnostics.terminalLeft.generation -
                first.diagnostics.dispatchLeft.generation === 1,
        "Dispatch/terminal diagnostic values were not retained independently.");
        assert(result.summary.evidenceExtraction.complete === true &&
            result.summary.evidenceExtraction.rawJsonFiles === 4 &&
            result.summary.evidenceExtraction.values > 0 &&
            result.summary.evidenceExtraction.nullValues > 0 &&
            result.summary.evidenceExtraction.emptyContainers > 0,
        "Raw JSON value extraction was not recorded.");

        const extracted = fs.readFileSync(path.join(root,
            "evidence-values.csv"), "utf8");
        assert(extracted.includes(
            "/waiter/replacementTimeline/dispatch/presentationProof/leftEye/generation,number,8") &&
            extracted.includes(
                "/waiter/replacementTimeline/terminal/presentationProof/leftEye/resourceRevision,number,41") &&
            extracted.includes(
                "/waiter/replacementTimeline/firstPhysicalMutation,null,null"),
        "Lossless extraction omitted a required diagnostic path or null value.");
        assert(extracted.includes("/analysisSentinel/falseValue,boolean,false") &&
            extracted.includes("/analysisSentinel/zeroValue,number,0") &&
            extracted.includes("/analysisSentinel/emptyArray,empty_array,[]") &&
            extracted.includes("/analysisSentinel/emptyObject,empty_object,{}") &&
            extracted.includes("/analysisSentinel/slash~1key~0,string"),
        "Lossless extraction dropped a false, zero, empty, or escaped path value.");
        assert(result.index.files.some((entry) =>
            entry.path === "evidence-values.csv"),
        "The lossless value export was not hashed in the receipt index.");
        const report = fs.readFileSync(path.join(root, "report.md"), "utf8");
        assert(report.includes("Task 2/evidence: **per transition**") &&
            report.includes("Task 2 is deliberately not aggregated") &&
            report.includes("not stable: PresentationStretch") &&
            report.includes("Non-stable terminal notes: **1**") &&
            report.includes("Presentation stretch: **2 selected, " +
                "1 recovered PASS, 1 unrecovered**") &&
            report.includes("## Presentation stretch anomalies"),
        "The report still presents an aggregate Task 2 verdict.");
        const transitionCsv = fs.readFileSync(path.join(root,
            "transitions.csv"), "utf8");
        assert(transitionCsv.startsWith("lane,pass,ordinal") &&
            transitionCsv.includes("boundary_exposed") &&
            transitionCsv.includes("reported_violations") &&
            transitionCsv.includes("producer_invalid_evidence") &&
            transitionCsv.includes("violation_authority") &&
            transitionCsv.includes("dispatch_left_generation") &&
            transitionCsv.includes("dispatch_right_generation") &&
            transitionCsv.includes("terminal_left_resource_revision") &&
            transitionCsv.includes("terminal_right_resource_revision") &&
            transitionCsv.includes("stability_presentation_disposition") &&
            transitionCsv.includes("presentation_stretch_consecutive_frames") &&
            transitionCsv.includes("presentation_stretch_recovery_elapsed_ms") &&
            transitionCsv.includes("PresentationStretch"),
        "The compact transition table omitted diagnostic columns.");

        const outputs = ["report.md", "summary.json", "transitions.csv",
            "evidence-values.csv", "receipt-index.json"];
        const firstHashes = outputs.map((name) => sha(path.join(root, name)));
        result = finalizeEvidence(options);
        const secondHashes = outputs.map((name) => sha(path.join(root, name)));
        assert(JSON.stringify(firstHashes) === JSON.stringify(secondHashes),
            "Offline finalization output hashes are not deterministic.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testUnownedViolationRemainsReported() {
    const root = createEvidenceRoot();
    try {
        const retainedPath = path.join(root, "raw", "pass-1", "transitions",
            "02", "retained.json");
        const receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        receipt.projection.phaseCountersAuthoritative = true;
        receipt.projection.producerInvalidEvidence =
            ["physical_mutation_boundary_owner_mismatch"];
        receipt.projection.reportedInvariantViolations =
            ["postMutationOldGenerationPresented"];
        receipt.waiter.transitionId = 101;
        receipt.waiter.presentationCycleAudit = {
            evidenceComplete: true,
            retentionOverflow: false,
            ownerTransitionId: 101,
            ownerToken: 1,
            eyeObservations: 2,
        };
        receipt.waiter.replacementTimeline.firstPhysicalMutation.stressSessionId = 7;
        receipt.waiter.replacementTimeline.firstPhysicalMutation
            .qualificationTransitionId = 101;
        receipt.waiter.replacementTimeline.firstPhysicalMutation.ownershipToken = 2;
        writeJson(retainedPath, receipt);
        const result = finalizeEvidence({ root, variant: "nvidia",
            runId: "nvidia-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        const row = result.summary.transitions[1];
        assert(row.task2Verdict === "INCONCLUSIVE" &&
            row.phaseCountersAuthoritative === false &&
            row.phaseCounterAuthorityStatus === "MISMATCHED" &&
            row.phaseCounterAuthorityReasons.includes(
                "boundary_audit_token_mismatch") &&
            row.reportedTask2Violations.includes(
                "postMutationOldGenerationPresented") &&
            row.authoritativeTask2Violations.length === 0 &&
            row.task2ProducerInvalidEvidence.includes(
                "physical_mutation_boundary_owner_mismatch"),
        "Finalization promoted an unowned reported counter into false evidence.");
        const report = fs.readFileSync(path.join(root, "report.md"), "utf8");
        assert(report.includes("Reported violations") &&
            report.includes("physical_mutation_boundary_owner_mismatch"),
        "The report hid the observed counter or its invalid authority.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testReportingSeparation() {
    const root = createEvidenceRoot();
    try {
        const retainedPath = path.join(root, "raw", "pass-1", "transitions",
            "01", "retained.json");
        const receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        receipt.waiter.target.method = "dlss";
        writeJson(retainedPath, receipt);
        const result = finalizeEvidence({ root, variant: "nvidia",
            runId: "nvidia-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        assert(result.summary.render.verdict === "PASS" &&
            result.summary.reporting.status === "INCOMPLETE",
        "Reporting incompleteness rewrote a completed render PASS.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testMatchedViolationSurvivesIncompletePeer() {
    const root = createEvidenceRoot();
    try {
        const retainedPath = path.join(root, "raw", "pass-1", "transitions",
            "02", "retained.json");
        const receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        receipt.projection.phaseCountersAuthoritative = false;
        receipt.projection.phaseCounterAuthorityStatus = "INCOMPLETE";
        receipt.projection.phaseCounterAuthorityReasons =
            ["preMutationStretchWithoutMutation_first_offender_missing"];
        receipt.projection.producerInvalidEvidence =
            ["preMutationStretchWithoutMutation_first_offender_missing"];
        receipt.projection.reportedInvariantViolations = [
            "preMutationStretchWithoutMutation",
            "postMutationOldGenerationPresented",
        ];
        receipt.projection.violationAuthority = {
            preMutationStretchWithoutMutation: {
                status: "INCOMPLETE",
                reasons: [
                    "preMutationStretchWithoutMutation_first_offender_missing",
                ],
            },
            postMutationOldGenerationPresented: {
                status: "MATCHED", reasons: [],
            },
        };
        writeJson(retainedPath, receipt);
        const result = finalizeEvidence({ root, variant: "nvidia",
            runId: "nvidia-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        const row = result.summary.transitions[1];
        assert(row.task2Verdict === "FAIL" &&
            row.phaseCounterAuthorityStatus === "INCOMPLETE" &&
            row.authoritativeTask2Violations.includes(
                "postMutationOldGenerationPresented"),
        "Finalization erased a matched violation because another counter was incomplete.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testAmdParity() {
    const root = createEvidenceRoot("amd");
    try {
        const result = finalizeEvidence({ root, variant: "amd",
            runId: "amd-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        assert(result.summary.protocol === "renderscale-tuning-amd" &&
            result.summary.transitions[0].task2Verdict === "INCONCLUSIVE" &&
            result.summary.transitions[1].task2Verdict === "FAIL" &&
            result.summary.task2Evidence.mode === "per_transition" &&
            result.summary.task2Evidence.counts.INCONCLUSIVE === 1 &&
            result.summary.task2Evidence.counts.FAIL === 1 &&
            result.summary.evidenceExtraction.complete === true,
        "AMD did not use the shared Task 2 finalization contract.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testRecoveryIsReportedWithoutRewritingFailure() {
    const root = createEvidenceRoot("nvidia", true);
    try {
        const retainedPath = path.join(root, "raw", "pass-1", "transitions",
            "02", "retained.json");
        const receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        receipt.recovery = {
            status: "RECOVERED",
            target: {
                method: "dlss", qualityMode: "hoshipa",
                renderScaleMode: true, dlssProfile: "K",
            },
            receiptKey: "nvidia-test-run:nvidia:pass-1:transition-2:recovery",
        };
        receipt.recoveryReceiptKey = receipt.recovery.receiptKey;
        writeJson(retainedPath, receipt);
        const result = finalizeEvidence({ root, variant: "nvidia",
            runId: "nvidia-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        const row = result.summary.transitions[1];
        assert(result.summary.schemaVersion ===
            "renderscale-tuning-nvidia-summary-v5" &&
            row.renderVerdict === "FAIL" &&
            row.recoveryStatus === "RECOVERED" &&
            row.recoveryTarget.method === "dlss" &&
            row.recoveryReceiptKey === receipt.recovery.receiptKey,
        "Recovery rewrote the failed row or was omitted from the summary.");
        const csvText = fs.readFileSync(path.join(root, "transitions.csv"),
            "utf8");
        const reportText = fs.readFileSync(path.join(root, "report.md"), "utf8");
        assert(csvText.includes("recovery_status") &&
            csvText.includes("RECOVERED") &&
            reportText.includes("| FAIL |") &&
            reportText.includes("| reset after row |"),
        "Recovery was omitted from the durable CSV or report.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testValidationLeavesEvidenceUntouched() {
    const root = createEvidenceRoot();
    try {
        const before = sha(path.join(root, "summary.json"));
        try {
            finalizeEvidence({ root, variant: "nvidia", runId: "wrong-run",
                buildId: "e".repeat(64), expectedRows: 2 });
            throw new Error("Expected identity validation to fail.");
        } catch (error) {
            assert(error.message === "finalization_identity_ambiguous",
                "Unexpected finalization validation error.");
        }
        assert(sha(path.join(root, "summary.json")) === before,
            "A validation error modified preserved evidence.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testAmdTraceCapabilityOnlyAffectsReporting() {
    const root = createEvidenceRoot("amd");
    try {
        const options = { root, variant: "amd",
            runId: "amd-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" };
        const supported = finalizeEvidence(options);
        const livePath = path.join(root, "raw", "live-result.json");
        const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
        live.traceCapability = { status: "unsupported" };
        writeJson(livePath, live);
        const result = finalizeEvidence(options);
        assert(result.summary.render.verdict === supported.summary.render.verdict &&
            result.summary.reporting.status === "INCOMPLETE" &&
            result.summary.traceCapability.status === "unsupported" &&
            result.summary.reporting.reasons.includes(
                "amd_trace_capability_evidence_incomplete"),
        `Missing optional AMD trace evidence changed row results or allowed reporting completion: ${JSON.stringify({ render: result.summary.render, reporting: result.summary.reporting })}`);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testVariantAndSourceProfileValidation() {
    const root = createEvidenceRoot();
    try {
        const retainedPath = path.join(root, "raw", "pass-1", "transitions",
            "01", "retained.json");
        let receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        receipt.variant = "amd";
        writeJson(retainedPath, receipt);
        try {
            finalizeEvidence({ root, variant: "nvidia", runId: "nvidia-test-run",
                buildId: "e".repeat(64), expectedRows: 2 });
            throw new Error("Expected variant mismatch.");
        } catch (error) {
            assert(error.message === "terminal_receipt_variant_mismatch",
                "A mixed-variant receipt was accepted.");
        }
        receipt.variant = "nvidia";
        receipt.waiter.replacementTimeline.dispatch.presentationProof
            .rightEye.method = "taa";
        writeJson(retainedPath, receipt);
        try {
            finalizeEvidence({ root, variant: "nvidia", runId: "nvidia-test-run",
                buildId: "e".repeat(64), expectedRows: 2 });
            throw new Error("Expected source method mismatch.");
        } catch (error) {
            assert(error.message === "source_profile_method_mismatch",
                "Mismatched source-eye methods were accepted.");
        }
        receipt.waiter.replacementTimeline.dispatch.presentationProof.leftEye =
            "none";
        receipt.waiter.replacementTimeline.dispatch.presentationProof
            .rightEye.method = "none";
        writeJson(retainedPath, receipt);
        try {
            finalizeEvidence({ root, variant: "nvidia", runId: "nvidia-test-run",
                buildId: "e".repeat(64), expectedRows: 2 });
            throw new Error("Expected malformed source proof.");
        } catch (error) {
            assert(error.message === "source_profile_method_invalid",
                "A malformed source-eye proof was accepted.");
        }
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }

    const missing = createEvidenceRoot();
    try {
        const retainedPath = path.join(missing, "raw", "pass-1", "transitions",
            "01", "retained.json");
        const receipt = JSON.parse(fs.readFileSync(retainedPath, "utf8"));
        delete receipt.waiter.replacementTimeline.dispatch.presentationProof.leftEye;
        delete receipt.waiter.replacementTimeline.dispatch.presentationProof.rightEye;
        writeJson(retainedPath, receipt);
        const result = finalizeEvidence({ root: missing, variant: "nvidia",
            runId: "nvidia-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        assert(result.summary.transitions[0].source.method === "not_exposed",
            "A genuinely unexposed source method was inferred.");
    } finally {
        fs.rmSync(missing, { recursive: true, force: true });
    }
}

function testUnsafeEvidenceNumberFailsClosed() {
    const root = createEvidenceRoot();
    try {
        const before = sha(path.join(root, "summary.json"));
        fs.writeFileSync(path.join(root, "raw", "unsafe-number.json"),
            "{\"value\":9007199254740993}\n");
        try {
            finalizeEvidence({ root, variant: "nvidia",
                runId: "nvidia-test-run", buildId: "e".repeat(64),
                expectedRows: 2 });
            throw new Error("Expected unsafe evidence number to fail.");
        } catch (error) {
            assert(error.message === "evidence_numeric_value_not_lossless",
                "Unsafe JSON integer was not rejected losslessly.");
        }
        assert(sha(path.join(root, "summary.json")) === before,
            "Unsafe evidence modified finalized output.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testStreamedEvidence() {
    const root = createEvidenceRoot();
    const readFile = fs.readFileSync;
    try {
        const csvPath = path.join(root, "evidence-values.csv");
        const options = { root, variant: "nvidia", runId: "nvidia-test-run",
            buildId: "e".repeat(64), expectedRows: 2 };
        const initial = finalizeEvidence(options).summary.evidenceExtraction;
        const value = 'quotes " and commas,\nUnicode: 雪 🐉'.repeat(4096);
        writeJson(path.join(root, "raw/z-stream.json"), {
            "a/~": [null, [], {}, false, 0, value],
        });
        // Hashing must not materialize the generated CSV as one buffer either.
        fs.readFileSync = (file, ...args) => {
            assert(file !== csvPath, "Receipt indexing read the entire CSV.");
            return readFile(file, ...args);
        };
        const result = finalizeEvidence(options);
        fs.readFileSync = readFile;
        const actual = readFile(csvPath, "utf8");
        const expected = [
            'raw/z-stream.json,,,,/a~1~0/0,null,null',
            'raw/z-stream.json,,,,/a~1~0/1,empty_array,[]',
            'raw/z-stream.json,,,,/a~1~0/2,empty_object,{}',
            'raw/z-stream.json,,,,/a~1~0/3,boolean,false',
            'raw/z-stream.json,,,,/a~1~0/4,number,0',
            `raw/z-stream.json,,,,/a~1~0/5,string,"${JSON.stringify(value)
                .replace(/"/g, '""')}"`,
            "",
        ].join("\n");
        assert(actual.endsWith(expected),
            "Streaming changed CSV escaping, row order, or a large Unicode value.");
        const stats = result.summary.evidenceExtraction;
        assert(stats.rawJsonFiles === initial.rawJsonFiles + 1 &&
            stats.values === initial.values + 6 &&
            stats.nullValues === initial.nullValues + 1 &&
            stats.emptyContainers === initial.emptyContainers + 2,
        "Streamed extraction counts are incorrect.");
        const indexed = result.index.files.find(file => file.path === "evidence-values.csv");
        assert(indexed.sha256 === sha(csvPath) &&
            indexed.bytes === Buffer.byteLength(actual),
        "Streamed checksum or UTF-8 byte count differs from the written CSV.");
    } finally {
        fs.readFileSync = readFile;
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testEvidenceBeyondStringLimit() {
    if (!process.argv.includes("--large-evidence")) return;
    const root = createEvidenceRoot();
    try {
        const options = { root, variant: "nvidia", runId: "nvidia-test-run",
            buildId: "e".repeat(64), expectedRows: 2 };
        const initial = finalizeEvidence(options).summary.evidenceExtraction;
        const csvPath = path.join(root, "evidence-values.csv");
        const expectedHash = crypto.createHash("sha256").update(fs.readFileSync(csvPath));
        const limit = require("node:buffer").constants.MAX_STRING_LENGTH;
        const payload = "x".repeat(8 * 1024 * 1024);
        const count = Math.ceil(limit / payload.length);
        for (let index = 0; index < count; index += 1) {
            const source = `raw/z-large/${String(index).padStart(3, "0")}.json`;
            writeJson(path.join(root, source), payload);
            expectedHash.update(`${source},,,,,string,"""${payload}"""\n`);
        }
        const result = finalizeEvidence(options);
        const indexed = result.index.files.find(file => file.path === "evidence-values.csv");
        assert(indexed.bytes > limit && indexed.sha256 === expectedHash.digest("hex") &&
            result.summary.evidenceExtraction.values === initial.values + count,
        "Evidence beyond the JavaScript string limit was truncated or changed.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testEvidenceWriteFailures() {
    for (const failure of ["parse", "numeric", "write", "rename"]) {
        const root = createEvidenceRoot();
        const writeFile = fs.writeFileSync;
        const rename = fs.renameSync;
        const open = fs.openSync;
        const close = fs.closeSync;
        const descriptors = new Set();
        try {
            const options = { root, variant: "nvidia", runId: "nvidia-test-run",
                buildId: "e".repeat(64), expectedRows: 2 };
            finalizeEvidence(options);
            const outputs = ["summary.json", "transitions.csv", "report.md",
                "evidence-values.csv", "receipt-index.json"];
            const before = outputs.map(name => sha(path.join(root, name)));
            const temporary = path.join(root, "evidence-values.csv.tmp-finalizer");
            fs.openSync = (file, ...args) => {
                const descriptor = open(file, ...args);
                if (file === temporary) descriptors.add(descriptor);
                return descriptor;
            };
            fs.closeSync = (descriptor) => {
                close(descriptor);
                descriptors.delete(descriptor);
            };
            if (failure === "parse" || failure === "numeric") {
                // A valid large row forces buffered output before validation fails.
                writeJson(path.join(root, "raw/z-large.json"), "x".repeat(100000));
                writeFile(path.join(root, "raw/zz-invalid.json"),
                    failure === "parse" ? "{" : "9007199254740993");
            } else if (failure === "write") {
                fs.writeFileSync = (file, ...args) => {
                    if (descriptors.has(file)) {
                        writeFile(file, "partial output");
                        throw new Error("injected_disk_full");
                    }
                    return writeFile(file, ...args);
                };
            } else {
                fs.renameSync = (source, ...args) => {
                    if (source === temporary) throw new Error("injected_rename_failure");
                    return rename(source, ...args);
                };
            }
            let error;
            try { finalizeEvidence(options); } catch (caught) { error = caught; }
            assert(error && (failure === "parse" ? error instanceof SyntaxError :
                error.message === ({ numeric: "evidence_numeric_value_not_lossless",
                    write: "injected_disk_full", rename: "injected_rename_failure" })[failure]),
            `${failure} did not propagate the evidence failure.`);
            assert(descriptors.size === 0 && !fs.existsSync(temporary),
                `${failure} leaked a file descriptor or partial CSV.`);
            assert(JSON.stringify(before) === JSON.stringify(outputs.map(name =>
                sha(path.join(root, name)))),
            `${failure} replaced previously finalized evidence.`);
        } finally {
            fs.writeFileSync = writeFile;
            fs.renameSync = rename;
            fs.openSync = open;
            fs.closeSync = close;
            fs.rmSync(root, { recursive: true, force: true });
        }
    }
}

function testActualBackendProjection() {
    const root = createEvidenceRoot();
    const firstPath = path.join(root, "raw", "pass-1", "transitions",
        "01", "retained.json");
    const secondPath = path.join(root, "raw", "pass-1", "transitions",
        "02", "retained.json");
    const options = { root, variant: "nvidia", runId: "nvidia-test-run",
        buildId: "e".repeat(64), expectedRows: 2,
        generatedUtc: "2026-08-30T20:00:00.000Z" };
    try {
        const scaled = JSON.parse(fs.readFileSync(firstPath, "utf8"));
        scaled.waiter.target = {
            method: "dlss", qualityMode: 3, renderScaleMode: true,
        };
        scaled.waiter.replacementTimeline.terminal.presentationProof.backend =
            "dlss";
        writeJson(firstPath, scaled);

        const native = JSON.parse(fs.readFileSync(secondPath, "utf8"));
        native.waiter.target = {
            method: "fsr", qualityMode: 0, renderScaleMode: false,
        };
        native.waiter.nativeVendorExecution = {
            required: true,
            sameFrameBothEyesValid: true,
            actualBackend: "fsr_host",
        };
        writeJson(secondPath, native);

        let result = finalizeEvidence(options);
        assert(result.summary.transitions[0].actualBackend === "dlss" &&
            result.summary.transitions[1].actualBackend === "fsr_host" &&
            !result.summary.reporting.reasons.includes(
                "reporting_contract_incomplete"),
        "Owning backend evidence was not projected into complete reporting.");
        const csvText = fs.readFileSync(path.join(root, "transitions.csv"),
            "utf8");
        const reportText = fs.readFileSync(path.join(root, "report.md"), "utf8");
        assert(csvText.includes("actual_backend") &&
            csvText.includes("dlss") && csvText.includes("fsr_host") &&
            reportText.includes("Actual backend") &&
            reportText.includes("| fsr_host |"),
        "Actual backend was omitted from a rendered transition output.");

        delete native.waiter.nativeVendorExecution;
        writeJson(secondPath, native);
        result = finalizeEvidence(options);
        assert(result.summary.transitions[1].renderVerdict === "PASS" &&
            result.summary.transitions[1].actualBackend === "not_exposed" &&
            result.summary.reporting.status === "INCOMPLETE" &&
            result.summary.reporting.reasons.includes(
                "reporting_contract_incomplete"),
        "Missing native backend evidence did not preserve PASS and fail reporting.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testTraceCompletenessPassability() {
    const root = createEvidenceRoot();
    const buildId = "e".repeat(64);
    try {
        const file = path.join(root, "raw/pass-1/transitions/02/retained.json");
        const receipt = JSON.parse(fs.readFileSync(file, "utf8"));
        receipt.waiter.target = { method: "dlss", qualityMode: 0, renderScaleMode: false };
        receipt.waiter.nativeVendorExecution = { actualBackend: "dlss" };
        const summary = { active: false, sessionID: 17, totalRecords: 70,
            droppedRecords: 0, overwrittenRecords: 0 };
        receipt.traceReset = { action: "dlss_trace_reset", producer: { buildId },
            capture: { ...summary, totalRecords: 0 } };
        receipt.traceStart = { action: "dlss_trace_start", producer: { buildId },
            capture: { ...summary, active: true, totalRecords: 0 } };
        receipt.traceStop = { action: "dlss_trace_stop", producer: { buildId }, capture: summary };
        const pages = [0, 32, 64].map(cursor => {
            const page = tracePage(buildId, 17, cursor,
                records(cursor + 1, Math.min(32, 70 - cursor)), cursor < 64, 32);
            page.capture.latestSequence = 70;
            page.capture.summary = { ...summary };
            return page;
        });
        receipt.traceRead = pages[0];
        receipt.traceReadPages = pages;
        const options = { root, variant: "nvidia", runId: "nvidia-test-run",
            buildId, expectedRows: 2 };
        writeJson(file, receipt);
        let result = finalizeEvidence(options);
        assert(result.summary.reporting.status === "COMPLETE" &&
            result.summary.transitions[1].traceEvidence.records === 70,
        "A complete producer-shaped trace cannot pass offline finalization.");
        for (const change of [
            row => { delete row.traceReadPages; },
            row => { row.traceReadPages[1].capture.summary.sessionID += 1; },
            row => { row.traceReadPages[1].capture.records[0].current.sequence -= 1; },
            row => { row.traceReadPages[2].capture.latestSequence += 1; },
            row => { row.traceStop.capture.active = true; },
            row => { row.traceStop.capture.droppedRecords = 1; },
        ]) {
            const broken = JSON.parse(JSON.stringify(receipt));
            change(broken);
            writeJson(file, broken);
            result = finalizeEvidence(options);
            assert(result.summary.reporting.status === "INCOMPLETE" &&
                result.summary.transitions[1].renderVerdict === "PASS" &&
                result.summary.transitions[1].traceComplete === false,
            "An incomplete or foreign trace passed reporting or rewrote render truth.");
        }
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

function testJournalOnlyPartialFinalization() {
    const root = createEvidenceRoot();
    try {
        const runId = "nvidia-test-run";
        const journal = path.join(root, "raw/journal");
        const row = retained(true, false, { runId, buildId: "e".repeat(64) });
        writeJson(path.join(journal, "000001.json"), {
            sequence: 1, receiptKey: `${runId}:nvidia:pass-1:transition-1`,
            value: { ...row, projection: null },
        });
        writeJson(path.join(journal, "000002.json"), {
            sequence: 2, receiptKey: `${runId}:nvidia:pass-1:transition-1`, value: row,
        });
        fs.rmSync(path.join(root, "raw/pass-1"), { recursive: true });
        const before = sha(path.join(journal, "000001.json"));
        const options = { root, variant: "nvidia", runId,
            buildId: "e".repeat(64), expectedRows: 66 };
        let result = finalizeEvidence(options);
        assert(result.summary.assayExecution.transitionsDispatched === 1 &&
            result.summary.assayExecution.status === "INCOMPLETE" &&
            result.summary.transitions[0].renderVerdict === "PASS",
        "Partial journal evidence was discarded instead of reported.");
        result = finalizeEvidence(options);
        assert(sha(path.join(journal, "000001.json")) === before &&
            result.summary.transitions.length === 1,
        "Restarting offline finalization changed or duplicated earlier evidence.");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

Promise.resolve().then(testBoundedPaging).then(testPagingValidation)
    .then(testTraceCompletenessPassability)
    .then(testJournalOnlyPartialFinalization)
    .then(testPagingResume).then(testDeploymentVerification)
    .then(testOfflineFinalization)
    .then(testReportingSeparation).then(testUnownedViolationRemainsReported)
    .then(testMatchedViolationSurvivesIncompletePeer)
    .then(testAmdParity)
    .then(testAmdTraceCapabilityOnlyAffectsReporting)
    .then(testRecoveryIsReportedWithoutRewritingFailure)
    .then(testBaselineOnlyInterruptedFinalization)
    .then(testPartialInterruptedFinalization)
    .then(testValidationLeavesEvidenceUntouched)
    .then(testVariantAndSourceProfileValidation)
    .then(testActualBackendProjection)
    .then(testStreamedEvidence).then(testEvidenceWriteFailures)
    .then(testEvidenceBeyondStringLimit)
    .then(testUnsafeEvidenceNumberFailsClosed).then(() => {
        process.stdout.write("Render-scale tuning finalizer tests passed.\n");
    }).catch((error) => {
        process.stderr.write(`${error.stack || error}\n`);
        process.exitCode = 1;
    });
