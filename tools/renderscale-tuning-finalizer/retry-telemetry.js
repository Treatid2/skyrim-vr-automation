// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const positive = value => Number.isSafeInteger(value) && value > 0;
const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
const eventTypes = new Set(["Retry", "RelatchAdmitted", "Applied", "Stable", "Failure",
    "ViewportReady", "ViewportWaitBegin", "ViewportWaitEnd", "GuardArmed", "ProofRevoked",
    "SettleGuardSatisfied", "PromotionCandidate", "Promoted", "GuardCleared"]);
const viewportRoles = new Set(["FullEye", "FoveatedCenter", "SubmitStageFoveatedCenter"]);

// Cumulative snapshots are read only after measurement, from the owned waiter.
function retryTelemetry(retained) {
    const waiter = retained?.waiter || {};
    const capture = waiter.status && waiter.status.retryTelemetry ||
        waiter.observation && waiter.observation.status &&
            waiter.observation.status.retryTelemetry || retained?.retryTelemetry;
    const unavailable = reason => ({ status: reason, outcome: "n/a", reasons: [reason],
        retryCount: null, retryReasons: [], retries: [], waits: [],
        stabilization: [], events: [] });
    if (!capture) return unavailable("not_exposed");
    if (capture.schemaVersion !== 1 || capture.devBenchOnly !== true ||
        !Array.isArray(capture.events)) return unavailable("unsupported_schema");
    const sessionId = waiter.baseline && waiter.baseline.stressSessionId;
    const timing = waiter.timing || {};
    if (!positive(sessionId) || capture.sessionId !== sessionId) {
        return unavailable("session_mismatch");
    }
    if (!positive(capture.qpcFrequency) ||
        capture.qpcFrequency !== timing.tickFrequency ||
        !positive(timing.dispatchTick)) return unavailable("clock_unavailable");
    const timeline = waiter.replacementTimeline || retained?.replacementTimeline || {};
    const terminal = timeline.terminal || {};
    const mutation = timeline.firstPhysicalMutation || {};
    const owner = positive(terminal.replacementRequestId) && positive(terminal.replacementTransitionEpoch) ?
        terminal : mutation;
    const requestId = owner.replacementRequestId;
    const epoch = owner.replacementTransitionEpoch;
    if (!positive(requestId) || !positive(epoch)) return unavailable("owner_unavailable");
    const reasons = [];
    if (positive(mutation.replacementRequestId) && positive(mutation.replacementTransitionEpoch) &&
        (mutation.replacementRequestId !== requestId || mutation.replacementTransitionEpoch !== epoch)) {
        reasons.push("transition_owner_changed");
    }
    if (!positive(capture.capacity) || !nonnegative(capture.overwrittenEvents) ||
        capture.retainedEvents !== capture.events.length || capture.events.length > capture.capacity ||
        capture.overwrittenEvents > 0 && capture.events.length !== capture.capacity ||
        capture.coalescedEvents !== 0) reasons.push("invalid_retention_metadata");
    let sequence = capture.overwrittenEvents, lastTick = 0;
    for (const event of capture.events) {
        if (!event || event.sessionId !== sessionId || !positive(event.requestId) ||
            !positive(event.transitionEpoch) || !positive(event.sequence) ||
            event.sequence !== sequence + 1 || !positive(event.timestampQpc) || !nonnegative(event.frame) ||
            !eventTypes.has(event.event) || typeof event.reason !== "string" || event.reason.length === 0 ||
            (event.event === "Retry" && (typeof event.sourceFile !== "string" ||
                !event.sourceFile.length || !positive(event.sourceLine) ||
                typeof event.retryKind !== "string" || !event.retryKind.length)) ||
            (event.event.startsWith("Viewport") && (!viewportRoles.has(event.viewport?.role) ||
                !nonnegative(event.generation)))) {
            reasons.push("invalid_event");
        }
        if (event?.timestampQpc < lastTick) reasons.push("event_clock_regression");
        sequence = event?.sequence;
        lastTick = event?.timestampQpc;
    }
    const endTick = positive(terminal.tick) ? terminal.tick : timing.strictSatisfiedTick;
    if (!positive(endTick) || endTick < timing.dispatchTick) return unavailable("terminal_clock_unavailable");
    if (capture.overwrittenEvents > 0 &&
        !(capture.events[0]?.timestampQpc < timing.dispatchTick)) reasons.push("events_overwritten_in_window");
    const events = capture.events.filter(event => event && event.sessionId === sessionId &&
        event.requestId === requestId && event.transitionEpoch === epoch && positive(event.timestampQpc) &&
        event.timestampQpc >= timing.dispatchTick && event.timestampQpc <= endTick);
    if (events.length === 0) reasons.push("owner_events_missing");
    const windowComplete = reasons.length === 0;
    const milliseconds = (begin, end) => windowComplete && positive(begin) && positive(end) && end >= begin ?
        (end - begin) * 1000 / capture.qpcFrequency : null;
    const waits = [];
    const ends = new Set();
    for (const begin of events.filter(event => event.event === "ViewportWaitBegin")) {
        const matches = events.filter(event => event.event === "ViewportWaitEnd" &&
            event.beginSequence === begin.sequence);
        const end = matches.length === 1 ? matches[0] : null;
        const sameOwner = end && end.generation === begin.generation &&
            end.viewport && begin.viewport && end.viewport.role === begin.viewport.role &&
            end.beginQpc === begin.timestampQpc && end.beginFrame === begin.frame &&
            positive(end.pendingObservations) && end.sequence > begin.sequence &&
            !(end.reason === "viewport_preparation_ready" && events.some(event =>
                event.sequence > begin.sequence && event.sequence < end.sequence &&
                (["GuardArmed", "GuardCleared"].includes(event.event) ||
                    event.event === "ViewportWaitBegin" && event.viewport?.role === begin.viewport?.role)));
        const duration = sameOwner ? milliseconds(begin.timestampQpc, end.timestampQpc) : null;
        const status = matches.length > 1 ? "duplicate_end" : !end ? "unresolved" : !sameOwner || duration === null ? "invalid_interval" :
            end.reason === "viewport_preparation_ready" ? "ready" : end.reason;
        if (end) ends.add(end.sequence);
        if (status !== "ready") reasons.push(`viewport_wait_${status}`);
        waits.push({ beginSequence: begin.sequence, endSequence: end && end.sequence,
            role: begin.viewport && begin.viewport.role, status,
            reason: begin.reason, slot: begin.viewport && begin.viewport.slot,
            cacheHit: begin.viewport && begin.viewport.cacheHit,
            victimQuality: begin.viewport && begin.viewport.victimQuality,
            victimPreset: begin.viewport && begin.viewport.victimPreset,
            firstFenceResult: begin.viewport && begin.viewport.fenceResult,
            finalFenceResult: end && end.viewport && end.viewport.fenceResult,
            pendingObservations: end && end.pendingObservations,
            observedWaitMs: status === "ready" ? duration : null,
            observedUntilClosureMs: duration });
    }
    if (events.some(event => event.event === "ViewportWaitEnd" && !ends.has(event.sequence))) {
        reasons.push("wait_begin_missing");
    }
    const retries = events.filter(event => event.event === "Retry").map(event => {
        const stable = events.find(next => next.sequence > event.sequence && next.event === "Stable");
        const admitted = event.reason === "render_target_relatch_requeued" &&
            events.find(next => next.sequence > event.sequence && next.event === "RelatchAdmitted");
        return { sequence: event.sequence, reason: event.reason, kind: event.retryKind,
            sourceFile: event.sourceFile, sourceLine: event.sourceLine,
            retryToStableMs: stable ? milliseconds(event.timestampQpc, stable.timestampQpc) : null,
            requeueToAdmissionMs: admitted ? milliseconds(event.timestampQpc, admitted.timestampQpc) : null };
    });
    const stabilization = events.filter(event => event.event === "PromotionCandidate").map(candidate => {
        const boundary = events.filter(event => ["GuardArmed", "GuardCleared"].includes(event.event) &&
            event.sequence < candidate.sequence).at(-1);
        const guard = boundary?.event === "GuardArmed" ? boundary : null;
        const segment = events.filter(event => guard && event.sequence > guard.sequence &&
            event.sequence < candidate.sequence);
        const viewportStates = new Map();
        for (const event of segment.filter(event => event.viewport)) viewportStates.set(event.viewport.role, event);
        const readiness = [...viewportStates.values()];
        const ready = readiness.length && readiness.every(event => event.event === "ViewportReady" ||
            waits.some(wait => wait.endSequence === event.sequence && wait.status === "ready")) ?
            readiness.reduce((latest, event) => event.sequence > latest.sequence ? event : latest) : null;
        const settled = segment.find(event => event.event === "SettleGuardSatisfied");
        const promotionBoundary = events.find(event => event.sequence > candidate.sequence &&
            ["Promoted", "GuardArmed", "GuardCleared", "PromotionCandidate"].includes(event.event));
        const promoted = promotionBoundary?.event === "Promoted" ? promotionBoundary : null;
        const gaps = [];
        if (!guard) gaps.push("guard_begin_missing");
        if (!promoted) gaps.push("promotion_missing");
        if (readiness.length && !ready) gaps.push("viewport_readiness_incomplete");
        if (!positive(candidate.guardStartFrame) || !nonnegative(candidate.minimumSettleFrames) ||
            candidate.frame < candidate.guardStartFrame ||
            !positive(candidate.requiredStableCycles) || !nonnegative(candidate.stableCycles) ||
            candidate.stableCycles < candidate.requiredStableCycles ||
            typeof candidate.proofDrivenRelease !== "boolean" || typeof candidate.settleGuardRequired !== "boolean" ||
            candidate.proofDrivenRelease && candidate.settleGuardRequired ||
            guard && candidate.guardStartFrame !== guard.guardStartFrame ||
            promoted && promoted.guardStartFrame !== candidate.guardStartFrame) gaps.push("invalid_guard_evidence");
        if (candidate.settleGuardRequired && (!settled ||
            candidate.guardDeadlineFrame !== candidate.guardStartFrame + candidate.minimumSettleFrames ||
            settled.settleGuardRequired !== true ||
            settled.guardStartFrame !== candidate.guardStartFrame ||
            settled.frame < candidate.guardDeadlineFrame || candidate.frame < candidate.guardDeadlineFrame)) {
            gaps.push("settle_guard_observation_missing_or_invalid");
        }
        reasons.push(...gaps);
        const duration = (begin, end) => gaps.length === 0 ? milliseconds(begin, end) : null;
        return { candidateSequence: candidate.sequence, status: windowComplete && !gaps.length ? "complete" : "incomplete",
            reasons: gaps,
            proofRevoked: segment.some(event => event.event === "ProofRevoked"),
            proofDrivenRelease: candidate.proofDrivenRelease,
            settleGuardRequired: candidate.settleGuardRequired,
            guardStartFrame: candidate.guardStartFrame,
            guardDeadlineFrame: candidate.guardDeadlineFrame,
            minimumSettleFrames: candidate.minimumSettleFrames,
            stableCycles: candidate.stableCycles, requiredStableCycles: candidate.requiredStableCycles,
            guardToCandidateMs: guard ? duration(guard.timestampQpc, candidate.timestampQpc) : null,
            readyToCandidateMs: ready ? duration(ready.timestampQpc, candidate.timestampQpc) : null,
            readyToGuardSatisfiedMs: ready && settled ? duration(ready.timestampQpc, settled.timestampQpc) : null,
            guardSatisfiedBeforeReady: ready && settled ? settled.timestampQpc < ready.timestampQpc : null,
            guardSatisfiedToCandidateMs: settled ? duration(settled.timestampQpc, candidate.timestampQpc) : null,
            candidateToPromotionMs: promoted ? duration(candidate.timestampQpc, promoted.timestampQpc) : null };
    });
    return { schemaVersion: 1, status: reasons.length ? "incomplete" : "complete",
        outcome: reasons.length ? "n/a" : "available",
        reasons: [...new Set(reasons)], sessionId, requestId, transitionEpoch: epoch,
        qpcFrequency: capture.qpcFrequency, overwrittenEvents: capture.overwrittenEvents,
        retryCount: windowComplete ? retries.length : null,
        observedRetryCount: retries.length, retryReasons: [...new Set(retries.map(event => event.reason))],
        retries, waits, stabilization, events };
}

module.exports = { retryTelemetry };
