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
    if (!page || page.action !== "dlss_trace_read" || page.ok === false ||
        page.isError === true || !capture ||
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
    if (!Number.isSafeInteger(capture.limit) ||
        capture.limit > state.maximum || capture.limit < 1 ||
        capture.records.length > capture.limit) {
        throw new Error("trace_page_limit_out_of_range");
    }
    if (!Number.isSafeInteger(capture.afterSequence) ||
        capture.afterSequence < 0 || capture.afterSequence !== state.afterSequence) {
        throw new Error("trace_page_cursor_mismatch");
    }
    if (typeof capture.moreAvailable !== "boolean" ||
        typeof capture.requestedSequenceOverwritten !== "boolean" ||
        !Number.isSafeInteger(capture.availableFromSequence) ||
        capture.availableFromSequence < 0 ||
        !Number.isSafeInteger(capture.latestSequence) ||
        capture.latestSequence < 0 ||
        !Number.isSafeInteger(capture.lastReturnedSequence) ||
        capture.lastReturnedSequence < 0) {
        throw new Error("trace_page_metadata_invalid");
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
    if (capture.moreAvailable === false &&
        capture.latestSequence !== lastSequence) {
        throw new Error("trace_terminal_sequence_mismatch");
    }
    if (capture.moreAvailable === true &&
        capture.latestSequence <= lastSequence) {
        throw new Error("trace_continuation_sequence_mismatch");
    }
    if (capture.moreAvailable === true && capture.records.length === 0) {
        throw new Error("trace_empty_continuation_page");
    }
    if (state.latestSequence !== null &&
        capture.latestSequence !== state.latestSequence) {
        throw new Error("trace_closed_window_changed");
    }
    return { page, sessionId, lastSequence,
        latestSequence: capture.latestSequence };
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
        latestSequence: null,
        maximum,
    };
    const pages = [];
    const records = [];

    for (let index = 0; index < existingPages.length; index += 1) {
        const rawPage = existingPages[index];
        if (index > 0 && pages[index - 1].capture.moreAvailable !== true) {
            throw new Error("trace_page_after_terminal");
        }
        const checked = validateTracePage(rawPage, state);
        state.sessionId = checked.sessionId;
        state.afterSequence = checked.lastSequence;
        state.latestSequence = checked.latestSequence;
        pages.push(checked.page);
        records.push(...checked.page.capture.records);
        if (checked.page.capture.moreAvailable !== true) {
            if (index < existingPages.length - 1) {
                throw new Error("trace_page_after_terminal");
            }
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
        state.latestSequence = checked.latestSequence;
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

function readLiveResult(root, variant, runId) {
    const file = path.join(root, "raw", "live-result.json");
    if (!fs.existsSync(file)) return null;
    const value = readJson(file);
    if (value.variant !== variant || value.runId !== runId) {
        throw new Error("live_result_identity_mismatch");
    }
    return value;
}

function decodedScenarioRoot(value) {
    if (value && Array.isArray(value.content) && value.content[0] &&
        typeof value.content[0].text === "string") {
        try {
            return decodedScenarioRoot(JSON.parse(value.content[0].text));
        } catch {
            return null;
        }
    }
    return value && Array.isArray(value.results) ? value : null;
}

function amdTraceCapabilityEvidence(root, liveResult, buildId) {
    if (!liveResult || !liveResult.traceCapability ||
        liveResult.traceCapability.status !== "supported") {
        return { complete: false,
            reasons: ["amd_trace_capability_not_supported_or_missing"] };
    }
    if (liveResult.traceCapability.lifecycle) {
        return traceLifecycleEvidence(
            liveResult.traceCapability.lifecycle, buildId, false);
    }
    const rawRoot = path.join(root, "raw");
    const files = fs.existsSync(rawRoot) ? walk(rawRoot).filter((file) =>
        path.extname(file).toLowerCase() === ".json") : [];
    for (const file of files) {
        let scenarioRoot;
        try {
            scenarioRoot = decodedScenarioRoot(readJson(file));
        } catch {
            continue;
        }
        if (!scenarioRoot) continue;
        const entries = new Map(scenarioRoot.results
            .filter((entry) => entry && typeof entry.label === "string")
            .map((entry) => [entry.label, entry.result]));
        const retained = {
            traceReset: entries.get("amd-dlss-trace-reset"),
            traceStart: entries.get("amd-dlss-trace-start"),
            traceStop: entries.get("amd-dlss-trace-stop"),
            traceRead: entries.get("amd-dlss-trace-read"),
        };
        if (Object.values(retained).every(Boolean)) {
            return traceLifecycleEvidence(retained, buildId, false);
        }
    }
    return { complete: false,
        reasons: ["amd_trace_capability_lifecycle_missing"] };
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

function validatePreBaselineInterruption(root, variant, runId, liveResult) {
    if (variant !== "amd" || !liveResult || liveResult.status !== "INTERRUPTED" ||
        liveResult.variant !== variant || liveResult.runId !== runId ||
        !Array.isArray(liveResult.lanes) || liveResult.lanes.length !== 0 ||
        typeof liveResult.error !== "string" || liveResult.error.length === 0 ||
        !liveResult.failure || typeof liveResult.failure !== "object") {
        throw new Error("pre_baseline_interruption_evidence_invalid");
    }
    const cleanup = liveResult.failure.traceCleanup || liveResult.failure.cleanup;
    if (!cleanup || !["CONFIRMED_INACTIVE", "UNRESOLVED"].includes(cleanup.status)) {
        throw new Error("pre_baseline_interruption_cleanup_missing");
    }
    if (liveResult.error === "amd_dlss_trace_not_empty") {
        const contamination = liveResult.failure.contamination;
        if (liveResult.failure.reason !== "amd_dlss_trace_not_empty" ||
            cleanup.status !== "CONFIRMED_INACTIVE" ||
            !Number.isSafeInteger(cleanup.acquiredSessionId) ||
            cleanup.acquiredSessionId < 1 || !cleanup.stop ||
            cleanup.stop.id !== cleanup.acquiredSessionId ||
            cleanup.stop.active !== false || !contamination ||
            !["records", "totalRecords", "setConstantsCalls", "evaluateCalls"]
                .every((name) => Number.isSafeInteger(contamination[name]) &&
                    contamination[name] >= 0) ||
            typeof liveResult.failure.traceLifecycleReceiptKey !== "string" ||
            liveResult.failure.traceLifecycleReceiptKey.length === 0) {
            throw new Error("pre_baseline_trace_contamination_evidence_invalid");
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
    const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;
    const rawOwnerPrerequisiteReasons = [];
    if (!positiveInteger(waiter.transitionId)) {
        rawOwnerPrerequisiteReasons.push("waiter_transition_owner_invalid");
    }
    if (!positiveInteger(audit.ownerTransitionId)) {
        rawOwnerPrerequisiteReasons.push("audit_transition_owner_invalid");
    }
    if (!positiveInteger(audit.ownerToken)) {
        rawOwnerPrerequisiteReasons.push("audit_owner_token_invalid");
    }
    if (boundary) {
        if (!positiveInteger(waiter.baseline &&
            waiter.baseline.stressSessionId)) {
            rawOwnerPrerequisiteReasons.push("baseline_stress_owner_invalid");
        }
        if (!positiveInteger(boundary.stressSessionId)) {
            rawOwnerPrerequisiteReasons.push("boundary_stress_owner_invalid");
        }
        if (!positiveInteger(boundary.qualificationTransitionId)) {
            rawOwnerPrerequisiteReasons.push("boundary_transition_owner_invalid");
        }
        if (!positiveInteger(boundary.ownershipToken)) {
            rawOwnerPrerequisiteReasons.push("boundary_owner_token_invalid");
        }
    }
    if (rawOwnerPrerequisiteReasons.length > 0) {
        missing.push("authoritative_cycle_owner");
    }
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
    if (rawOwnerPrerequisiteReasons.length > 0) {
        authoritativeViolations = [];
    }

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
    if (explicitMismatch) {
        phaseCountersAuthoritative = false;
        authoritativeViolations = [];
        verdict = "INCONCLUSIVE";
    }
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
        ...rawOwnerPrerequisiteReasons,
        ...producerInvalid.filter((value) =>
            /_(first_offender_missing|temporal_order_unproven)$/.test(value))]);
    const ownerCorrelatedAuditObserved =
        positiveInteger(waiter.transitionId) &&
        audit.ownerTransitionId === waiter.transitionId &&
        positiveInteger(audit.ownerToken) &&
        Number.isSafeInteger(audit.eyeObservations) &&
        audit.eyeObservations > 0;
    const transitionEvidenceComplete =
        Boolean(timeline.dispatch) && audit.evidenceComplete === true &&
        audit.retentionOverflow !== true && ownerCorrelatedAuditObserved &&
        Number.isSafeInteger(waiter.schemaRevision) &&
        waiter.schemaRevision >= 14;
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
        rawOwnerPrerequisitesValid:
            rawOwnerPrerequisiteReasons.length === 0,
        rawOwnerPrerequisiteReasons,
        producerInvalidEvidence: producerInvalid,
        auditStorageComplete: projection.auditStorageComplete ??
            (audit.evidenceComplete === true && audit.retentionOverflow !== true),
        ownerCorrelatedAuditObserved,
        transitionEvidenceComplete,
    };
}

function finalProfile(waiter) {
    const snapshot = waiter.upscalingSnapshot || {};
    const profiles = snapshot.profiles || {};
    const stable = snapshot.stable || profiles.stable ||
        snapshot.effective || profiles.effective || {};
    const named = (value) => value && typeof value === "object" &&
        typeof value.name === "string" ? value.name : value;
    const methodValue = named(stable.method);
    const qualityValue = named(stable.qualityMode);
    const method = typeof methodValue === "string" && methodValue.length > 0 ?
        methodValue : "not_exposed";
    const quality = (typeof qualityValue === "string" &&
        qualityValue.length > 0) || Number.isSafeInteger(qualityValue) ?
        qualityValue : "not_exposed";
    const renderScaleMode = typeof stable.renderScaleMode === "boolean" ?
        stable.renderScaleMode : "not_exposed";
    const stateRevision = Number.isSafeInteger(snapshot.stateRevision) &&
        snapshot.stateRevision >= 0 ? snapshot.stateRevision : "not_exposed";
    const missing = [];
    if (method === "not_exposed") missing.push("final_method_not_exposed");
    if (quality === "not_exposed") missing.push("final_quality_not_exposed");
    if (renderScaleMode === "not_exposed") {
        missing.push("final_render_scale_mode_not_exposed");
    }
    if (stateRevision === "not_exposed") {
        missing.push("final_state_revision_not_exposed");
    }
    return {
        method,
        quality,
        renderScaleMode,
        stateRevision,
        complete: missing.length === 0,
        missing,
    };
}

function identityKey(identity) {
    return `${identity && identity.lane || "default"}|${identity && identity.pass}|${identity && identity.ordinal}`;
}

function readExecutionPlan(root, variant, runId, buildId) {
    const file = path.join(root, "raw", "execution-plan.json");
    if (!fs.existsSync(file)) {
        return { file: null, plan: null, reasons: ["execution_plan_missing"] };
    }
    const plan = readJson(file);
    const reasons = [];
    if (!plan || plan.schemaVersion !== "renderscale-tuning-execution-plan-v1" ||
        plan.variant !== variant || plan.runId !== runId || plan.buildId !== buildId ||
        !Array.isArray(plan.entries) || plan.entries.length < 1) {
        reasons.push("execution_plan_identity_invalid");
    }
    if (Array.isArray(plan && plan.entries) && plan.entries.some((entry) =>
        !entry || !Number.isSafeInteger(entry.pass) || entry.pass < 1 ||
        !Number.isSafeInteger(entry.ordinal) || entry.ordinal < 1 ||
        !Number.isSafeInteger(entry.transitionId) || entry.transitionId < 1 ||
        typeof entry.ownerId !== "string" || !entry.ownerId.startsWith(`${runId}-`) ||
        !entry.target || typeof entry.target !== "object" ||
        !entry.laneContract || typeof entry.laneContract !== "object")) {
        reasons.push("execution_plan_entry_invalid");
    }
    return { file: relative(root, file), plan, reasons };
}

function targetsMatch(actual, expected) {
    if (!actual || !expected) return false;
    for (const name of ["method", "qualityMode", "renderScaleMode"]) {
        if (actual[name] !== expected[name]) return false;
    }
    if (actual.method === "fsr" && actual.fsrRuntime !== expected.fsrRuntime) {
        return false;
    }
    if (actual.method === "dlss" && Object.hasOwn(expected, "dlssProfile") &&
        actual.dlssProfile !== expected.dlssProfile) {
        return false;
    }
    return true;
}

function retainedPassScope(root, file) {
    const relativePath = relative(root, file);
    const parts = relativePath.split("/");
    const passPart = parts.find((part) => /^pass-\d+$/.test(part));
    const lanePart = parts.find((part) => /^lane-/.test(part));
    return {
        relativePath,
        lane: lanePart ? lanePart.slice(5) : "default",
        pass: passPart ? Number(passPart.slice(5)) : null,
    };
}

function scenarioSucceeded(value) {
    if (!value || value.ok !== true || value.aborted !== false ||
        !Number.isSafeInteger(value.stepsRun) || !Array.isArray(value.results) ||
        value.stepsRun !== value.results.length) {
        return false;
    }
    return !value.results.some((entry) => entry && (entry.ok === false ||
        entry.isError === true || entry.result &&
        (entry.result.ok === false || entry.result.isError === true)));
}

function producerBuildMatches(value, buildId) {
    return Boolean(value && value.producer && value.producer.buildId === buildId);
}

function rawPassEvidence(root) {
    const rawRoot = path.join(root, "raw");
    if (!fs.existsSync(rawRoot)) {
        return { scenarios: [], cleanup: [], transitions: [] };
    }
    const scenarios = [];
    const cleanup = [];
    const transitions = [];
    for (const file of walk(rawRoot).filter((candidate) =>
        path.extname(candidate).toLowerCase() === ".json" &&
        path.basename(candidate) !== "live-result.json")) {
        let value;
        try {
            value = readJson(file);
        } catch {
            continue;
        }
        const scope = retainedPassScope(root, file);
        if (path.basename(file) === "retained.json" && rowIdentity(root, file)) {
            transitions.push({ value, scope, identity: rowIdentity(root, file) });
        }
        const rootValue = decodedScenarioRoot(value);
        if (rootValue) scenarios.push({ value: rootValue, scope });
        if (value && value.status === "CONFIRMED_INACTIVE" &&
            Array.isArray(value.knownSessionIds) && value.after) {
            cleanup.push({ value, scope });
        }
    }
    return { scenarios, cleanup, transitions };
}

function scenarioResult(root, label) {
    const entry = root && Array.isArray(root.results) ? root.results.find(
        (candidate) => candidate && candidate.label === label) : null;
    return entry && entry.result;
}

function stressSession(value) {
    const session = value && value.status && value.status.session;
    return {
        id: session && Number.isSafeInteger(session.id) ? session.id : null,
        active: session && typeof session.active === "boolean" ?
            session.active : null,
    };
}

function passFinalizationEvidence(root, liveResult, planEntries, rows, variant,
    buildId) {
    const reasons = [];
    if (!liveResult || liveResult.ok !== true ||
        liveResult.status !== "COMPLETE" || !Array.isArray(liveResult.lanes)) {
        return { complete: false, reasons: ["live_result_complete_missing"],
            passes: [] };
    }
    const passKeys = unique(planEntries.map((entry) =>
        `${entry.lane || "default"}|${entry.pass}`));
    const raw = rawPassEvidence(root);
    const results = [];
    const ownerPairs = [];
    for (const key of passKeys) {
        const [laneId, passText] = key.split("|");
        const passNumber = Number(passText);
        const plannedPass = planEntries.filter((entry) =>
            `${entry.lane || "default"}|${entry.pass}` === key);
        const liveLaneIds = unique(plannedPass.map((entry) =>
            entry.laneContract && entry.laneContract.id || entry.lane || "default"));
        const liveLaneId = liveLaneIds.length === 1 ? liveLaneIds[0] : null;
        const lane = liveResult.lanes.find((candidate) => candidate &&
            (candidate.id || "default") === liveLaneId);
        const pass = lane && Array.isArray(lane.passes) ? lane.passes.find(
            (candidate) => candidate && candidate.pass === passNumber) : null;
        const passReasons = [];
        const ownership = pass && pass.ownership || {};
        const baseline = ownership.baseline || {};
        const measured = ownership.measured || {};
        const trace = ownership.trace || {};
        const cpu = ownership.cpu || {};
        const traceRequired = variant === "nvidia" && plannedPass.some((entry) =>
            entry.target && entry.target.method === "dlss");
        const cleanup = pass && pass.cleanup || {};
        const after = cleanup.after || {};
        const positive = (value) => Number.isSafeInteger(value) && value > 0;
        if (positive(baseline.startSessionId) && positive(measured.sessionId)) {
            const ownerPair = `${baseline.startSessionId}|${measured.sessionId}`;
            if (ownerPairs.includes(ownerPair)) {
                passReasons.push("pass_owner_identity_reused");
            }
            ownerPairs.push(ownerPair);
        }
        if (!pass || pass.status !== "COMPLETE") {
            passReasons.push("pass_complete_missing");
        }
        if (liveLaneId === null) {
            passReasons.push("planned_lane_contract_ambiguous");
        }
        if (baseline.proven !== true || !positive(baseline.startSessionId) ||
            baseline.active !== false) {
            passReasons.push("baseline_owner_finalization_invalid");
        }
        if (measured.proven !== true || !positive(measured.sessionId) ||
            measured.active !== false) {
            passReasons.push("measured_owner_finalization_invalid");
        }
        if (cpu.proven !== true || !positive(cpu.sessionId) ||
            cpu.active !== false) {
            passReasons.push("cpu_owner_finalization_invalid");
        }
        const acquisitionPlan = plannedPass.find((entry) => entry.ordinal === 1);
        const acquisitionRecord = acquisitionPlan && raw.transitions.find((candidate) =>
            identityKey(candidate.identity) === identityKey(acquisitionPlan));
        const acquisition = acquisitionRecord && acquisitionRecord.value.cpuAcquisition;
        const acquisitionStep = acquisitionRecord &&
            acquisitionRecord.value.cpuAcquisitionStep;
        const telemetry = acquisition && acquisition.performanceTelemetry;
        const acquiredCpu = telemetry && telemetry.cpuPerformance;
        if (!acquisition) {
            passReasons.push("retained_cpu_acquisition_receipt_missing");
        } else {
            if (acquisition.ok === false || acquisition.isError === true ||
                acquisition.action !== "qualification_dispatch" ||
                acquisition.accepted !== true) {
                passReasons.push("retained_cpu_acquisition_receipt_invalid");
            }
            if (!acquisitionStep ||
                acquisitionStep.label !== "qualification-dispatch" ||
                acquisitionStep.ok === false ||
                acquisitionStep.isError === true ||
                !acquisitionStep.result ||
                JSON.stringify(acquisitionStep.result) !==
                    JSON.stringify(acquisition)) {
                passReasons.push("retained_cpu_acquisition_step_mismatch");
            }
            if (!acquisitionPlan || acquisition.transitionId !==
                acquisitionPlan.transitionId || acquisition.ownerId !==
                acquisitionPlan.ownerId) {
                passReasons.push("retained_cpu_acquisition_owner_mismatch");
            }
            if (!producerBuildMatches(acquisition, buildId)) {
                passReasons.push("retained_cpu_acquisition_build_mismatch");
            }
            if (!telemetry || telemetry.started !== true || !acquiredCpu ||
                acquiredCpu.active !== true) {
                passReasons.push("retained_cpu_acquisition_inactive");
            }
            if (!acquiredCpu || !positive(acquiredCpu.sessionId)) {
                passReasons.push("retained_cpu_acquisition_session_invalid");
            } else if (acquiredCpu.sessionId !== cpu.sessionId) {
                passReasons.push("retained_cpu_acquisition_session_mismatch");
            }
        }
        if (cleanup.status !== "CONFIRMED_INACTIVE" ||
            !Array.isArray(cleanup.knownSessionIds) ||
            !cleanup.knownSessionIds.includes(baseline.startSessionId) ||
            !cleanup.knownSessionIds.includes(measured.sessionId) ||
            !Array.isArray(cleanup.knownCpuSessionIds) ||
            !cleanup.knownCpuSessionIds.includes(cpu.sessionId)) {
            passReasons.push("cleanup_owner_certificate_invalid");
        }
        const activeNames = ["stressActive", "cpuActive", "gpuActive",
            "textureActive", "probeActive", "traceActive"];
        if (!Array.isArray(after.missing) || after.missing.length > 0 ||
            activeNames.some((name) => after[name] !== false)) {
            passReasons.push("cleanup_inactivity_unproven");
        }
        const scopeMatches = (candidate, phase) => candidate.scope.pass === passNumber &&
            candidate.scope.lane === laneId &&
            candidate.scope.relativePath.toLowerCase().includes(`/${phase}/`);
        const baselineReceipt = raw.scenarios.find((candidate) => {
            const startResult = scenarioResult(candidate.value,
                "baseline-stress-start");
            const start = stressSession(startResult);
            const waiter = scenarioResult(candidate.value, "qualification-wait");
            return scopeMatches(candidate, "baseline") &&
                scenarioSucceeded(candidate.value) &&
                producerBuildMatches(startResult, buildId) &&
                producerBuildMatches(waiter, buildId) &&
                startResult.action === "start" &&
                waiter.action === "qualification_wait" &&
                start.id === baseline.startSessionId &&
                start.active === true && waiter.baseline &&
                waiter.baseline.stressSessionId === baseline.startSessionId;
        });
        if (!baselineReceipt) {
            passReasons.push("retained_baseline_owner_receipt_missing");
        }
        const handoffReceipt = raw.scenarios.find((candidate) => {
            const stopResult = scenarioResult(candidate.value,
                "baseline-stress-stop");
            const startResult = scenarioResult(candidate.value,
                "measured-stress-start");
            const stopped = stressSession(stopResult);
            const started = stressSession(startResult);
            return scopeMatches(candidate, "handoff") &&
                scenarioSucceeded(candidate.value) &&
                producerBuildMatches(stopResult, buildId) &&
                producerBuildMatches(startResult, buildId) &&
                stopResult.action === "stop" && startResult.action === "start" &&
                stopped.id === baseline.startSessionId &&
                stopped.active === false && started.id === measured.sessionId &&
                started.active === true;
        });
        if (!handoffReceipt) {
            passReasons.push("retained_handoff_owner_receipt_missing");
        }
        const cleanupReceipt = raw.cleanup.find((candidate) => {
            const value = candidate.value;
            return scopeMatches(candidate, "cleanup") &&
                value.knownSessionIds.includes(baseline.startSessionId) &&
                value.knownSessionIds.includes(measured.sessionId) &&
                Array.isArray(value.knownCpuSessionIds) &&
                value.knownCpuSessionIds.includes(cpu.sessionId) &&
                value.after.stressSessionId === measured.sessionId &&
                value.after.cpuSessionId === cpu.sessionId &&
                (!traceRequired ||
                    Array.isArray(value.knownTraceSessionIds) &&
                    value.knownTraceSessionIds.includes(trace.sessionId) &&
                    value.after.traceSessionId === trace.sessionId) &&
                Array.isArray(value.after.missing) &&
                value.after.missing.length === 0 &&
                ["stressActive", "cpuActive", "gpuActive", "textureActive",
                    "probeActive", "traceActive"].every((name) =>
                    value.after[name] === false);
        });
        if (!cleanupReceipt) {
            passReasons.push("retained_cleanup_receipt_missing");
        }
        const statusReceipt = raw.scenarios.find((candidate) => {
            if (!scopeMatches(candidate, "cleanup") ||
                !candidate.scope.relativePath.toLowerCase().includes(
                    "final-status-after-cleanup") ||
                !scenarioSucceeded(candidate.value)) {
                return false;
            }
            const renderResult = scenarioResult(candidate.value, "render-status");
            const cpuResult = scenarioResult(candidate.value, "cpu-status");
            const gpuResult = scenarioResult(candidate.value, "gpu-status");
            const textureResult = scenarioResult(candidate.value, "texture-status");
            const traceResult = scenarioResult(candidate.value,
                "dlss-trace-status");
            const stress = stressSession(renderResult);
            const cpuStatus = cpuResult && cpuResult.cpuPerformance;
            const gpu = gpuResult && gpuResult.capture;
            const texture = textureResult && textureResult.capture;
            const probe = renderResult && renderResult.status &&
                renderResult.status.loadPresentationProbe;
            const traceStatus = traceResult && traceResult.capture &&
                (traceResult.capture.summary || traceResult.capture);
            return [renderResult, cpuResult, gpuResult, textureResult]
                .every((value) => producerBuildMatches(value, buildId)) &&
                (!traceRequired || producerBuildMatches(traceResult, buildId)) &&
                stress.id === measured.sessionId && stress.active === false &&
                cpuStatus && cpuStatus.sessionId === cpu.sessionId &&
                cpuStatus.active === false && gpu && gpu.active === false &&
                texture && texture.active === false && probe &&
                probe.active === false && (!traceRequired || traceStatus &&
                    traceStatus.sessionID === trace.sessionId &&
                    traceStatus.active === false);
        });
        if (!statusReceipt) {
            passReasons.push("retained_cleanup_status_receipt_missing");
        }
        const ownedRows = rows.filter((row) =>
            `${row.lane || "default"}|${row.pass}` === key);
        if (ownedRows.length === 0 || !positive(measured.sessionId) ||
            ownedRows.some((row) =>
                row.terminalStressSessionId !== measured.sessionId)) {
            passReasons.push("measured_row_owner_mismatch");
        }
        if (traceRequired) {
            if (trace.proven !== true || !positive(trace.sessionId) ||
                trace.active !== false ||
                !Array.isArray(cleanup.knownTraceSessionIds) ||
                !cleanup.knownTraceSessionIds.includes(trace.sessionId)) {
                passReasons.push("trace_owner_finalization_invalid");
            }
        }
        results.push({ lane: laneId, pass: passNumber,
            complete: passReasons.length === 0,
            reasons: unique(passReasons) });
        reasons.push(...passReasons.map((reason) =>
            `${laneId}:pass-${passNumber}:${reason}`));
    }
    if (passKeys.length === 0) reasons.push("planned_passes_missing");
    return { complete: reasons.length === 0, reasons: unique(reasons),
        passes: results };
}

function presentationStretchDetails(waiter, projection, renderVerdict) {
    const selected = projection.presentationStretchSelected === true;
    const presentation = waiter.diagnostics && waiter.diagnostics.delta &&
        waiter.diagnostics.delta.presentation || {};
    let consecutiveFrames = selected ? "not_exposed" : 0;
    if (selected && Number.isSafeInteger(presentation.stretchCompletedEpisodes) &&
        presentation.stretchCompletedEpisodes === 1 &&
        Number.isSafeInteger(presentation.stretchCompletedFrames) &&
        presentation.stretchCompletedFrames >= 0) {
        consecutiveFrames = presentation.stretchCompletedFrames;
    } else if (selected &&
        Number.isSafeInteger(presentation.maximumStretchFramesBaseline) &&
        Number.isSafeInteger(presentation.maximumStretchFramesCurrent) &&
        presentation.maximumStretchFramesCurrent >= 0 &&
        (presentation.maximumStretchFramesBaseline === 0 ||
            presentation.maximumStretchFramesCurrent >
                presentation.maximumStretchFramesBaseline)) {
        consecutiveFrames = presentation.maximumStretchFramesCurrent;
    }
    const recovered = selected && renderVerdict === "PASS" &&
        waiter.satisfied === true && waiter.presentationStable === true &&
        waiter.cleanupDrained === true;
    const milestone = waiter.milestoneTimings &&
        waiter.milestoneTimings.presentation || {};
    return {
        selected,
        consecutiveFrames,
        recovered,
        recoveryFrame: recovered && Number.isSafeInteger(milestone.frame) ?
            milestone.frame : "not_exposed",
        recoveryElapsedMs: recovered && Number.isFinite(milestone.elapsedMs) ?
            milestone.elapsedMs : "not_exposed",
    };
}

function sourceProfile(waiter) {
    const timeline = waiter.replacementTimeline || {};
    const proof = timeline.dispatch && timeline.dispatch.presentationProof || {};
    const leftPresent = Object.hasOwn(proof, "leftEye");
    const rightPresent = Object.hasOwn(proof, "rightEye");
    const left = proof.leftEye;
    const right = proof.rightEye;
    if (leftPresent !== rightPresent) {
        throw new Error("source_profile_method_incomplete");
    }
    if (leftPresent && (!left || typeof left !== "object" ||
        !right || typeof right !== "object")) {
        throw new Error("source_profile_method_invalid");
    }
    const leftMethod = left && typeof left === "object" ? left.method : undefined;
    const rightMethod = right && typeof right === "object" ? right.method : undefined;
    const leftExposed = leftMethod !== null && leftMethod !== undefined;
    const rightExposed = rightMethod !== null && rightMethod !== undefined;
    let method = "not_exposed";
    if (leftExposed !== rightExposed) {
        throw new Error("source_profile_method_incomplete");
    }
    if (leftExposed && rightExposed) {
        if (typeof leftMethod !== "string" || typeof rightMethod !== "string" ||
            leftMethod.length === 0 || rightMethod.length === 0) {
            throw new Error("source_profile_method_invalid");
        }
        if (leftMethod !== rightMethod) {
            throw new Error("source_profile_method_mismatch");
        }
        method = leftMethod;
    }
    return {
        method,
        qualityMode: Object.hasOwn(proof, "qualityMode") ?
            proof.qualityMode : "not_exposed",
        renderScaleMode: Object.hasOwn(proof, "renderScaleMode") ?
            proof.renderScaleMode : "not_exposed",
    };
}

function backendContract(target, laneContract) {
    if (target.method === "none" || target.method === "taa") {
        return target.renderScaleMode === false ? ["none"] : [];
    }
    if (target.method === "dlss") return ["dlss"];
    if (target.method === "fsr" && laneContract &&
        laneContract.configuredFsrRuntime === target.fsrRuntime &&
        Array.isArray(laneContract.expectedBackends)) {
        if (laneContract.requiresDocumentedFsr4UnavailableCondition === true &&
            (!laneContract.fallbackQualification ||
                laneContract.fallbackQualification.satisfied !== true ||
                !laneContract.fallbackQualification.unavailableCondition ||
                !Number.isSafeInteger(
                    laneContract.fallbackQualification.unavailableCondition.mask) ||
                laneContract.fallbackQualification.unavailableCondition.mask < 1)) {
            return [];
        }
        return laneContract.expectedBackends.filter((value) =>
            typeof value === "string" && value.length > 0);
    }
    return [];
}

function actualBackendEvidence(waiter, target, laneContract) {
    const allowed = backendContract(target, laneContract);
    const rejected = [];
    const accept = (value, source) => {
        const normalized = typeof value === "string" ? value.trim() : "";
        if (normalized.length === 0) {
            rejected.push({ source, value: value ?? null,
                reason: "backend_not_exposed" });
            return null;
        }
        if (!allowed.includes(normalized)) {
            rejected.push({ source, value,
                reason: "backend_incompatible_with_target" });
            return null;
        }
        return { value: normalized, source };
    };
    if (allowed.length === 0) {
        return { value: "not_exposed", source: "none", rejected: [{
            source: "target", value: target,
            reason: "target_backend_contract_invalid",
        }] };
    }
    if (target.method === "none" || target.method === "taa") {
        return { value: "none", source: "logical_native", rejected };
    }
    if (target.renderScaleMode === false) {
        const execution = waiter.nativeVendorExecution ||
            waiter.observation && waiter.observation.nativeVendorExecution;
        const candidate = accept(execution && execution.actualBackend,
            "native_vendor_execution");
        return candidate ? { ...candidate, rejected } :
            { value: "not_exposed", source: "none", rejected };
    }
    if (target.renderScaleMode !== true) {
        return { value: "not_exposed", source: "none", rejected: [{
            source: "target.renderScaleMode", value: target.renderScaleMode ?? null,
            reason: "render_scale_mode_invalid",
        }] };
    }
    const timeline = waiter.replacementTimeline || {};
    const proof = timeline.terminal &&
        timeline.terminal.presentationProof || {};
    const direct = accept(proof.backend, "terminal.presentationProof.backend");
    if (direct) return { ...direct, rejected };
    const leftValue = proof.leftEye && proof.leftEye.backend;
    const rightValue = proof.rightEye && proof.rightEye.backend;
    const left = accept(leftValue, "terminal.presentationProof.leftEye.backend");
    const right = accept(rightValue, "terminal.presentationProof.rightEye.backend");
    if (left && right && left.value === right.value) {
        return { value: left.value, source: "terminal.presentationProof.eyes",
            rejected };
    }
    if (left && right && left.value !== right.value) {
        rejected.push({ source: "terminal.presentationProof.eyes",
            value: [left.value, right.value], reason: "backend_eye_mismatch" });
    }
    if (target.method === "fsr") {
        const dispatch = waiter.status && waiter.status.fsrDispatch;
        const candidate = accept(dispatch && dispatch.actualDispatchBackend,
            "status.fsrDispatch.actualDispatchBackend");
        if (candidate) return { ...candidate, rejected };
    }
    return { value: "not_exposed", source: "none", rejected };
}

function traceLifecycleEvidence(retained, buildId, requireDispatch) {
    const reasons = [];
    const names = [["traceReset", "dlss_trace_reset"],
        ["traceStart", "dlss_trace_start"],
        ["traceStop", "dlss_trace_stop"]];
    for (const [name, action] of names) {
        const value = retained[name];
        if (!value || value.action !== action || value.ok === false ||
            value.isError === true) {
            reasons.push(`${name}_invalid`);
        }
        if (!value || !value.producer || value.producer.buildId !== buildId) {
            reasons.push(`${name}_build_mismatch`);
        }
    }
    const summaries = names.map(([name]) => retained[name] &&
        retained[name].capture && (retained[name].capture.summary ||
            retained[name].capture));
    const rawPages = Array.isArray(retained.tracePages) &&
        retained.tracePages.length > 0 ? retained.tracePages :
        retained.traceRead ? [retained.traceRead] : [];
    const pageSummaries = rawPages.map((page) => page && page.capture &&
        page.capture.summary);
    const sessions = [...summaries, ...pageSummaries]
        .map((summary) => summary && summary.sessionID);
    if (sessions.some((value) => !Number.isSafeInteger(value) || value < 1) ||
        unique(sessions).length !== 1) {
        reasons.push("trace_session_identity_invalid");
    }
    if (!summaries[0] || summaries[0].active !== false ||
        !summaries[1] || summaries[1].active !== true ||
        !summaries[2] || summaries[2].active !== false ||
        pageSummaries.some((summary) => !summary || summary.active !== false)) {
        reasons.push("trace_lifecycle_state_invalid");
    }
    const records = [];
    if (rawPages.length > 0 && Number.isSafeInteger(sessions[0]) &&
        sessions[0] > 0) {
        try {
            const firstLimit = rawPages[0] && rawPages[0].capture &&
                rawPages[0].capture.limit;
            const state = {
                buildId,
                sessionId: sessions[0],
                afterSequence: 0,
                latestSequence: null,
                maximum: Number.isSafeInteger(firstLimit) && firstLimit > 0 ?
                    firstLimit : 256,
            };
            for (let index = 0; index < rawPages.length; index += 1) {
                const rawPage = rawPages[index];
                if (index > 0 &&
                    rawPages[index - 1].capture.moreAvailable !== true) {
                    throw new Error("trace_page_after_terminal");
                }
                const checked = validateTracePage(rawPage, state);
                state.sessionId = checked.sessionId;
                state.afterSequence = checked.lastSequence;
                state.latestSequence = checked.latestSequence;
                records.push(...checked.page.capture.records);
            }
            if (rawPages[rawPages.length - 1].capture.moreAvailable !== false) {
                reasons.push("trace_page_nonterminal");
            }
        } catch (error) {
            reasons.push(error.message);
        }
    } else {
        reasons.push("trace_read_capture_missing");
    }
    const summary = pageSummaries[pageSummaries.length - 1] || {};
    if (Number.isSafeInteger(summary.totalRecords) &&
        summary.totalRecords !== records.length) {
        reasons.push("trace_total_records_mismatch");
    }
    if (requireDispatch && (!Number.isSafeInteger(summary.totalRecords) ||
        summary.totalRecords < 1 || !Number.isSafeInteger(summary.setConstantsCalls) ||
        summary.setConstantsCalls < 1 || !Number.isSafeInteger(summary.evaluateCalls) ||
        summary.evaluateCalls < 1 || records.length < 1)) {
        reasons.push("trace_dispatch_evidence_missing");
    }
    if (!requireDispatch && (summary.totalRecords !== 0 ||
        summary.setConstantsCalls !== 0 || summary.evaluateCalls !== 0 ||
        records.length !== 0)) {
        reasons.push("trace_capability_window_not_empty");
    }
    return { complete: unique(reasons).length === 0,
        reasons: unique(reasons), sessionId: sessions[0] || null,
        pages: rawPages.length, records: records.length };
}

function transitionRow(root, file, retained, planned) {
    const identity = rowIdentity(root, file);
    const waiter = retained.waiter || {};
    const projection = retained.projection || {};
    const task2 = normalizeTask2(retained);
    const profile = finalProfile(waiter);
    const timeline = waiter.replacementTimeline || retained.replacementTimeline || {};
    const diagnostics = transitionDiagnostics(timeline);
    const boundary = timeline.firstPhysicalMutation;
    const target = waiter.target || {};
    const renderVerdict = projection.renderVerdict ||
        (waiter.satisfied === true ? "PASS" : "FAIL");
    const stretch = presentationStretchDetails(waiter, projection, renderVerdict);
    const traceRequired = retained.variant === "nvidia" &&
        target.method === "dlss";
    const traceValidation = traceRequired ? traceLifecycleEvidence(retained,
        waiter.producer && waiter.producer.buildId, true) :
        { complete: true, reasons: [], sessionId: null };
    const backend = actualBackendEvidence(waiter, target,
        planned && planned.laneContract);
    const recovery = retained.recovery || null;
    return {
        ...identity,
        terminalTransitionId: waiter.transitionId ?? null,
        terminalOwnerId: waiter.ownerId ?? null,
        terminalStressSessionId: (waiter.baseline &&
            waiter.baseline.stressSessionId) ?? null,
        target,
        source: sourceProfile(waiter),
        actualBackend: backend.value,
        actualBackendSource: backend.source,
        actualBackendRejectedEvidence: backend.rejected,
        renderVerdict,
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
        rawOwnerPrerequisitesValid: task2.rawOwnerPrerequisitesValid,
        rawOwnerPrerequisiteReasons: task2.rawOwnerPrerequisiteReasons,
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
        finalProfileComplete: profile.complete,
        finalProfileMissing: profile.missing,
        nonStableNote: projection.nonStableNote || null,
        presentationStretchSelected: stretch.selected,
        presentationStretchConsecutiveFrames: stretch.consecutiveFrames,
        presentationStretchRecovered: stretch.recovered,
        presentationStretchRecoveryFrame: stretch.recoveryFrame,
        presentationStretchRecoveryElapsedMs: stretch.recoveryElapsedMs,
        traceRequired,
        traceComplete: traceValidation.complete,
        traceValidationReasons: traceValidation.reasons,
        traceSessionId: traceValidation.sessionId,
        recoveryStatus: recovery ? recovery.status || "not_exposed" : "not_needed",
        recoveryTarget: recovery ? recovery.target || null : null,
        recoveryReceiptKey: retained.recoveryReceiptKey ||
            recovery && recovery.receiptKey || null,
        sourceRecoveryReceiptKey: retained.sourceRecoveryReceiptKey || null,
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
        "actual_backend", "actual_backend_source",
        "actual_backend_rejected_evidence", "render_verdict", "stability_status",
        "stability_presentation_disposition",
        "stability_left_eye_path", "stability_right_eye_path",
        "stability_controller_state", "stability_presentation_phase",
        "stability_failure_codes", "task2_verdict", "mutation_expectation",
        "missing_evidence", "producer_invalid_evidence", "reported_violations",
        "authoritative_violations", "violation_authority",
        "phase_counter_authority_status",
        "phase_counter_authority_reasons", "phase_counters_authoritative",
        "audit_storage_complete", "owner_correlated_audit_observed",
        "transition_evidence_complete",
        "physical_mutation_started", "final_method", "final_quality",
        "final_render_scale_mode", "final_state_revision", "final_profile_complete",
        "final_profile_missing", "trace_required", "trace_complete",
        "trace_validation_reasons", "trace_session_id",
        "recovery_status", "recovery_target",
        "recovery_receipt_key", "source_recovery_receipt_key",
        "presentation_stretch_selected",
        "presentation_stretch_consecutive_frames",
        "presentation_stretch_recovered",
        "presentation_stretch_recovery_frame",
        "presentation_stretch_recovery_elapsed_ms",
        "boundary_exposed", "dispatch_frame",
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
        const note = row.nonStableNote;
        const values = [row.lane, row.pass, row.ordinal, row.target.method,
            row.target.qualityMode, row.target.renderScaleMode, row.actualBackend,
            row.actualBackendSource, row.actualBackendRejectedEvidence,
            row.renderVerdict,
            note ? note.status : "stable",
            note ? note.presentationDisposition : "n/a",
            note ? note.leftEyePath : "n/a",
            note ? note.rightEyePath : "n/a",
            note ? note.controllerState : "n/a",
            note ? note.presentationPhase : "n/a",
            note ? note.failureCodes : [],
            row.task2Verdict, row.mutationExpectation, row.task2MissingEvidence,
            row.task2ProducerInvalidEvidence, row.reportedTask2Violations,
            row.authoritativeTask2Violations,
            row.task2ViolationAuthority,
            row.phaseCounterAuthorityStatus, row.phaseCounterAuthorityReasons,
            row.phaseCountersAuthoritative, row.auditStorageComplete,
            row.ownerCorrelatedAuditObserved, row.transitionEvidenceComplete,
            row.physicalMutationStarted,
            row.finalMethod, row.finalQuality, row.finalRenderScaleMode,
            row.finalStateRevision, row.finalProfileComplete,
            row.finalProfileMissing, row.traceRequired, row.traceComplete,
            row.traceValidationReasons, row.traceSessionId,
            row.recoveryStatus, row.recoveryTarget, row.recoveryReceiptKey,
            row.sourceRecoveryReceiptKey,
            row.presentationStretchSelected,
            row.presentationStretchConsecutiveFrames,
            row.presentationStretchRecovered,
            row.presentationStretchRecoveryFrame,
            row.presentationStretchRecoveryElapsedMs,
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
    const rows = summary.transitions.map((row) => {
        const note = row.nonStableNote;
        const stability = note ?
            `not stable: ${note.presentationDisposition}; ` +
                `${note.leftEyePath}/${note.rightEyePath}; ` +
                `${note.controllerState}/${note.presentationPhase}` : "stable";
        const recovery = row.recoveryStatus === "RECOVERED" ?
            "reset after row" : row.sourceRecoveryReceiptKey ?
                "started after reset" : row.recoveryStatus;
        return (
        `| ${row.lane || "default"} | ${row.pass} | ${row.ordinal} | ` +
        `${row.actualBackend} | ${row.renderVerdict} | ${stability} | ` +
        `${row.task2Verdict} | ` +
        `${row.presentationStretchSelected ?
            row.presentationStretchConsecutiveFrames : "none"} | ` +
        `${row.presentationStretchRecovered ?
            `${row.presentationStretchRecoveryFrame}/` +
                `${row.presentationStretchRecoveryElapsedMs} ms` : "none"} | ` +
        `${recovery} | ` +
        `${row.phaseCounterAuthorityStatus} | ` +
        `${row.reportedTask2Violations.join("; ") || "none"} | ` +
        `${row.task2MissingEvidence.join("; ") || "none"} | ` +
        `${row.task2ProducerInvalidEvidence.join("; ") || "none"} |`);
    }).join("\n");
    const interruption = summary.assayExecution.interruption;
    const failure = interruption && interruption.failure;
    const recovery = failure && failure.recovery;
    const recoveryDecision = recovery && recovery.decision;
    const recoveryReasons = recoveryDecision &&
        Array.isArray(recoveryDecision.reasons) ? recoveryDecision.reasons : [];
    const stretchRows = summary.presentationStretchAnomalies.transitions
        .map((entry) => `| ${entry.lane || "default"} | ${entry.pass} | ` +
            `${entry.ordinal} | ${JSON.stringify(entry.from)} | ` +
            `${JSON.stringify(entry.to)} | ${entry.consecutiveFrames} | ` +
            `${entry.recovered ? "yes" : "no"} |`)
        .join("\n");
    return `# ${summary.protocol} final report\n\n` +
        `- Assay execution: **${summary.assayExecution.status}**\n` +
        `- Transitions dispatched: **${summary.assayExecution.transitionsDispatched}/` +
        `${summary.assayExecution.expectedTransitions}**\n` +
        `- Render verdict: **${summary.render.verdict}**\n` +
        `- Non-stable terminal notes: **${summary.stabilityNotes.count}**\n` +
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
        (recovery ?
            `- Recovery decision: **${recoveryDecision &&
                recoveryDecision.satisfied === true ? "SATISFIED" : "FAILED"}** ` +
            `(apply accepted: ${recovery.apply && recovery.apply.accepted}; ` +
            `waiter satisfied: ${recovery.waiter && recovery.waiter.satisfied}; ` +
            `safe terminal: ${recovery.safeTerminal &&
                recovery.safeTerminal.satisfied})\n` : "") +
        (recoveryReasons.length > 0 ?
            `- Recovery blockers: **${recoveryReasons.join("; ")}**\n` : "") +
        (summary.memoryConfirmation ?
            `- Memory confirmation: **${summary.memoryConfirmation.verdict}**\n` : "") +
        `- Presentation stretch: **` +
        `${summary.presentationStretchAnomalies.selected} selected, ` +
        `${summary.presentationStretchAnomalies.recoveredPass} recovered PASS, ` +
        `${summary.presentationStretchAnomalies.unrecovered} unrecovered**\n` +
        `\n` +
        `Task 2 is deliberately not aggregated. Reporting failure does not ` +
        `rewrite the render result, and a render pass does not hide missing ` +
        `per-transition evidence. Every raw JSON value is available in ` +
        `\`${summary.evidenceExtraction.path}\`.\n\n` +
        `## Transitions\n\n` +
        `| Lane | Pass | Row | Actual backend | Render | Stability | Task 2 | Stretch frames | Stretch recovery | Recovery | Authority | Reported violations | ` +
        `Missing evidence | Invalid producer evidence |\n` +
        `| --- | ---: | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n${rows}\n\n` +
        `## Presentation stretch anomalies\n\n` +
        `| Lane | Pass | Row | From | To | Consecutive frames | Recovered PASS |\n` +
        `| --- | ---: | ---: | --- | --- | ---: | --- |\n` +
        `${stretchRows || "| none | - | - | - | - | - | - |"}\n`;
}

function presentationStretchAnomalies(rows) {
    const selected = rows.filter((row) => row.presentationStretchSelected);
    const recovered = selected.filter((row) =>
        row.presentationStretchRecovered && row.renderVerdict === "PASS");
    return {
        selected: selected.length,
        recoveredPass: recovered.length,
        unrecovered: selected.length - recovered.length,
        transitions: selected.map((row) => ({
            lane: row.lane,
            pass: row.pass,
            ordinal: row.ordinal,
            from: row.source,
            to: row.target,
            consecutiveFrames: row.presentationStretchConsecutiveFrames,
            recovered: row.presentationStretchRecovered &&
                row.renderVerdict === "PASS",
            recoveryFrame: row.presentationStretchRecoveryFrame,
            recoveryElapsedMs: row.presentationStretchRecoveryElapsedMs,
        })),
    };
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
    const existingSummaryPath = path.join(root, "summary.json");
    const existing = fs.existsSync(existingSummaryPath) ? readJson(existingSummaryPath) : {};
    const runIds = unique([options.runId, existing.runId]);
    const buildIds = unique([options.buildId, existing.build && existing.build.buildId]);
    if (runIds.length !== 1 || buildIds.length !== 1) {
        throw new Error("finalization_identity_ambiguous");
    }
    for (const entry of allRetained) {
        if (!entry.value || entry.value.variant !== variant) {
            throw new Error("terminal_receipt_variant_mismatch");
        }
    }
    const planState = readExecutionPlan(root, variant, runIds[0], buildIds[0]);
    const planEntries = planState.plan && Array.isArray(planState.plan.entries) ?
        planState.plan.entries : [];
    const planByIdentity = new Map(planEntries.map((entry) =>
        [identityKey(entry), entry]));
    const rows = retained.map(({ file, value }) => {
        const identity = rowIdentity(root, file);
        return transitionRow(root, file, value,
            planByIdentity.get(identityKey(identity)) || null);
    })
        .sort((left, right) => (left.lane || "").localeCompare(right.lane || "") ||
            left.pass - right.pass || left.ordinal - right.ordinal);
    const liveResult = readLiveResult(root, variant, runIds[0]);
    const interrupted = liveResult && liveResult.status === "INTERRUPTED" ?
        liveResult : null;
    const interruptedPass = interrupted && interrupted.lanes && interrupted.lanes
        .flatMap((lane) => lane.passes || [])
        .find((pass) => pass.status === "INTERRUPTED");
    const persistedExpectedRows = existing.assayExecution &&
        existing.assayExecution.expectedTerminalReceipts;
    const persistedCountExpected = existing.counts &&
        existing.counts.transitionsExpected;
    const declaredExpectedRows = options.expectedRows ??
        (Number.isSafeInteger(persistedExpectedRows) ? persistedExpectedRows : null) ??
        (Number.isSafeInteger(persistedCountExpected) ? persistedCountExpected : null) ??
        (planEntries.length > 0 ? planEntries.length : null);
    if (declaredExpectedRows !== null &&
        (!Number.isSafeInteger(declaredExpectedRows) ||
            declaredExpectedRows < rows.length || declaredExpectedRows < 1)) {
        throw new Error("invalid_expected_terminal_receipts");
    }
    const expectedRows = declaredExpectedRows ?? "not_exposed";
    const rowKeys = rows.map(identityKey);
    const duplicateRowIdentities = unique(rowKeys.filter((key, index) =>
        rowKeys.indexOf(key) !== index));
    const planKeys = planEntries.map(identityKey);
    const duplicatePlanIdentities = unique(planKeys.filter((key, index) =>
        planKeys.indexOf(key) !== index));
    const duplicatePlanTransitionIds = unique(planEntries
        .map((entry) => entry.transitionId)
        .filter((value, index, values) => values.indexOf(value) !== index));
    const duplicatePlanOwnerIds = unique(planEntries
        .map((entry) => entry.ownerId)
        .filter((value, index, values) => values.indexOf(value) !== index));
    const terminalTransitionIds = rows.map((row) => row.terminalTransitionId);
    const terminalOwnerIds = rows.map((row) => row.terminalOwnerId);
    const duplicateTerminalTransitionIds = unique(terminalTransitionIds
        .filter((value, index, values) => value !== null &&
            values.indexOf(value) !== index));
    const duplicateTerminalOwnerIds = unique(terminalOwnerIds
        .filter((value, index, values) => value !== null &&
            values.indexOf(value) !== index));
    const executionPlanConflicts = [...planState.reasons];
    if (duplicatePlanIdentities.length > 0 ||
        duplicatePlanTransitionIds.length > 0 || duplicatePlanOwnerIds.length > 0) {
        executionPlanConflicts.push("execution_plan_duplicate_identity");
    }
    if (declaredExpectedRows !== null && planEntries.length > 0 &&
        declaredExpectedRows !== planEntries.length) {
        executionPlanConflicts.push("execution_plan_count_mismatch");
    }
    for (const row of rows) {
        const planned = planByIdentity.get(identityKey(row));
        if (!planned) {
            executionPlanConflicts.push("terminal_receipt_not_planned");
            continue;
        }
        if (row.terminalTransitionId !== planned.transitionId ||
            row.terminalOwnerId !== planned.ownerId) {
            executionPlanConflicts.push("terminal_receipt_owner_mismatch");
        }
        if (!targetsMatch(row.target, planned.target)) {
            executionPlanConflicts.push("terminal_receipt_target_mismatch");
        }
    }
    const uniqueExecutionPlanConflicts = unique(executionPlanConflicts);
    const executionScopeComplete = declaredExpectedRows !== null &&
        duplicateRowIdentities.length === 0 &&
        duplicateTerminalTransitionIds.length === 0 &&
        duplicateTerminalOwnerIds.length === 0 &&
        uniqueExecutionPlanConflicts.length === 0;
    const baselineOnlyInterrupted = rows.length === 0;
    let preBaselineInterrupted = false;
    if (baselineOnlyInterrupted) {
        const baselineFiles = walk(path.join(root, "raw")).filter((file) =>
            path.basename(file) === "baseline.json" &&
            relative(root, file).split("/").includes("baseline"));
        preBaselineInterrupted = baselineFiles.length === 0;
        if (preBaselineInterrupted) {
            validatePreBaselineInterruption(root, variant, runIds[0], liveResult);
        } else {
            validateBaselineOnlyInterruption(root, variant, runIds[0], buildIds[0]);
        }
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
    const passFinalization = passFinalizationEvidence(
        root, liveResult, planEntries, rows, variant, buildIds[0]);
    const assayStatus = interrupted ? "INTERRUPTED" :
        executionScopeComplete && rows.length === declaredExpectedRows &&
            passFinalization.complete ?
            "COMPLETE" : "INCOMPLETE";
    const renderVerdict = aggregateVerdict(rows.map((row) => row.renderVerdict));
    const task2Counts = verdictCounts(rows.map((row) => row.task2Verdict));
    const nonStableTransitions = rows.filter((row) => row.nonStableNote).map((row) => ({
        lane: row.lane,
        pass: row.pass,
        ordinal: row.ordinal,
        ...row.nonStableNote,
    }));
    const reportingReasons = [];
    if (assayStatus !== "COMPLETE") reportingReasons.push("terminal_receipts_incomplete");
    if (declaredExpectedRows === null) {
        reportingReasons.push("execution_scope_missing");
    }
    if (duplicateRowIdentities.length > 0) {
        reportingReasons.push("duplicate_transition_identity");
    }
    if (duplicateTerminalTransitionIds.length > 0 ||
        duplicateTerminalOwnerIds.length > 0) {
        reportingReasons.push("duplicate_terminal_receipt_identity");
    }
    if (uniqueExecutionPlanConflicts.length > 0) {
        reportingReasons.push("execution_plan_mismatch");
    }
    if (preBaselineInterrupted) reportingReasons.push("pre_baseline_interrupted");
    else if (baselineOnlyInterrupted) reportingReasons.push("baseline_only_interrupted");
    if (interrupted && !baselineOnlyInterrupted) {
        reportingReasons.push("assay_interrupted");
    }
    if (rows.some((row) => !row.traceComplete)) {
        reportingReasons.push("required_trace_evidence_incomplete");
    }
    if (rows.some((row) => row.phaseCounterAuthorityStatus === "MISMATCHED")) {
        reportingReasons.push("task2_owner_authority_mismatch");
    }
    if (rows.some((row) => row.rawOwnerPrerequisitesValid === false)) {
        reportingReasons.push("task2_owner_authority_incomplete");
    }
    if (!passFinalization.complete) {
        reportingReasons.push("pass_finalization_incomplete");
    }
    if (rows.some((row) => row.renderVerdict === "PASS" &&
        (row.actualBackend === "not_exposed" || !row.finalProfileComplete))) {
        reportingReasons.push("reporting_contract_incomplete");
    }
    const amdTraceEvidence = variant === "amd" ?
        amdTraceCapabilityEvidence(root, liveResult, buildIds[0]) :
        { complete: true, reasons: [] };
    if (variant === "amd" && !amdTraceEvidence.complete) {
        reportingReasons.push("amd_trace_capability_evidence_incomplete");
    }
    const deployment = deploymentVerification(root, buildIds[0], options);
    if (!deployment.complete) reportingReasons.push(deployment.reason);
    const reportingStatus = reportingReasons.length === 0 ? "COMPLETE" : "INCOMPLETE";
    const extraction = evidenceValues(root);
    const generatedUtc = options.generatedUtc || existing.generatedUtc ||
        "not_exposed";
    const summary = {
        ...existing,
        schemaVersion: `renderscale-tuning-${variant}-summary-v5`,
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
            executionScope: {
                complete: executionScopeComplete,
                source: planEntries.length > 0 ? planState.file :
                    options.expectedRows !== undefined ? "argument" :
                    existing.assayExecution &&
                        existing.assayExecution.expectedTerminalReceipts !== undefined ?
                        "retained_assay_execution" :
                        existing.counts &&
                            existing.counts.transitionsExpected !== undefined ?
                            "retained_counts" : "missing",
                duplicateRowIdentities,
                duplicateTerminalTransitionIds,
                duplicateTerminalOwnerIds,
                planEntries: planEntries.length,
                conflicts: uniqueExecutionPlanConflicts,
            },
            interruption: interrupted ? {
                phase: preBaselineInterrupted ? "pre_baseline" :
                    baselineOnlyInterrupted ? "baseline" : "assay",
                error: interrupted.error || interruptedPass &&
                    interruptedPass.error || null,
                failure: interrupted.failure ||
                    interruptedPass && interruptedPass.failure || null,
                undispatchedTransitionReceipts: undispatchedFailures.map((entry) =>
                    relative(root, entry.file)),
            } : null,
            passFinalization },
        render: { verdict: renderVerdict },
        stabilityNotes: { count: nonStableTransitions.length,
            transitions: nonStableTransitions },
        presentationStretchAnomalies: presentationStretchAnomalies(rows),
        task2Evidence: { mode: "per_transition", counts: task2Counts,
            aggregateVerdict: "NOT_COMPUTED" },
        reporting: { status: reportingStatus, reasons: reportingReasons },
        reportingContract: { complete: reportingStatus === "COMPLETE",
            status: reportingStatus, reasons: reportingReasons },
        traceCapability: variant === "amd" ?
            liveResult && liveResult.traceCapability || { status: "missing" } :
            { status: "not_applicable" },
        traceCapabilityEvidence: variant === "amd" ? amdTraceEvidence :
            { complete: true, reasons: [], status: "not_applicable" },
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
