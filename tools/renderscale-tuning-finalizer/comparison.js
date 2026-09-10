// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { envelope, step, transitionHealth, transitionTimings, switchHealthSummary,
    markdownTable } = require("./switch-health.js");
const { sourceProfile, actualBackend, laneQualification, readLaneContext } = require("./finalizer.js");
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const canonical = value => JSON.stringify(value, (_, item) => item && typeof item === "object" &&
    !Array.isArray(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const key = row => `${row.lane || "default"}:${row.pass}:${row.ordinal}`;
const delta = (baseline, candidate) => Number.isFinite(baseline) && Number.isFinite(candidate) ?
    { absolute: candidate - baseline, percent: baseline > 0 ? (candidate / baseline - 1) * 100 : null } :
    { absolute: null, percent: null };
const route = row => `${canonical(row.source)} -> ${canonical(row.target)}`;
function profileName(profile) {
    if (!profile) return "n/a";
    if (profile.method === "none" || profile.method === "taa") return profile.method.toUpperCase();
    if (profile.method === "dlss" && profile.qualityMode === 0) return "DLAA";
    const quality = ["AA", "Hoshipa", "UQ", "Q", "Bal", "Perf", "UP"][profile.qualityMode];
    return `${String(profile.method).toUpperCase()} ${quality ?? profile.qualityMode}`;
}

function loadRun(root, provenance = {}) {
    root = path.resolve(root);
    const summary = envelope(path.join(root, "summary.json"));
    if (!summary?.runId || !summary.build?.buildId || !Array.isArray(summary.transitions))
        throw new Error("comparison_summary_identity_missing");
    const manifest = envelope(path.join(root, "raw/startup/deployment-manifest.json"));
    const sourceCommit = summary.build.sourceCommit ?? manifest?.identity?.source?.commit ?? null;
    if (manifest && (manifest.buildId !== summary.build.buildId ||
        (manifest.identity?.source?.commit && sourceCommit !== manifest.identity.source.commit)))
        throw new Error("comparison_manifest_identity_mismatch");
    if (provenance.sourceCommit && provenance.sourceCommit !== sourceCommit)
        throw new Error("comparison_provenance_source_mismatch");
    const index = envelope(path.join(root, "receipt-index.json"));
    const indexed = new Map((index?.files ?? []).map(item => [item.path, item]));
    const seen = new Set(), evidence = [];
    const laneContext = readLaneContext(root);
    const rows = summary.transitions.map(original => {
        if (seen.has(key(original))) throw new Error("comparison_duplicate_transition_identity");
        seen.add(key(original));
        const raw = path.resolve(root, original.rawRetained);
        if (!raw.startsWith(`${root}${path.sep}`)) throw new Error("comparison_receipt_outside_run");
        const retained = envelope(raw), waiter = retained?.waiter;
        if (!retained) {
            evidence.push({ path: original.rawRetained, sha256: null, indexVerified: false,
                status: "MISSING_RECEIPT" });
            const health = transitionHealth({}); health.receiptMissing = true;
            return { ...original, switchHealth: health, switchTimings: transitionTimings({}),
                retainedRetry: null };
        }
        if (waiter?.producer?.buildId !== summary.build.buildId ||
            (sourceCommit && waiter.producer.sourceCommit !== sourceCommit) ||
            !waiter.ownerId?.startsWith(`${summary.runId}-`))
            throw new Error("comparison_receipt_owner_mismatch");
        if (canonical(original.target) !== canonical(waiter.target))
            throw new Error("comparison_receipt_target_mismatch");
        if (canonical(original.source) !== canonical(sourceProfile(waiter)) ||
            original.actualBackend !== actualBackend(waiter, waiter.target))
            throw new Error("comparison_receipt_route_or_backend_mismatch");
        const digest = hash(raw), expected = indexed.get(original.rawRetained);
        if (index && (!expected || expected.sha256 !== digest || expected.bytes !== fs.statSync(raw).size))
            throw new Error("comparison_receipt_index_mismatch");
        evidence.push({ path: original.rawRetained, sha256: digest, indexVerified: Boolean(expected) });
        return { ...original, laneQualification: laneQualification(root, original.lane, waiter, waiter.target, laneContext),
            switchHealth: transitionHealth(waiter),
            switchTimings: transitionTimings(waiter), retainedRetry: retained.retryTelemetry ?? null };
    });
    const health = switchHealthSummary(root, rows, summary.build.buildId);
    const position = envelope(path.join(root, "raw/startup/positioning.json"));
    const prepare = envelope(path.join(root, "raw/startup/prepare.json"));
    return { root, runId: summary.runId, protocol: summary.protocol, build: summary.build,
        sourceCommit, rendererBaseCommit: provenance.rendererBaseCommit ?? null,
        mainVRBaseCommit: provenance.mainVRBaseCommit ?? null,
        provenanceEvidence: provenance.evidence ?? null,
        artifact: manifest?.artifact ?? null, rows, health, evidence,
        execution: summary.assayExecution, reporting: summary.reporting,
        memory: summary.memoryConfirmation ?? null, pacing: summary.pacing ?? null,
        fixtureFingerprint: summary.fixtureFingerprint ?? summary.fixture?.fingerprint ?? null,
        context: { adapter: step(position, "position-renderscale")?.status?.adapter ?? null,
            scene: step(position, "position-scene") ?? null,
            foveation: prepare?.after?.foveation ?? null,
            toolchain: manifest?.identity?.toolchain ?? null,
            dependencies: manifest?.identity?.dependencies ?? null,
            shaderCompiler: summary.build.shaderCompilerIdentity ?? null },
        limitations: ["Headset refresh, driver version, power state and full modlist/cache equality require retained proof.",
            "One process and ordered repeats do not establish causal or statistically significant gains.",
            "Missing profiler samples are unavailable time evidence, never zero cost."] };
}

function compareData(baseline, candidate, policy = null) {
    const b = new Map(baseline.rows.map(row => [key(row), row]));
    const c = new Map(candidate.rows.map(row => [key(row), row]));
    const pairs = [...new Set([...b.keys(), ...c.keys()])].sort((a, z) =>
        a.localeCompare(z, "en", { numeric: true })).map(identity => {
        const left = b.get(identity) ?? null, right = c.get(identity) ?? null;
        const reasons = [];
        if (!left || !right) reasons.push("transition_not_run_or_receipt_missing");
        else {
            if (route(left) !== route(right)) reasons.push("source_or_destination_mismatch");
            if (left.actualBackend !== right.actualBackend || [left, right].some(row =>
                !row.actualBackend || row.actualBackend === "not_exposed")) reasons.push("backend_not_matched");
            for (const dimension of ["displayEyeWidth", "displayEyeHeight", "renderEyeWidth", "renderEyeHeight"])
                if (!Number.isFinite(left.switchHealth.ownedMetric?.[dimension]) ||
                    left.switchHealth.ownedMetric[dimension] !== right.switchHealth.ownedMetric?.[dimension])
                    reasons.push(`${dimension}_not_matched`);
        }
        return { identity, lane: (right ?? left).lane, pass: (right ?? left).pass,
            ordinal: (right ?? left).ordinal, baseline: left, candidate: right,
            status: reasons.length ? "UNMATCHED" : "MATCHED", reasons,
            deltas: Object.fromEntries(["strictMs", "presentationMs", "cleanupMs", "cleanupTailMs",
                "strictFrames", "relatchProofMs", "relatchProofFrames", "requestToAppliedFrames"].map(metric =>
                [metric, delta(left?.switchTimings[metric], right?.switchTimings[metric])])),
            stretchDeltas: Object.fromEntries(["completedEpisodes", "completedFrames", "completedMs"].map(metric =>
                [metric, delta(left?.switchHealth.stretch[metric], right?.switchHealth.stretch[metric])])),
            retryDelta: delta(left?.switchHealth.retryCount, right?.switchHealth.retryCount) };
    });
    const passes = candidate.health.passes.map(current => {
        const previous = baseline.health.passes.find(pass =>
            (pass.lane || "default") === (current.lane || "default") && pass.pass === current.pass);
        const currentFailures = new Set(current.failedGates.map(gate => gate.name));
        const previousFailures = new Set(previous?.failedGates.map(gate => gate.name) ?? []);
        return { lane: current.lane, pass: current.pass, baseline: previous ?? null, candidate: current,
            timingDeltas: Object.fromEntries(["mean", "median", "p95", "maximum", "total"].map(metric =>
                [metric, delta(previous?.timings.strictMs[metric], current.timings.strictMs[metric])])),
            newUnmetGates: [...currentFailures].filter(name => !previousFailures.has(name)),
            persistentUnmetGates: [...currentFailures].filter(name => previousFailures.has(name)),
            resolvedGates: [...previousFailures].filter(name => !currentFailures.has(name)),
            applicableHealthGates: current.applicableFailedGates,
            newFailureRows: pairs.filter(pair => pair.lane === current.lane && pair.pass === current.pass &&
                pair.baseline && pair.candidate && Object.entries(pair.candidate.switchHealth.counters).some(([name, value]) =>
                    value > 0 && Number.isFinite(pair.baseline.switchHealth.counters[name]) &&
                    value > pair.baseline.switchHealth.counters[name])).map(pair => pair.ordinal) };
    });
    const contextMatches = Object.fromEntries(Object.keys(candidate.context).map(name =>
        [name, baseline.context[name] !== null && candidate.context[name] !== null &&
            canonical(baseline.context[name]) === canonical(candidate.context[name])]));
    const reasons = [];
    for (const [name, matched] of Object.entries(contextMatches))
        if (!matched) reasons.push(`retained_context_not_matched:${name}`);
    if (!baseline.rendererBaseCommit || !candidate.rendererBaseCommit ||
        !baseline.mainVRBaseCommit || !candidate.mainVRBaseCommit)
        reasons.push("renderer_or_main_vr_base_provenance_missing");
    if ([baseline, candidate].some(run => run.evidence.some(item => !item.indexVerified)))
        reasons.push("receipt_index_verification_incomplete");
    if (!pairs.length || pairs.some(pair => pair.status !== "MATCHED")) reasons.push("unmatched_or_missing_transitions");
    if (!baseline.fixtureFingerprint || baseline.fixtureFingerprint !== candidate.fixtureFingerprint)
        reasons.push("matching_fixture_fingerprint_unavailable");
    if (baseline.execution?.status !== "COMPLETE" || candidate.execution?.status !== "COMPLETE")
        reasons.push("incomplete_execution_coverage");
    if (baseline.reporting?.status !== "COMPLETE" || candidate.reporting?.status !== "COMPLETE")
        reasons.push("incomplete_reporting");
    if (candidate.health.evidenceStatus !== "COMPLETE" || baseline.health.evidenceStatus !== "COMPLETE")
        reasons.push("incomplete_health_evidence");
    if ([baseline, candidate].some(run => run.rows.some(row =>
        row.lane && row.lane !== "nvidia" && row.laneQualification?.verdict !== "PASS")))
        reasons.push("amd_lane_qualification_failed_or_missing");
    const validPolicy = policy && typeof policy.id === "string" && policy.id.length > 0 &&
        Number.isFinite(policy.absoluteToleranceMs) && policy.absoluteToleranceMs >= 0 &&
        Number.isFinite(policy.relativeTolerancePercent) && policy.relativeTolerancePercent >= 0 &&
        Number.isSafeInteger(policy.requiredPasses) && policy.requiredPasses >= 2;
    if (!validPolicy) reasons.push("explicit_versioned_tolerance_policy_missing");
    const lanePasses = new Map();
    for (const pass of passes) {
        if (!lanePasses.has(pass.lane)) lanePasses.set(pass.lane, new Set());
        lanePasses.get(pass.lane).add(pass.pass);
    }
    if (validPolicy && [...lanePasses.values()].some(values => values.size < policy.requiredPasses))
        reasons.push("required_repeat_coverage_missing");
    const within = (base, change) => Math.abs(change) <= Math.max(policy.absoluteToleranceMs,
        base * policy.relativeTolerancePercent / 100);
    const worse = validPolicy ? pairs.filter(pair => pair.status === "MATCHED" &&
        pair.deltas.strictMs.absolute > 0 && !within(pair.baseline.switchTimings.strictMs, pair.deltas.strictMs.absolute)) : [];
    const badHealth = candidate.health.passes.some(pass => pass.healthStandard === "NOT_MET");
    let status = "INCONCLUSIVE";
    if (badHealth || (worse.length && !reasons.length)) status = "DOES_NOT_MEET_STANDARD";
    else if (!reasons.length && pairs.every(pair => pair.deltas.strictMs.absolute !== null)) {
        const improvedEveryPass = passes.every(pass => pass.timingDeltas.mean.absolute < 0 &&
            !within(pass.baseline.timings.strictMs.mean, pass.timingDeltas.mean.absolute));
        const neutral = pairs.every(pair => within(pair.baseline.switchTimings.strictMs, pair.deltas.strictMs.absolute));
        status = improvedEveryPass ? "IMPROVEMENT_SUPPORTED" : neutral ? "NEUTRAL_SUPPORTED" : "INCONCLUSIVE";
    }
    return { schemaVersion: "renderscale-switch-comparison-v1", baseline, candidate, pairs, passes,
        contextMatches, policy, changeAssessment: { status, scope: "improvement_or_neutral",
            changesTestResult: false, reasons: [...(badHealth ? ["candidate_health_standard_not_met"] : []),
                ...(worse.length ? ["per_transition_latency_exceeds_tolerance"] : []), ...reasons],
            slowerOutsideTolerance: worse.map(pair => pair.identity) },
        prInclusion: "USER_DECIDES", deltaDefinition: "candidate minus baseline; negative latency is faster" };
}

function reportComparison(result) {
    const { baseline: b, candidate: c } = result;
    const fmt = value => value == null ? "n/a" : Number.isInteger(value) ? String(value) : value.toFixed(3);
    const paired = (pair, field) => `${fmt(pair.baseline?.switchTimings[field])} / ${fmt(pair.candidate?.switchTimings[field])}`;
    const f = row => row ? `${fmt(row.switchHealth.counters.fidelityMismatches)}/${fmt(row.switchHealth.counters.vendorFailureStretchEyeObservations)}` : "n/a";
    let text = "# Upscaling switch comparison\n\n" +
        `Change assessment: **${result.changeAssessment.status}**. Test execution remains ` +
        `**${b.execution?.status ?? "unknown"} / ${c.execution?.status ?? "unknown"}** (baseline/candidate).\n\n` +
        "This assessment describes whether the change meets the improvement-or-neutral standard. " +
        "It does not rewrite terminal results or mark a completed test as failed. PR inclusion is the user's decision.\n\n" +
        markdownTable(["Identity", "Baseline", "Candidate"], [
            ["Run", b.runId, c.runId], ["Renderer base", b.rendererBaseCommit, c.rendererBaseCommit],
            ["Main-VR base/equivalent", b.mainVRBaseCommit, c.mainVRBaseCommit],
            ["Compiled source", b.sourceCommit, c.sourceCommit], ["Build ID", b.build.buildId, c.build.buildId],
            ["DLL SHA-256", b.artifact?.sha256, c.artifact?.sha256],
            ["Evidence root", b.root, c.root]]) +
        `Assessment limits: ${result.changeAssessment.reasons.join("; ") || "none"}.\n\n` +
        "## Per-pass summary\n\n" + markdownTable(["Lane", "Pass", "Rows B/C", "Mean ms B/C", "Mean delta %",
            "Retries B/C", "Fidelity B/C", "Vendor failures B/C", "New failure rows", "Health standard B/C"],
        result.passes.map(pass => [pass.lane, pass.pass, `${pass.baseline?.rows ?? "n/a"}/${pass.candidate.rows}`,
            `${fmt(pass.baseline?.timings.strictMs.mean)}/${fmt(pass.candidate.timings.strictMs.mean)}`,
            pass.timingDeltas.mean.percent, `${fmt(pass.baseline?.retries)}/${fmt(pass.candidate.retries)}`,
            `${fmt(pass.baseline?.counters.fidelityMismatches)}/${fmt(pass.candidate.counters.fidelityMismatches)}`,
            `${fmt(pass.baseline?.counters.vendorFailureStretchEyeObservations)}/${fmt(pass.candidate.counters.vendorFailureStretchEyeObservations)}`,
            pass.newFailureRows.join(", ") || "none", `${pass.baseline?.healthStandard ?? "n/a"}/${pass.candidate.healthStandard}`]));
    text += "## Side-by-side relatch, completion and stretch summary\n\n" +
        "Relatch proof is dispatch to the first exact new generation proof. Strict completion " +
        "includes the remaining qualification/cleanup conditions. Relatch sample counts exclude " +
        "missing or inapplicable boundaries; neither is replaced with zero. Stretch totals span " +
        "the full owned pass capture.\n\n";
    const summaryMetrics = [
        ["Relatch proof mean", "ms", pass => pass?.timings.relatchProofMs.mean],
        ["Relatch proof mean", "frames", pass => pass?.timings.relatchProofFrames.mean],
        ["Relatch proof total", "ms", pass => pass?.timings.relatchProofMs.total],
        ["Relatch proof total", "frames", pass => pass?.timings.relatchProofFrames.total],
        ["Relatch proof samples", "transitions", pass => pass?.timings.relatchProofMs.count],
        ["Strict completion mean", "ms", pass => pass?.timings.strictMs.mean],
        ["Strict completion mean", "frames", pass => pass?.timings.strictFrames.mean],
        ["Strict completion total", "ms", pass => pass?.timings.strictMs.total],
        ["Strict completion total", "frames", pass => pass?.timings.strictFrames.total],
        ["Stretch completed episodes", "episodes", pass => pass?.stressPresentation?.allowedPresentationStretch?.completedEpisodes],
        ["Stretch completed total", "frames", pass => pass?.stressPresentation?.allowedPresentationStretch?.completedFrames],
        ["Stretch completed total", "ms", pass => pass?.stressPresentation?.allowedPresentationStretch?.completedMilliseconds],
        ["Stretch longest episode", "ms", pass => pass?.stressPresentation?.allowedPresentationStretch?.maximumCompletedMilliseconds],
    ];
    text += markdownTable(["Lane", "Pass", "Metric", "Unit", "Baseline", "Candidate", "Delta", "Delta %"],
        result.passes.flatMap(pass => summaryMetrics.map(([name, unit, value]) => {
            const left = value(pass.baseline), right = value(pass.candidate), change = delta(left, right);
            return [pass.lane, pass.pass, name, unit, left, right, change.absolute, change.percent];
        })));
    for (const identity of [...new Set(result.pairs.map(pair => `${pair.lane || "default"}:${pair.pass}`))]) {
        const pairs = result.pairs.filter(pair => `${pair.lane || "default"}:${pair.pass}` === identity);
        text += `## ${identity}\n\n` +
            "B/C cells are baseline/candidate; times are ms excluding the pre-dispatch wait. " +
            "F/V is fidelity mismatch observations / vendor-failure eye observations.\n\n" +
            markdownTable(["Row", "Switch", "Strict B/C", "Delta ms", "Delta %", "Retries B/C", "F/V B -> C", "Pair"],
                pairs.map(pair => [pair.ordinal,
                    `${profileName((pair.candidate ?? pair.baseline).source)} -> ${profileName((pair.candidate ?? pair.baseline).target)}`,
                    paired(pair, "strictMs"),
                    pair.deltas.strictMs.absolute, pair.deltas.strictMs.percent,
                    `${fmt(pair.baseline?.switchHealth.retryCount)}/${fmt(pair.candidate?.switchHealth.retryCount)}`,
                    `${f(pair.baseline)} -> ${f(pair.candidate)}`, pair.status])) +
            markdownTable(["Row", "Presentation B/C", "Cleanup B/C", "Cleanup tail B/C", "Phase durations B", "Phase durations C"],
                pairs.map(pair => [pair.ordinal, paired(pair, "presentationMs"), paired(pair, "cleanupMs"), paired(pair, "cleanupTailMs"),
                    canonical(pair.baseline?.switchTimings.phases ?? null), canonical(pair.candidate?.switchTimings.phases ?? null)])) +
            markdownTable(["Row", "Relatch proof frames B/C", "Delta frames", "Relatch proof ms B/C", "Delta ms",
                "Strict frames B/C", "Delta frames"], pairs.map(pair => [pair.ordinal,
                paired(pair, "relatchProofFrames"), pair.deltas.relatchProofFrames.absolute,
                paired(pair, "relatchProofMs"), pair.deltas.relatchProofMs.absolute,
                paired(pair, "strictFrames"), pair.deltas.strictFrames.absolute])) +
            markdownTable(["Row", "Stretch episodes B/C", "Delta", "Stretch frames B/C", "Delta", "Stretch ms B/C", "Delta ms"],
                pairs.map(pair => [pair.ordinal, ...["completedEpisodes", "completedFrames", "completedMs"].flatMap(field =>
                    [`${fmt(pair.baseline?.switchHealth.stretch[field])} / ${fmt(pair.candidate?.switchHealth.stretch[field])}`,
                        pair.stretchDeltas[field].absolute])]));
    }
    text += "## Cumulative gates and other health evidence\n\n";
    for (const run of [b, c]) for (const pass of run.health.passes) {
        text += `### ${run.runId} / ${pass.lane || "default"} / pass ${pass.pass}\n\n` +
            `Accepted: ${pass.cumulativeAcceptance?.accepted ?? "n/a"}. Health evidence: ${pass.evidenceStatus}.\n\n` +
            markdownTable(["Raw unmet gate", "Observed", "Limit", "Assessment role", "Reason"], pass.failedGates.map(gate =>
                [gate.name, canonical(gate.observed), canonical(gate.limit), gate.assessmentRole, gate.assessmentReason])) +
            markdownTable(["Failure counter", "Observations"], Object.entries(pass.counters));
    }
    return text + resourceComparison(result) + "## Context, memory, CPU/GPU and evidence\n\n" +
        markdownTable(["Retained context matches", "Result"], Object.entries(result.contextMatches)) +
        "Full start/end memory evidence, CPU/GPU/resource counters, phase timings, retry details, " +
        "native execution proofs, every gate and raw receipt hash are in comparison.json. " +
        "comparison.csv contains every paired or missing transition with both original row payloads. " +
        "Missing samples remain null/n/a. Current and baseline failures are preserved separately; " +
        "a persistent gate failure is not automatically a newly introduced regression. The fixed stretch-frame cutoff " +
        "is diagnostic only because settling imposes stretch. Compare its actual frames and duration, " +
        "together with time to applied relatch and strict completion. Request-to-applied frames begin at the " +
        "producer request, whereas strict frames/ms begin at qualification dispatch; these intervals must not be conflated.\n\n" +
        [...new Set([...b.limitations, ...c.limitations])].map(item => `- ${item}\n`).join("");
}

function flatten(value, prefix = "") {
    if (value && typeof value === "object" && !Array.isArray(value))
        return Object.entries(value).flatMap(([name, item]) => flatten(item, `${prefix}/${name}`));
    return typeof value === "number" || typeof value === "boolean" || value === null ? [[prefix, value]] : [];
}

function resourceComparison(result) {
    const boundary = (run, lane, pass) => {
        const memory = run.memory?.lanes?.[lane] ?? run.memory;
        return memory?.boundaries?.[`pass${pass}`] ?? memory?.boundaryGroups?.[`pass${pass}`] ?? null;
    };
    let report = "## Side-by-side memory boundaries\n\n" +
        "Memory classification is retained independently. Negative deltas do not prove leak freedom. " +
        "Fresh tracker counts are not process-wide net allocation counts.\n\n" +
        markdownTable(["Lane", "Pass", "Metric", "B start/end/change", "C start/end/change", "Change difference C-B"],
            result.passes.flatMap(pass => ["processPrivateMiB", "systemCommitMiB", "dxgiUsageMiB", "liveTextures", "liveTextureMiB"].map(metric => {
                const b = boundary(result.baseline, pass.lane, pass.pass);
                const c = boundary(result.candidate, pass.lane, pass.pass);
                const values = group => ["start", "end", "delta"].map(part => group?.[part]?.[metric] ?? "n/a").join(" / ");
                return [pass.lane, pass.pass, metric, values(b), values(c), delta(b?.delta?.[metric], c?.delta?.[metric]).absolute];
            })));
    report += "## Side-by-side CPU/GPU/resource observations\n\n" +
        "Counters span different observed frame counts and changing methods. They are not whole-frame " +
        "timings. Unresolved profiler totals are n/a; fresh resolved sample qualification is separate.\n\n";
    for (const pass of result.passes) {
        const telemetry = value => Object.fromEntries(["cpu", "gpu", "texture", "profiler"].flatMap(group =>
            flatten(value?.[group] ?? null, group).map(([name, item]) => [name,
                name.startsWith("profiler/totalsMs/") && !value?.profilerHasSamples ? null : item])));
        const b = telemetry(pass.baseline), c = telemetry(pass.candidate);
        const rows = [...new Set([...Object.keys(b), ...Object.keys(c)])].sort().map(name =>
            [name, b[name] ?? null, c[name] ?? null, delta(b[name], c[name]).absolute]);
        report += `<details><summary>${pass.lane || "default"} pass ${pass.pass}: all captured scalar counters</summary>\n\n` +
            markdownTable(["Metric (captured units)", "Baseline", "Candidate", "Delta"], rows) + "</details>\n\n";
    }
    return report;
}

function writeComparison(options) {
    const provenance = options.provenancePath ? envelope(options.provenancePath) : {};
    const policy = options.policyPath ? envelope(options.policyPath) : null;
    const result = compareData(loadRun(options.baselineRoot, provenance.baseline),
        loadRun(options.candidateRoot, provenance.candidate), policy);
    const output = path.resolve(options.outputRoot);
    if ([result.baseline.root, result.candidate.root].some(root => output === root ||
        output.startsWith(`${root}${path.sep}`))) throw new Error("comparison_output_must_be_separate_from_raw_runs");
    fs.mkdirSync(output, { recursive: true });
    const csv = ["identity,status,baseline_source,candidate_source,strict_delta_ms,strict_delta_percent,baseline_row,candidate_row",
        ...result.pairs.map(pair => [pair.identity, pair.status, result.baseline.sourceCommit,
            result.candidate.sourceCommit, pair.deltas.strictMs.absolute, pair.deltas.strictMs.percent,
            pair.baseline, pair.candidate].map(value => `"${(typeof value === "object" ? JSON.stringify(value) : String(value ?? "n/a")).replaceAll('"', '""')}"`).join(","))].join("\n") + "\n";
    for (const [name, value] of [["comparison.json", JSON.stringify(result, null, 2) + "\n"],
        ["comparison.md", reportComparison(result)], ["comparison.csv", csv]]) {
        const temporary = path.join(output, name + ".tmp-comparison");
        fs.writeFileSync(temporary, value);
        fs.renameSync(temporary, path.join(output, name));
    }
    return result;
}

if (require.main === module) {
    try {
        const args = {};
        for (let i = 2; i < process.argv.length; i += 2) {
            if (!process.argv[i].startsWith("--") || !process.argv[i + 1]) throw new Error("invalid_comparison_arguments");
            args[process.argv[i].slice(2)] = process.argv[i + 1];
        }
        const result = writeComparison({ baselineRoot: args["baseline-root"], candidateRoot: args["candidate-root"],
            outputRoot: args["output-root"], provenancePath: args["provenance-path"], policyPath: args["policy-path"] });
        process.stdout.write(JSON.stringify({ ok: true, pairs: result.pairs.length,
            changeAssessment: result.changeAssessment, prInclusion: result.prInclusion }) + "\n");
    } catch (error) { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; }
}

module.exports = { loadRun, compareData, reportComparison, writeComparison };
