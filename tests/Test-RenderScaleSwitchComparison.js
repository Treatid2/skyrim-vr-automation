// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { loadRun, compareData, reportComparison, writeComparison } =
    require("../tools/renderscale-tuning-finalizer/comparison.js");
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "csx-switch-comparison-"));
const write = (file, data) => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data));
};
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const policy = { id: "test-policy-v1", absoluteToleranceMs: 2, relativeTolerancePercent: 2, requiredPasses: 2 };

function fixture(name, speed = 100, failures = 0, native = false) {
    const root = path.join(temporary, name), buildId = name[0].repeat(64), sourceCommit = name[0].repeat(40);
    const rows = [], indexed = [];
    for (const pass of [1, 2]) {
        const relative = `raw/lane-nvidia/pass-${pass}/transitions/01/retained.json`;
        const target = { method: native ? "dlss" : "fsr", qualityMode: native ? 0 : 1, renderScaleMode: !native };
        const counters = { deviceLost: 0, outOfMemory: 0, transition: 0, dlssLifecycle: 0,
            fsrLifecycle: 0, memoryTrim: 0, retirementFence: 0, fidelityMismatches: failures };
        const row = { lane: "nvidia", pass, ordinal: 1, rawRetained: relative,
            source: { method: "taa", qualityMode: 0, renderScaleMode: false }, target,
            actualBackend: native ? "DLSS" : "FSRRuntime", renderVerdict: "PASS", task2Verdict: "PASS" };
        rows.push(row);
        const waiter = { producer: { buildId, sourceCommit }, ownerId: `${name}-owner-${pass}`,
            baseline: { stressSessionId: pass }, target, satisfied: true, strictSatisfied: true,
            strictElapsedMs: speed, strictElapsedFrames: 10, presentationElapsedMs: speed - 2,
            cleanupElapsedMs: speed, milestoneTimings: { cleanupTailMs: 2 },
            timing: { tickFrequency: 1000, dispatchTick: 1000, strictSatisfiedTick: 1000 + speed },
            replacementTimeline: { dispatch: { frame: 20, tick: 1000,
                presentationProof: { qualityMode: 0, renderScaleMode: false,
                    leftEye: { method: "taa" }, rightEye: { method: "taa" } } },
                firstNewGenerationProven: { frame: 28, tick: 1000 + speed - 10 },
                terminal: { replacementRequestId: pass, replacementTransitionEpoch: pass,
                    presentationProof: { backend: native ? "DLSS" : "FSRRuntime" } } },
            nativeVendorExecution: { required: native, sameFrameBothEyesValid: native, actualBackend: native ? "DLSS" : "FSRRuntime" },
            diagnostics: { delta: { failures: counters, stress: { retryEvents: 1 },
                presentation: { vendorFailureStretchEyeObservations: failures ? 1 : 0,
                    boundsMismatchFallbackEyeObservations: 0, stretchCompletedEpisodes: 1,
                    stretchCompletedFrames: 6, stretchCompletedQpcTicks: 60 } } } };
        write(path.join(root, relative), { waiter });
        indexed.push({ path: relative, sha256: hash(path.join(root, relative)), bytes: fs.statSync(path.join(root, relative)).size });
        const gates = [{ name: "presentation_stretch_frame_bound", passed: false,
            observed: { maximumObservedFrames: 6 }, limit: { maximumFrames: 2 } }];
        if (native) gates.push({ name: "presentation_recovered", passed: false, limit: { path: "VendorEvaluated" },
            observed: { leftPath: "NativeOriginal", rightPath: "NativeOriginal" } });
        if (failures) gates.push({ name: "fidelity_invariants", passed: false, observed: failures, limit: 0 });
        const record = { producer: { buildId }, session: { active: false, id: pass, overwrittenEvents: 0 },
            acceptance: { accepted: false, gates, failureReasons: gates.map(gate => gate.name) },
            presentationPath: { allowedPresentationStretch: { completedEpisodes: 1, completedFrames: 6,
                completedMilliseconds: 60, maximumCompletedMilliseconds: 60 } },
            metrics: [{ requestID: pass, transitionEpoch: pass, fidelityMismatches: failures,
                retries: 1, requestedFrame: 21, appliedFrame: 25, displayEyeWidth: 1512,
                displayEyeHeight: 1680, renderEyeWidth: 1284, renderEyeHeight: 1428 }],
            events: [{ type: "Retry", requestID: pass, transitionEpoch: pass, occurrences: 1 }] };
        write(path.join(root, `raw/lane-nvidia/pass-${pass}/finalization/cleanup.json`),
            { results: [{ label: "measured-stress-stop", result: { record } }] });
    }
    write(path.join(root, "summary.json"), { runId: name, build: { buildId, sourceCommit }, transitions: rows,
        assayExecution: { status: "COMPLETE" }, reporting: { status: "COMPLETE" }, fixtureFingerprint: "fixture-one" });
    const summary = read(path.join(root, "summary.json")); summary.build.shaderCompilerIdentity = "test-compiler";
    write(path.join(root, "summary.json"), summary);
    write(path.join(root, "raw/startup/deployment-manifest.json"), { buildId,
        identity: { source: { commit: sourceCommit }, toolchain: { compiler: "test" }, dependencies: {} } });
    write(path.join(root, "raw/startup/positioning.json"), { results: [
        { label: "position-renderscale", result: { status: { adapter: { vendorId: 4318 } } } },
        { label: "position-scene", result: { cell: "fixture" } }] });
    write(path.join(root, "raw/startup/prepare.json"), { after: { foveation: { center: .3 } } });
    write(path.join(root, "receipt-index.json"), { files: indexed });
    return { root, provenance: { sourceCommit, rendererBaseCommit: sourceCommit, mainVRBaseCommit: sourceCommit } };
}

function load(value) { return loadRun(value.root, value.provenance); }

try {
    const base = fixture("baseline"), fast = fixture("candidate", 80), recovered = fixture("recovered", 80, 2);
    const b = load(base), c = load(fast), r = load(recovered);
    assert.equal(b.health.passes[0].cumulativeAcceptance.accepted, false);
    assert.equal(b.health.passes[0].healthStandard, "MET");
    assert.equal(b.health.passes[0].failedGates[0].assessmentRole, "DIAGNOSTIC_ONLY");
    assert.equal(c.rows[0].switchTimings.relatchProofMs, 70);
    assert.equal(c.rows[0].switchTimings.relatchProofFrames, 8);
    assert.equal(c.rows[0].switchTimings.requestToAppliedFrames, 4);
    assert.deepEqual(c.rows[0].switchHealth.stretch, { completedEpisodes: 1, completedFrames: 6, completedMs: 60 });
    const adverse = compareData(b, r, policy);
    assert.equal(adverse.changeAssessment.status, "DOES_NOT_MEET_STANDARD");
    assert.equal(adverse.changeAssessment.changesTestResult, false);
    assert.equal(adverse.candidate.execution.status, "COMPLETE");
    assert.equal(adverse.candidate.rows[0].renderVerdict, "PASS");
    assert.deepEqual(adverse.passes[0].newFailureRows, [1]);
    assert.equal(adverse.candidate.health.passes[0].counters.fidelityMismatches, 2);
    assert.equal(compareData(b, c, policy).changeAssessment.status, "IMPROVEMENT_SUPPORTED");
    const amdBase = structuredClone(b), amdCandidate = structuredClone(c);
    for (const run of [amdBase, amdCandidate]) {
        for (const row of run.rows) {
            row.lane = "explicit_fsr4";
            row.laneQualification = { verdict: "PASS", reasons: [] };
        }
        for (const pass of run.health.passes) pass.lane = "explicit_fsr4";
    }
    assert.equal(compareData(amdBase, amdCandidate, policy).changeAssessment.status, "IMPROVEMENT_SUPPORTED");
    for (const qualification of [{ verdict: "FAIL" }, null]) {
        amdCandidate.rows[0].laneQualification = qualification;
        const invalid = compareData(amdBase, amdCandidate, policy);
        assert.equal(invalid.changeAssessment.status, "INCONCLUSIVE");
        assert(invalid.changeAssessment.reasons.includes("amd_lane_qualification_failed_or_missing"));
        assert.equal(invalid.candidate.rows[0].renderVerdict, "PASS");
    }
    assert.equal(compareData(b, c).changeAssessment.status, "INCONCLUSIVE");
    assert.equal(compareData(b, load(fixture("neutral", 101)), policy).changeAssessment.status, "NEUTRAL_SUPPORTED");
    assert.equal(compareData(b, load(fixture("slow", 103)), policy).changeAssessment.status, "DOES_NOT_MEET_STANDARD");
    const native = fixture("native", 100, 0, true), n = load(native);
    assert.equal(n.health.passes[0].healthStandard, "MET");
    assert.equal(n.health.passes[0].failedGates[1].assessmentRole, "CONTRACT_MISMATCH");
    const changedLimit = fixture("limit"), limitFile = path.join(changedLimit.root, "raw/lane-nvidia/pass-1/finalization/cleanup.json");
    const limitRecord = read(limitFile); limitRecord.results[0].result.record.acceptance.gates[0].limit.maximumFrames = 3;
    write(limitFile, limitRecord);
    assert.equal(load(changedLimit).health.passes[0].healthStandard, "NOT_MET");
    const wrong = fixture("wrong"), cleanup = path.join(wrong.root, "raw/lane-nvidia/pass-1/finalization/cleanup.json");
    const record = read(cleanup); record.results[0].result.record.producer.buildId = "wrong"; write(cleanup, record);
    assert.equal(load(wrong).health.passes[0].evidenceStatus, "INCOMPLETE");
    assert.equal(load(wrong).rows[0].switchHealth.ownedMetric, null);
    const missing = structuredClone(c); missing.rows.pop();
    const partial = compareData(b, missing, policy);
    assert.equal(partial.pairs.length, 2);
    assert.equal(partial.pairs[1].status, "UNMATCHED");
    assert.equal(partial.changeAssessment.status, "INCONCLUSIVE");
    const mismatched = structuredClone(c); mismatched.rows[0].source.method = "none";
    assert.equal(compareData(b, mismatched, policy).changeAssessment.status, "INCONCLUSIVE");
    const wrongCounter = fixture("counter"), file = path.join(wrongCounter.root, "raw/lane-nvidia/pass-1/transitions/01/retained.json");
    const value = read(file); delete value.waiter.diagnostics.delta.failures.fidelityMismatches; write(file, value);
    assert.throws(() => load(wrongCounter), /receipt_index_mismatch/);
    fs.unlinkSync(path.join(wrongCounter.root, "receipt-index.json"));
    const unknown = load(wrongCounter);
    assert.equal(unknown.rows[0].switchHealth.counters.fidelityMismatches, null);
    assert.equal(unknown.health.passes[0].evidenceStatus, "INCOMPLETE");
    assert.equal(compareData(b, unknown, policy).changeAssessment.status, "INCONCLUSIVE");
    const absent = fixture("absent");
    fs.unlinkSync(path.join(absent.root, "raw/lane-nvidia/pass-1/transitions/01/retained.json"));
    const absentRun = load(absent);
    assert.equal(absentRun.rows[0].switchTimings.strictMs, null);
    assert.equal(absentRun.rows[1].switchTimings.strictMs, 100);
    assert.equal(compareData(b, absentRun, policy).pairs[0].status, "UNMATCHED");
    assert.throws(() => loadRun(base.root, { sourceCommit: "wrong" }), /provenance_source_mismatch/);
    const duplicate = fixture("duplicate"), summaryFile = path.join(duplicate.root, "summary.json");
    const summary = read(summaryFile); summary.transitions.push(summary.transitions[0]); write(summaryFile, summary);
    assert.throws(() => load(duplicate), /duplicate_transition_identity/);
    assert.throws(() => writeComparison({ baselineRoot: base.root, candidateRoot: fast.root,
        outputRoot: fast.root }), /output_must_be_separate/);
    const before = hash(path.join(recovered.root, "summary.json"));
    const output = path.join(temporary, "output");
    const result = writeComparison({ baselineRoot: base.root, candidateRoot: recovered.root, outputRoot: output });
    assert.equal(hash(path.join(recovered.root, "summary.json")), before);
    assert.equal(result.pairs.length, 2);
    const report = reportComparison(adverse);
    for (const text of ["Relatch proof mean", "Strict completion total", "Stretch completed episodes",
        "Stretch completed total", "Delta frames", "Stretch ms B/C", "DIAGNOSTIC_ONLY"])
        assert(report.includes(text), `Missing requested observable report field: ${text}`);
    assert(read(path.join(output, "comparison.json")).pairs[0].candidate.switchHealth.findings.length > 0);
    console.log("Switch-health and comparison tests passed: recovery, imposed stretch, native gate, ownership, missing data, pairing, tolerances, provenance and unchanged input evidence.");
} finally {
    assert(path.resolve(temporary).startsWith(path.resolve(os.tmpdir()) + path.sep));
    fs.rmSync(temporary, { recursive: true });
}
