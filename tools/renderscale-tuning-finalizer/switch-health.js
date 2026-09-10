// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const failureNames = ["deviceLost", "outOfMemory", "transition", "dlssLifecycle",
    "fsrLifecycle", "memoryTrim", "retirementFence", "fidelityMismatches"];
const presentationNames = ["vendorFailureStretchEyeObservations",
    "boundsMismatchFallbackEyeObservations"];
const number = value => Number.isFinite(value) && value >= 0 ? value : null;
const counter = value => Number.isSafeInteger(value) && value >= 0 ? value : null;

function envelope(file) {
    if (!fs.existsSync(file)) return null;
    let value = JSON.parse(fs.readFileSync(file, "utf8"));
    while (Array.isArray(value?.content)) {
        const texts = value.content.filter(item => item.type === "text");
        if (value.isError || texts.length !== 1) throw new Error("invalid_health_envelope");
        value = JSON.parse(texts[0].text);
    }
    return value;
}

function step(value, label) {
    const matches = (value?.results || []).filter(item => item.label === label);
    return matches.length === 1 && matches[0].ok !== false ? matches[0].result : null;
}

function statistics(values) {
    const samples = values.filter(value => number(value) !== null).sort((a, b) => a - b);
    if (!samples.length) return { count: 0, missing: values.length,
        total: null, mean: null, median: null, p95: null, maximum: null };
    const quantile = q => {
        const index = (samples.length - 1) * q, low = Math.floor(index);
        return samples[low] + (samples[Math.ceil(index)] - samples[low]) * (index - low);
    };
    const total = samples.reduce((sum, value) => sum + value, 0);
    return { count: samples.length, missing: values.length - samples.length,
        total, mean: total / samples.length, median: quantile(.5), p95: quantile(.95),
        maximum: samples.at(-1) };
}

function transitionHealth(waiter) {
    const delta = waiter.diagnostics?.delta;
    const counters = Object.fromEntries(failureNames.map(key =>
        [key, counter(delta?.failures?.[key])]));
    for (const key of presentationNames) counters[key] = counter(delta?.presentation?.[key]);
    const missing = Object.keys(counters).filter(key => counters[key] === null);
    const findings = Object.entries(counters).filter(([, value]) => value > 0)
        .map(([counterName, observations]) => ({ counter: counterName, observations }));
    return { status: findings.length ? "FINDINGS_PRESENT" : missing.length ?
        "INCONCLUSIVE" : "NO_COUNTED_FAILURES", counters, findings, missing,
    terminalRecovered: waiter.strictSatisfied === true,
    strictFailureReasons: waiter.strictFailureReasons ?? null,
    failureReasons: waiter.failureReasons ?? null,
    diagnosticsDelta: delta ?? null,
    stressSessionId: waiter.baseline?.stressSessionId ?? null,
    requestId: waiter.replacementTimeline?.terminal?.replacementRequestId ?? null,
    transitionEpoch: waiter.replacementTimeline?.terminal?.replacementTransitionEpoch ?? null,
    nativeVendorExecution: waiter.nativeVendorExecution ?? null };
}

function gateAssessment(gate, terminal) {
    if (gate.name === "presentation_stretch_frame_bound" && gate.limit?.maximumFrames === 2) return { ...gate,
        assessmentRole: "DIAGNOSTIC_ONLY",
        assessmentReason: "Fixed stretch cutoff is inapplicable to imposed settling; compare measured frames and duration." };
    const native = terminal?.target?.qualityMode === 0 && terminal?.target?.renderScaleMode === false &&
        ["dlss", "fsr"].includes(terminal?.target?.method) &&
        terminal?.switchHealth?.nativeVendorExecution?.required === true &&
        terminal.switchHealth.nativeVendorExecution.sameFrameBothEyesValid === true;
    if (gate.name === "presentation_recovered" && native && gate.limit?.path === "VendorEvaluated" &&
        gate.observed?.leftPath === "NativeOriginal" && gate.observed?.rightPath === "NativeOriginal")
        return { ...gate, assessmentRole: "CONTRACT_MISMATCH",
            assessmentReason: "Scaled-presentation gate conflicts with the proven native terminal target." };
    return { ...gate, assessmentRole: "HEALTH", assessmentReason: "Applicable observed health gate." };
}

function transitionTimings(waiter) {
    const start = waiter.replacementTimeline?.dispatch;
    const relatch = waiter.replacementTimeline?.firstNewGenerationProven;
    const frequency = waiter.timing?.tickFrequency;
    const relatchFrames = counter(relatch?.frame) !== null && counter(start?.frame) !== null &&
        relatch.frame >= start.frame ? relatch.frame - start.frame : null;
    const relatchMs = number(relatch?.tick) !== null && number(start?.tick) !== null &&
        relatch.tick >= start.tick && Number.isFinite(frequency) && frequency > 0 ?
            (relatch.tick - start.tick) * 1000 / frequency : null;
    return { definition: "qualification_dispatch_to_producer_milestone",
        unit: "ms", excludesPreDispatchWait: true,
        strictMs: number(waiter.strictElapsedMs),
        presentationMs: number(waiter.presentationElapsedMs),
        cleanupMs: number(waiter.cleanupElapsedMs),
        cleanupTailMs: number(waiter.milestoneTimings?.cleanupTailMs),
        strictFrames: counter(waiter.strictElapsedFrames),
        relatchProofFrames: relatchFrames, relatchProofMs: relatchMs,
        relatchDefinition: "qualification_dispatch_to_first_exact_new_generation_proven",
        relatchStatus: relatchMs !== null && relatchFrames !== null ? "MEASURED" :
            waiter.replacementTimeline?.mutationExpectation === "not_required" ? "NOT_APPLICABLE" : "NOT_EXPOSED",
        phases: waiter.phaseDurations ?? null, qpc: waiter.timing ?? null,
        milestones: waiter.milestoneTimings ?? null };
}

function metricFor(row, record, issues) {
    const matches = (record?.metrics || []).filter(metric =>
        metric.requestID === row.switchHealth.requestId &&
        metric.transitionEpoch === row.switchHealth.transitionEpoch);
    if (matches.length !== 1) {
        issues.push(`row_${row.ordinal}:owned_metric_missing_or_ambiguous`);
        return null;
    }
    const metric = matches[0];
    if (metric.fidelityMismatches !== row.switchHealth.counters.fidelityMismatches)
        issues.push(`row_${row.ordinal}:fidelity_counter_disagreement`);
    const diagnosticRetries = counter(row.switchHealth.diagnosticsDelta?.stress?.retryEvents);
    if (diagnosticRetries !== counter(metric.retries))
        issues.push(`row_${row.ordinal}:retry_counter_disagreement`);
    if (record.session.overwrittenEvents === 0) {
        const retries = (record.events || []).filter(event => event.type === "Retry" &&
            event.requestID === metric.requestID && event.transitionEpoch === metric.transitionEpoch);
        const total = retries.reduce((sum, event) => sum + (counter(event.occurrences) ?? NaN), 0);
        if (total !== metric.retries) issues.push(`row_${row.ordinal}:retry_event_disagreement`);
    } else issues.push(`row_${row.ordinal}:stress_event_overflow_or_unknown`);
    return metric;
}

function passHealth(root, rows, buildId) {
    const first = rows[0], issues = [];
    const passRoot = path.dirname(path.dirname(path.dirname(path.resolve(root, first.rawRetained))));
    const cleanupPath = path.join(passRoot, "finalization", "cleanup.json");
    const cleanup = envelope(cleanupPath);
    const before = envelope(path.join(passRoot, "finalization", "final-status-before-cleanup.json"));
    const record = step(cleanup, "measured-stress-stop")?.record;
    const observedRows = rows.filter(row => !row.switchHealth.receiptMissing);
    const owned = record?.producer?.buildId === buildId && record?.session?.active === false &&
        observedRows.length > 0 && observedRows.every(row => row.switchHealth.stressSessionId === record.session.id);
    if (!owned) issues.push("owned_stopped_stress_record_missing_or_mismatched");
    const acceptance = owned ? record.acceptance ?? null : null;
    if (typeof acceptance?.accepted !== "boolean" || !Array.isArray(acceptance?.gates))
        issues.push("stress_acceptance_missing");
    for (const row of rows) {
        const metric = owned ? metricFor(row, record, issues) : null;
        row.switchHealth.ownedMetric = metric;
        row.switchHealth.ownedRetryCount = counter(metric?.retries);
        row.switchHealth.retryCount = counter(metric?.retries) ??
            counter(row.switchHealth.diagnosticsDelta?.stress?.retryEvents);
        row.switchHealth.retryCountSource = metric ? "owned_stress_metric" : "window_diagnostic_only";
        row.switchTimings.requestToAppliedFrames = Number.isSafeInteger(metric?.appliedFrame) &&
            Number.isSafeInteger(metric?.requestedFrame) && metric.appliedFrame >= metric.requestedFrame ?
                metric.appliedFrame - metric.requestedFrame : null;
        const presentation = row.switchHealth.diagnosticsDelta?.presentation;
        const frequency = row.switchTimings.qpc?.tickFrequency;
        row.switchHealth.stretch = { completedEpisodes: counter(presentation?.stretchCompletedEpisodes),
            completedFrames: counter(presentation?.stretchCompletedFrames),
            completedMs: number(presentation?.stretchCompletedQpcTicks) !== null &&
                Number.isFinite(frequency) && frequency > 0 ? presentation.stretchCompletedQpcTicks * 1000 / frequency : null };
        row.switchHealth.missing.forEach(key => issues.push(`row_${row.ordinal}:missing_${key}`));
    }
    const keys = [...failureNames, ...presentationNames];
    const totals = Object.fromEntries(keys.map(key => [key,
        rows.every(row => row.switchHealth.counters[key] !== null) ?
            rows.reduce((sum, row) => sum + row.switchHealth.counters[key], 0) : null]));
    const findings = rows.filter(row => row.switchHealth.findings.length).map(row => ({
        ordinal: row.ordinal, source: row.source, target: row.target,
        terminalRender: row.renderVerdict, terminalRecovered: row.switchHealth.terminalRecovered,
        counters: row.switchHealth.counters, receipt: row.rawRetained }));
    const failedGates = (acceptance?.gates?.filter(gate => gate.passed === false) ?? [])
        .map(gate => gateAssessment(gate, rows.at(-1)));
    const applicableFailedGates = failedGates.filter(gate => gate.assessmentRole === "HEALTH");
    if (acceptance?.accepted === false && !failedGates.length) issues.push("unexplained_cumulative_rejection");
    const notMet = findings.length > 0 || applicableFailedGates.length > 0 ||
        rows.some(row => row.renderVerdict === "FAIL" || row.authoritativeTask2Violations?.length > 0);
    const profiler = step(before, "profiler-status")?.result ?? null;
    return { lane: first.lane, pass: first.pass, rows: rows.length,
        terminalCounts: Object.fromEntries(["PASS", "FAIL", "INCONCLUSIVE"].map(verdict =>
            [verdict, rows.filter(row => row.renderVerdict === verdict).length])),
        status: notMet ? "FINDINGS_PRESENT" : issues.length ? "INCONCLUSIVE" : "NO_COUNTED_FAILURES",
        healthStandard: notMet ? "NOT_MET" : issues.length ? "INCONCLUSIVE" : "MET",
        evidenceStatus: issues.length ? "INCOMPLETE" : "COMPLETE", issues: [...new Set(issues)],
        counters: totals, affectedTransitions: findings, cumulativeAcceptance: acceptance,
        authoritativePhaseFindings: rows.filter(row => row.authoritativeTask2Violations?.length > 0)
            .map(row => ({ ordinal: row.ordinal, violations: row.authoritativeTask2Violations })),
        failedGates, applicableFailedGates,
        gateInterpretation: "Preserve raw acceptance; exclude the imposed-stretch cutoff and proven native-target gate mismatch from health assessment.",
        stressSessionId: owned ? record.session.id : null,
        stressSource: path.relative(root, cleanupPath).split(path.sep).join("/"),
        timings: Object.fromEntries(["strictMs", "presentationMs", "cleanupMs", "cleanupTailMs", "strictFrames",
            "relatchProofMs", "relatchProofFrames", "requestToAppliedFrames"]
            .map(key => [key, statistics(rows.map(row => row.switchTimings[key]))])),
        retries: rows.every(row => row.switchHealth.retryCount !== null) ?
            rows.reduce((sum, row) => sum + row.switchHealth.retryCount, 0) : null,
        stressPresentation: owned ? record.presentationPath ?? null : null,
        memoryTrend: owned ? record.memoryTrend ?? null : null,
        cpu: step(cleanup, "cpu-performance-stop")?.cpuPerformance ?? null,
        gpu: step(cleanup, "gpu-performance-stop")?.capture ?? null,
        texture: step(cleanup, "texture-lifetime-stop")?.capture ?? null,
        profiler, profilerHasSamples: Boolean(profiler && profiler.timerCount > 0 &&
            profiler.frame?.captured > 0),
        freshness: step(before, "render-status")?.status?.submitInputFreshness ?? null };
}

function switchHealthSummary(root, rows, buildId) {
    const groups = new Map();
    for (const row of rows) {
        const key = `${row.lane ?? ""}:${row.pass}`;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
    }
    const passes = [...groups.values()].map(group => passHealth(root, group, buildId));
    return { schemaVersion: "renderscale-switch-health-v1", scope: "full_observed_transition_history",
        status: passes.some(pass => pass.status === "FINDINGS_PRESENT") ? "FINDINGS_PRESENT" :
            passes.length && passes.every(pass => pass.status === "NO_COUNTED_FAILURES") ?
                "NO_COUNTED_FAILURES" : "INCONCLUSIVE",
        evidenceStatus: passes.length && passes.every(pass => pass.evidenceStatus === "COMPLETE") ?
            "COMPLETE" : "INCOMPLETE",
        interpretation: "Health findings and unmet standards do not rewrite test execution or terminal verdicts.",
        passes };
}

const display = value => value == null ? "n/a" : typeof value === "number" ?
    Number.isInteger(value) ? String(value) : value.toFixed(3) : String(value).replaceAll("|", "\\|");
function markdownTable(headers, rows) {
    return `| ${headers.join(" | ")} |\n| ${headers.map(() => "---").join(" | ")} |\n` +
        rows.map(row => `| ${row.map(display).join(" | ")} |`).join("\n") + "\n\n";
}

function healthReport(health) {
    return "## Per-pass switch health and performance\n\n" +
        "Terminal PASS means the waiter reached its terminal condition. Full-history " +
        "health, cumulative acceptance, evidence completeness, and change assessment " +
        "remain separate. Recovered failures stay visible and do not relabel a completed test.\n\n" +
        markdownTable(["Lane", "Pass", "Rows", "Terminal PASS/FAIL", "Strict mean ms", "p95 ms",
            "Max ms", "Mean strict frames", "Mean relatch ms", "Mean relatch frames", "Stretch episodes",
            "Stretch frames", "Stretch ms", "Retries", "Fidelity", "Vendor-failure eyes", "Health standard", "Evidence"],
        health.passes.map(pass => [pass.lane, pass.pass, pass.rows,
            `${pass.terminalCounts.PASS}/${pass.terminalCounts.FAIL}`,
            pass.timings.strictMs.mean, pass.timings.strictMs.p95, pass.timings.strictMs.maximum,
            pass.timings.strictFrames.mean, pass.timings.relatchProofMs.mean, pass.timings.relatchProofFrames.mean,
            pass.stressPresentation?.allowedPresentationStretch?.completedEpisodes,
            pass.stressPresentation?.allowedPresentationStretch?.completedFrames,
            pass.stressPresentation?.allowedPresentationStretch?.completedMilliseconds,
            pass.retries, pass.counters.fidelityMismatches, pass.counters.vendorFailureStretchEyeObservations,
            pass.healthStandard, pass.evidenceStatus])) +
        health.passes.map(pass => `### ${pass.lane || "default"} pass ${pass.pass}\n\n` +
            `Cumulative accepted: **${display(pass.cumulativeAcceptance?.accepted)}**. ` +
            `Evidence gaps: ${pass.issues.join("; ") || "none"}.\n\n` +
            markdownTable(["Raw unmet gate", "Observed", "Limit", "Assessment role", "Reason"], pass.failedGates.map(gate =>
                [gate.name, JSON.stringify(gate.observed), JSON.stringify(gate.limit), gate.assessmentRole, gate.assessmentReason])) +
            markdownTable(["Row", "Recovered", "Nonzero failure observations", "Receipt"],
                pass.affectedTransitions.map(row => [row.ordinal, row.terminalRecovered,
                    Object.entries(row.counters).filter(([, value]) => value > 0)
                        .map(([key, value]) => `${key}=${value}`).join("; "), row.receipt]))).join("") +
        "All counters, gate observations and limits, owned metrics, phase timings, CPU/GPU " +
        "workload, memory, resource and retry evidence remain in summary.json. " +
        "Profiler totals without resolved fresh samples cannot establish GPU cost or FPS.\n\n";
}

module.exports = { envelope, step, statistics, transitionHealth, transitionTimings,
    switchHealthSummary, healthReport, markdownTable };
