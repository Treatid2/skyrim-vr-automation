// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { amdLaneAvailability } = require("../renderscale-tuning-live/runner.js");
const { envelope, step } = require("./switch-health.js");

const boundarySources = {
    pass1_start: "pass-1/handoff.json",
    pass1_end: "pass-1/finalization/final-status-before-cleanup.json",
    cooldown_start: "pass-1/cooldown-start.json",
    cooldown_end: "pass-1/cooldown-end.json",
    pass2_start: "pass-2/handoff.json",
    pass2_end: "pass-2/finalization/final-status-before-cleanup.json",
};
const metrics = {
    processPrivateMiB: "Process private MiB",
    systemCommitMiB: "System commit MiB",
    dxgiUsageMiB: "DXGI process usage MiB",
    memoryPressure: "Memory pressure",
    liveTextures: "Live tracked textures",
    liveTextureMiB: "Estimated live tracked texture MiB",
};
const numericMetrics = Object.keys(metrics).filter(key => key !== "memoryPressure");
const trackerCounters = ["droppedTextureRecords", "recordingFailures",
    "attachFailures", "sentinelAllocationFailures", "outstandingUnknownEstimateCount"];
const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
const sessionId = value => Number.isSafeInteger(value) && value > 0 ? value : null;
const relative = (root, file) => path.relative(root, file).split(path.sep).join("/");
const emptyMetrics = () => Object.fromEntries(Object.keys(metrics).map(key => [key, null]));

function readEnvelope(file) {
    let value = JSON.parse(fs.readFileSync(file, "utf8"));
    while (Array.isArray(value?.content)) {
        if (value.isError) throw new Error("mcp_error");
        const texts = value.content.filter(item => item.type === "text");
        if (texts.length !== 1) throw new Error("ambiguous_envelope");
        value = JSON.parse(texts[0].text);
    }
    return value;
}

function toolResult(envelope, label, action, buildId, issues) {
    const steps = Array.isArray(envelope?.results) ?
        envelope.results.filter(step => step?.label === label) : [];
    const step = steps.length === 1 ? steps[0] : null;
    if (!step || step.ok !== true || step.tool !== "communityshaders.renderscale" ||
        step.isError === true || step.result?.ok === false || step.result?.isError === true ||
        step.result?.error ||
        step.result?.action !== action || step.result.producer?.buildId !== buildId) {
        issues.push(`${label}:missing_or_invalid_producer`);
        return null;
    }
    return step.result;
}

function readBoundary(options, base, lane, name) {
    const { root, variant, buildId, writeAtomic } = options;
    const source = path.join(base, boundarySources[name]);
    const copy = path.join(root, "raw/memory", ...(variant === "amd" ? [lane] : []),
        `${name}.json`);
    const boundary = { source: relative(root, source), receipt: null,
        stressSessionId: null, stressStartFrame: null, textureSessionId: null, sampleFrame: null,
        metrics: emptyMetrics(), trackerDiagnostics: {}, issues: [] };
    if (!fs.existsSync(source)) {
        boundary.issues.push("boundary_receipt_missing");
        return boundary;
    }
    const bytes = fs.readFileSync(source);
    boundary.receipt = relative(root, copy);
    if (fs.existsSync(copy)) {
        if (!fs.readFileSync(copy).equals(bytes)) {
            boundary.issues.push("memory_boundary_copy_conflict");
            boundary.receipt = boundary.source;
        }
    } else {
        fs.mkdirSync(path.dirname(copy), { recursive: true });
        writeAtomic(copy, bytes);
    }
    let envelope;
    try { envelope = readEnvelope(source); }
    catch (error) {
        boundary.issues.push(`boundary_decode_failed:${error.message}`);
        return boundary;
    }
    const start = name === "pass1_start" || name === "pass2_start";
    const render = toolResult(envelope, start ? "measured-stress-start" : "render-status",
        start ? "start" : "status", buildId, boundary.issues)?.status;
    const texture = toolResult(envelope, start ? "texture-lifetime-start" : "texture-status",
        start ? "texture_lifetime_start" : "texture_lifetime_status",
        buildId, boundary.issues)?.capture;
    boundary.stressSessionId = sessionId(render?.session?.id);
    boundary.stressStartFrame = nonnegative(render?.session?.startFrame) ? render.session.startFrame : null;
    boundary.textureSessionId = sessionId(texture?.sessionID);
    if (boundary.stressSessionId === null) boundary.issues.push("stress_session_missing");
    if (boundary.textureSessionId === null) boundary.issues.push("texture_session_missing");
    const memory = render?.controller?.memory;
    boundary.sampleFrame = nonnegative(memory?.sampleFrame) ? memory.sampleFrame : null;
    const validSampleFrame = boundary.sampleFrame !== null && boundary.stressStartFrame !== null &&
        boundary.sampleFrame >= boundary.stressStartFrame;
    if (!validSampleFrame) boundary.issues.push("memory_sample_frame_invalid");
    const expectedActive = !name.startsWith("cooldown");
    if (render?.session?.active !== expectedActive) boundary.issues.push("stress_capture_state_mismatch");
    if (texture?.active !== expectedActive) boundary.issues.push("texture_capture_state_mismatch");
    const mib = (value, valid) => valid === true && nonnegative(value) ? value / 1048576 : null;
    if (boundary.stressSessionId !== null && validSampleFrame && render.session.active === expectedActive) {
        boundary.metrics.processPrivateMiB = mib(memory?.processPrivateUsageBytes,
            memory?.processPrivateUsageValid);
        boundary.metrics.systemCommitMiB = mib(memory?.systemCommitBytes, memory?.systemCommitValid);
        boundary.metrics.dxgiUsageMiB = mib(memory?.usageBytes, memory?.valid);
        boundary.metrics.memoryPressure = memory?.valid === true &&
            typeof memory.pressure === "string" && memory.pressure.length > 0 ? memory.pressure : null;
    }
    if (boundary.textureSessionId !== null && texture?.supported === true && texture.active === expectedActive) {
        boundary.metrics.liveTextures = nonnegative(texture.liveTextureRecordCount) ?
            texture.liveTextureRecordCount : null;
        boundary.metrics.liveTextureMiB = mib(texture.outstandingEstimatedBytes, true);
    }
    for (const key of trackerCounters) {
        boundary.trackerDiagnostics[key] = nonnegative(texture?.[key]) ? texture[key] : null;
        if (boundary.trackerDiagnostics[key] !== 0) boundary.issues.push(`texture_tracking_incomplete:${key}`);
    }
    return boundary;
}

function validateSessions(boundaries, retained, lane, variant) {
    for (const pass of [1, 2]) {
        const names = pass === 1 ? ["pass1_start", "pass1_end", "cooldown_start", "cooldown_end"] :
            ["pass2_start", "pass2_end"];
        const rows = retained.filter(row => row.pass === pass &&
            (row.lane === lane || variant === "nvidia" && row.lane === null));
        const stressIds = new Set(rows.map(row => row.stressSessionId));
        const start = boundaries[`pass${pass}_start`];
        for (const name of names) {
            const boundary = boundaries[name];
            if (boundary.stressSessionId !== null &&
                (start.stressSessionId !== null && (boundary.stressSessionId !== start.stressSessionId ||
                    boundary.stressStartFrame !== start.stressStartFrame) ||
                    stressIds.size > 0 && (stressIds.size !== 1 || !stressIds.has(boundary.stressSessionId)))) {
                boundary.issues.push("stress_session_mismatch");
                for (const key of ["processPrivateMiB", "systemCommitMiB", "dxgiUsageMiB", "memoryPressure"]) {
                    boundary.metrics[key] = null;
                }
            }
            if (boundary.textureSessionId !== null && start.textureSessionId !== null &&
                boundary.textureSessionId !== start.textureSessionId) {
                boundary.issues.push("texture_session_mismatch");
                boundary.metrics.liveTextures = boundary.metrics.liveTextureMiB = null;
            }
        }
    }
    const first = boundaries.pass1_start, second = boundaries.pass2_start;
    if (first.textureSessionId !== null && first.textureSessionId === second.textureSessionId) {
        second.issues.push("texture_tracker_not_reset_for_repeat");
    }
    if (first.stressSessionId !== null && first.stressSessionId === second.stressSessionId) {
        second.issues.push("stress_session_not_reset_for_repeat");
    }
    let previousFrame = null;
    for (const name of Object.keys(boundarySources)) {
        const boundary = boundaries[name];
        if (boundary.sampleFrame !== null) {
            if (previousFrame !== null && boundary.sampleFrame < previousFrame) {
                boundary.issues.push("memory_sample_frame_regression");
                boundary.metrics = emptyMetrics();
            }
            previousFrame = Math.max(previousFrame ?? 0, boundary.sampleFrame);
        }
    }
}

function cooldownDuration(base) {
    const file = path.join(base, "pass-1/cooldown.json");
    if (!fs.existsSync(file)) return null;
    let value;
    try { value = readEnvelope(file); } catch { return null; }
    const wait = value?.results?.[0];
    return value?.ok === true && value.aborted === false && Array.isArray(value.results) &&
        value.stepsRun === 1 && value.results.length === 1 && wait?.kind === "wait" &&
        wait.ok !== false && wait.isError !== true && wait.ms === 10000 &&
        nonnegative(wait.elapsedMs) ? wait.elapsedMs : null;
}

function confirmLane(options, lane, matrix) {
    const { root, variant, liveResult, retained } = options;
    const modern = path.join(root, "raw", `lane-${lane}`);
    // A legacy NVIDIA directory is unambiguous; AMD boundaries always need a lane.
    const hasModernBoundaries = Object.values(boundarySources).some(source =>
        fs.existsSync(path.join(modern, source)));
    const base = variant === "nvidia" && !hasModernBoundaries ? path.join(root, "raw") : modern;
    const retainedBoundaries = Object.fromEntries(Object.keys(boundarySources).map(name =>
        [name, readBoundary(options, base, lane, name)]));
    validateSessions(retainedBoundaries, retained, lane, variant);
    const laneResults = Array.isArray(liveResult?.lanes) ? liveResult.lanes.filter(value => value?.id === lane) : [];
    const laneResult = laneResults.length === 1 ? laneResults[0] : null;
    // Worker cleanup/cooldown errors can relabel a fully measured pass INTERRUPTED.
    const coverage = [1, 2].map(pass => {
        const rows = retained.filter(row => row.pass === pass &&
            (row.lane === lane || variant === "nvidia" && row.lane === null));
        const ordinals = rows.map(row => row.ordinal);
        const complete = ordinals.length === matrix.transitions.length && new Set(ordinals).size === ordinals.length &&
            matrix.transitions.every(row => ordinals.includes(row.ordinal));
        return { pass, complete, retainedTransitions: ordinals.length,
            expectedTransitions: matrix.transitions.length,
            unavailableTransitions: matrix.transitions.filter(row => !ordinals.includes(row.ordinal)).map(row => row.ordinal) };
    });
    const completedPasses = coverage.filter(pass => pass.complete).map(pass => pass.pass);
    const boundaries = {}, deltas = {};
    for (const group of ["pass1", "cooldown", "pass2"]) {
        const start = retainedBoundaries[`${group}_start`].metrics;
        const end = retainedBoundaries[`${group}_end`].metrics;
        deltas[group] = Object.fromEntries(numericMetrics.map(key => [key,
            start[key] !== null && end[key] !== null ? end[key] - start[key] : null]));
        boundaries[group] = { start, end, delta: deltas[group] };
    }
    const ratios = Object.fromEntries(numericMetrics.map(key => [key,
        deltas.pass1[key] > 0 && deltas.pass2[key] !== null ? deltas.pass2[key] / deltas.pass1[key] : null]));
    const unavailableBoundaries = Object.entries(retainedBoundaries)
        .filter(([, boundary]) => boundary.receipt === null).map(([name]) => name);
    const issues = Object.entries(retainedBoundaries).flatMap(([name, boundary]) => [
        ...boundary.issues.map(reason => `${name}:${reason}`),
        ...Object.keys(metrics).filter(key => boundary.metrics[key] === null).map(key => `${name}:${key}:unavailable`),
    ]);
    for (const pass of coverage) {
        if (!pass.complete) issues.push(`pass${pass.pass}:matrix_receipts_incomplete_or_duplicated`);
    }
    if (laneResults.length > 1) issues.push("duplicate_live_result_lane");
    const cooldownMilliseconds = cooldownDuration(base);
    if (cooldownMilliseconds === null) issues.push("cooldown_wait_missing_or_invalid");
    else if (cooldownMilliseconds < 10000) issues.push("cooldown_wait_incomplete");
    const repeatCompleted = completedPasses.length === 2;
    const available = repeatCompleted && issues.length === 0;
    const positivePass1PrivateAndCommit = available ?
        deltas.pass1.processPrivateMiB > 0 && deltas.pass1.systemCommitMiB > 0 : null;
    const pass2ResourceGrowth = available ? ["dxgiUsageMiB", "liveTextures", "liveTextureMiB"]
        .some(key => deltas.pass2[key] > 0) : null;
    const retentionPredicate = available ? positivePass1PrivateAndCommit &&
        ratios.processPrivateMiB >= 0.75 && ratios.systemCommitMiB >= 0.75 && pass2ResourceGrowth : null;
    const initializationPredicate = available ? positivePass1PrivateAndCommit &&
        ratios.processPrivateMiB <= 0.25 && ratios.systemCommitMiB <= 0.25 && !pass2ResourceGrowth : null;
    const verdict = !repeatCompleted ? "repeat_not_completed" : retentionPredicate ? "retention_signal" :
        initializationPredicate ? "initialization_dominated" : "inconclusive";
    return { lane, status: available ? "complete" : "incomplete",
        laneExecutionStatus: laneResult?.status || "not_exposed",
        passesCompleted: completedPasses.length, completedPasses, coverage,
        completionSource: "fixed_matrix_receipt_coverage",
        cooldownMilliseconds, boundaries, retainedBoundaries, deltas, ratios,
        predicateInputs: { available, reason: !repeatCompleted ? "repeat_not_completed" :
            available ? null : "memory_evidence_incomplete", pass1: deltas.pass1, pass2: deltas.pass2,
            positivePass1PrivateAndCommit, pass2ResourceGrowth, retentionPredicate, initializationPredicate },
        unavailableBoundaries, issues, verdict, outcome: available ? verdict : "n/a",
        conclusion: available ? "classification_is_not_proof_for_or_against_a_leak" :
            "no_leak_or_retention_conclusion_possible",
        textureScope: "Growth is relative to the freshly reset tracker in each pass; session IDs are retained.",
    };
}

function memoryConfirmation(options) {
    const matrix = JSON.parse(fs.readFileSync(path.join(__dirname, "../../skills",
        `renderscale-tuning-${options.variant}/references/matrix.v1.json`), "utf8"));
    if (options.variant === "nvidia") return confirmLane(options, "nvidia", matrix);
    const position = envelope(path.join(options.root, "raw/startup/positioning.json"));
    const capabilities = step(position, "position-capabilities")?.capabilities;
    const lanes = Object.fromEntries(matrix.lanes.map(lane => {
        const result = confirmLane(options, lane.id, matrix);
        const live = options.liveResult?.lanes?.filter(value => value.id === lane.id) || [];
        const entry = live.length === 1 ? live[0] : null;
        const eligibility = amdLaneAvailability(lane, capabilities);
        const blocked = entry?.status === "BLOCKED" && eligibility.runnable === false &&
            Array.isArray(entry.passes) && entry.passes.length === 0 &&
            result.coverage.every(pass => pass.retainedTransitions === 0) &&
            result.unavailableBoundaries.length === Object.keys(boundarySources).length;
        result.applicability = { status: blocked ? "NOT_APPLICABLE" : "APPLICABLE", eligibility,
            reason: blocked ? eligibility.reason : null };
        if (blocked) {
            result.status = "not_applicable";
            result.verdict = "lane_blocked";
            result.predicateInputs.reason = "lane_blocked_by_retained_capabilities";
            result.unavailableEvidence = result.issues;
            result.issues = [];
        }
        return [lane.id, result];
    }));
    return { mode: "per_lane", verdict: "per_lane",
        status: Object.values(lanes).every(lane => ["complete", "not_applicable"].includes(lane.status)) ? "complete" : "incomplete", lanes };
}

function memoryReport(confirmation) {
    const lanes = confirmation.mode === "per_lane" ? Object.values(confirmation.lanes) : [confirmation];
    const display = value => value === null ? "n.d." : typeof value === "number" ?
        String(Number(value.toFixed(3))) : String(value).replaceAll("|", "\\|").replaceAll("\n", " ");
    return "## Memory confirmation\n\n" + lanes.map(lane => {
        const rows = Object.entries(metrics).map(([key, label]) => {
            const cells = [label];
            for (const group of ["pass1", "cooldown", "pass2"]) {
                cells.push(...[lane.boundaries[group].start[key], lane.boundaries[group].end[key],
                    lane.deltas[group][key] ?? null].map(display));
            }
            cells.push(display(lane.ratios[key] ?? null));
            return `| ${cells.join(" | ")} |`;
        }).join("\n");
        return `### ${lane.lane}\n\n` +
            `Memory outcome: **${lane.outcome}** (${lane.verdict}); completed passes: ${lane.passesCompleted}/2; ` +
            `cooldown: ${display(lane.cooldownMilliseconds)} ms.\n\n` +
            `| Metric | Pass 1 start | Pass 1 end | Pass 1 delta | Cooldown start | Cooldown end | Cooldown delta | Pass 2 start | Pass 2 end | Pass 2 delta | Pass 2 / pass 1 growth |\n` +
            `| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n${rows}\n\n` +
            `Predicate inputs (unrounded):\n\n\x60\x60\x60json\n${JSON.stringify(lane.predicateInputs, null, 2)}\n\x60\x60\x60\n\n` +
            `Conclusion: ${lane.conclusion}. ${lane.textureScope}\n\n` +
            `Evidence gaps: ${lane.issues.length ? lane.issues.join("; ") : "none"}.\n\n`;
    }).join("");
}

module.exports = { memoryConfirmation, memoryReport };
