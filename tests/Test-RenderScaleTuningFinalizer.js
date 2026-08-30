// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const {
    collectTracePages,
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

function retained(boundary, violation, identity = {}) {
    const runId = identity.runId || "nvidia-test-run";
    const buildId = identity.buildId || "e".repeat(64);
    return {
        waiter: {
            satisfied: true,
            ownerId: `${runId}-owner`,
            baseline: { stressSessionId: 7 },
            producer: { buildId },
            target: { method: "none", qualityMode: 0, renderScaleMode: false },
            replacementTimeline: {
                mutationExpectation: "required",
                ...(boundary ? { firstPhysicalMutation: {
                    physicalMutationStarted: true,
                } } : {}),
            },
            upscalingSnapshot: {
                stateRevision: 8,
                stable: { method: "none", qualityMode: 0, renderScaleMode: false },
            },
        },
        projection: {
            renderVerdict: "PASS",
            evidenceVerdict: violation ? "FAIL" : "PASS",
            task2Verdict: violation ? "FAIL" : "PASS",
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

function createEvidenceRoot(variant = "nvidia") {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "rst-finalizer-"));
    const runId = `${variant}-test-run`;
    const buildId = "e".repeat(64);
    writeJson(path.join(root, "summary.json"), {
        runId,
        generatedUtc: "2026-08-30T20:00:00.000Z",
        build: { buildId },
        counts: { transitionsDispatched: 2 },
    });
    writeJson(path.join(root, "raw", "pass-1", "transitions", "01",
        "retained.json"), retained(false, true, { runId, buildId }));
    writeJson(path.join(root, "raw", "pass-1", "transitions", "02",
        "retained.json"), retained(true, true, { runId, buildId }));
    return root;
}

function testOfflineFinalization() {
    const root = createEvidenceRoot();
    try {
        const options = { root, variant: "nvidia", runId: "nvidia-test-run",
            buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" };
        let result = finalizeEvidence(options);
        assert(result.summary.assayExecution.status === "COMPLETE",
            "Completed assay execution was rewritten.");
        assert(result.summary.render.verdict === "PASS",
            "Render PASS was rewritten by evidence handling.");
        assert(result.summary.task2Evidence.verdict === "FAIL",
            "A genuine post-boundary violation did not remain FAIL.");
        assert(result.summary.reporting.status === "COMPLETE",
            "Complete preserved receipts did not finalize.");
        const first = result.summary.transitions[0];
        assert(first.task2Verdict === "INCONCLUSIVE" &&
            first.task2MissingEvidence.includes(
                "missing_required_mutation_boundary") &&
            first.phaseCountersAuthoritative === false,
        "Missing required mutation boundary was not INCONCLUSIVE.");
        assert(result.summary.transitions[1].task2Verdict === "FAIL",
            "Post-boundary violation was downgraded.");

        const outputs = ["report.md", "summary.json", "transitions.csv",
            "receipt-index.json"];
        const firstHashes = outputs.map((name) => sha(path.join(root, name)));
        result = finalizeEvidence(options);
        const secondHashes = outputs.map((name) => sha(path.join(root, name)));
        assert(JSON.stringify(firstHashes) === JSON.stringify(secondHashes),
            "Offline finalization output hashes are not deterministic.");
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

function testAmdParity() {
    const root = createEvidenceRoot("amd");
    try {
        const result = finalizeEvidence({ root, variant: "amd",
            runId: "amd-test-run", buildId: "e".repeat(64), expectedRows: 2,
            generatedUtc: "2026-08-30T20:00:00.000Z" });
        assert(result.summary.protocol === "renderscale-tuning-amd" &&
            result.summary.transitions[0].task2Verdict === "INCONCLUSIVE" &&
            result.summary.transitions[1].task2Verdict === "FAIL",
        "AMD did not use the shared Task 2 finalization contract.");
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

Promise.resolve().then(testBoundedPaging).then(testPagingValidation)
    .then(testPagingResume).then(testOfflineFinalization)
    .then(testReportingSeparation).then(testAmdParity)
    .then(testValidationLeavesEvidenceUntouched).then(() => {
        process.stdout.write("Render-scale tuning finalizer tests passed.\n");
    }).catch((error) => {
        process.stderr.write(`${error.stack || error}\n`);
        process.exitCode = 1;
    });
