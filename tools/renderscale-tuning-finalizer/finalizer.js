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

function qualificationWait(value) {
    if (value && Array.isArray(value.content) && value.content[0] &&
        typeof value.content[0].text === "string") {
        return qualificationWait(JSON.parse(value.content[0].text));
    }
    if (value && Array.isArray(value.results)) {
        const step = value.results.find((entry) => entry && entry.result &&
            (entry.label === "qualification-wait" ||
                entry.result.action === "qualification_wait"));
        return step && step.result;
    }
    return value && value.action === "qualification_wait" ? value : null;
}

function interruptedLiveResult(root, variant, runId) {
    const file = path.join(root, "raw", "live-result.json");
    if (!fs.existsSync(file)) return null;
    const value = readJson(file);
    if (value.status !== "INTERRUPTED") return null;
    if (value.variant !== variant || value.runId !== runId) {
        throw new Error("interrupted_result_identity_mismatch");
    }
    return value;
}

function validateBaselineOnlyInterruption(root, variant, runId, buildId) {
    const liveResultPath = path.join(root, "raw", "live-result.json");
    if (!fs.existsSync(liveResultPath)) {
        throw new Error("baseline_interruption_result_missing");
    }
    const liveResult = readJson(liveResultPath);
    if (liveResult.status !== "INTERRUPTED" || liveResult.variant !== variant ||
        liveResult.runId !== runId) {
        throw new Error("baseline_interruption_identity_mismatch");
    }
    const baselineFiles = walk(path.join(root, "raw")).filter((file) =>
        path.basename(file) === "baseline.json" &&
        relative(root, file).split("/").includes("baseline"));
    if (baselineFiles.length === 0) {
        throw new Error("baseline_interruption_receipt_missing");
    }
    for (const file of baselineFiles) {
        const waiter = qualificationWait(readJson(file));
        if (!waiter || !waiter.producer || waiter.producer.buildId !== buildId ||
            typeof waiter.ownerId !== "string" ||
            !waiter.ownerId.startsWith(`${runId}-`) || !waiter.baseline ||
            !Number.isSafeInteger(waiter.baseline.stressSessionId) ||
            waiter.baseline.stressSessionId < 1) {
            throw new Error("baseline_interruption_receipt_mismatch");
        }
    }
}

function baselineOnlyMemoryConfirmation() {
    return {
        passesCompleted: 0,
        cooldownMilliseconds: null,
        boundaries: { pass1: null, cooldown: null, pass2: null },
        deltas: null,
        ratios: null,
        predicateInputs: { available: false, reason: "repeat_not_completed" },
        unavailableBoundaries: ["pass1_start", "pass1_end", "cooldown_start",
            "cooldown_end", "pass2_start", "pass2_end"],
        verdict: "repeat_not_completed",
        conclusion: "no_leak_or_retention_conclusion_possible",
    };
}

function deploymentVerification(root, buildId, options) {
    const file = path.join(root, "raw", "startup", "deployment-verification.json");
    const retainedManifest = path.join(
        root, "raw", "startup", "deployment-manifest.json");
    if (options.artifactPath || options.manifestPath) {
        if (!options.artifactPath || !options.manifestPath) {
            throw new Error("deployment_verification_paths_incomplete");
        }
        const artifactPath = path.resolve(options.artifactPath);
        const manifestPath = path.resolve(options.manifestPath);
        const manifest = readJson(manifestPath);
        const expected = manifest && manifest.artifact;
        const artifactBytes = fs.statSync(artifactPath).size;
        const artifactSha256 = sha256(artifactPath);
        if (manifest.buildId !== buildId || !expected ||
            String(expected.sha256).toLowerCase() !== artifactSha256 ||
            Number(expected.sizeBytes) !== artifactBytes) {
            throw new Error("deployment_manifest_mismatch");
        }
        const receipt = {
            schemaVersion: "renderscale-tuning-deployment-verification-v1",
            buildId,
            artifact: { fileName: path.basename(artifactPath),
                bytes: artifactBytes, sha256: artifactSha256 },
            manifest: { fileName: path.basename(manifestPath),
                path: relative(root, retainedManifest),
                sha256: sha256(manifestPath) },
            manifestVerified: true,
        };
        fs.mkdirSync(path.dirname(file), { recursive: true });
        writeAtomic(retainedManifest, fs.readFileSync(manifestPath));
        writeAtomic(file, `${JSON.stringify(receipt, null, 2)}\n`);
    }
    if (!fs.existsSync(file)) {
        return { complete: false, reason: "deployment_verification_missing" };
    }
    const receipt = readJson(file);
    if (receipt.buildId !== buildId || receipt.manifestVerified !== true ||
        !receipt.artifact ||
        !/^[a-f0-9]{64}$/i.test(String(receipt.artifact.sha256 || "")) ||
        !Number.isSafeInteger(receipt.artifact.bytes) ||
        receipt.artifact.bytes < 1 || !receipt.manifest ||
        typeof receipt.manifest.path !== "string") {
        throw new Error("deployment_verification_invalid");
    }
    const manifestEvidence = path.resolve(root, receipt.manifest.path);
    if (!manifestEvidence.startsWith(`${root}${path.sep}`) ||
        !fs.existsSync(manifestEvidence) ||
        sha256(manifestEvidence) !== receipt.manifest.sha256) {
        throw new Error("deployment_manifest_evidence_invalid");
    }
    return { complete: true, receipt: relative(root, file),
        artifactSha256: receipt.artifact.sha256 };
}

function aggregateVerdict(values) {
    if (values.includes("FAIL")) return "FAIL";
    if (values.includes("INCONCLUSIVE")) return "INCONCLUSIVE";
    return values.length > 0 && values.every((value) => value === "PASS") ?
        "PASS" : "INCONCLUSIVE";
}

function verdictCounts(values) {
    const counts = { PASS: 0, FAIL: 0, INCONCLUSIVE: 0 };
    for (const value of values) {
        if (Object.hasOwn(counts, value)) counts[value] += 1;
        else throw new Error("invalid_task2_verdict");
    }
    return counts;
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

function exposed(value) {
    return value === null || value === undefined ? "not_exposed" : value;
}

function facetValue(facet, name) {
    return facet && typeof facet === "object" ? exposed(facet[name]) :
        "not_exposed";
}

function proofEyeValue(facet, side, name) {
    if (!facet || typeof facet !== "object") return "not_exposed";
    const proof = facet.presentationProof &&
        typeof facet.presentationProof === "object" ? facet.presentationProof : null;
    const eye = proof && proof[`${side}Eye`] || facet[`${side}Eye`];
    return eye && typeof eye === "object" ? exposed(eye[name]) : "not_exposed";
}

function transitionDiagnostics(timeline) {
    const dispatch = timeline.dispatch || null;
    const terminal = timeline.terminal || null;
    const boundary = timeline.firstPhysicalMutation || null;
    const eyeValues = (facet, side) => ({
        generation: proofEyeValue(facet, side, "generation"),
        transitionEpoch: proofEyeValue(facet, side, "transitionEpoch"),
        resourceRevision: proofEyeValue(facet, side, "resourceRevision"),
    });
    return {
        diagnosticOnly: true,
        boundaryExposed: boundary !== null,
        dispatchFrame: facetValue(dispatch, "frame"),
        dispatchQpcTick: exposed(dispatch && (dispatch.tick ?? dispatch.qpcTick)),
        dispatchLeft: eyeValues(dispatch, "left"),
        dispatchRight: eyeValues(dispatch, "right"),
        terminalFrame: facetValue(terminal, "frame"),
        terminalQpcTick: exposed(terminal && (terminal.tick ?? terminal.qpcTick)),
        terminalLeft: eyeValues(terminal, "left"),
        terminalRight: eyeValues(terminal, "right"),
        firstPhysicalMutationFrame: facetValue(boundary, "frame"),
        firstPhysicalMutationQpcTick:
            exposed(boundary && (boundary.tick ?? boundary.qpcTick)),
        firstPhysicalMutationSource:
            facetValue(boundary, "physicalMutationSource"),
    };
}

function pointerSegment(value) {
    return String(value).replaceAll("~", "~0").replaceAll("/", "~1");
}

function flattenJson(value, pointer, emit) {
    if (Array.isArray(value)) {
        if (value.length === 0) {
            emit(pointer, "empty_array", "[]");
            return;
        }
        value.forEach((entry, index) =>
            flattenJson(entry, `${pointer}/${index}`, emit));
        return;
    }
    if (value !== null && typeof value === "object") {
        const keys = Object.keys(value).sort((left, right) =>
            left.localeCompare(right));
        if (keys.length === 0) {
            emit(pointer, "empty_object", "{}");
            return;
        }
        for (const key of keys) {
            flattenJson(value[key], `${pointer}/${pointerSegment(key)}`, emit);
        }
        return;
    }
    const type = value === null ? "null" : typeof value;
    if (type === "number" && (!Number.isFinite(value) ||
        (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
        throw new Error("evidence_numeric_value_not_lossless");
    }
    emit(pointer, type, JSON.stringify(value));
}

function rawIdentity(root, file) {
    const parts = relative(root, file).split("/");
    const passPart = parts.find((part) => /^pass-\d+$/.test(part));
    const transitionIndex = parts.indexOf("transitions");
    const ordinalPart = transitionIndex >= 0 ? parts[transitionIndex + 1] : null;
    const lanePart = parts.find((part) => /^lane-/.test(part));
    return {
        lane: lanePart ? lanePart.slice(5) : "",
        pass: passPart ? Number(passPart.slice(5)) : "",
        ordinal: ordinalPart && /^\d+$/.test(ordinalPart) ?
            Number(ordinalPart) : "",
    };
}

function evidenceValues(root) {
    const rawRoot = path.join(root, "raw");
    const files = fs.existsSync(rawRoot) ? walk(rawRoot).filter((file) =>
        path.extname(file).toLowerCase() === ".json").sort() : [];
    const columns = ["source_path", "lane", "pass", "ordinal",
        "json_pointer", "value_type", "value_json"];
    const lines = [columns.join(",")];
    const stats = { rawJsonFiles: files.length, values: 0, nullValues: 0,
        emptyContainers: 0 };
    for (const file of files) {
        const source = relative(root, file);
        const identity = rawIdentity(root, file);
        flattenJson(readJson(file), "", (pointer, type, valueJson) => {
            stats.values += 1;
            if (type === "null") stats.nullValues += 1;
            if (type === "empty_array" || type === "empty_object") {
                stats.emptyContainers += 1;
            }
            lines.push([source, identity.lane, identity.pass, identity.ordinal,
                pointer, type, valueJson].map(csvCell).join(","));
        });
    }
    return { text: `${lines.join("\n")}\n`, stats };
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
    const producerInvalid = unique(projection.producerInvalidEvidence || []);
    const counters = projection.invariantViolations || {};
    const reportedViolations = unique(projection.reportedInvariantViolations ||
        Object.entries(counters).filter(([, value]) => value > 0)
            .map(([name]) => name));
    const violationAuthority = projection.violationAuthority || {};
    const hasViolationAuthority = Object.keys(violationAuthority).length > 0;
    let authoritativeViolations = (projection.genuineInvariantViolations || [])
        .filter((name) => !hasViolationAuthority ||
            violationAuthority[name] &&
            violationAuthority[name].status === "MATCHED");
    let verdict = projection.task2Verdict || projection.evidenceVerdict ||
        "INCONCLUSIVE";
    const audit = waiter.presentationCycleAudit || retained.presentationCycleAudit || {};
    if (!Number.isSafeInteger(waiter.schemaRevision) ||
        waiter.schemaRevision < 14) {
        missing.push("authoritative_violation_schema");
    }
    if (!Number.isSafeInteger(audit.eyeObservations) ||
        audit.eyeObservations < 1) {
        missing.push("authoritative_cycle_observations");
    }
    const authorityMissing = missing.some((value) => [
        "authoritative_cycle_audit",
        "authoritative_cycle_owner",
        "authoritative_cycle_counters",
        "authoritative_cycle_observations",
        "authoritative_violation_schema",
    ].includes(value));
    const authorityInvalid = producerInvalid.some((value) =>
        value === "physical_mutation_boundary_owner_mismatch" ||
        /_(first_offender_missing|temporal_order_unproven|temporal_order_conflict|not_before_boundary|precedes_boundary)$/.test(
            value));
    if (!hasViolationAuthority && authorityInvalid) {
        authoritativeViolations = [];
    }
    let phaseCountersAuthoritative =
        projection.phaseCountersAuthoritative !== false &&
        !authorityMissing && !authorityInvalid;

    if (expectation === "required" && !boundary) {
        missing.push("missing_required_mutation_boundary");
        authoritativeViolations = [];
        phaseCountersAuthoritative = false;
        verdict = "INCONCLUSIVE";
    } else if (authoritativeViolations.length > 0) {
        verdict = "FAIL";
    } else if (!phaseCountersAuthoritative) {
        authoritativeViolations = [];
        verdict = "INCONCLUSIVE";
    }
    const baselineSession = waiter.baseline && waiter.baseline.stressSessionId;
    const derivedMismatchReasons = [];
    if (Number.isSafeInteger(audit.ownerTransitionId) &&
        audit.ownerTransitionId > 0 &&
        Number.isSafeInteger(waiter.transitionId) && waiter.transitionId > 0 &&
        audit.ownerTransitionId !== waiter.transitionId) {
        derivedMismatchReasons.push("audit_transition_owner_mismatch");
    }
    if (boundary && Number.isSafeInteger(boundary.stressSessionId) &&
        boundary.stressSessionId > 0 && Number.isSafeInteger(baselineSession) &&
        baselineSession > 0 && boundary.stressSessionId !== baselineSession) {
        derivedMismatchReasons.push("boundary_stress_session_mismatch");
    }
    if (boundary && Number.isSafeInteger(boundary.qualificationTransitionId) &&
        boundary.qualificationTransitionId > 0 &&
        Number.isSafeInteger(waiter.transitionId) && waiter.transitionId > 0 &&
        boundary.qualificationTransitionId !== waiter.transitionId) {
        derivedMismatchReasons.push("boundary_transition_owner_mismatch");
    }
    if (boundary && Number.isSafeInteger(boundary.ownershipToken) &&
        boundary.ownershipToken > 0 && Number.isSafeInteger(audit.ownerToken) &&
        audit.ownerToken > 0 && boundary.ownershipToken !== audit.ownerToken) {
        derivedMismatchReasons.push("boundary_audit_token_mismatch");
    }
    const temporalMismatchReasons = producerInvalid.filter((value) =>
        /_(temporal_order_conflict|not_before_boundary|precedes_boundary)$/.test(
            value));
    const projectedMismatchReasons =
        projection.phaseCounterAuthorityStatus === "MISMATCHED" ?
            projection.phaseCounterAuthorityReasons || [] : [];
    const mismatchReasons = unique([...derivedMismatchReasons,
        ...temporalMismatchReasons, ...projectedMismatchReasons]);
    const explicitMismatch = mismatchReasons.length > 0;
    const authorityStatus = explicitMismatch ? "MISMATCHED" :
        !phaseCountersAuthoritative ? "INCOMPLETE" :
            projection.phaseCounterAuthorityStatus || "MATCHED";
    const projectedAuthorityReasons =
        Array.isArray(projection.phaseCounterAuthorityReasons) &&
        projection.phaseCounterAuthorityReasons.length > 0 ?
            projection.phaseCounterAuthorityReasons : null;
    const authorityReasons = unique(authorityStatus === "MISMATCHED" ?
        mismatchReasons : projectedAuthorityReasons ||
        [...missing.filter((value) => value.startsWith("authoritative_") ||
            value === "missing_required_mutation_boundary"),
        ...producerInvalid.filter((value) =>
            /_(first_offender_missing|temporal_order_unproven)$/.test(value))]);
    return {
        verdict,
        expectation,
        missingEvidence: unique(missing),
        phaseCountersAuthoritative,
        authorityStatus,
        authorityReasons,
        observedPhaseCounters: counters,
        reportedViolations,
        violationAuthority,
        authoritativeViolations,
        producerInvalidEvidence: producerInvalid,
        auditStorageComplete: projection.auditStorageComplete ??
            (audit.evidenceComplete === true && audit.retentionOverflow !== true),
        ownerCorrelatedAuditObserved:
            projection.ownerCorrelatedAuditObserved ??
            (audit.ownerTransitionId === waiter.transitionId &&
                Number.isSafeInteger(audit.ownerToken) && audit.ownerToken > 0 &&
                Number.isSafeInteger(audit.eyeObservations) &&
                audit.eyeObservations > 0),
        transitionEvidenceComplete:
            projection.transitionEvidenceComplete ??
            (Boolean(timeline.dispatch) &&
                audit.evidenceComplete === true &&
                audit.retentionOverflow !== true &&
                audit.ownerTransitionId === waiter.transitionId &&
                Number.isSafeInteger(audit.ownerToken) && audit.ownerToken > 0 &&
                Number.isSafeInteger(audit.eyeObservations) &&
                audit.eyeObservations > 0 &&
                Number.isSafeInteger(waiter.schemaRevision) &&
                waiter.schemaRevision >= 14),
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
    const diagnostics = transitionDiagnostics(timeline);
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
        task2ProducerInvalidEvidence: task2.producerInvalidEvidence,
        phaseCountersAuthoritative: task2.phaseCountersAuthoritative,
        phaseCounterAuthorityStatus: task2.authorityStatus,
        phaseCounterAuthorityReasons: task2.authorityReasons,
        observedPhaseCounters: task2.observedPhaseCounters,
        reportedTask2Violations: task2.reportedViolations,
        task2ViolationAuthority: task2.violationAuthority,
        authoritativeTask2Violations: task2.authoritativeViolations,
        auditStorageComplete: task2.auditStorageComplete,
        ownerCorrelatedAuditObserved: task2.ownerCorrelatedAuditObserved,
        transitionEvidenceComplete: task2.transitionEvidenceComplete,
        mutationExpectation: task2.expectation,
        diagnostics,
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

function transitionWasDispatched(retained) {
    const waiter = retained && retained.waiter;
    return Boolean(waiter &&
        ((waiter.replacementTimeline && waiter.replacementTimeline.dispatch) ||
            (waiter.frames && Number.isSafeInteger(waiter.frames.dispatch)) ||
            (waiter.timing && Number.isSafeInteger(waiter.timing.dispatchTick))));
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
        "missing_evidence", "producer_invalid_evidence", "reported_violations",
        "authoritative_violations", "violation_authority",
        "phase_counter_authority_status",
        "phase_counter_authority_reasons", "phase_counters_authoritative",
        "audit_storage_complete", "owner_correlated_audit_observed",
        "transition_evidence_complete",
        "physical_mutation_started", "final_method", "final_quality",
        "final_render_scale_mode", "final_state_revision", "trace_required",
        "trace_complete", "boundary_exposed", "dispatch_frame",
        "dispatch_qpc_tick", "dispatch_left_generation",
        "dispatch_left_transition_epoch", "dispatch_left_resource_revision",
        "dispatch_right_generation", "dispatch_right_transition_epoch",
        "dispatch_right_resource_revision",
        "terminal_frame", "terminal_qpc_tick", "terminal_left_generation",
        "terminal_left_transition_epoch", "terminal_left_resource_revision",
        "terminal_right_generation", "terminal_right_transition_epoch",
        "terminal_right_resource_revision",
        "first_physical_mutation_frame", "first_physical_mutation_qpc_tick",
        "first_physical_mutation_source", "raw_retained",
    ];
    const lines = [columns.join(",")];
    for (const row of rows) {
        const diagnostics = row.diagnostics;
        const values = [row.lane, row.pass, row.ordinal, row.target.method,
            row.target.qualityMode, row.target.renderScaleMode, row.renderVerdict,
            row.task2Verdict, row.mutationExpectation, row.task2MissingEvidence,
            row.task2ProducerInvalidEvidence, row.reportedTask2Violations,
            row.authoritativeTask2Violations,
            row.task2ViolationAuthority,
            row.phaseCounterAuthorityStatus, row.phaseCounterAuthorityReasons,
            row.phaseCountersAuthoritative, row.auditStorageComplete,
            row.ownerCorrelatedAuditObserved, row.transitionEvidenceComplete,
            row.physicalMutationStarted,
            row.finalMethod, row.finalQuality, row.finalRenderScaleMode,
            row.finalStateRevision, row.traceRequired, row.traceComplete,
            diagnostics.boundaryExposed, diagnostics.dispatchFrame,
            diagnostics.dispatchQpcTick, diagnostics.dispatchLeft.generation,
            diagnostics.dispatchLeft.transitionEpoch,
            diagnostics.dispatchLeft.resourceRevision,
            diagnostics.dispatchRight.generation,
            diagnostics.dispatchRight.transitionEpoch,
            diagnostics.dispatchRight.resourceRevision,
            diagnostics.terminalFrame, diagnostics.terminalQpcTick,
            diagnostics.terminalLeft.generation,
            diagnostics.terminalLeft.transitionEpoch,
            diagnostics.terminalLeft.resourceRevision,
            diagnostics.terminalRight.generation,
            diagnostics.terminalRight.transitionEpoch,
            diagnostics.terminalRight.resourceRevision,
            diagnostics.firstPhysicalMutationFrame,
            diagnostics.firstPhysicalMutationQpcTick,
            diagnostics.firstPhysicalMutationSource,
            row.rawRetained];
        lines.push(values.map(csvCell).join(","));
    }
    return `${lines.join("\n")}\n`;
}

function report(summary) {
    const rows = summary.transitions.map((row) =>
        `| ${row.lane || "default"} | ${row.pass} | ${row.ordinal} | ` +
        `${row.renderVerdict} | ${row.task2Verdict} | ` +
        `${row.phaseCounterAuthorityStatus} | ` +
        `${row.reportedTask2Violations.join("; ") || "none"} | ` +
        `${row.task2MissingEvidence.join("; ") || "none"} | ` +
        `${row.task2ProducerInvalidEvidence.join("; ") || "none"} |`).join("\n");
    const interruption = summary.assayExecution.interruption;
    const failure = interruption && interruption.failure;
    return `# ${summary.protocol} final report\n\n` +
        `- Assay execution: **${summary.assayExecution.status}**\n` +
        `- Transitions dispatched: **${summary.assayExecution.transitionsDispatched}/` +
        `${summary.assayExecution.expectedTransitions}**\n` +
        `- Render verdict: **${summary.render.verdict}**\n` +
        `- Task 2/evidence: **per transition** ` +
        `(${summary.task2Evidence.counts.PASS} PASS, ` +
        `${summary.task2Evidence.counts.FAIL} FAIL, ` +
        `${summary.task2Evidence.counts.INCONCLUSIVE} INCONCLUSIVE)\n` +
        `- Reporting completeness: **${summary.reporting.status}**\n` +
        `- Deployment verification: **${summary.deploymentVerification.complete ?
            "COMPLETE" : "INCOMPLETE"}**\n` +
        (interruption ?
            `- Interruption: **${interruption.error || "not_exposed"}**\n` : "") +
        (failure ?
            `- Failed scenario step: **${failure.failedStep || "not_exposed"}** ` +
            `(first unreported: ${failure.firstUnreportedStep || "none"}; ` +
            `receipt: ${failure.receiptKey || "not_exposed"})\n` : "") +
        (summary.memoryConfirmation ?
            `- Memory confirmation: **${summary.memoryConfirmation.verdict}**\n` : "") +
        `\n` +
        `Task 2 is deliberately not aggregated. Reporting failure does not ` +
        `rewrite the render result, and a render pass does not hide missing ` +
        `per-transition evidence. Every raw JSON value is available in ` +
        `\`${summary.evidenceExtraction.path}\`.\n\n` +
        `## Transitions\n\n` +
        `| Lane | Pass | Row | Render | Task 2 | Authority | Reported violations | ` +
        `Missing evidence | Invalid producer evidence |\n` +
        `| --- | ---: | ---: | --- | --- | --- | --- | --- | --- |\n${rows}\n`;
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
    const allRetained = retainedFiles.map((file) => ({ file, value: readJson(file) }));
    const retained = allRetained.filter((entry) =>
        transitionWasDispatched(entry.value));
    const undispatchedFailures = allRetained.filter((entry) =>
        !transitionWasDispatched(entry.value));
    const rows = retained.map(({ file, value }) => transitionRow(root, file, value))
        .sort((left, right) => (left.lane || "").localeCompare(right.lane || "") ||
            left.pass - right.pass || left.ordinal - right.ordinal);

    const existingSummaryPath = path.join(root, "summary.json");
    const existing = fs.existsSync(existingSummaryPath) ? readJson(existingSummaryPath) : {};
    const runIds = unique([options.runId, existing.runId]);
    const buildIds = unique([options.buildId, existing.build && existing.build.buildId]);
    if (runIds.length !== 1 || buildIds.length !== 1) {
        throw new Error("finalization_identity_ambiguous");
    }
    const interrupted = interruptedLiveResult(
        root, variant, runIds[0]);
    const expectedRows = options.expectedRows ??
        (existing.assayExecution &&
            existing.assayExecution.expectedTerminalReceipts) ??
        (existing.counts && existing.counts.transitionsExpected) ?? rows.length;
    if (!Number.isSafeInteger(expectedRows) || expectedRows < rows.length ||
        expectedRows < 1) {
        throw new Error("invalid_expected_terminal_receipts");
    }
    const baselineOnlyInterrupted = rows.length === 0;
    if (baselineOnlyInterrupted) {
        validateBaselineOnlyInterruption(root, variant, runIds[0], buildIds[0]);
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
    const assayStatus = interrupted ? "INTERRUPTED" :
        rows.length === expectedRows ? "COMPLETE" : "INCOMPLETE";
    const renderVerdict = aggregateVerdict(rows.map((row) => row.renderVerdict));
    const task2Counts = verdictCounts(rows.map((row) => row.task2Verdict));
    const reportingReasons = [];
    if (assayStatus !== "COMPLETE") reportingReasons.push("terminal_receipts_incomplete");
    if (baselineOnlyInterrupted) reportingReasons.push("baseline_only_interrupted");
    if (interrupted && !baselineOnlyInterrupted) {
        reportingReasons.push("assay_interrupted");
    }
    if (rows.some((row) => !row.traceComplete)) {
        reportingReasons.push("required_trace_evidence_incomplete");
    }
    const deployment = deploymentVerification(root, buildIds[0], options);
    if (!deployment.complete) reportingReasons.push(deployment.reason);
    const reportingStatus = reportingReasons.length === 0 ? "COMPLETE" : "INCOMPLETE";
    const extraction = evidenceValues(root);
    const generatedUtc = options.generatedUtc || existing.generatedUtc ||
        "not_exposed";
    const summary = {
        ...existing,
        schemaVersion: `renderscale-tuning-${variant}-summary-v4`,
        protocol: `renderscale-tuning-${variant}`,
        runId: runIds[0],
        generatedUtc,
        executionStatus: assayStatus,
        renderVerdict,
        reportingStatus,
        counts: baselineOnlyInterrupted ? {
            ...(existing.counts || {}),
            transitionsDispatched: 0,
            transitionsExpected: expectedRows,
        } : existing.counts,
        assayExecution: { status: assayStatus, terminalReceipts: rows.length,
            expectedTerminalReceipts: expectedRows,
            transitionsDispatched: rows.length,
            expectedTransitions: expectedRows,
            interruption: interrupted ? {
                error: interrupted.error || null,
                failure: interrupted.failure ||
                    interrupted.lanes && interrupted.lanes
                        .flatMap((lane) => lane.passes || [])
                        .find((pass) => pass.status === "INTERRUPTED")?.failure || null,
                undispatchedTransitionReceipts: undispatchedFailures.map((entry) =>
                    relative(root, entry.file)),
            } : null },
        render: { verdict: renderVerdict },
        task2Evidence: { mode: "per_transition", counts: task2Counts,
            aggregateVerdict: "NOT_COMPUTED" },
        reporting: { status: reportingStatus, reasons: reportingReasons },
        reportingContract: { complete: reportingStatus === "COMPLETE",
            status: reportingStatus, reasons: reportingReasons },
        deploymentVerification: deployment,
        memoryConfirmation: baselineOnlyInterrupted ?
            baselineOnlyMemoryConfirmation() : existing.memoryConfirmation,
        evidenceExtraction: { complete: true,
            path: "evidence-values.csv",
            format: "rfc6901-json-pointer-long-form-csv",
            ...extraction.stats },
        transitions: rows,
    };
    delete summary.evidenceVerdict;
    delete summary.task2Verdict;
    delete summary.overallVerdict;
    const reportText = report(summary);
    const csvText = csv(rows);
    const summaryText = `${JSON.stringify(summary, null, 2)}\n`;

    // All raw evidence and identities are validated before replacing any output.
    writeAtomic(path.join(root, "summary.json"), summaryText);
    writeAtomic(path.join(root, "transitions.csv"), csvText);
    writeAtomic(path.join(root, "report.md"), reportText);
    writeAtomic(path.join(root, "evidence-values.csv"), extraction.text);

    const files = walk(root).filter((file) =>
        path.basename(file) !== "receipt-index.json" &&
        !file.endsWith(".tmp-finalizer")).sort();
    const index = {
        schemaVersion: `renderscale-tuning-${variant}-receipt-index-v3`,
        generatedUtc,
        runId: runIds[0],
        buildId: buildIds[0],
        assayStatus,
        renderVerdict,
        task2Evidence: { mode: "per_transition", counts: task2Counts,
            aggregateVerdict: "NOT_COMPUTED" },
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
            artifactPath: args["artifact-path"],
            manifestPath: args["manifest-path"],
        });
        process.stdout.write(`${JSON.stringify({ ok: true,
            assayStatus: result.summary.assayExecution.status,
            renderVerdict: result.summary.render.verdict,
            task2EvidenceMode: result.summary.task2Evidence.mode,
            task2RowCounts: result.summary.task2Evidence.counts,
            reportingStatus: result.summary.reporting.status })}\n`);
    } catch (error) {
        process.stderr.write(`${error.stack || error}\n`);
        process.exitCode = 1;
    }
}

module.exports = {
    collectTracePages,
    deploymentVerification,
    finalizeEvidence,
    normalizeTask2,
    traceCapacity,
    validateTracePage,
};
