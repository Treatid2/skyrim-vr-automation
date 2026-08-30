// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

function unwrapTraceRead(value) {
    if (value && Array.isArray(value.content) && value.content[0] &&
        typeof value.content[0].text === "string") {
        return unwrapTraceRead(JSON.parse(value.content[0].text));
    }
    if (value && Array.isArray(value.results)) {
        const step = value.results.find((entry) => entry &&
            entry.result && entry.result.action === "dlss_trace_read");
        return step && step.result;
    }
    return value && value.result && value.result.action === "dlss_trace_read" ?
        value.result : value;
}

function recordSequence(record) {
    const value = record && (record.sequence ??
        (record.current && record.current.sequence));
    return Number.isSafeInteger(value) && value > 0 ? value : null;
}

function traceCapacity(schema) {
    const maximum = schema && (schema.maximum ?? schema.max ??
        (schema.limit && schema.limit.maximum));
    if (!Number.isSafeInteger(maximum) || maximum < 1) {
        throw new Error("trace_schema_maximum_missing");
    }
    return maximum;
}

function validateTracePage(rawPage, state) {
    const page = unwrapTraceRead(rawPage);
    const capture = page && page.capture;
    const producer = page && page.producer;
    if (!page || page.action !== "dlss_trace_read" || !capture ||
        !Array.isArray(capture.records)) {
        throw new Error("invalid_trace_page");
    }
    if (!producer || producer.buildId !== state.buildId) {
        throw new Error("trace_build_changed");
    }
    const sessionId = capture.summary && capture.summary.sessionID;
    if (!Number.isSafeInteger(sessionId) || sessionId < 1) {
        throw new Error("trace_session_missing");
    }
    if (state.sessionId !== null && sessionId !== state.sessionId) {
        throw new Error("trace_session_changed");
    }
    if (capture.limit > state.maximum || capture.limit < 1) {
        throw new Error("trace_page_limit_out_of_range");
    }
    if (capture.afterSequence !== state.afterSequence) {
        throw new Error("trace_page_cursor_mismatch");
    }
    if (capture.requestedSequenceOverwritten === true ||
        (Number.isSafeInteger(capture.availableFromSequence) &&
            capture.availableFromSequence > state.afterSequence + 1)) {
        throw new Error("trace_requested_sequence_overwritten");
    }

    let expected = state.afterSequence + 1;
    for (const record of capture.records) {
        const sequence = recordSequence(record);
        if (sequence === null) throw new Error("trace_sequence_missing");
        if (sequence < expected) throw new Error("trace_sequence_duplicate");
        if (sequence > expected) throw new Error("trace_sequence_gap");
        expected += 1;
    }
    const lastSequence = capture.records.length > 0 ? expected - 1 :
        state.afterSequence;
    if (capture.lastReturnedSequence !== lastSequence) {
        throw new Error("trace_last_sequence_mismatch");
    }
    if (capture.moreAvailable === true && capture.records.length === 0) {
        throw new Error("trace_empty_continuation_page");
    }
    return { page, sessionId, lastSequence };
}

async function collectTracePages(options) {
    const {
        readPage, expectedBuildId, schema, expectedSessionId = null,
        existingPages = [], preservePage = async () => {},
    } = options;
    if (typeof readPage !== "function" || typeof preservePage !== "function" ||
        typeof expectedBuildId !== "string" || expectedBuildId.length === 0) {
        throw new Error("invalid_trace_paging_options");
    }
    const maximum = traceCapacity(schema);
    const state = {
        buildId: expectedBuildId,
        sessionId: expectedSessionId,
        afterSequence: 0,
        maximum,
    };
    const pages = [];
    const records = [];

    for (const rawPage of existingPages) {
        const checked = validateTracePage(rawPage, state);
        state.sessionId = checked.sessionId;
        state.afterSequence = checked.lastSequence;
        pages.push(checked.page);
        records.push(...checked.page.capture.records);
        if (checked.page.capture.moreAvailable !== true) {
            return { pages, records, sessionId: state.sessionId, maximum };
        }
    }

    while (pages.length === 0 ||
        pages[pages.length - 1].capture.moreAvailable === true) {
        const rawPage = await readPage({
            action: "dlss_trace_read",
            afterSequence: state.afterSequence,
            limit: maximum,
            expectedBuildId,
        });
        // Preserve the producer receipt even when validation rejects it.
        await preservePage(rawPage, pages.length + 1);
        const checked = validateTracePage(rawPage, state);
        state.sessionId = checked.sessionId;
        state.afterSequence = checked.lastSequence;
        pages.push(checked.page);
        records.push(...checked.page.capture.records);
    }
    return { pages, records, sessionId: state.sessionId, maximum };
}

function readJson(file) {
    return JSON.parse(fs.readFileSync(file, "utf8"));
}

function relative(root, file) {
    return path.relative(root, file).split(path.sep).join("/");
}

function walk(root) {
    const files = [];
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
        const full = path.join(root, entry.name);
        if (entry.isDirectory()) files.push(...walk(full));
        else if (entry.isFile()) files.push(full);
    }
    return files;
}

function aggregateVerdict(values) {
    if (values.includes("FAIL")) return "FAIL";
    if (values.includes("INCONCLUSIVE")) return "INCONCLUSIVE";
    return values.length > 0 && values.every((value) => value === "PASS") ?
        "PASS" : "INCONCLUSIVE";
}

function rowIdentity(root, file) {
    const parts = relative(root, file).split("/");
    const passPart = parts.find((part) => /^pass-\d+$/.test(part));
    const transitionIndex = parts.indexOf("transitions");
    const ordinalPart = transitionIndex >= 0 ? parts[transitionIndex + 1] : null;
    if (!passPart || !ordinalPart || !/^\d+$/.test(ordinalPart)) return null;
    const lanePart = parts.find((part) => /^lane-/.test(part));
    return {
        lane: lanePart ? lanePart.slice(5) : null,
        pass: Number(passPart.slice(5)),
        ordinal: Number(ordinalPart),
    };
}

function unique(values) {
    return [...new Set(values.filter((value) => value !== null &&
        value !== undefined && value !== ""))];
}

function normalizeTask2(retained) {
    const waiter = retained.waiter || {};
    const projection = retained.projection || {};
    const timeline = waiter.replacementTimeline || retained.replacementTimeline || {};
    const expectation = timeline.mutationExpectation ||
        projection.mutationExpectation || "unknown";
    const boundary = timeline.firstPhysicalMutation;
    const missing = unique([...(projection.missingEvidence || [])]
        .filter((value) => value !== "first_physical_mutation"));
    const counters = projection.invariantViolations || {};
    let authoritativeViolations = projection.genuineInvariantViolations || [];
    let verdict = projection.task2Verdict || projection.evidenceVerdict ||
        "INCONCLUSIVE";
    let phaseCountersAuthoritative = true;

    if (expectation === "required" && !boundary) {
        missing.push("missing_required_mutation_boundary");
        authoritativeViolations = [];
        phaseCountersAuthoritative = false;
        verdict = "INCONCLUSIVE";
    } else if (authoritativeViolations.length > 0) {
        verdict = "FAIL";
    }
    return {
        verdict,
        expectation,
        missingEvidence: unique(missing),
        phaseCountersAuthoritative,
        observedPhaseCounters: counters,
        authoritativeViolations,
    };
}

function finalProfile(waiter) {
    const snapshot = waiter.upscalingSnapshot || {};
    const stable = snapshot.stable || snapshot.effective || {};
    return {
        method: stable.method ?? "not_exposed",
        quality: stable.qualityMode ?? "not_exposed",
        renderScaleMode: stable.renderScaleMode ?? "not_exposed",
        stateRevision: snapshot.stateRevision ?? "not_exposed",
    };
}

function transitionRow(root, file, retained) {
    const identity = rowIdentity(root, file);
    const waiter = retained.waiter || {};
    const projection = retained.projection || {};
    const task2 = normalizeTask2(retained);
    const profile = finalProfile(waiter);
    const timeline = waiter.replacementTimeline || retained.replacementTimeline || {};
    const boundary = timeline.firstPhysicalMutation;
    const target = waiter.target || {};
    const traceRequired = target.method === "dlss";
    const traceComplete = !traceRequired || ["traceReset", "traceStart", "traceStop",
        "traceRead"].every((name) => retained[name]);
    return {
        ...identity,
        target,
        renderVerdict: projection.renderVerdict ||
            (waiter.satisfied === true ? "PASS" : "FAIL"),
        task2Verdict: task2.verdict,
        task2MissingEvidence: task2.missingEvidence,
        phaseCountersAuthoritative: task2.phaseCountersAuthoritative,
        observedPhaseCounters: task2.observedPhaseCounters,
        authoritativeTask2Violations: task2.authoritativeViolations,
        mutationExpectation: task2.expectation,
        physicalMutationStarted: boundary ?
            boundary.physicalMutationStarted === true : "not_exposed",
        finalMethod: profile.method,
        finalQuality: profile.quality,
        finalRenderScaleMode: profile.renderScaleMode,
        finalStateRevision: profile.stateRevision,
        presentationStretchSelected:
            projection.presentationStretchSelected === true,
        presentationStretchRecovered:
            projection.presentationStretchTerminalRecovery === true,
        traceRequired,
        traceComplete,
        rawRetained: relative(root, file),
    };
}

function csvCell(value) {
    const text = Array.isArray(value) ? value.join(";") :
        value && typeof value === "object" ? JSON.stringify(value) : String(value ?? "");
    return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function csv(rows) {
    const columns = [
        "lane", "pass", "ordinal", "method", "quality_mode", "render_scale_mode",
        "render_verdict", "task2_verdict", "mutation_expectation",
        "missing_evidence", "phase_counters_authoritative",
        "physical_mutation_started", "final_method", "final_quality",
        "final_render_scale_mode", "final_state_revision", "trace_required",
        "trace_complete", "raw_retained",
    ];
    const lines = [columns.join(",")];
    for (const row of rows) {
        const values = [row.lane, row.pass, row.ordinal, row.target.method,
            row.target.qualityMode, row.target.renderScaleMode, row.renderVerdict,
            row.task2Verdict, row.mutationExpectation, row.task2MissingEvidence,
            row.phaseCountersAuthoritative, row.physicalMutationStarted,
            row.finalMethod, row.finalQuality, row.finalRenderScaleMode,
            row.finalStateRevision, row.traceRequired, row.traceComplete,
            row.rawRetained];
        lines.push(values.map(csvCell).join(","));
    }
    return `${lines.join("\n")}\n`;
}

function report(summary) {
    const rows = summary.transitions.map((row) =>
        `| ${row.lane || "default"} | ${row.pass} | ${row.ordinal} | ` +
        `${row.renderVerdict} | ${row.task2Verdict} | ` +
        `${row.task2MissingEvidence.join("; ") || "none"} |`).join("\n");
    return `# ${summary.protocol} final report\n\n` +
        `- Assay execution: **${summary.assayExecution.status}**\n` +
        `- Render verdict: **${summary.render.verdict}**\n` +
        `- Task 2/evidence verdict: **${summary.task2Evidence.verdict}**\n` +
        `- Reporting completeness: **${summary.reporting.status}**\n\n` +
        `The four statuses are independent. Reporting failure does not rewrite ` +
        `the render result, and a render pass does not hide missing Task 2 evidence.\n\n` +
        `## Transitions\n\n` +
        `| Lane | Pass | Row | Render | Task 2 | Missing evidence |\n` +
        `| --- | ---: | ---: | --- | --- | --- |\n${rows}\n`;
}

function writeAtomic(file, content) {
    const temporary = `${file}.tmp-finalizer`;
    fs.writeFileSync(temporary, content);
    fs.renameSync(temporary, file);
}

function sha256(file) {
    return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function finalizeEvidence(options) {
    const root = path.resolve(options.root);
    const variant = options.variant;
    if (!fs.statSync(root).isDirectory() || !["nvidia", "amd"].includes(variant)) {
        throw new Error("invalid_finalization_options");
    }
    const retainedFiles = walk(root).filter((file) =>
        path.basename(file) === "retained.json" && rowIdentity(root, file));
    const retained = retainedFiles.map((file) => ({ file, value: readJson(file) }));
    const rows = retained.map(({ file, value }) => transitionRow(root, file, value))
        .sort((left, right) => (left.lane || "").localeCompare(right.lane || "") ||
            left.pass - right.pass || left.ordinal - right.ordinal);
    if (rows.length === 0) throw new Error("no_terminal_receipts");

    const existingSummaryPath = path.join(root, "summary.json");
    const existing = fs.existsSync(existingSummaryPath) ? readJson(existingSummaryPath) : {};
    const runIds = unique([options.runId, existing.runId]);
    const buildIds = unique([options.buildId, existing.build && existing.build.buildId]);
    if (runIds.length !== 1 || buildIds.length !== 1) {
        throw new Error("finalization_identity_ambiguous");
    }
    for (const entry of retained) {
        const waiter = entry.value.waiter || {};
        const producerBuild = waiter.producer && waiter.producer.buildId;
        if (producerBuild !== buildIds[0]) {
            throw new Error("terminal_receipt_build_mismatch");
        }
        if (typeof waiter.ownerId !== "string" ||
            !waiter.ownerId.startsWith(`${runIds[0]}-`)) {
            throw new Error("terminal_receipt_run_mismatch");
        }
        if (!waiter.baseline ||
            !Number.isSafeInteger(waiter.baseline.stressSessionId) ||
            waiter.baseline.stressSessionId < 1) {
            throw new Error("terminal_receipt_session_missing");
        }
    }
    const expectedRows = options.expectedRows ??
        (existing.counts && existing.counts.transitionsDispatched) ?? rows.length;
    const assayStatus = rows.length === expectedRows ? "COMPLETE" : "INCOMPLETE";
    const renderVerdict = aggregateVerdict(rows.map((row) => row.renderVerdict));
    const task2Verdict = aggregateVerdict(rows.map((row) => row.task2Verdict));
    const reportingReasons = [];
    if (assayStatus !== "COMPLETE") reportingReasons.push("terminal_receipts_incomplete");
    if (rows.some((row) => !row.traceComplete)) {
        reportingReasons.push("required_trace_evidence_incomplete");
    }
    const reportingStatus = reportingReasons.length === 0 ? "COMPLETE" : "INCOMPLETE";
    const overallVerdict = aggregateVerdict([renderVerdict, task2Verdict]);
    const generatedUtc = options.generatedUtc || existing.generatedUtc ||
        "not_exposed";
    const summary = {
        ...existing,
        schemaVersion: `renderscale-tuning-${variant}-summary-v2`,
        protocol: `renderscale-tuning-${variant}`,
        runId: runIds[0],
        generatedUtc,
        executionStatus: assayStatus,
        renderVerdict,
        evidenceVerdict: task2Verdict,
        task2Verdict,
        reportingStatus,
        overallVerdict,
        assayExecution: { status: assayStatus, terminalReceipts: rows.length,
            expectedTerminalReceipts: expectedRows },
        render: { verdict: renderVerdict },
        task2Evidence: { verdict: task2Verdict,
            inconclusiveRows: rows.filter((row) => row.task2Verdict === "INCONCLUSIVE").length },
        reporting: { status: reportingStatus, reasons: reportingReasons },
        reportingContract: { complete: reportingStatus === "COMPLETE",
            status: reportingStatus, reasons: reportingReasons },
        transitions: rows,
    };
    const reportText = report(summary);
    const csvText = csv(rows);
    const summaryText = `${JSON.stringify(summary, null, 2)}\n`;

    // All raw evidence and identities are validated before replacing any output.
    writeAtomic(path.join(root, "summary.json"), summaryText);
    writeAtomic(path.join(root, "transitions.csv"), csvText);
    writeAtomic(path.join(root, "report.md"), reportText);

    const files = walk(root).filter((file) =>
        path.basename(file) !== "receipt-index.json" &&
        !file.endsWith(".tmp-finalizer")).sort();
    const index = {
        schemaVersion: `renderscale-tuning-${variant}-receipt-index-v2`,
        generatedUtc,
        runId: runIds[0],
        buildId: buildIds[0],
        assayStatus,
        renderVerdict,
        task2Verdict,
        reportingStatus,
        files: files.map((file) => ({ path: relative(root, file),
            bytes: fs.statSync(file).size, sha256: sha256(file) })),
    };
    writeAtomic(path.join(root, "receipt-index.json"),
        `${JSON.stringify(index, null, 2)}\n`);
    return { summary, index };
}

function parseArguments(argv) {
    const result = {};
    for (let index = 0; index < argv.length; index += 2) {
        const name = argv[index];
        if (!name.startsWith("--") || argv[index + 1] === undefined) {
            throw new Error("invalid_arguments");
        }
        result[name.slice(2)] = argv[index + 1];
    }
    return result;
}

if (require.main === module) {
    try {
        const args = parseArguments(process.argv.slice(2));
        const result = finalizeEvidence({
            root: args.root,
            variant: args.variant,
            runId: args["run-id"],
            buildId: args["build-id"],
            expectedRows: args["expected-rows"] ? Number(args["expected-rows"]) : undefined,
            generatedUtc: args["generated-utc"],
        });
        process.stdout.write(`${JSON.stringify({ ok: true,
            assayStatus: result.summary.assayExecution.status,
            renderVerdict: result.summary.render.verdict,
            task2Verdict: result.summary.task2Evidence.verdict,
            reportingStatus: result.summary.reporting.status })}\n`);
    } catch (error) {
        process.stderr.write(`${error.stack || error}\n`);
        process.exitCode = 1;
    }
}

module.exports = {
    collectTracePages,
    finalizeEvidence,
    normalizeTask2,
    traceCapacity,
    validateTracePage,
};
