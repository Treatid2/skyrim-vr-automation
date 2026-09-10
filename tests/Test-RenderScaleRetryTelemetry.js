// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const assert = require("node:assert/strict");
const { retryTelemetry } = require("../tools/renderscale-tuning-finalizer/retry-telemetry.js");

function fixture() {
    const guard = { guardStartFrame: 11, minimumSettleFrames: 6,
        guardDeadlineFrame: 17, stableCycles: 2, requiredStableCycles: 2,
        proofDrivenRelease: false, settleGuardRequired: true };
    const viewport = role => ({ role, slot: 1, cacheHit: false,
        victimQuality: 3, victimPreset: 1, fenceResult: "Pending" });
    const events = [
        { event: "GuardArmed", timestampQpc: 110, frame: 11, ...guard },
        { event: "ViewportWaitBegin", timestampQpc: 120, frame: 12, viewport: viewport("FullEye") },
        { event: "Retry", timestampQpc: 121, frame: 12, retryKind: "Backend",
            reason: "dlss_viewport_recycle", sourceFile: "Upscaling.cpp", sourceLine: 100 },
        { event: "ViewportWaitEnd", timestampQpc: 130, frame: 13,
            reason: "viewport_preparation_ready", beginSequence: 2, beginQpc: 120, beginFrame: 12,
            pendingObservations: 2, viewport: { ...viewport("FullEye"), fenceResult: "Ready" } },
        { event: "ViewportReady", timestampQpc: 135, frame: 14,
            viewport: { ...viewport("SubmitStageFoveatedCenter"), cacheHit: true, fenceResult: "NotPolled" } },
        { event: "SettleGuardSatisfied", timestampQpc: 170, frame: 17, ...guard },
        { event: "PromotionCandidate", timestampQpc: 180, frame: 18, ...guard },
        { event: "Promoted", timestampQpc: 190, frame: 19, ...guard },
        { event: "Stable", timestampQpc: 200, frame: 20 },
    ].map((event, index) => ({ sequence: index + 1, sessionId: 1, requestId: 2,
        transitionEpoch: 3, generation: 5, reason: "observed", ...event }));
    return { waiter: { baseline: { stressSessionId: 1 },
        timing: { dispatchTick: 100, tickFrequency: 1000, strictSatisfiedTick: 210 },
        replacementTimeline: { firstPhysicalMutation: { replacementRequestId: 2, replacementTransitionEpoch: 3 },
            terminal: { replacementRequestId: 2, replacementTransitionEpoch: 3, tick: 210 } },
        status: { retryTelemetry: { schemaVersion: 1, devBenchOnly: true, sessionId: 1,
            qpcFrequency: 1000, capacity: 1024, retainedEvents: events.length,
            overwrittenEvents: 0, coalescedEvents: 0, events } } } };
}

function testRetryTelemetry() {
    const value = fixture();
    let result = retryTelemetry(value);
    assert.equal(result.status, "complete");
    assert.equal(result.outcome, "available");
    assert.equal(result.retryCount, 1);
    assert.equal(result.waits[0].observedWaitMs, 10);
    assert.equal(result.retries[0].retryToStableMs, 79);
    assert.equal(result.stabilization[0].readyToCandidateMs, 45);
    assert.equal(result.stabilization[0].candidateToPromotionMs, 10);

    for (const corrupt of [
        capture => { capture.retainedEvents--; },
        capture => { capture.events[2].sequence = capture.events[1].sequence; },
        capture => { capture.events[2].timestampQpc = 119; },
        capture => { capture.events[2].sourceFile = ""; },
        capture => { capture.events[2].frame = -1; },
        capture => { capture.events[2] = null; },
        capture => { capture.events[2].event = 42; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry);
        result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.outcome, "n/a");
        assert.equal(result.retryCount, null);
        assert.ok(result.waits.every(wait => wait.observedWaitMs === null));
        assert.ok(result.stabilization.every(entry => entry.readyToCandidateMs === null));
    }
    for (const corrupt of [
        events => { events[3].generation = 6; },
        events => { events[3].beginFrame++; },
        events => { events[3].pendingObservations = 0; },
        events => { events[3].event = "RelatchAdmitted"; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry.events);
        result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, 1, "A missing wait endpoint must not erase a verified retry count.");
        assert.equal(result.waits[0].observedWaitMs, null);
        assert.equal(result.stabilization[0].readyToCandidateMs, null);
    }
    for (const corrupt of [
        events => { events[0].event = "GuardCleared"; },
        events => { events[5].frame = 16; },
        events => { events[6].guardDeadlineFrame = 16; },
        events => { events[6].stableCycles = 1; },
        events => { events[7].event = "GuardCleared"; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry.events);
        result = retryTelemetry(bad);
        assert.equal(result.stabilization[0].status, "incomplete");
        assert.equal(result.stabilization[0].readyToCandidateMs, null);
        assert.equal(result.stabilization[0].candidateToPromotionMs, null);
    }
    const overflow = fixture(), capture = overflow.waiter.status.retryTelemetry;
    capture.overwrittenEvents = 5;
    capture.capacity = capture.events.length;
    capture.events.forEach(event => { event.sequence += 5; if (event.beginSequence) event.beginSequence += 5; });
    assert.equal(retryTelemetry(overflow).retryCount, null);
    capture.events.unshift({ ...capture.events[0], sequence: 6, timestampQpc: 50,
        frame: 5, event: "Applied", requestId: 99 });
    capture.events.slice(1).forEach(event => { event.sequence++; if (event.beginSequence) event.beginSequence++; });
    capture.retainedEvents++;
    capture.capacity++;
    result = retryTelemetry(overflow);
    assert.equal(result.status, "complete", "Old overwritten events outside the covered window are not a current gap.");
    assert.equal(result.retryCount, 1);

    const changedOwner = fixture();
    changedOwner.waiter.replacementTimeline.firstPhysicalMutation.replacementRequestId = 98;
    assert.equal(retryTelemetry(changedOwner).retryCount, null);
    assert.equal(retryTelemetry(null).status, "not_exposed");
    assert.equal(retryTelemetry(null).outcome, "n/a");
}

if (require.main === module) {
    testRetryTelemetry();
    process.stdout.write("Render-scale retry telemetry tests passed.\n");
}
module.exports = { fixture, testRetryTelemetry };
