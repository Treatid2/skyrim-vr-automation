// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { memoryConfirmation, memoryReport } = require("../tools/renderscale-tuning-finalizer/memory-confirmation.js");

function writeJson(file, value) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(value));
}

function writeMemoryFixture(root, settings = {}) {
    const variant = settings.variant || "nvidia", lane = settings.lane || "nvidia";
    const buildId = "e".repeat(64);
    const base = path.join(root, "raw", ...(settings.legacy ? [] : [`lane-${lane}`]));
    const files = {};
    const p1Growth = settings.p1Growth ?? 100, p2Growth = settings.p2Growth ?? 75;
    const resourceGrowth = settings.resourceGrowth ?? 1;
    const frames = { pass1_start: 100, pass1_end: 190, cooldown_start: 191,
        cooldown_end: 195, pass2_start: 200, pass2_end: 290 };
    for (const [name, pass, start, privateMiB, resource] of [
        ["pass1_start", 1, true, 100, 0], ["pass1_end", 1, false, 100 + p1Growth, 1],
        ["cooldown_start", 1, false, 100 + p1Growth, 1], ["cooldown_end", 1, false, 100 + p1Growth, 1],
        ["pass2_start", 2, true, 300, 0], ["pass2_end", 2, false, 300 + p2Growth, resourceGrowth],
    ]) {
        const value = { ok: true, aborted: false, results: [
            { label: start ? "measured-stress-start" : "render-status", ok: true,
                tool: "communityshaders.renderscale", result: {
                    action: start ? "start" : "status", producer: { buildId },
                    status: { session: { id: pass + 6, startFrame: pass * 100,
                        active: !name.startsWith("cooldown") },
                        controller: { memory: {
                            sampleFrame: frames[name],
                            processPrivateUsageBytes: privateMiB * 1048576, processPrivateUsageValid: true,
                            systemCommitBytes: (privateMiB + 100) * 1048576, systemCommitValid: true,
                            usageBytes: (20 + resource) * 1048576, valid: true, pressure: "Normal",
                        } } } } },
            { label: start ? "texture-lifetime-start" : "texture-status", ok: true,
                tool: "communityshaders.renderscale", result: {
                    action: start ? "texture_lifetime_start" : "texture_lifetime_status",
                    producer: { buildId }, capture: {
                        sessionID: pass, supported: true, active: !name.startsWith("cooldown"),
                        liveTextureRecordCount: resource, outstandingEstimatedBytes: resource * 1048576,
                        droppedTextureRecords: 0, recordingFailures: 0, attachFailures: 0,
                        sentinelAllocationFailures: 0, outstandingUnknownEstimateCount: 0,
                    } } },
        ] };
        const suffix = name.startsWith("cooldown") ? name.replace("_", "-") + ".json" :
            start ? "handoff.json" : "finalization/final-status-before-cleanup.json";
        files[name] = path.join(base, `pass-${pass}`, suffix);
        writeJson(files[name], settings.envelope ?
            { content: [{ type: "text", text: JSON.stringify(value) }] } : value);
    }
    writeJson(path.join(base, "pass-1/cooldown.json"), {
        ok: true, aborted: false, stepsRun: 1, elapsedMs: 10001,
        results: [{ kind: "wait", ms: 10000, elapsedMs: 10001 }],
    });
    const liveResult = { runId: `${variant}-test-run`, variant, status: "COMPLETE",
        lanes: [{ id: lane, status: "COMPLETE", passes: [
            { pass: 1, status: "COMPLETE" }, { pass: 2, status: "COMPLETE" },
        ] }] };
    const matrix = JSON.parse(fs.readFileSync(path.join(__dirname, "../skills",
        `renderscale-tuning-${variant}/references/matrix.v1.json`), "utf8"));
    return { files, root, buildId, variant, liveResult,
        retained: [1, 2].flatMap(pass => matrix.transitions.map(({ ordinal }) => ({
            lane: settings.legacy ? null : lane, pass, ordinal, stressSessionId: pass + 6 }))),
        writeAtomic: (file, bytes) => fs.writeFileSync(file, bytes) };
}

function withFixture(settings, action) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "rst-memory-"));
    try { action(writeMemoryFixture(root, settings)); }
    finally { fs.rmSync(root, { recursive: true, force: true }); }
}

function changeBoundary(options, name, change) {
    const value = JSON.parse(fs.readFileSync(options.files[name], "utf8"));
    change(value);
    writeJson(options.files[name], value);
}

function testMemoryConfirmation() {
    for (const settings of [{}, { envelope: true }, { legacy: true }]) {
        withFixture(settings, options => {
            const result = memoryConfirmation(options);
            assert.equal(result.verdict, "retention_signal");
            assert.equal(result.passesCompleted, 2);
            assert.equal(result.cooldownMilliseconds, 10001);
            assert.equal(result.ratios.processPrivateMiB, 0.75);
            assert.equal(result.boundaries.pass1.start.liveTextures, 0);
            for (const boundary of Object.values(result.retainedBoundaries)) {
                assert.deepEqual(fs.readFileSync(path.join(options.root, boundary.receipt)),
                    fs.readFileSync(path.join(options.root, boundary.source)));
            }
            assert.deepEqual(memoryConfirmation(options), result);
            const report = memoryReport(result);
            assert.match(report, /Pass 2 \/ pass 1 growth/);
            assert.match(report, /System commit MiB/);
            assert.match(report, /Memory pressure \| Normal/);
            assert.match(report, /"retentionPredicate": true/);
        });
    }
    for (const [settings, verdict] of [
        [{ p2Growth: 25, resourceGrowth: 0 }, "initialization_dominated"],
        [{ p2Growth: 26, resourceGrowth: 0 }, "inconclusive"],
        [{ p2Growth: 74 }, "inconclusive"],
        [{ p1Growth: 0, p2Growth: 0, resourceGrowth: 0 }, "inconclusive"],
        [{ p1Growth: -10, p2Growth: 0, resourceGrowth: 0 }, "inconclusive"],
    ]) withFixture(settings, options => {
        const result = memoryConfirmation(options);
        assert.equal(result.verdict, verdict);
        if (settings.p1Growth <= 0) assert.equal(result.ratios.processPrivateMiB, null);
    });
    withFixture({}, options => {
        fs.unlinkSync(options.files.pass2_end);
        const result = memoryConfirmation(options);
        assert.equal(result.verdict, "inconclusive");
        assert.equal(result.predicateInputs.available, false);
        assert.deepEqual(result.unavailableBoundaries, ["pass2_end"]);
        assert.equal(result.deltas.pass2.liveTextures, null);
        assert.equal(result.outcome, "n/a");
        assert.match(memoryReport(result), /n\.d/);
    });
    withFixture({}, options => {
        options.liveResult.status = "INTERRUPTED";
        options.liveResult.lanes[0].passes[1].status = "INTERRUPTED";
        const result = memoryConfirmation(options);
        assert.equal(result.passesCompleted, 2);
        assert.equal(result.verdict, "retention_signal");
        assert.equal(result.completionSource, "fixed_matrix_receipt_coverage");
    });
    for (const duplicate of [false, true]) withFixture({}, options => {
        const missing = options.retained.pop();
        if (duplicate) options.retained.push({ ...options.retained.at(-1) });
        const result = memoryConfirmation(options);
        assert.equal(result.passesCompleted, 1);
        assert.equal(result.verdict, "repeat_not_completed");
        assert.deepEqual(result.coverage[1].unavailableTransitions, [missing.ordinal]);
        assert.equal(result.deltas.pass2.processPrivateMiB, 75);
        assert.equal(result.conclusion, "no_leak_or_retention_conclusion_possible");
    });
    withFixture({ legacy: true }, options => {
        fs.mkdirSync(path.join(options.root, "raw/lane-nvidia/pass-1/transitions"), { recursive: true });
        assert.equal(memoryConfirmation(options).verdict, "retention_signal");
    });
    for (const lanes of [null, {}, []]) withFixture({}, options => {
        options.liveResult.lanes = lanes;
        assert.equal(memoryConfirmation(options).verdict, "retention_signal");
    });
    withFixture({}, options => {
        options.liveResult.lanes.push(options.liveResult.lanes[0]);
        const result = memoryConfirmation(options);
        assert.equal(result.predicateInputs.available, false);
        assert.ok(result.issues.includes("duplicate_live_result_lane"));
    });
    for (const mutate of [
        value => { value.results[0].result.producer.buildId = "foreign"; },
        value => { value.results[0].result.status.session.id = 99; },
        value => { value.results[0].result.status.session.startFrame += 1; },
        value => { value.results[0].result.status.session.active = false; },
        value => { value.results[0].result.status.controller.memory.sampleFrame = 199; },
        value => { delete value.results[0].result.status.controller.memory.sampleFrame; },
        value => { value.results[0].result.status.controller.memory.systemCommitValid = false; },
        value => { value.results[0].ok = false; },
        value => { value.results[0].result.ok = false; },
        value => { value.results[0].result.error = "capture_failed"; },
        value => { value.results[1].result.producer.buildId = "foreign"; },
        value => { value.results[1].result.capture.active = false; },
        value => { value.results[1].result.capture.sessionID = 99; },
        value => { value.results[1].result.capture.droppedTextureRecords = 1; },
        value => { delete value.results[1].result.capture.outstandingEstimatedBytes; },
    ]) withFixture({}, options => {
        changeBoundary(options, "pass2_end", mutate);
        const result = memoryConfirmation(options);
        assert.equal(result.verdict, "inconclusive");
        assert.equal(result.predicateInputs.available, false);
        assert.equal(result.predicateInputs.initializationPredicate, null);
        assert.ok(result.issues.length > 0);
    });
    withFixture({}, options => {
        changeBoundary(options, "cooldown_end", value => {
            value.results[0].result.status.controller.memory.sampleFrame = 180;
        });
        const result = memoryConfirmation(options);
        assert.equal(result.predicateInputs.available, false);
        assert.equal(result.deltas.cooldown.processPrivateMiB, null);
        assert.ok(result.issues.includes("cooldown_end:memory_sample_frame_regression"));
    });
    for (const change of [value => { value.stepsRun = 2; },
        value => { value.results[0].ok = false; },
        value => { value.results[0].elapsedMs = 9999; }]) withFixture({}, options => {
        const file = path.join(options.root, "raw/lane-nvidia/pass-1/cooldown.json");
        const wait = JSON.parse(fs.readFileSync(file, "utf8"));
        change(wait);
        writeJson(file, wait);
        assert.equal(memoryConfirmation(options).predicateInputs.available, false);
    });
    withFixture({}, options => {
        const result = memoryConfirmation(options);
        const copy = path.join(options.root, result.retainedBoundaries.pass1_start.receipt);
        fs.writeFileSync(copy, '{"preservedMeasurement":123}');
        const conflicted = memoryConfirmation(options);
        assert.equal(conflicted.outcome, "n/a");
        assert.equal(conflicted.retainedBoundaries.pass1_start.receipt,
            conflicted.retainedBoundaries.pass1_start.source);
        assert.ok(conflicted.issues.includes("pass1_start:memory_boundary_copy_conflict"));
        assert.equal(fs.readFileSync(copy, "utf8"), '{"preservedMeasurement":123}');
    });
    withFixture({ variant: "amd", lane: "explicit_fsr4" }, options => {
        const peer = writeMemoryFixture(options.root, { variant: "amd", lane: "explicit_fsr3",
            p2Growth: 25, resourceGrowth: 0 });
        options.liveResult.lanes.push(...peer.liveResult.lanes);
        options.retained.push(...peer.retained);
        const result = memoryConfirmation(options);
        assert.equal(result.verdict, "per_lane");
        assert.equal(result.lanes.explicit_fsr4.verdict, "retention_signal");
        assert.equal(result.lanes.explicit_fsr3.verdict, "initialization_dominated");
        assert.equal(result.lanes.fsr4_to_fsr3_fallback.verdict, "repeat_not_completed");
        assert.match(result.lanes.explicit_fsr4.retainedBoundaries.pass1_start.receipt,
            /^raw\/memory\/explicit_fsr4\//);
    });
}

if (require.main === module) {
    testMemoryConfirmation();
    process.stdout.write("Render-scale memory confirmation tests passed.\n");
}

module.exports = { writeMemoryFixture, testMemoryConfirmation };
