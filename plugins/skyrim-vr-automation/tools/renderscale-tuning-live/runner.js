// SPDX-License-Identifier: GPL-3.0-or-later

async function runRenderScaleTuningLive(context) {
    "use strict";

    const {
        tools, store, notify, variant, runId, buildId,
        positioningRoot, matrix,
    } = context;
    const scenarioTool = tools.mcp__devbench_vr__scenario;
    const renderScaleTool = tools.mcp__devbench_vr__communityshaders_renderscale;
    if (typeof scenarioTool !== "function" || typeof renderScaleTool !== "function") {
        throw new Error("plugin_direct_unavailable");
    }
    const retainedReceiptKeys = [];

    function retain(key, value) {
        store(key, value);
        if (!retainedReceiptKeys.includes(key)) retainedReceiptKeys.push(key);
    }

    function retainLiveResult(summary) {
        const key = `${runId}:live-result`;
        if (!retainedReceiptKeys.includes(key)) retainedReceiptKeys.push(key);
        summary.receiptKeys = [...retainedReceiptKeys];
        store(key, summary);
    }

    function unique(values) {
        return [...new Set(values.filter((value) => value !== null &&
            value !== undefined && value !== ""))];
    }

    const quality = Object.freeze({
        native_aa: 0,
        hoshipa: 1,
        ultra_quality: 2,
        quality: 3,
        balanced: 4,
        performance: 5,
        ultra_performance: 6,
    });
    const qualityName = Object.freeze(Object.fromEntries(
        Object.entries(quality).map(([name, value]) => [value, name])));
    const dlssProfile = Object.freeze({ J: 0, K: 1, L: 2, M: 3, F: 4, E: 5 });
    const foveation = Object.freeze({
        foveatedVendorDispatch: true,
        foveatedCenterArea: 0.3,
        peripheryTAAEnable: true,
        peripheryTAACenterArea: 0.3,
        peripheryTAAOuterScale: 0.7,
    });

    function decodeEnvelope(envelope) {
        const block = envelope && envelope.content && envelope.content[0];
        if (!block || block.type !== "text" || typeof block.text !== "string") {
            throw new Error("invalid_mcp_envelope");
        }
        return JSON.parse(block.text);
    }

    function resultMap(root) {
        return new Map((root.results || [])
            .filter((entry) => entry && typeof entry.label === "string")
            .map((entry) => [entry.label, entry.result]));
    }

    function reportedError(value) {
        if (!value || typeof value !== "object") return null;
        for (const name of ["error", "message", "reason"]) {
            if (typeof value[name] === "string" && value[name].length > 0) {
                return value[name];
            }
        }
        return null;
    }

    function scenarioDiagnostic(root, steps, receiptKey, phase = "response") {
        const results = root && Array.isArray(root.results) ? root.results : [];
        const reportedSteps = results.map((entry, index) => {
            const planned = steps[index] || {};
            const result = entry && entry.result;
            const failed = Boolean(entry && (entry.ok === false ||
                entry.isError === true ||
                (result && (result.ok === false || result.isError === true))));
            const error = failed ?
                reportedError(entry) || reportedError(result) : null;
            return {
                index,
                label: entry && typeof entry.label === "string" ?
                    entry.label : planned.label || null,
                failed,
                error,
            };
        });
        const failed = reportedSteps.find((entry) => entry.failed) || null;
        const firstUnreported = results.length < steps.length ?
            steps[results.length] : null;
        return {
            phase,
            receiptKey,
            ok: root && typeof root.ok === "boolean" ? root.ok : null,
            aborted: root && typeof root.aborted === "boolean" ?
                root.aborted : null,
            stepsRun: root && Number.isSafeInteger(root.stepsRun) ?
                root.stepsRun : null,
            expectedSteps: steps.length,
            reportedError: root && (root.ok === false || root.isError === true) ?
                reportedError(root) || (failed && failed.error) || null :
                failed && failed.error || null,
            failedStep: failed && failed.label || null,
            firstUnreportedStep: firstUnreported && firstUnreported.label || null,
            reportedSteps,
        };
    }

    function diagnosticError(code, diagnostic) {
        const error = new Error(code);
        error.diagnostic = diagnostic;
        return error;
    }

    function requireScenario(root, steps, receiptKey) {
        if (!root || root.ok !== true || root.aborted !== false ||
            root.stepsRun !== steps.length || !Array.isArray(root.results)) {
            throw diagnosticError("scenario_failed",
                scenarioDiagnostic(root, steps, receiptKey));
        }
        return resultMap(root);
    }

    // Qualification producers have used flat profiles and wrapped public
    // snapshots. Decode either shape without changing the measured sequence.
    function terminalBoundary(waiter) {
        const snapshot = waiter && waiter.upscalingSnapshot;
        if (!snapshot || typeof snapshot !== "object") {
            throw diagnosticError("effective_profile_missing", {
                reason: "upscaling_snapshot_missing",
            });
        }
        const profile = snapshot.effective ||
            (snapshot.profiles && snapshot.profiles.effective);
        const enumName = (value, names = null) =>
            value && typeof value === "object" ? value.name :
                names && Number.isSafeInteger(value) ? names[value] : value;
        if (!profile || typeof profile !== "object") {
            throw diagnosticError("effective_profile_missing", {
                reason: "effective_profile_missing",
            });
        }
        const decoded = {
            method: enumName(profile.method),
            qualityMode: enumName(profile.qualityMode, qualityName),
            renderScaleMode: profile.renderScaleMode,
            dlssProfile: enumName(profile.dlssProfile),
            fsrRuntime: enumName(profile.fsrRuntime),
        };
        const validName = (value) =>
            typeof value === "string" && value.length > 0;
        if (!Number.isSafeInteger(snapshot.stateRevision) ||
            snapshot.stateRevision < 0 || !validName(decoded.method) ||
            !validName(decoded.qualityMode) ||
            typeof decoded.renderScaleMode !== "boolean" ||
            !validName(decoded.dlssProfile) || !validName(decoded.fsrRuntime)) {
            throw diagnosticError("effective_profile_invalid", {
                reason: "effective_profile_shape_invalid",
                stateRevision: snapshot.stateRevision ?? null,
                fields: {
                    method: decoded.method ?? null,
                    qualityMode: decoded.qualityMode ?? null,
                    renderScaleMode: decoded.renderScaleMode ?? null,
                    dlssProfile: decoded.dlssProfile ?? null,
                    fsrRuntime: decoded.fsrRuntime ?? null,
                },
            });
        }
        return {
            revision: snapshot.stateRevision,
            profile: decoded,
        };
    }

    // Keep positioning admission inside the runner so callers cannot add
    // shape checks between the fixed COC prefix and measured execution.
    function positioningInputs(root) {
        if (!root || root.ok !== true || root.aborted !== false ||
            !Number.isSafeInteger(root.stepsRun) ||
            !Array.isArray(root.results) ||
            root.stepsRun !== root.results.length) {
            throw new Error("positioning_scenario_failed");
        }
        const requiredLabels = [
            "position-coc",
            "position-health",
            "position-state",
            "position-scene",
            "position-capabilities",
            "position-snapshot",
            "position-renderscale",
        ];
        for (const label of requiredLabels) {
            const entry = root.results.find((candidate) =>
                candidate && candidate.label === label);
            // Tool payloads are opaque; only the outer scenario result is
            // part of positioning admission.
            if (!entry || !Object.prototype.hasOwnProperty.call(entry, "result")) {
                throw new Error(`positioning_tool_result_missing:${label}`);
            }
        }
        const results = resultMap(root);
        const sceneResult = results.get("position-scene");
        const snapshotResult = results.get("position-snapshot");
        const capabilitiesResult = results.get("position-capabilities");
        const renderScaleResult = results.get("position-renderscale");
        if (!sceneResult || sceneResult.playerLoaded !== true ||
            !sceneResult.cell ||
            sceneResult.cell.editorId !== "WhiterunDragonsreach") {
            throw new Error("positioning_scene_mismatch");
        }
        if (!snapshotResult || !snapshotResult.snapshot) {
            throw new Error("positioning_snapshot_missing");
        }
        if (variant === "amd" &&
            (!capabilitiesResult || !capabilitiesResult.capabilities)) {
            throw new Error("positioning_capabilities_missing");
        }
        const adapter = renderScaleResult && renderScaleResult.status &&
            renderScaleResult.status.adapter;
        if (!adapter || adapter.available !== true) {
            throw diagnosticError("positioning_adapter_unavailable", {
                reason: "adapter_identity_not_available",
                variant,
                adapter: adapter || null,
            });
        }
        const vendorId = typeof adapter.vendorId === "string" &&
            /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(adapter.vendorId) ?
            Number(adapter.vendorId) : adapter.vendorId;
        const expectedVendorId = variant === "amd" ? 0x1002 : 0x10de;
        if (!Number.isSafeInteger(vendorId) || vendorId !== expectedVendorId) {
            throw diagnosticError("positioning_adapter_vendor_mismatch", {
                reason: "adapter_vendor_mismatch",
                variant,
                expectedVendorId,
                actualVendorId: Number.isSafeInteger(vendorId) ? vendorId : null,
                adapter,
            });
        }
        return {
            cellEditorId: sceneResult.cell.editorId,
            boundary: terminalBoundary({
                upscalingSnapshot: snapshotResult.snapshot,
            }),
            capabilities: capabilitiesResult &&
                capabilitiesResult.capabilities || {},
            adapter: { ...adapter, vendorId },
        };
    }

    const positioning = positioningInputs(positioningRoot);
    const capabilities = positioning.capabilities;
    notify({
        phase: "positioning",
        status: "admitted",
        cellEditorId: positioning.cellEditorId,
        buildId,
        adapterVendorId: positioning.adapter.vendorId,
    });

    function targetFor(boundary, destination, fsrRuntime) {
        return {
            method: destination.method,
            qualityMode: destination.qualityMode,
            renderScaleMode: destination.renderScaleMode,
            dlssProfile: boundary.profile.dlssProfile,
            fsrRuntime: fsrRuntime || destination.fsrRuntime || boundary.profile.fsrRuntime,
        };
    }

    function waiterTarget(target) {
        const result = {
            method: target.method,
            qualityMode: quality[target.qualityMode],
            renderScaleMode: target.renderScaleMode,
        };
        if (target.method === "dlss") result.dlssProfile = target.dlssProfile;
        if (target.method === "fsr") result.fsrRuntime = target.fsrRuntime;
        return result;
    }

    function toolStep(label, tool, args) {
        return { label, tool, args };
    }

    async function scenario(steps, receiptKey) {
        let envelope;
        try {
            envelope = await scenarioTool({
                action: "run",
                async: false,
                continueOnError: false,
                steps,
            });
        } catch (error) {
            throw diagnosticError("scenario_transport_failed", {
                phase: "transport",
                receiptKey,
                ok: null,
                aborted: null,
                stepsRun: null,
                expectedSteps: steps.length,
                reportedError: error instanceof Error ?
                    error.message : String(error),
                failedStep: null,
                firstUnreportedStep: steps[0] && steps[0].label || null,
                reportedSteps: [],
            });
        }
        retain(receiptKey, envelope);
        try {
            return { envelope, root: decodeEnvelope(envelope) };
        } catch (error) {
            throw diagnosticError("scenario_decode_failed", {
                phase: "decode",
                receiptKey,
                ok: null,
                aborted: null,
                stepsRun: null,
                expectedSteps: steps.length,
                reportedError: error instanceof Error ?
                    error.message : String(error),
                failedStep: null,
                firstUnreportedStep: null,
                reportedSteps: [],
            });
        }
    }

    async function renderScale(args) {
        const envelope = await renderScaleTool(args);
        return { envelope, root: decodeEnvelope(envelope) };
    }

    function ids(laneIndex, pass, ordinal, baseline) {
        const serial = laneIndex * 100 + pass * 40 + ordinal;
        const stem = `${runId}-${variant}-${laneIndex}-${pass}-${baseline ? "b" : ordinal}`;
        return {
            transitionId: (baseline ? 900000 : 100000) + serial,
            ownerId: `${stem}-owner`,
            clientId: `${stem}-client`,
            commandId: `${stem}-apply`,
            profilerClientId: `${stem}-profiler-client`,
            profilerCommandId: `${stem}-profiler-clear`,
        };
    }

    function recoveryIds(laneIndex, pass, ordinal) {
        const serial = laneIndex * 100 + pass * 40 + ordinal;
        const stem = `${runId}-${variant}-${laneIndex}-${pass}-${ordinal}-recovery`;
        return {
            transitionId: 500000 + serial,
            ownerId: `${stem}-owner`,
        };
    }

    function qualificationSteps(boundary, target, identifiers, baseline, firstRow) {
        const steps = [];
        if (baseline) {
            steps.push(toolStep("baseline-stress-reset", "communityshaders.renderscale", {
                action: "reset", expectedBuildId: buildId,
            }));
            steps.push(toolStep("baseline-stress-start", "communityshaders.renderscale", {
                action: "start", expectedBuildId: buildId,
            }));
        } else {
            steps.push({ label: "transition-pace", wait: matrix.pacingMilliseconds });
            if (variant === "nvidia" && target.method === "dlss") {
                steps.push(toolStep("dlss-trace-reset", "communityshaders.renderscale", {
                    action: "dlss_trace_reset", expectedBuildId: buildId,
                }));
                steps.push(toolStep("dlss-trace-start", "communityshaders.renderscale", {
                    action: "dlss_trace_start", expectedBuildId: buildId,
                }));
            }
        }
        steps.push(toolStep("qualification-begin", "communityshaders.renderscale", {
            action: "qualification_begin",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedBuildId: buildId,
        }));
        if (firstRow) {
            steps.push(toolStep("profiler-clear-history", "communityshaders.profiler_api", {
                contractMajor: 1,
                clientId: identifiers.profilerClientId,
                commandId: identifiers.profilerCommandId,
                action: "clear_history",
                expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("qualification-dispatch", "communityshaders.renderscale", {
            action: "qualification_dispatch",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            startPerformanceTelemetry: firstRow,
            expectedBuildId: buildId,
        }));
        steps.push(toolStep("profile-apply", "communityshaders.upscaling_api", {
            action: "apply",
            expectedBuildId: buildId,
            expectedStateRevision: boundary.revision,
            target,
            purpose: "direct",
            persistence: "runtime_only",
            clientId: identifiers.clientId,
            commandId: identifiers.commandId,
            reason: baseline ? "render-scale tuning baseline" : "render-scale tuning transition",
        }));
        const waitArgs = {
            action: "qualification_wait",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedCellEditorId: "WhiterunDragonsreach",
            timeoutMs: matrix.completionTimeoutMilliseconds,
            milestone: "strict",
            target: waiterTarget(target),
            expectedBuildId: buildId,
        };
        // None and TAA have no live vendor path; their configured fixture remains telemetry.
        if (target.method === "dlss" || target.method === "fsr") {
            waitArgs.foveation = foveation;
        }
        steps.push(toolStep("qualification-wait", "communityshaders.renderscale", waitArgs));
        return steps;
    }

    function optionalSafetyFactClear(facts, name) {
        // Older producers may omit diagnostics; an explicit non-true value still fails closed.
        return !Object.prototype.hasOwnProperty.call(facts, name) ||
            facts[name] === true;
    }

    function safeTerminalAssessment(waiter, identifiers) {
        if (!waiter) return { satisfied: false, reasons: ["waiter_missing"] };
        const reasons = [];
        if (waiter.action !== "qualification_wait") reasons.push("action_mismatch");
        if (waiter.transitionId !== identifiers.transitionId) {
            reasons.push("transition_id_mismatch");
        }
        if (waiter.ownerId !== identifiers.ownerId) reasons.push("owner_id_mismatch");
        const snapshot = waiter.upscalingSnapshot;
        if (!snapshot) reasons.push("upscaling_snapshot_missing");
        else if (snapshot.activeOperationId !== 0) {
            reasons.push("active_operation_not_clear");
        }
        const facts = waiter.observation && waiter.observation.facts;
        if (!facts) reasons.push("facts_missing");
        else {
            if (facts.stressSession !== true) reasons.push("stress_session_not_owned");
            if (facts.exactCell !== true) reasons.push("exact_cell_not_proven");
            if (facts.loadedInWorld !== true) reasons.push("in_world_not_proven");
            if (facts.terminalClear !== true) reasons.push("terminal_not_clear");
            if (!optionalSafetyFactClear(facts, "apiOperationClear")) {
                reasons.push("api_operation_not_clear");
            }
            if (!optionalSafetyFactClear(facts, "physicalMutationClear")) {
                reasons.push("physical_mutation_not_clear");
            }
        }
        return { satisfied: reasons.length === 0, reasons };
    }

    function safeTerminal(waiter, identifiers) {
        return safeTerminalAssessment(waiter, identifiers).satisfied;
    }

    function scalar(value) {
        if (typeof value === "string" || typeof value === "boolean" ||
            Number.isFinite(value)) {
            return value;
        }
        return value && typeof value.name === "string" ? value.name : null;
    }

    function reasonProjection(reasons) {
        const values = (Array.isArray(reasons) ? reasons : []).map((reason) => {
            if (typeof reason === "string") return reason;
            if (!reason || typeof reason !== "object") return null;
            const category = typeof reason.category === "string" ?
                `${reason.category}:` : "";
            if (typeof reason.code === "string") return `${category}${reason.code}`;
            return typeof reason.reason === "string" ? reason.reason : null;
        }).filter(Boolean);
        const limit = 32;
        return {
            values: values.slice(0, limit),
            total: values.length,
            truncated: values.length > limit,
        };
    }

    function eyeIdentity(eye) {
        if (!eye || typeof eye !== "object") return null;
        return {
            generation: scalar(eye.generation),
            transitionEpoch: scalar(eye.transitionEpoch),
            resourceRevision: scalar(eye.resourceRevision),
            deviceIdentity: scalar(eye.deviceIdentity),
            compositorCycleToken: scalar(eye.compositorCycleToken),
            path: scalar(eye.path),
        };
    }

    function recoveryAssessment(root, apply, waiter, identifiers) {
        const safety = safeTerminalAssessment(waiter, identifiers);
        const timeline = waiter && waiter.replacementTimeline;
        const terminal = timeline && timeline.terminal;
        const proof = terminal && terminal.presentationProof;
        const reasons = [];
        if (!root || root.ok !== true) reasons.push("scenario_not_ok");
        if (!apply) reasons.push("apply_missing");
        else if (apply.accepted !== true) reasons.push("apply_not_accepted");
        if (!waiter) reasons.push("waiter_missing");
        else if (waiter.satisfied !== true) reasons.push("waiter_not_satisfied");
        reasons.push(...safety.reasons.map((reason) => `safe_terminal:${reason}`));
        if (!waiter || !waiter.milestoneTimings) {
            reasons.push("milestone_timings_missing");
        }
        if (!timeline) reasons.push("replacement_timeline_missing");
        const snapshot = waiter && waiter.upscalingSnapshot;
        const observation = waiter && waiter.observation;
        const physical = observation && observation.physical;
        const presentation = observation && observation.replacementPresentation;
        const strictReasons = waiter &&
            (waiter.strictFailureReasons || waiter.failureReasons);
        return {
            decision: { satisfied: reasons.length === 0, reasons },
            scenarioOk: root && typeof root.ok === "boolean" ? root.ok : null,
            apply: {
                present: Boolean(apply),
                accepted: apply && typeof apply.accepted === "boolean" ?
                    apply.accepted : null,
                status: scalar(apply && apply.status),
                disposition: scalar(apply && apply.disposition),
            },
            waiter: {
                present: Boolean(waiter),
                satisfied: waiter && typeof waiter.satisfied === "boolean" ?
                    waiter.satisfied : null,
                outcome: scalar(waiter && waiter.outcome),
                timedOutMilestone: scalar(waiter && waiter.timedOutMilestone),
            },
            milestones: {
                presentationStable: waiter &&
                    typeof waiter.presentationStable === "boolean" ?
                    waiter.presentationStable : null,
                cleanupDrained: waiter && typeof waiter.cleanupDrained === "boolean" ?
                    waiter.cleanupDrained : null,
                strictSatisfied: waiter && typeof waiter.strictSatisfied === "boolean" ?
                    waiter.strictSatisfied : null,
            },
            failures: {
                presentation: {
                    mask: scalar(waiter && waiter.presentationFailureMask),
                    reasons: reasonProjection(waiter && waiter.presentationFailureReasons),
                },
                cleanup: {
                    mask: scalar(waiter && waiter.cleanupFailureMask),
                    reasons: reasonProjection(waiter && waiter.cleanupFailureReasons),
                },
                strict: {
                    mask: scalar(waiter && waiter.strictFailureMask),
                    reasons: reasonProjection(strictReasons),
                },
            },
            safeTerminal: safety,
            controller: {
                activeOperationId: scalar(snapshot && snapshot.activeOperationId),
                stateRevision: scalar(snapshot && snapshot.stateRevision),
                transitionState: scalar(snapshot && snapshot.transitionState),
                physicalState: scalar(physical && physical.state),
                presentationPhase: scalar(presentation && presentation.phase),
            },
            evidence: {
                milestoneTimingsPresent: Boolean(waiter && waiter.milestoneTimings),
                replacementTimelinePresent: Boolean(timeline),
                terminalTimelinePresent: Boolean(terminal),
            },
            terminalIdentity: terminal ? {
                frame: scalar(terminal.frame),
                qpcTick: scalar(terminal.tick),
                currentPresentationGeneration:
                    scalar(terminal.currentPresentationGeneration),
                currentPresentationProviderGeneration:
                    scalar(terminal.currentPresentationProviderGeneration),
                currentPresentationResourceRevision:
                    scalar(terminal.currentPresentationResourceRevision),
                replacementRequestId: scalar(terminal.replacementRequestId),
                replacementTransitionEpoch:
                    scalar(terminal.replacementTransitionEpoch),
                replacementContractGeneration:
                    scalar(terminal.replacementContractGeneration),
                physicalMutationEpoch: scalar(terminal.physicalMutationEpoch),
                proof: proof ? {
                    proven: typeof proof.proven === "boolean" ? proof.proven : null,
                    contractGeneration: scalar(proof.contractGeneration),
                    transitionEpoch: scalar(proof.transitionEpoch),
                    resourcePublicationGeneration:
                        scalar(proof.resourcePublicationGeneration),
                    resourceRevision: scalar(proof.resourceRevision),
                    deviceIdentity: scalar(proof.deviceIdentity),
                    compositorCycleToken: scalar(proof.compositorCycleToken),
                    leftEye: eyeIdentity(proof.leftEye || terminal.leftEye),
                    rightEye: eyeIdentity(proof.rightEye || terminal.rightEye),
                } : null,
            } : null,
        };
    }

    function recoverableTerminal(waiter, identifiers) {
        if (!waiter || waiter.action !== "qualification_wait" ||
            waiter.transitionId !== identifiers.transitionId ||
            waiter.ownerId !== identifiers.ownerId ||
            !waiter.upscalingSnapshot ||
            !Number.isSafeInteger(waiter.upscalingSnapshot.activeOperationId)) {
            return false;
        }
        const facts = waiter.observation && waiter.observation.facts;
        if (!facts || facts.stressSession !== true || facts.exactCell !== true ||
            facts.loadedInWorld !== true) {
            return false;
        }
        const failureCodes = Array.isArray(waiter.failureReasons) ?
            waiter.failureReasons.map((reason) =>
                typeof reason === "string" ? reason :
                    reason && `${reason.category || ""}:${reason.code || ""}`)
                .filter(Boolean).map((reason) => reason.toLowerCase()) : [];
        return !failureCodes.some((reason) =>
            /device[_ -]?los(?:s|t)|out[_ -]?of[_ -]?memory|(^|[:_ -])oom($|[:_ -])/.test(reason));
    }

    function nonStableNote(waiter) {
        if (!waiter || waiter.satisfied === true) return null;
        const timeline = waiter.replacementTimeline || {};
        const observation = waiter.observation || {};
        const physical = observation.physical || {};
        const presentation = observation.replacementPresentation || {};
        const facets = [timeline.terminal, timeline.firstNewGenerationProven,
            timeline.firstPostMutation, timeline.firstPhysicalMutation,
            timeline.lastPreMutation].filter((facet) => facet);
        const dispositionFacet = facets.find((facet) =>
            typeof facet.selectedPresentationDisposition === "string");
        const terminal = timeline.terminal || {};
        const proof = terminal.presentationProof || {};
        const failureCodes = Array.isArray(waiter.failureReasons) ?
            waiter.failureReasons.map((reason) => {
                if (typeof reason === "string") return reason;
                if (!reason || typeof reason !== "object") return null;
                const category = typeof reason.category === "string" ?
                    `${reason.category}:` : "";
                return typeof reason.code === "string" ?
                    `${category}${reason.code}` : null;
            }).filter((reason) => reason) : [];
        return {
            status: "not_stable",
            deadlineMilliseconds: matrix.completionTimeoutMilliseconds,
            outcome: waiter.outcome || null,
            timedOutMilestone: waiter.timedOutMilestone || null,
            presentationDisposition: dispositionFacet ?
                dispositionFacet.selectedPresentationDisposition : "not_exposed",
            leftEyePath: presentation.leftEye && presentation.leftEye.path ||
                proof.leftEye && proof.leftEye.path || "not_exposed",
            rightEyePath: presentation.rightEye && presentation.rightEye.path ||
                proof.rightEye && proof.rightEye.path || "not_exposed",
            controllerState: physical.state || "not_exposed",
            presentationPhase: physical.presentationPhase || "not_exposed",
            failureCodes,
        };
    }

    function facetProjection(facet) {
        if (!facet || typeof facet !== "object") return null;
        const proof = facet.presentationProof && typeof facet.presentationProof === "object" ?
            facet.presentationProof : null;
        const preparation = facet.preparationAdmission &&
            typeof facet.preparationAdmission === "object" ? facet.preparationAdmission : null;
        const mutationAdmission = facet.replacementMutationAdmission &&
            typeof facet.replacementMutationAdmission === "object" ?
            facet.replacementMutationAdmission : null;
        const leftEye = proof && proof.leftEye && typeof proof.leftEye === "object" ?
            proof.leftEye : null;
        const rightEye = proof && proof.rightEye && typeof proof.rightEye === "object" ?
            proof.rightEye : null;
        return {
            tick: facet.tick ?? null,
            frame: facet.frame ?? null,
            proof_kind: proof ? proof.kind ?? null : null,
            proof_frame: proof ? proof.frame ?? null : null,
            proof_qpc_tick: proof ? proof.qpcTick ?? null : null,
            proof_method: proof ? proof.method ?? null : null,
            proof_backend: proof ? proof.backend ?? null : null,
            proof_request_id: proof ? proof.requestId ?? null : null,
            proof_transition_epoch: proof ? proof.transitionEpoch ?? null : null,
            proof_contract_generation: proof ? proof.contractGeneration ?? null : null,
            proof_provider_runtime_generation: proof ?
                proof.providerRuntimeGeneration ?? null : null,
            proof_publication_generation: proof ?
                proof.resourcePublicationGeneration ?? null : null,
            proof_resource_revision: proof ? proof.resourceRevision ?? null : null,
            proof_device_identity: proof ? proof.deviceIdentity ?? null : null,
            proof_compositor_cycle_token: proof ? proof.compositorCycleToken ?? null : null,
            proof_render_width: proof ? proof.renderWidth ?? null : null,
            proof_render_height: proof ? proof.renderHeight ?? null : null,
            proof_display_width: proof ? proof.displayWidth ?? null : null,
            proof_display_height: proof ? proof.displayHeight ?? null : null,
            left_eye_frame: leftEye ? leftEye.frame ?? null : null,
            left_eye_compositor_cycle_token: leftEye ?
                leftEye.compositorCycleToken ?? null : null,
            left_eye_transition_epoch: leftEye ? leftEye.transitionEpoch ?? null : null,
            left_eye_method: leftEye ? leftEye.method ?? null : null,
            left_eye_path: leftEye ? leftEye.path ?? null : null,
            left_eye_generation: leftEye ? leftEye.generation ?? null : null,
            left_eye_device_identity: leftEye ? leftEye.deviceIdentity ?? null : null,
            left_eye_resource_revision: leftEye ? leftEye.resourceRevision ?? null : null,
            left_eye_loading_or_menu_context: leftEye ?
                leftEye.loadingOrMenuContext === true : null,
            left_eye_transition_cooldown: leftEye ?
                leftEye.transitionCooldown === true : null,
            right_eye_frame: rightEye ? rightEye.frame ?? null : null,
            right_eye_compositor_cycle_token: rightEye ?
                rightEye.compositorCycleToken ?? null : null,
            right_eye_transition_epoch: rightEye ? rightEye.transitionEpoch ?? null : null,
            right_eye_method: rightEye ? rightEye.method ?? null : null,
            right_eye_path: rightEye ? rightEye.path ?? null : null,
            right_eye_generation: rightEye ? rightEye.generation ?? null : null,
            right_eye_device_identity: rightEye ? rightEye.deviceIdentity ?? null : null,
            right_eye_resource_revision: rightEye ? rightEye.resourceRevision ?? null : null,
            right_eye_loading_or_menu_context: rightEye ?
                rightEye.loadingOrMenuContext === true : null,
            right_eye_transition_cooldown: rightEye ?
                rightEye.transitionCooldown === true : null,
            preparation_status: preparation ? preparation.status ?? null : null,
            preparation_reason_mask: preparation ? preparation.reasonMask ?? null : null,
            mutation_admission_status: mutationAdmission ?
                mutationAdmission.status ?? null : null,
            mutation_admission_blocked: mutationAdmission ?
                mutationAdmission.blocked === true : null,
            mutation_admission_reason_mask: mutationAdmission ?
                mutationAdmission.reasonMask ?? null : null,
            physical_mutation_started: facet.physicalMutationStarted === true,
            physical_mutation_source: facet.physicalMutationSource ?? null,
            selected_presentation_disposition:
                facet.selectedPresentationDisposition ?? null,
        };
    }

    function invariantCount(audit, name) {
        const violations = audit && audit.violations;
        const value = violations && violations[name];
        return Number.isSafeInteger(value) && value >= 0 ? value : null;
    }

    function positiveInteger(value) {
        return Number.isSafeInteger(value) && value > 0;
    }

    function nonNegativeInteger(value) {
        return Number.isSafeInteger(value) && value >= 0;
    }

    function isVendorTarget(target) {
        return target && (target.method === "dlss" || target.method === "fsr");
    }

    function matchesMutationBoundaryGeneration(boundaryGeneration, proofGeneration, target) {
        if (!nonNegativeInteger(boundaryGeneration) ||
            !nonNegativeInteger(proofGeneration) || !target) {
            return false;
        }
        return isVendorTarget(target) ?
            boundaryGeneration === 0 || boundaryGeneration === proofGeneration :
            proofGeneration === 0;
    }

    function exactNativeStereoProof(proof, target) {
        const exactEye = (eye) => eye &&
            positiveInteger(eye.frame) && eye.frame === proof.frame &&
            positiveInteger(eye.qpcTick) &&
            positiveInteger(eye.compositorCycleToken) &&
            eye.compositorCycleToken === proof.compositorCycleToken &&
            positiveInteger(eye.transitionEpoch) &&
            eye.transitionEpoch === proof.transitionEpoch &&
            eye.method === target.method && eye.backend === "none" &&
            eye.generation === 0 && eye.deviceIdentity === proof.deviceIdentity &&
            eye.resourceRevision === proof.resourceRevision &&
            eye.renderWidth === proof.renderWidth &&
            eye.renderHeight === proof.renderHeight &&
            eye.displayWidth === proof.displayWidth &&
            eye.displayHeight === proof.displayHeight &&
            eye.vendorDispatchFrame === 0 && eye.vendorDispatchSerial === 0 &&
            eye.vendorRuntimeFallback === false;
        return positiveInteger(proof.frame) && positiveInteger(proof.qpcTick) &&
            positiveInteger(proof.compositorCycleToken) && proof.backend === "none" &&
            proof.contractGeneration === 0 &&
            proof.providerRuntimeGeneration === 0 &&
            proof.sharedVendorDispatchRequired === false &&
            proof.vendorDispatchProven === false &&
            exactEye(proof.leftEye) && exactEye(proof.rightEye);
    }

    function exactTargetProof(proof, target) {
        if (!proof || proof.proven !== true || !target) return false;
        const vendorTarget = isVendorTarget(target);
        const expectedKind = vendorTarget ?
            "exact_vendor_evaluation" : "exact_native_presentation";
        if (proof.kind !== expectedKind || proof.method !== target.method ||
            proof.qualityMode !== quality[target.qualityMode] ||
            proof.renderScaleMode !== target.renderScaleMode) {
            return false;
        }
        const identifiers = [
            proof.requestId,
            proof.transitionEpoch,
            proof.resourcePublicationGeneration,
            proof.resourceRevision,
            proof.deviceIdentity,
            proof.renderWidth,
            proof.renderHeight,
            proof.displayWidth,
            proof.displayHeight,
        ];
        if (!identifiers.every(positiveInteger)) return false;
        if (vendorTarget && (!positiveInteger(proof.contractGeneration) ||
            !positiveInteger(proof.providerRuntimeGeneration))) return false;
        if (!vendorTarget && !exactNativeStereoProof(proof, target)) return false;
        return target.renderScaleMode ?
            proof.renderWidth < proof.displayWidth &&
                proof.renderHeight < proof.displayHeight :
            proof.renderWidth === proof.displayWidth &&
                proof.renderHeight === proof.displayHeight;
    }

    function boundaryOrder(offender, boundary) {
        if (!offender || !boundary) return "unknown";
        const offenderTick = offender.qpcTick ?? offender.tick;
        const boundaryTick = boundary.qpcTick ?? boundary.tick;
        const frameComparable = positiveInteger(offender.frame) &&
            positiveInteger(boundary.frame);
        const tickComparable = positiveInteger(offenderTick) &&
            positiveInteger(boundaryTick);
        if (!frameComparable || !tickComparable) return "unknown";
        if (offender.frame === boundary.frame) {
            return offenderTick < boundaryTick ? "before" : "at_or_after";
        }
        const frameBefore = offender.frame < boundary.frame;
        const tickBefore = offenderTick < boundaryTick;
        if (frameBefore && tickBefore) return "before";
        if (!frameBefore && !tickBefore) return "at_or_after";
        return "conflict";
    }

    function task2Projection(waiter, target) {
        const timeline = waiter && waiter.replacementTimeline;
        const audit = waiter && waiter.presentationCycleAudit;
        const expectation = timeline && timeline.mutationExpectation || "unknown";
        const expectationReason = timeline && timeline.mutationExpectationReason;
        const required = expectation === "required";
        const notRequired = expectation === "not_required";
        const explicitNotRequiredReason = typeof expectationReason === "string" &&
            expectationReason.length > 0 && expectationReason !== "replacement_not_observed";
        const notRequiredEvidence = timeline &&
            timeline.mutationNotRequiredTerminalProof;
        const notRequiredProof = notRequiredEvidence &&
            notRequiredEvidence.presentationProof;
        const notRequiredOwnerProof = notRequiredEvidence && audit &&
            notRequiredEvidence.stressSessionId ===
                (waiter.baseline && waiter.baseline.stressSessionId) &&
            notRequiredEvidence.qualificationTransitionId ===
                waiter.transitionId &&
            positiveInteger(notRequiredEvidence.ownershipToken) &&
            notRequiredEvidence.ownershipToken === audit.ownerToken;
        const notRequiredIdentityProof = notRequiredEvidence &&
            notRequiredProof &&
            positiveInteger(notRequiredEvidence.replacementRequestId) &&
            notRequiredProof.requestId ===
                notRequiredEvidence.replacementRequestId &&
            positiveInteger(notRequiredEvidence.replacementTransitionEpoch) &&
            notRequiredProof.transitionEpoch ===
                notRequiredEvidence.replacementTransitionEpoch &&
            matchesMutationBoundaryGeneration(
                notRequiredEvidence.replacementContractGeneration,
                notRequiredProof.contractGeneration, target) &&
            positiveInteger(notRequiredEvidence.replacementDeviceIdentity) &&
            notRequiredProof.deviceIdentity ===
                notRequiredEvidence.replacementDeviceIdentity;
        const exactTerminalProof = notRequiredOwnerProof &&
            notRequiredIdentityProof &&
            exactTargetProof(notRequiredProof, target);
        const missing = [];
        const producerInvalid = [];
        if (!timeline || !timeline.dispatch) missing.push("dispatch");
        else if (!timeline.dispatch.presentationProof ||
            timeline.dispatch.presentationProof.proven !== true) {
            missing.push("truthful_current_contract");
        }
        if (required && !timeline.firstPhysicalMutation) {
            missing.push("missing_required_mutation_boundary");
        }
        if (required && !timeline.firstPostMutation) {
            missing.push("first_post_mutation");
        }
        if (required && (!timeline.firstNewGenerationProven ||
            !timeline.firstNewGenerationProven.presentationProof ||
            timeline.firstNewGenerationProven.presentationProof.proven !== true)) {
            missing.push("first_new_generation_proven");
        }
        if (notRequired && !explicitNotRequiredReason) {
            missing.push("mutation_not_required_reason");
        }
        if (notRequired && !exactTerminalProof) {
            missing.push("mutation_not_required_terminal_proof");
        }
        const auditStorageComplete = Boolean(audit &&
            audit.evidenceComplete === true && audit.retentionOverflow !== true);
        if (!auditStorageComplete) {
            missing.push("authoritative_cycle_audit");
        }
        const auditOwnerAuthoritative = Boolean(audit &&
            audit.ownerTransitionId === waiter.transitionId &&
            positiveInteger(audit.ownerToken));
        if (!auditOwnerAuthoritative) {
            missing.push("authoritative_cycle_owner");
        }
        const auditHasObservations = Boolean(audit &&
            positiveInteger(audit.eyeObservations));
        if (!auditHasObservations) {
            missing.push("authoritative_cycle_observations");
        }
        const violationSchemaAuthoritative = Number.isSafeInteger(
            waiter.schemaRevision) && waiter.schemaRevision >= 14;
        if (!violationSchemaAuthoritative) {
            missing.push("authoritative_violation_schema");
        }
        const violationNames = [
            "preMutationExactPresentationSuppressed",
            "preMutationStretchWithoutMutation",
            "postMutationOldGenerationPresented",
            "postMutationUnprovenStereoSubmitted",
        ];
        const violations = Object.fromEntries(violationNames.map((name) =>
            [name, invariantCount(audit, name)]));
        const countersComplete = Object.values(violations)
            .every((value) => value !== null);
        if (!countersComplete) {
            missing.push("authoritative_cycle_counters");
        }
        const boundary = timeline && timeline.firstPhysicalMutation;
        const boundaryOwnerMismatch = Boolean(boundary &&
            (!positiveInteger(boundary.stressSessionId) ||
                boundary.stressSessionId !==
                    (waiter.baseline && waiter.baseline.stressSessionId) ||
                boundary.qualificationTransitionId !== waiter.transitionId ||
                !positiveInteger(boundary.ownershipToken) || !audit ||
                boundary.ownershipToken !== audit.ownerToken ||
                !positiveInteger(boundary.replacementRequestId) ||
                !positiveInteger(boundary.replacementTransitionEpoch) ||
                !nonNegativeInteger(boundary.replacementContractGeneration) ||
                !positiveInteger(boundary.replacementDeviceIdentity) ||
                !positiveInteger(boundary.frame) ||
                !positiveInteger(boundary.tick) ||
                typeof boundary.physicalMutationSource !== "string" ||
                boundary.physicalMutationSource.length === 0));
        if (boundaryOwnerMismatch) {
            producerInvalid.push("physical_mutation_boundary_owner_mismatch");
        }
        const transitionEvidenceComplete = Boolean(timeline && timeline.dispatch &&
            auditStorageComplete && auditOwnerAuthoritative &&
            auditHasObservations && countersComplete &&
            violationSchemaAuthoritative);
        const basePhaseCountersAuthoritative = transitionEvidenceComplete &&
            (!required || Boolean(boundary) && !boundaryOwnerMismatch);
        const authorityMismatchReasons = [];
        if (audit && positiveInteger(audit.ownerTransitionId) &&
            audit.ownerTransitionId !== waiter.transitionId) {
            authorityMismatchReasons.push("audit_transition_owner_mismatch");
        }
        if (boundary && positiveInteger(boundary.stressSessionId) &&
            positiveInteger(waiter.baseline && waiter.baseline.stressSessionId) &&
            boundary.stressSessionId !== waiter.baseline.stressSessionId) {
            authorityMismatchReasons.push("boundary_stress_session_mismatch");
        }
        if (boundary && positiveInteger(boundary.qualificationTransitionId) &&
            boundary.qualificationTransitionId !== waiter.transitionId) {
            authorityMismatchReasons.push("boundary_transition_owner_mismatch");
        }
        if (boundary && positiveInteger(boundary.ownershipToken) && audit &&
            positiveInteger(audit.ownerToken) &&
            boundary.ownershipToken !== audit.ownerToken) {
            authorityMismatchReasons.push("boundary_audit_token_mismatch");
        }
        const baseAuthorityStatus = authorityMismatchReasons.length > 0 ?
            "MISMATCHED" : basePhaseCountersAuthoritative ?
                "MATCHED" : "INCOMPLETE";
        const baseAuthorityReasons = authorityMismatchReasons.length > 0 ?
            authorityMismatchReasons : [...new Set([
                ...missing.filter((value) => value.startsWith("authoritative_") ||
                    value === "missing_required_mutation_boundary"),
                ...(boundaryOwnerMismatch ?
                    ["physical_mutation_boundary_owner_mismatch"] : []),
            ])];
        const postMutationOffenders = {
            postMutationOldGenerationPresented:
                "firstPostMutationOldGenerationPresented",
            postMutationUnprovenStereoSubmitted:
                "firstPostMutationUnprovenStereoSubmitted",
        };
        const preMutationOffenders = {
            preMutationExactPresentationSuppressed:
                "firstPreMutationExactPresentationSuppressed",
            preMutationStretchWithoutMutation:
                "firstPreMutationStretchWithoutMutation",
        };
        const temporallyImpossible = [];
        const genuineViolations = [];
        const reportedViolations = [];
        const violationAuthority = {};
        for (const [name, count] of Object.entries(violations)) {
            if (!(count > 0)) continue;
            reportedViolations.push(name);
            // Preserve producer counters even when their phase owner is unproven.
            if (!basePhaseCountersAuthoritative) {
                violationAuthority[name] = {
                    status: baseAuthorityStatus,
                    reasons: baseAuthorityReasons,
                };
                continue;
            }
            const offenderName = postMutationOffenders[name];
            const preMutationOffenderName = preMutationOffenders[name];
            const firstOffenderName = offenderName || preMutationOffenderName;
            const offender = audit && audit.violations &&
                audit.violations[firstOffenderName];
            if (!offender) {
                const reason = `${name}_first_offender_missing`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "INCOMPLETE", reasons: [reason],
                };
                continue;
            }
            if (preMutationOffenderName && !boundary && notRequired) {
                genuineViolations.push(name);
                violationAuthority[name] = { status: "MATCHED", reasons: [] };
                continue;
            }
            const order = boundaryOrder(offender, boundary);
            if (preMutationOffenderName && order === "before") {
                genuineViolations.push(name);
                violationAuthority[name] = { status: "MATCHED", reasons: [] };
            } else if (preMutationOffenderName && order === "at_or_after") {
                temporallyImpossible.push(name);
                const reason = `${name}_not_before_boundary`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "MISMATCHED", reasons: [reason],
                };
            } else if (preMutationOffenderName && order === "conflict") {
                temporallyImpossible.push(name);
                const reason = `${name}_temporal_order_conflict`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "MISMATCHED", reasons: [reason],
                };
            } else if (preMutationOffenderName) {
                const reason = `${name}_temporal_order_unproven`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "INCOMPLETE", reasons: [reason],
                };
            } else if (order === "before") {
                temporallyImpossible.push(name);
                const reason = `${name}_precedes_boundary`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "MISMATCHED", reasons: [reason],
                };
            } else if (order === "conflict") {
                temporallyImpossible.push(name);
                const reason = `${name}_temporal_order_conflict`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "MISMATCHED", reasons: [reason],
                };
            } else if (order === "unknown") {
                const reason = `${name}_temporal_order_unproven`;
                producerInvalid.push(reason);
                violationAuthority[name] = {
                    status: "INCOMPLETE", reasons: [reason],
                };
            } else {
                genuineViolations.push(name);
                violationAuthority[name] = { status: "MATCHED", reasons: [] };
            }
        }
        const violationAuthorityValues = Object.values(violationAuthority);
        const phaseCounterAuthorityStatus = violationAuthorityValues.some((value) =>
            value.status === "MISMATCHED") ? "MISMATCHED" :
            violationAuthorityValues.some((value) =>
                value.status === "INCOMPLETE") ? "INCOMPLETE" : baseAuthorityStatus;
        const phaseCounterAuthorityReasons = [...new Set([
            ...(baseAuthorityStatus === "MATCHED" ? [] : baseAuthorityReasons),
            ...violationAuthorityValues.flatMap((value) => value.reasons),
        ])];
        const phaseCountersAuthoritative =
            phaseCounterAuthorityStatus === "MATCHED";

        const firstExactCycles = audit && audit.firstExactNewGenerationCycles;
        const firstNew = timeline && timeline.firstNewGenerationProven;
        const firstNewProof = firstNew && firstNew.presentationProof;
        if (!Number.isSafeInteger(firstExactCycles) || firstExactCycles < 0) {
            producerInvalid.push("first_exact_new_generation_counter_invalid");
        } else if (firstExactCycles > 0 && !firstNew) {
            producerInvalid.push("first_exact_new_generation_proof_missing");
        } else if (firstExactCycles === 0 && firstNew) {
            producerInvalid.push("first_exact_new_generation_counter_missing");
        }
        if (firstNew) {
            if (!exactTargetProof(firstNewProof, target)) {
                producerInvalid.push("first_new_generation_target_mismatch");
            }
            if (boundaryOrder(firstNew, boundary) !== "at_or_after") {
                producerInvalid.push("first_new_generation_not_after_boundary");
            }
            if (firstNew.qualificationTransitionId !== waiter.transitionId ||
                !positiveInteger(firstNew.ownershipToken) ||
                !audit || firstNew.ownershipToken !== audit.ownerToken ||
                !boundary || firstNew.stressSessionId !== boundary.stressSessionId ||
                firstNew.qualificationTransitionId !==
                    boundary.qualificationTransitionId ||
                firstNew.ownershipToken !== boundary.ownershipToken ||
                !firstNewProof || firstNewProof.requestId !==
                    boundary.replacementRequestId ||
                firstNewProof.transitionEpoch !==
                    boundary.replacementTransitionEpoch ||
                !matchesMutationBoundaryGeneration(
                    boundary.replacementContractGeneration,
                    firstNewProof.contractGeneration, target) ||
                firstNewProof.deviceIdentity !==
                    boundary.replacementDeviceIdentity) {
                producerInvalid.push("first_new_generation_owner_mismatch");
            }
        }
        const exactViolation = genuineViolations.length > 0;
        const evidenceVerdict = exactViolation ? "FAIL" :
            missing.length > 0 || producerInvalid.length > 0 ||
                expectation === "unknown" ? "INCONCLUSIVE" : "PASS";
        return {
            renderVerdict: waiter && waiter.satisfied === true ? "PASS" : "FAIL",
            evidenceVerdict,
            task2Verdict: evidenceVerdict,
            mutationExpectation: expectation,
            mutationExpectationReason: expectationReason || null,
            mutationNotRequiredProven: notRequired &&
                explicitNotRequiredReason && exactTerminalProof,
            auditStorageComplete,
            ownerCorrelatedAuditObserved: auditOwnerAuthoritative &&
                auditHasObservations,
            transitionEvidenceComplete,
            missingEvidence: missing,
            phaseCountersAuthoritative,
            phaseCounterAuthorityStatus,
            phaseCounterAuthorityReasons,
            invariantViolations: violations,
            reportedInvariantViolations: reportedViolations,
            violationAuthority,
            genuineInvariantViolations: genuineViolations,
            temporallyImpossibleViolations: temporallyImpossible,
            producerInvalidEvidence: producerInvalid,
        };
    }

    function transitionProjection(waiter, target) {
        const timeline = waiter && waiter.replacementTimeline || {};
        const auditDispositions = waiter && waiter.presentationCycleAudit &&
            waiter.presentationCycleAudit.dispositionCounts;
        const presentationStretchSelected = [
            timeline.firstPhysicalMutation,
            timeline.firstPostMutation,
            timeline.firstNewGenerationProven,
            timeline.terminal,
        ].some((facet) => facet &&
            (facet.selectedPresentationDisposition === "PresentationStretch" ||
                facet.selectedPresentationDisposition === "presentation_stretch")) ||
            Boolean(auditDispositions &&
                ((auditDispositions.beforeMutation &&
                    auditDispositions.beforeMutation.presentation_stretch > 0) ||
                    (auditDispositions.afterMutation &&
                        auditDispositions.afterMutation.presentation_stretch > 0)));
        const task2 = task2Projection(waiter, target);
        return {
            satisfied: waiter.satisfied === true,
            nonStableNote: nonStableNote(waiter),
            presentationStable: waiter.presentationStable === true,
            cleanupDrained: waiter.cleanupDrained === true,
            presentationStretchSelected: presentationStretchSelected === true,
            presentationStretchTerminalRecovery: presentationStretchSelected === true &&
                waiter.satisfied === true && waiter.presentationStable === true &&
                waiter.cleanupDrained === true,
            ...task2,
            dispatch_: facetProjection(timeline.dispatch),
            blocked_pre_mutation_: facetProjection(timeline.blockedPreMutation),
            last_pre_mutation_: facetProjection(timeline.lastPreMutation),
            first_physical_mutation_: facetProjection(timeline.firstPhysicalMutation) ||
                (task2.mutationNotRequiredProven ?
                    "not_required" : "not_exposed"),
            first_post_mutation_: facetProjection(timeline.firstPostMutation),
            first_new_generation_proven_: facetProjection(
                timeline.firstNewGenerationProven),
            terminal_: facetProjection(timeline.terminal),
            phaseDurations: waiter.phaseDurations || null,
            presentationCycleAudit: waiter.presentationCycleAudit || null,
        };
    }

    async function recoverTerminal(identifiers) {
        const status = await renderScale({
            action: "qualification_status",
            expectedBuildId: buildId,
        });
        retain(`${runId}:recovery:${identifiers.transitionId}`, status.envelope);
        const qualification = status.root.qualification;
        const waiter = qualification && qualification.lastEvidence;
        if (qualification && qualification.active === false && waiter &&
            waiter.transitionId === identifiers.transitionId &&
            waiter.ownerId === identifiers.ownerId) {
            return waiter;
        }
        throw new Error("terminal_receipt_unavailable");
    }

    async function closeOpenQualification(identifiers) {
        const status = await renderScale({
            action: "qualification_status",
            expectedBuildId: buildId,
        });
        retain(`${runId}:recovery:${identifiers.transitionId}:close-status`,
            status.envelope);
        const qualification = status.root.qualification;
        if (qualification && qualification.active === true &&
            qualification.transitionId === identifiers.transitionId &&
            qualification.ownerId === identifiers.ownerId) {
            const cancel = await renderScale({
                action: "qualification_cancel",
                transitionId: identifiers.transitionId,
                ownerId: identifiers.ownerId,
                expectedBuildId: buildId,
            });
            retain(`${runId}:recovery:${identifiers.transitionId}:cancel`,
                cancel.envelope);
        }
    }

    async function restoreBaseline(boundary, lane, laneIndex, pass, row,
        closeDlssTraceSessionId) {
        const target = targetFor(boundary,
            matrix.destinations[matrix.initialDestination],
            lane.configuredFsrRuntime);
        if ((target.method !== "dlss" && target.method !== "fsr") ||
            target.renderScaleMode !== true ||
            !Number.isSafeInteger(quality[target.qualityMode])) {
            throw new Error("recovery_baseline_target_invalid");
        }
        const identifiers = recoveryIds(laneIndex, pass, row.ordinal);
        const steps = [];
        if (Number.isSafeInteger(closeDlssTraceSessionId) &&
            closeDlssTraceSessionId > 0) {
            steps.push(toolStep("failed-dlss-trace-stop",
                "communityshaders.renderscale", {
                    action: "dlss_trace_stop",
                    expectedSessionId: closeDlssTraceSessionId,
                    expectedBuildId: buildId,
                }));
            steps.push(toolStep("failed-dlss-trace-read",
                "communityshaders.renderscale", {
                    action: "dlss_trace_read", afterSequence: 0,
                    limit: matrix.traceReadLimit, expectedBuildId: buildId,
                }));
        }
        steps.push(toolStep("recovery-qualification-begin",
            "communityshaders.renderscale", {
                action: "qualification_begin",
                transitionId: identifiers.transitionId,
                ownerId: identifiers.ownerId,
                expectedBuildId: buildId,
            }));
        steps.push(toolStep("recovery-qualification-dispatch",
            "communityshaders.renderscale", {
                action: "qualification_dispatch",
                transitionId: identifiers.transitionId,
                ownerId: identifiers.ownerId,
                startPerformanceTelemetry: false,
                expectedBuildId: buildId,
            }));
        const applyArgs = {
            action: "apply",
            method: target.method,
            enabled: true,
            qualityMode: quality[target.qualityMode],
            expectedBuildId: buildId,
        };
        if (target.method === "dlss") {
            applyArgs.dlssPreset = dlssProfile[target.dlssProfile];
        }
        steps.push(toolStep("recovery-profile-apply",
            "communityshaders.renderscale", applyArgs));
        const waitArgs = {
            action: "qualification_wait",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedCellEditorId: "WhiterunDragonsreach",
            timeoutMs: matrix.completionTimeoutMilliseconds,
            milestone: "strict",
            target: waiterTarget(target),
            foveation,
            expectedBuildId: buildId,
        };
        steps.push(toolStep("qualification-wait",
            "communityshaders.renderscale", waitArgs));
        const receiptKey =
            `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}:recovery`;
        const response = await scenario(steps, `${receiptKey}:scenario`);
        const entries = resultMap(response.root);
        const apply = entries.get("recovery-profile-apply");
        const waiter = entries.get("qualification-wait");
        const diagnostic = scenarioDiagnostic(
            response.root, steps, `${receiptKey}:scenario`);
        const assessment = recoveryAssessment(
            response.root, apply, waiter, identifiers);
        const recovered = assessment.decision.satisfied;
        const evidence = {
            status: recovered ? "RECOVERED" : "FAILED",
            scenarioReceiptKey: `${receiptKey}:scenario`,
            scenario: diagnostic,
            target,
            apply,
            waiter,
            failureSnapshot: recovered ? null : assessment,
            traceStop: entries.get("failed-dlss-trace-stop") || null,
            traceRead: entries.get("failed-dlss-trace-read") || null,
        };
        retain(receiptKey, evidence);
        if (!recovered) {
            if (!waiter) await closeOpenQualification(identifiers);
            throw diagnosticError("transition_recovery_failed", {
                ...diagnostic,
                recovery: assessment,
            });
        }
        return {
            boundary: {
                ...terminalBoundary(waiter),
                recoveryReceiptKey: receiptKey,
            },
            receiptKey,
            evidence,
            summary: {
                status: "RECOVERED",
                target,
                receiptKey,
                elapsedMs: waiter.timing ? waiter.timing.elapsedMs : null,
            },
        };
    }

    function sessionSnapshot(value) {
        const session = value && value.status && value.status.session;
        return {
            present: Boolean(session && typeof session === "object"),
            id: session && Object.hasOwn(session, "id") ? session.id : null,
            active: session && typeof session.active === "boolean" ?
                session.active : null,
        };
    }

    function baselineOwnership(start, waiter) {
        const started = sessionSnapshot(start);
        const waiterId = waiter && waiter.baseline &&
            waiter.baseline.stressSessionId;
        const reasons = [];
        if (!started.present) reasons.push("start_session_missing");
        if (!Number.isSafeInteger(started.id) || started.id < 1) {
            reasons.push("start_session_id_invalid");
        }
        if (started.active !== true) reasons.push("start_session_not_active");
        if (!Number.isSafeInteger(waiterId) || waiterId < 1) {
            reasons.push("waiter_session_id_invalid");
        }
        if (Number.isSafeInteger(started.id) && Number.isSafeInteger(waiterId) &&
            started.id !== waiterId) {
            reasons.push("baseline_session_id_mismatch");
        }
        return {
            status: reasons.length === 0 ? "MATCHED_ACTIVE" : "UNPROVEN",
            startSessionId: started.id,
            waiterSessionId: waiterId ?? null,
            startActive: started.active,
            reasons,
        };
    }

    function cpuDispatchOwnership(dispatch, identifiers, receiptKey) {
        const telemetry = dispatch && dispatch.performanceTelemetry;
        const cpu = telemetry && telemetry.cpuPerformance;
        const reasons = [];
        if (!dispatch || dispatch.action !== "qualification_dispatch" ||
            dispatch.accepted !== true) {
            reasons.push("dispatch_receipt_invalid");
        }
        if (!dispatch || dispatch.transitionId !== identifiers.transitionId ||
            dispatch.ownerId !== identifiers.ownerId) {
            reasons.push("dispatch_owner_identity_mismatch");
        }
        if (!dispatch || !dispatch.producer || dispatch.producer.buildId !== buildId) {
            reasons.push("dispatch_build_identity_mismatch");
        }
        if (!telemetry || telemetry.started !== true) {
            reasons.push("performance_telemetry_start_unproven");
        }
        if (!cpu || cpu.active !== true ||
            !Number.isSafeInteger(cpu.sessionId) || cpu.sessionId < 1) {
            reasons.push("cpu_session_identity_unproven");
        }
        return {
            status: reasons.length === 0 ? "MATCHED_ACTIVE" : "UNPROVEN",
            sessionId: cpu && Number.isSafeInteger(cpu.sessionId) ?
                cpu.sessionId : null,
            active: cpu && typeof cpu.active === "boolean" ? cpu.active : null,
            transitionId: dispatch && dispatch.transitionId || null,
            ownerId: dispatch && dispatch.ownerId || null,
            receiptKey,
            source: "qualification-dispatch",
            reasons,
        };
    }

    async function baseline(boundary, lane, laneIndex, pass, ownerState) {
        const target = targetFor(
            boundary, matrix.destinations[matrix.initialDestination], lane.configuredFsrRuntime);
        const identifiers = ids(laneIndex, pass, 0, true);
        const steps = qualificationSteps(boundary, target, identifiers, true, false);
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:baseline`;
        let response;
        try {
            response = await scenario(steps, receiptKey);
        } catch (scenarioFailure) {
            let waiter;
            try {
                waiter = await recoverTerminal(identifiers);
            } catch {
                throw diagnosticError("baseline_receipt_unavailable",
                    scenarioFailure && scenarioFailure.diagnostic || null);
            }
            if (!safeTerminal(waiter, identifiers) || !waiter.milestoneTimings ||
                !waiter.replacementTimeline) {
                throw diagnosticError("baseline_failed",
                    scenarioFailure && scenarioFailure.diagnostic || null);
            }
            const ownership = baselineOwnership(null, waiter);
            ownerState.baseline = { ...ownership, active: true, proven: false };
            throw diagnosticError("baseline_owner_identity_unproven", {
                phase: "ownership",
                receiptKey,
                scenario: scenarioFailure && scenarioFailure.diagnostic || null,
                ownership,
                handoffDecision: "REFUSED",
                cleanupDisposition: "PENDING_RECONCILIATION",
            });
        }
        const entries = resultMap(response.root);
        const start = entries.get("baseline-stress-start");
        const waiter = entries.get("qualification-wait");
        const ownership = baselineOwnership(start, waiter);
        ownerState.baseline = {
            ...ownership,
            active: ownership.startActive === true,
            proven: ownership.status === "MATCHED_ACTIVE",
        };
        if (!response.root.ok || !waiter || !safeTerminal(waiter, identifiers) ||
            !waiter.milestoneTimings ||
            !waiter.replacementTimeline || ownership.status !== "MATCHED_ACTIVE") {
            await closeOpenQualification(identifiers);
            const diagnostic = scenarioDiagnostic(response.root, steps, receiptKey,
                ownership.status === "MATCHED_ACTIVE" ? "response" : "ownership");
            diagnostic.ownership = ownership;
            diagnostic.handoffDecision = "REFUSED";
            diagnostic.cleanupDisposition = "PENDING_RECONCILIATION";
            throw diagnosticError(ownership.status === "MATCHED_ACTIVE" ?
                "baseline_failed" : "baseline_owner_identity_unproven", diagnostic);
        }
        return { boundary: terminalBoundary(waiter),
            stressSessionId: ownership.startSessionId, waiter, ownership,
            nonStableNote: nonStableNote(waiter) };
    }

    async function armOwners(baselineResult, lane, laneIndex, pass,
        resetPerformance, ownerState) {
        const stem = `${runId}-${variant}-${laneIndex}-${pass}`;
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:handoff`;
        const steps = [
            toolStep("baseline-stress-stop", "communityshaders.renderscale", {
                action: "stop", expectedSessionId: baselineResult.stressSessionId,
                expectedBuildId: buildId,
            }),
            toolStep("measured-stress-start", "communityshaders.renderscale", {
                action: "start", expectedBuildId: buildId,
            }),
            toolStep("texture-lifetime-reset", "communityshaders.renderscale", {
                action: "texture_lifetime_reset", expectedBuildId: buildId,
            }),
            toolStep("texture-lifetime-start", "communityshaders.renderscale", {
                action: "texture_lifetime_start", expectedBuildId: buildId,
            }),
            toolStep("load-presentation-reset", "communityshaders.renderscale", {
                action: "probe_reset", expectedBuildId: buildId,
            }),
            toolStep("load-presentation-start", "communityshaders.renderscale", {
                action: "probe_start", expectedBuildId: buildId,
            }),
        ];
        if (resetPerformance) {
            steps.push(toolStep("cpu-performance-reset", "communityshaders.renderscale", {
                action: "cpu_performance_reset", expectedBuildId: buildId,
            }));
            steps.push(toolStep("gpu-performance-reset", "communityshaders.renderscale", {
                action: "gpu_performance_reset", expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("profiler-enable", "communityshaders.profiler_api", {
            contractMajor: 1,
            clientId: `${stem}-profiler-client`,
            commandId: `${stem}-profiler-enable`,
            action: "set_enabled",
            enabled: true,
            expectedBuildId: buildId,
        }));
        const response = await scenario(steps, receiptKey);
        const entries = resultMap(response.root);
        const baselineStop = sessionSnapshot(entries.get("baseline-stress-stop"));
        const start = entries.get("measured-stress-start");
        const measured = sessionSnapshot(start);
        if (baselineStop.present && baselineStop.active === false &&
            baselineStop.id === baselineResult.stressSessionId) {
            ownerState.baseline.active = false;
        }
        if (measured.present && measured.active === true &&
            Number.isSafeInteger(measured.id) && measured.id > 0) {
            ownerState.measured = { sessionId: measured.id, active: true,
                proven: true, source: "measured-stress-start" };
        }
        const ownership = {
            status: "uncertain",
            baselineSessionId: baselineResult.stressSessionId,
            baselineStopSessionId: baselineStop.id,
            baselineStopActive: baselineStop.active,
            measuredSessionId: measured.id,
            measuredActive: measured.active,
            cleanupAttempted: false,
        };
        let scenarioError = null;
        try {
            requireScenario(response.root, steps, receiptKey);
        } catch (error) {
            scenarioError = error;
        }
        if (scenarioError || baselineStop.active !== false ||
            baselineStop.id !== baselineResult.stressSessionId ||
            !ownerState.measured) {
            const diagnostic = scenarioDiagnostic(
                response.root, steps, receiptKey, "ownership");
            diagnostic.ownership = ownership;
            diagnostic.ownership.reason = !ownerState.measured ?
                "measured_stress_session_identity_missing" :
                baselineStop.id !== baselineResult.stressSessionId ?
                    "baseline_stop_owner_mismatch" :
                    baselineStop.active !== false ?
                        "baseline_stop_not_confirmed" :
                        "handoff_step_failed_after_measured_start";
            throw diagnosticError(!ownerState.measured ?
                "measured_stress_session_identity_missing" :
                scenarioError ? "measured_owner_handoff_failed" :
                    "baseline_owner_stop_unconfirmed", diagnostic);
        }
        ownerState.measured.source = "measured-stress-start";
        return ownerState.measured.sessionId;
    }

    function traceSession(value) {
        const capture = value && value.capture;
        const summary = capture && (capture.summary || capture);
        return {
            present: Boolean(summary && typeof summary === "object"),
            id: summary && Number.isSafeInteger(summary.sessionID) ?
                summary.sessionID : null,
            active: summary && typeof summary.active === "boolean" ?
                summary.active : null,
        };
    }

    function updateTraceOwnership(entries, ownerState) {
        const started = traceSession(entries.get("dlss-trace-start"));
        if (started.present && Number.isSafeInteger(started.id) && started.id >= 1 &&
            started.active === true) {
            ownerState.trace = {
                proven: true,
                sessionId: started.id,
                active: true,
                source: "dlss-trace-start",
            };
        }
        const stopped = traceSession(entries.get("dlss-trace-stop"));
        if (stopped.present && ownerState.trace && ownerState.trace.proven &&
            stopped.id === ownerState.trace.sessionId && stopped.active === false) {
            ownerState.trace.active = false;
            ownerState.trace.stopSource = "dlss-trace-stop";
        }
    }

    function traceRecordSequence(record) {
        const value = record && (record.sequence ??
            (record.current && record.current.sequence));
        return Number.isSafeInteger(value) && value > 0 ? value : null;
    }

    function requireOwnedTraceState(result, action, sessionId, active) {
        const state = traceSession(result);
        if (!result || result.action !== action || result.ok === false ||
            result.isError === true || !result.producer ||
            result.producer.buildId !== buildId || !state.present ||
            state.id !== sessionId || state.active !== active) {
            throw diagnosticError("trace_owner_state_unproven", {
                action, expectedSessionId: sessionId, expectedActive: active,
                observed: state,
                reportedError: reportedError(result),
            });
        }
        return state;
    }

    async function closeOwnedTraceWindow(retainedKey, ownerState) {
        const owner = ownerState.trace;
        if (!owner || owner.proven !== true || owner.active !== true ||
            !Number.isSafeInteger(owner.sessionId) || owner.sessionId < 1) {
            throw diagnosticError("trace_owner_identity_missing", {
                owner: owner || null,
            });
        }
        const stopResult = await renderScale({
            action: "dlss_trace_stop",
            expectedSessionId: owner.sessionId,
            expectedBuildId: buildId,
        });
        retain(`${retainedKey}:trace-stop`, stopResult.envelope);
        requireOwnedTraceState(stopResult.root, "dlss_trace_stop",
            owner.sessionId, false);
        owner.active = false;
        owner.stopSource = "dlss-trace-stop";

        const pages = [];
        let afterSequence = 0;
        let latestSequence = null;
        for (let pageNumber = 1; pageNumber <= 4096; pageNumber += 1) {
            const readResult = await renderScale({
                action: "dlss_trace_read",
                afterSequence,
                limit: matrix.traceReadLimit,
                expectedBuildId: buildId,
            });
            retain(`${retainedKey}:trace-page-${pageNumber}`,
                readResult.envelope);
            const page = readResult.root;
            const capture = page && page.capture;
            const summary = capture && capture.summary;
            if (!page || page.action !== "dlss_trace_read" ||
                page.ok === false || page.isError === true ||
                !page.producer || page.producer.buildId !== buildId ||
                !capture || !Array.isArray(capture.records) ||
                !summary || summary.sessionID !== owner.sessionId ||
                summary.active !== false ||
                capture.afterSequence !== afterSequence ||
                !Number.isSafeInteger(capture.limit) || capture.limit < 1 ||
                capture.limit > matrix.traceReadLimit ||
                capture.records.length > capture.limit ||
                typeof capture.moreAvailable !== "boolean" ||
                !Number.isSafeInteger(capture.latestSequence) ||
                capture.latestSequence < 0 ||
                capture.requestedSequenceOverwritten !== false) {
                throw diagnosticError("trace_page_invalid", {
                    reason: "trace_page_invalid",
                    pageNumber, expectedSessionId: owner.sessionId,
                    afterSequence,
                });
            }
            if (latestSequence !== null &&
                capture.latestSequence !== latestSequence) {
                throw diagnosticError("trace_closed_window_changed", {
                    reason: "trace_closed_window_changed",
                    pageNumber, expectedLatestSequence: latestSequence,
                    observedLatestSequence: capture.latestSequence,
                });
            }
            latestSequence = capture.latestSequence;
            let expectedSequence = afterSequence + 1;
            for (const record of capture.records) {
                if (traceRecordSequence(record) !== expectedSequence) {
                    throw diagnosticError("trace_page_sequence_invalid", {
                        pageNumber, expectedSequence,
                    });
                }
                expectedSequence += 1;
            }
            const lastSequence = capture.records.length > 0 ?
                expectedSequence - 1 : afterSequence;
            if (capture.lastReturnedSequence !== lastSequence ||
                (capture.moreAvailable === true &&
                    (capture.records.length === 0 ||
                        capture.latestSequence <= lastSequence)) ||
                (capture.moreAvailable === false &&
                    capture.latestSequence !== lastSequence)) {
                throw diagnosticError("trace_page_terminal_invalid", {
                    pageNumber, lastSequence,
                });
            }
            pages.push(page);
            afterSequence = lastSequence;
            if (capture.moreAvailable === false) {
                if (!Number.isSafeInteger(summary.totalRecords) ||
                    summary.totalRecords !== afterSequence) {
                    throw diagnosticError("trace_total_records_mismatch", {
                        pageNumber, totalRecords: summary.totalRecords,
                        retainedRecords: afterSequence,
                    });
                }
                return { traceStop: stopResult.root,
                    traceRead: pages[0], tracePages: pages };
            }
        }
        throw diagnosticError("trace_page_count_exceeded", {
            expectedSessionId: owner.sessionId,
        });
    }

    async function transition(boundary, lane, laneIndex, pass, row, ownerState) {
        const destination = matrix.destinations[row.destination];
        const target = targetFor(boundary, destination, lane.configuredFsrRuntime);
        const identifiers = ids(laneIndex, pass, row.ordinal, false);
        const steps = qualificationSteps(
            boundary, target, identifiers, false, row.ordinal === 1);
        const receiptKey =
            `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}:scenario`;
        let response;
        let waiter;
        let projection;
        let diagnostic;
        let entries = new Map();
        let cpuOwnership = row.ordinal === 1 ? {
            status: "UNPROVEN",
            sessionId: null,
            active: null,
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            receiptKey,
            source: "qualification-dispatch",
            reasons: ["dispatch_receipt_unavailable"],
        } : null;
        const retainedKey =
            `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`;
        let retained;
        try {
            response = await scenario(steps, receiptKey);
        } catch (scenarioFailure) {
            try {
                waiter = await recoverTerminal(identifiers);
            } catch {
                retain(retainedKey, {
                    variant,
                    scenarioReceiptKey: receiptKey,
                    scenario: scenarioFailure && scenarioFailure.diagnostic || null,
                    waiter: null,
                    projection: null,
                    cpuOwnership,
                });
                throw diagnosticError("transition_receipt_unavailable",
                    scenarioFailure && scenarioFailure.diagnostic || null);
            }
            projection = transitionProjection(waiter, target);
            diagnostic = scenarioFailure && scenarioFailure.diagnostic || null;
            retained = {
                variant,
                scenarioReceiptKey: receiptKey,
                scenario: diagnostic,
                sourceRecoveryReceiptKey: boundary.recoveryReceiptKey || null,
                recoveredTerminal: true,
                waiter,
                projection,
                replacementTimeline: waiter.replacementTimeline || null,
                presentationCycleAudit: waiter.presentationCycleAudit || null,
                cpuOwnership,
            };
        }
        if (response) {
            entries = resultMap(response.root);
            updateTraceOwnership(entries, ownerState);
            if (row.ordinal === 1) {
                cpuOwnership = cpuDispatchOwnership(entries.get(
                    "qualification-dispatch"), identifiers, receiptKey);
                if (cpuOwnership.status === "MATCHED_ACTIVE") {
                    ownerState.cpu = {
                        proven: true,
                        sessionId: cpuOwnership.sessionId,
                        active: true,
                        transitionId: cpuOwnership.transitionId,
                        ownerId: cpuOwnership.ownerId,
                        receiptKey: cpuOwnership.receiptKey,
                        source: cpuOwnership.source,
                    };
                }
            }
            waiter = entries.get("qualification-wait");
            projection = waiter ? transitionProjection(waiter, target) : null;
            diagnostic = scenarioDiagnostic(response.root, steps, receiptKey);
            let traceEvidence = null;
            if (variant === "nvidia" && target.method === "dlss" &&
                ownerState.trace && ownerState.trace.active === true && waiter) {
                try {
                    traceEvidence = await closeOwnedTraceWindow(
                        retainedKey, ownerState);
                } catch (error) {
                    retain(retainedKey, {
                        variant,
                        scenarioReceiptKey: receiptKey,
                        scenario: diagnostic,
                        apply: entries.get("profile-apply"),
                        waiter,
                        projection,
                        traceReset: entries.get("dlss-trace-reset") || null,
                        traceStart: entries.get("dlss-trace-start") || null,
                        cpuAcquisition: row.ordinal === 1 ?
                            entries.get("qualification-dispatch") || null : null,
                        traceCollectionFailure: error && error.diagnostic || {
                            reason: error.message || String(error),
                        },
                    });
                    throw error;
                }
            }
            retained = {
                variant,
                scenarioReceiptKey: receiptKey,
                scenario: diagnostic,
                sourceRecoveryReceiptKey: boundary.recoveryReceiptKey || null,
                apply: entries.get("profile-apply"),
                waiter,
                projection,
                operation: waiter && waiter.upscalingSnapshot ? {
                    activeOperationId: waiter.upscalingSnapshot.activeOperationId,
                    stateRevision: waiter.upscalingSnapshot.stateRevision,
                } : null,
                preparation: waiter && waiter.observation ?
                    waiter.observation.preparationTelemetry || null : null,
                replacementTimeline: waiter ? waiter.replacementTimeline || null : null,
                presentationCycleAudit: waiter ? waiter.presentationCycleAudit || null : null,
                traceReset: entries.get("dlss-trace-reset") || null,
                traceStart: entries.get("dlss-trace-start") || null,
                traceStop: traceEvidence && traceEvidence.traceStop ||
                    entries.get("dlss-trace-stop") || null,
                traceRead: traceEvidence && traceEvidence.traceRead ||
                    entries.get("dlss-trace-read") || null,
                tracePages: traceEvidence && traceEvidence.tracePages || null,
                cpuAcquisition: row.ordinal === 1 ?
                    entries.get("qualification-dispatch") || null : null,
                cpuOwnership,
            };
            retain(retainedKey, retained);
            if (!waiter || (response.root.ok !== true &&
                diagnostic.failedStep !== "qualification-wait")) {
                await closeOpenQualification(identifiers);
                throw diagnosticError("transition_scenario_failed", diagnostic);
            }
        }
        retain(retainedKey, retained);
        if (cpuOwnership && cpuOwnership.status !== "MATCHED_ACTIVE") {
            throw diagnosticError("cpu_owner_identity_unproven", cpuOwnership);
        }
        let recovery = null;
        let nextBoundary;
        if (safeTerminal(waiter, identifiers)) {
            nextBoundary = terminalBoundary(waiter);
        } else {
            if (!recoverableTerminal(waiter, identifiers)) {
                throw new Error("transition_unsafe");
            }
            try {
                const restored = await restoreBaseline(
                    boundary, lane, laneIndex, pass, row,
                    variant === "nvidia" && target.method === "dlss" &&
                        !retained.traceStop && ownerState.trace &&
                        ownerState.trace.proven ? ownerState.trace.sessionId : null);
                recovery = restored.summary;
                retained.recovery = recovery;
                retained.recoveryReceiptKey = restored.receiptKey;
                if (restored.evidence.traceStop) {
                    retained.traceStop = restored.evidence.traceStop;
                    retained.traceRead = restored.evidence.traceRead;
                    updateTraceOwnership(new Map([
                        ["dlss-trace-stop", restored.evidence.traceStop],
                    ]), ownerState);
                }
                retain(retainedKey, retained);
                nextBoundary = restored.boundary;
            } catch (error) {
                const recoveryReceiptKey =
                    `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}:recovery`;
                retained.recovery = {
                    status: "FAILED",
                    error: error instanceof Error ? error.message : String(error),
                    receiptKey: recoveryReceiptKey,
                    scenario: error && typeof error === "object" ?
                        error.diagnostic || null : null,
                };
                retained.recoveryReceiptKey = recoveryReceiptKey;
                retain(retainedKey, retained);
                throw error;
            }
        }
        notify({
            lane: lane.id,
            pass,
            ordinal: row.ordinal,
            target,
            ...projection,
            outcome: waiter.outcome,
            elapsedMs: waiter.timing ? waiter.timing.elapsedMs : null,
            recovery,
            sourceRecoveryReceiptKey: retained.sourceRecoveryReceiptKey,
        });
        return { boundary: nextBoundary, waiter, projection, recovery,
            sourceRecoveryReceiptKey: retained.sourceRecoveryReceiptKey };
    }

    async function closeTraceAfterCapabilityFailure(receiptKey, startReceipt) {
        const started = traceSession(startReceipt);
        const evidence = {
            status: "PENDING",
            started,
            before: null,
            stop: null,
            after: null,
        };
        try {
            const beforeResult = await renderScale({
                action: "dlss_trace_status", expectedBuildId: buildId,
            });
            retain(`${receiptKey}:status-before`, beforeResult.envelope);
            evidence.before = traceSession(beforeResult.root);
            if (!evidence.before.present || evidence.before.active === null) {
                throw new Error("trace_cleanup_status_missing");
            }
            const startedIdentityValid = Boolean(startReceipt &&
                startReceipt.action === "dlss_trace_start" &&
                startReceipt.producer && startReceipt.producer.buildId === buildId &&
                started.present && started.active === true &&
                Number.isSafeInteger(started.id) && started.id >= 1);
            if (startReceipt && !startedIdentityValid) {
                throw new Error("trace_cleanup_owner_unproven");
            }
            if (evidence.before.active === true) {
                if (!startedIdentityValid || evidence.before.id !== started.id) {
                    throw new Error("trace_cleanup_owner_mismatch");
                }
                const stopResult = await renderScale({
                    action: "dlss_trace_stop",
                    expectedSessionId: started.id,
                    expectedBuildId: buildId,
                });
                retain(`${receiptKey}:stop`, stopResult.envelope);
                evidence.stop = traceSession(stopResult.root);
            }
            const afterResult = await renderScale({
                action: "dlss_trace_status", expectedBuildId: buildId,
            });
            retain(`${receiptKey}:status-after`, afterResult.envelope);
            evidence.after = traceSession(afterResult.root);
            if (!evidence.after.present || evidence.after.active !== false ||
                (startedIdentityValid && evidence.after.id !== started.id)) {
                throw new Error("trace_cleanup_postcondition_active");
            }
            evidence.status = "CONFIRMED_INACTIVE";
            retain(`${receiptKey}:decision`, evidence);
            return evidence;
        } catch (error) {
            evidence.status = "UNRESOLVED";
            evidence.reason = error.message || String(error);
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError(evidence.reason, evidence);
        }
    }

    async function retainAmdTraceCapability() {
        const receiptKey = `${runId}:amd:dlss-trace-capability`;
        const steps = [
            toolStep("amd-dlss-trace-status", "communityshaders.renderscale", {
                action: "dlss_trace_status", expectedBuildId: buildId,
            }),
            toolStep("amd-dlss-trace-reset", "communityshaders.renderscale", {
                action: "dlss_trace_reset", expectedBuildId: buildId,
            }),
            toolStep("amd-dlss-trace-start", "communityshaders.renderscale", {
                action: "dlss_trace_start", expectedBuildId: buildId,
            }),
        ];
        const unavailableTraceAction = (error) => {
            const diagnostic = error && error.diagnostic;
            const traceStep = diagnostic && [
                diagnostic.failedStep,
                diagnostic.firstUnreportedStep,
            ].some((label) => typeof label === "string" &&
                label.startsWith("amd-dlss-trace-"));
            const reported = diagnostic && [
                diagnostic.reportedError,
                ...(diagnostic.reportedSteps || []).map((step) => step.error),
            ].filter((value) => typeof value === "string").join(" ") ||
                (error && error.message || String(error || ""));
            const unavailable =
                /(?:unsupported|unknown|unrecognized|not[ _-](?:available|exposed|implemented)|missing)[\s\S]*(?:action|operation)|(?:action|operation)[\s\S]*(?:unsupported|unknown|unrecognized|not[ _-](?:available|exposed|implemented)|missing)/i
                    .test(reported || "");
            return (traceStep || !diagnostic) && unavailable ?
                diagnostic || { reportedError: reported } : null;
        };
        let response;
        try {
            response = await scenario(steps, receiptKey);
        } catch (error) {
            const diagnostic = unavailableTraceAction(error);
            if (diagnostic) {
                return { status: "unsupported", receiptKey, diagnostic };
            }
            let cleanup;
            try {
                cleanup = await closeTraceAfterCapabilityFailure(
                    `${receiptKey}:cleanup`, null);
            } catch (cleanupError) {
                throw diagnosticError("amd_trace_capability_cleanup_unresolved", {
                    original: error && error.diagnostic || error.message || String(error),
                    cleanup: cleanupError && cleanupError.diagnostic ||
                        cleanupError.message || String(cleanupError),
                });
            }
            throw diagnosticError(error.message, {
                original: error.diagnostic || null, traceCleanup: cleanup,
            });
        }
        let entries;
        try {
            entries = requireScenario(response.root, steps, receiptKey);
        } catch (error) {
            const diagnostic = unavailableTraceAction(error);
            const startReceipt = resultMap(response.root)
                .get("amd-dlss-trace-start");
            const started = traceSession(startReceipt);
            if (diagnostic && !(started.present &&
                Number.isSafeInteger(started.id) && started.id >= 1 &&
                started.active === true)) {
                return { status: "unsupported", receiptKey, diagnostic };
            }
            let cleanup;
            try {
                cleanup = await closeTraceAfterCapabilityFailure(
                    `${receiptKey}:cleanup`, startReceipt);
            } catch (cleanupError) {
                throw diagnosticError("amd_trace_capability_cleanup_unresolved", {
                    original: error && error.diagnostic || error.message || String(error),
                    cleanup: cleanupError && cleanupError.diagnostic ||
                        cleanupError.message || String(cleanupError),
                });
            }
            throw diagnosticError(error.message, {
                original: error.diagnostic || null, traceCleanup: cleanup,
            });
        }
        const startReceipt = entries.get("amd-dlss-trace-start");
        const started = traceSession(startReceipt);
        if (!startReceipt || startReceipt.action !== "dlss_trace_start" ||
            !startReceipt.producer || startReceipt.producer.buildId !== buildId ||
            !started.present || !Number.isSafeInteger(started.id) || started.id < 1 ||
            started.active !== true) {
            try {
                await closeTraceAfterCapabilityFailure(
                    `${receiptKey}:cleanup`, startReceipt);
            } catch (cleanupError) {
                throw diagnosticError("amd_trace_capability_cleanup_unresolved", {
                    original: { reason: "amd_trace_capability_owner_unproven",
                        started },
                    cleanup: cleanupError && cleanupError.diagnostic ||
                        cleanupError.message || String(cleanupError),
                });
            }
            throw diagnosticError("amd_trace_capability_owner_unproven", { started });
        }
        const ownerState = { trace: { proven: true, sessionId: started.id,
            active: true, source: "amd-dlss-trace-start" } };
        let traceEvidence;
        try {
            traceEvidence = await closeOwnedTraceWindow(receiptKey, ownerState);
        } catch (error) {
            let cleanup;
            try {
                cleanup = await closeTraceAfterCapabilityFailure(
                    `${receiptKey}:cleanup`, startReceipt);
            } catch (cleanupError) {
                throw diagnosticError("amd_trace_capability_cleanup_unresolved", {
                    original: error && error.diagnostic ||
                        error.message || String(error),
                    cleanup: cleanupError && cleanupError.diagnostic ||
                        cleanupError.message || String(cleanupError),
                });
            }
            throw diagnosticError(error.message, {
                original: error.diagnostic || null, traceCleanup: cleanup,
            });
        }
        const read = traceEvidence.tracePages[traceEvidence.tracePages.length - 1];
        const capture = read && read.capture;
        const summary = capture && capture.summary;
        const records = traceEvidence.tracePages.flatMap((page) =>
            page.capture.records);
        if (!capture || !summary || records.length !== 0 ||
            summary.totalRecords !== 0 ||
            summary.setConstantsCalls !== 0 || summary.evaluateCalls !== 0) {
            throw new Error("amd_dlss_trace_not_empty");
        }
        const lifecycle = {
            traceReset: entries.get("amd-dlss-trace-reset"),
            traceStart: startReceipt,
            traceStop: traceEvidence.traceStop,
            traceRead: traceEvidence.traceRead,
            tracePages: traceEvidence.tracePages,
        };
        retain(receiptKey, lifecycle);
        return { status: "supported", receiptKey, lifecycle };
    }

    async function status(lane, pass, suffix, includeTrace = false) {
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:${suffix}`;
        const steps = [
            toolStep("render-status", "communityshaders.renderscale", {
                action: "status", expectedBuildId: buildId,
            }),
            toolStep("cpu-status", "communityshaders.renderscale", {
                action: "cpu_performance_status", expectedBuildId: buildId,
            }),
            toolStep("gpu-status", "communityshaders.renderscale", {
                action: "gpu_performance_status", expectedBuildId: buildId,
            }),
            toolStep("texture-status", "communityshaders.renderscale", {
                action: "texture_lifetime_status", expectedBuildId: buildId,
            }),
        ];
        if (variant === "nvidia" && includeTrace) {
            steps.push(toolStep("dlss-trace-status",
                "communityshaders.renderscale", {
                    action: "dlss_trace_status", expectedBuildId: buildId,
                }));
        }
        const response = await scenario(steps, receiptKey);
        const entries = requireScenario(response.root, steps, receiptKey);
        return entries;
    }

    function cleanupState(entries) {
        const renderResult = entries && entries.get("render-status");
        const render = renderResult && renderResult.status;
        const session = render && render.session;
        const cpuResult = entries && entries.get("cpu-status");
        const gpuResult = entries && entries.get("gpu-status");
        const textureResult = entries && entries.get("texture-status");
        const traceResult = entries && entries.get("dlss-trace-status");
        const cpu = cpuResult && cpuResult.cpuPerformance;
        const gpu = gpuResult && gpuResult.capture;
        const texture = textureResult && textureResult.capture;
        const probe = render && render.loadPresentationProbe;
        const trace = variant === "nvidia" ? traceSession(traceResult) :
            { present: true, id: null, active: false };
        const missing = [];
        if (!session || typeof session.active !== "boolean" ||
            !Object.hasOwn(session, "id")) missing.push("render_session_status_missing");
        if (!cpu || typeof cpu.active !== "boolean") {
            missing.push("cpu_status_missing");
        } else if (cpu.active === true &&
            (!Number.isSafeInteger(cpu.sessionId) || cpu.sessionId < 1)) {
            missing.push("cpu_session_status_missing");
        }
        if (!gpu || typeof gpu.active !== "boolean") {
            missing.push("gpu_status_missing");
        }
        if (!texture || typeof texture.active !== "boolean") {
            missing.push("texture_status_missing");
        }
        if (!probe || typeof probe.active !== "boolean") {
            missing.push("probe_status_missing");
        }
        if (variant === "nvidia" && (!trace.present ||
            typeof trace.active !== "boolean" ||
            (trace.active === true &&
                (!Number.isSafeInteger(trace.id) || trace.id < 1)))) {
            missing.push("trace_status_missing");
        }
        return { render, session, cpu, gpu, texture, probe, trace, missing };
    }

    async function cleanup(lane, pass, ownerState) {
        const before = await status(
            lane, pass, "final-status-before-cleanup", true);
        const observed = cleanupState(before);
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:cleanup`;
        const knownSessionIds = unique([
            ownerState.baseline && ownerState.baseline.proven ?
                ownerState.baseline.startSessionId : null,
            ownerState.measured && ownerState.measured.proven ?
                ownerState.measured.sessionId : null,
        ]);
        const knownTraceSessionIds = unique([
            ownerState.trace && ownerState.trace.proven ?
                ownerState.trace.sessionId : null,
        ]);
        const knownCpuSessionIds = unique([
            ownerState.cpu && ownerState.cpu.proven ?
                ownerState.cpu.sessionId : null,
        ]);
        const evidence = {
            status: "PENDING",
            cleanupAttempted: false,
            knownSessionIds,
            knownTraceSessionIds,
            knownCpuSessionIds,
            before: {
                stressSessionId: observed.session ? observed.session.id : null,
                stressActive: observed.session ? observed.session.active : null,
                cpuActive: observed.cpu ? observed.cpu.active : null,
                cpuSessionId: observed.cpu ? observed.cpu.sessionId : null,
                gpuActive: observed.gpu ? observed.gpu.active : null,
                textureActive: observed.texture ? observed.texture.active : null,
                probeActive: observed.probe ? observed.probe.active : null,
                traceSessionId: observed.trace ? observed.trace.id : null,
                traceActive: observed.trace ? observed.trace.active : null,
                missing: observed.missing,
            },
        };
        if (observed.missing.length > 0) {
            evidence.status = "UNRESOLVED";
            evidence.reason = "cleanup_status_incomplete";
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError("cleanup_status_incomplete", evidence);
        }
        if (observed.session.active === true &&
            !knownSessionIds.includes(observed.session.id)) {
            evidence.status = "UNRESOLVED";
            evidence.reason = "cleanup_stress_owner_mismatch";
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError("cleanup_stress_owner_mismatch", evidence);
        }
        if (observed.trace.active === true &&
            !knownTraceSessionIds.includes(observed.trace.id)) {
            evidence.status = "UNRESOLVED";
            evidence.reason = "cleanup_trace_owner_mismatch";
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError("cleanup_trace_owner_mismatch", evidence);
        }
        if ((observed.cpu.active === true &&
            !knownCpuSessionIds.includes(observed.cpu.sessionId)) ||
            (knownCpuSessionIds.length > 0 &&
                observed.cpu.sessionId !== knownCpuSessionIds[0])) {
            evidence.status = "UNRESOLVED";
            evidence.reason = "cleanup_cpu_owner_mismatch";
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError("cleanup_cpu_owner_mismatch", evidence);
        }
        const steps = [];
        if (observed.session.active) {
            steps.push(toolStep("measured-stress-stop", "communityshaders.renderscale", {
                action: "stop", expectedSessionId: observed.session.id,
                expectedBuildId: buildId,
            }));
        }
        if (observed.cpu.active) {
            const args = { action: "cpu_performance_stop",
                expectedSessionId: knownCpuSessionIds[0], expectedBuildId: buildId };
            steps.push(toolStep("cpu-performance-stop", "communityshaders.renderscale", args));
        }
        if (observed.gpu.active) {
            steps.push(toolStep("gpu-performance-stop", "communityshaders.renderscale", {
                action: "gpu_performance_stop", expectedBuildId: buildId,
            }));
        }
        if (observed.texture.active) {
            steps.push(toolStep("texture-lifetime-stop", "communityshaders.renderscale", {
                action: "texture_lifetime_stop", expectedBuildId: buildId,
            }));
        }
        if (observed.probe.active) {
            steps.push(toolStep("load-presentation-stop", "communityshaders.renderscale", {
                action: "probe_stop", expectedBuildId: buildId,
            }));
        }
        if (observed.trace.active) {
            steps.push(toolStep("dlss-trace-stop", "communityshaders.renderscale", {
                action: "dlss_trace_stop",
                expectedSessionId: observed.trace.id,
                expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("profiler-disable", "communityshaders.profiler_api", {
            contractMajor: 1,
            clientId: `${runId}-${lane.id}-${pass}-cleanup-client`,
            commandId: `${runId}-${lane.id}-${pass}-cleanup-disable`,
            action: "set_enabled",
            enabled: false,
            expectedBuildId: buildId,
        }));
        evidence.cleanupAttempted = true;
        const response = await scenario(steps, receiptKey);
        requireScenario(response.root, steps, receiptKey);
        const after = cleanupState(await status(
            lane, pass, "final-status-after-cleanup", true));
        evidence.after = {
            stressSessionId: after.session ? after.session.id : null,
            stressActive: after.session ? after.session.active : null,
            cpuActive: after.cpu ? after.cpu.active : null,
            cpuSessionId: after.cpu ? after.cpu.sessionId : null,
            gpuActive: after.gpu ? after.gpu.active : null,
            textureActive: after.texture ? after.texture.active : null,
            probeActive: after.probe ? after.probe.active : null,
            traceSessionId: after.trace ? after.trace.id : null,
            traceActive: after.trace ? after.trace.active : null,
            missing: after.missing,
        };
        const expectedStressSessionId = ownerState.measured &&
            ownerState.measured.proven ? ownerState.measured.sessionId : null;
        const expectedCpuSessionId = ownerState.cpu && ownerState.cpu.proven ?
            ownerState.cpu.sessionId : null;
        const expectedTraceSessionId = ownerState.trace && ownerState.trace.proven ?
            ownerState.trace.sessionId : null;
        const postOwnerMismatch = (expectedStressSessionId !== null &&
            after.session.id !== expectedStressSessionId) ||
            (expectedCpuSessionId !== null &&
                after.cpu.sessionId !== expectedCpuSessionId) ||
            (expectedTraceSessionId !== null &&
                after.trace.id !== expectedTraceSessionId);
        const stillActive = after.missing.length > 0 || postOwnerMismatch ||
            after.session.active !== false || after.cpu.active !== false ||
            after.gpu.active !== false || after.texture.active !== false ||
            after.probe.active !== false || after.trace.active !== false;
        if (stillActive) {
            evidence.status = "UNRESOLVED";
            evidence.reason = after.missing.length > 0 ?
                "cleanup_post_status_incomplete" : postOwnerMismatch ?
                    "cleanup_post_owner_mismatch" : "cleanup_postcondition_active";
            retain(`${receiptKey}:decision`, evidence);
            throw diagnosticError(evidence.reason, evidence);
        }
        if (ownerState.baseline) ownerState.baseline.active = false;
        if (ownerState.measured) ownerState.measured.active = false;
        if (ownerState.trace) ownerState.trace.active = false;
        if (ownerState.cpu) ownerState.cpu.active = false;
        evidence.status = "CONFIRMED_INACTIVE";
        evidence.reason = null;
        retain(`${receiptKey}:decision`, evidence);
        return evidence;
    }

    async function cooldown(lane, pass) {
        await status(lane, pass, "cooldown-start");
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:cooldown`;
        const steps = [{ label: "memory-cooldown", wait: 10000 }];
        const response = await scenario(steps, receiptKey);
        requireScenario(response.root, steps, receiptKey);
        await status(lane, pass, "cooldown-end");
    }

    function lanes() {
        if (variant === "nvidia") {
            return [{
                id: "nvidia",
                configuredFsrRuntime: matrix.initialDormantFsrRuntime,
                runnable: true,
            }];
        }
        const supported = capabilities.supportedFSRRuntimeMask;
        const unavailable = capabilities.fsrRuntimeUnavailableConditions;
        const validUnavailable = Array.isArray(unavailable) &&
            unavailable.length === 2 && unavailable.every((entry) =>
                entry && typeof entry === "object" &&
                Number.isSafeInteger(entry.mask) && entry.mask >= 0);
        if (!Number.isSafeInteger(supported) || supported < 0 || supported > 3 ||
            !validUnavailable) {
            throw diagnosticError("amd_capabilities_invalid", {
                reason: "fsr_runtime_capability_shape_invalid",
                supportedFSRRuntimeMask: supported ?? null,
                unavailableConditionCount: Array.isArray(unavailable) ?
                    unavailable.length : null,
            });
        }
        const fsr3 = (supported & 1) !== 0 &&
            unavailable[0].mask === 0;
        const fsr4 = (supported & 2) !== 0;
        const fsr4Unavailable = unavailable[1].mask !== 0;
        return matrix.lanes.map((lane) => ({
            ...lane,
            runnable: lane.id === "explicit_fsr4" ? fsr4 && unavailable[1].mask === 0 :
                lane.id === "explicit_fsr3" ? fsr3 : fsr3 && fsr4Unavailable,
            fallbackQualification: {
                required: lane.requiresDocumentedFsr4UnavailableCondition === true,
                satisfied: lane.requiresDocumentedFsr4UnavailableCondition !== true ||
                    (fsr3 && fsr4Unavailable),
                unavailableCondition: lane.requiresDocumentedFsr4UnavailableCondition === true ?
                    unavailable[1] : null,
            },
        }));
    }

    function executionPlan(selectedLanes) {
        const entries = [];
        for (let laneIndex = 0; laneIndex < selectedLanes.length; laneIndex += 1) {
            const lane = selectedLanes[laneIndex];
            if (!lane.runnable) continue;
            for (let pass = 1; pass <= 2; pass += 1) {
                for (const row of matrix.transitions) {
                    const destination = matrix.destinations[row.destination];
                    const target = targetFor(positioning.boundary, destination,
                        lane.configuredFsrRuntime);
                    const identifiers = ids(laneIndex + 1, pass, row.ordinal, false);
                    entries.push({
                        lane: variant === "nvidia" ? null : lane.id,
                        pass,
                        ordinal: row.ordinal,
                        destination: row.destination,
                        transitionId: identifiers.transitionId,
                        ownerId: identifiers.ownerId,
                        target: waiterTarget(target),
                        laneContract: {
                            id: lane.id,
                            configuredFsrRuntime: lane.configuredFsrRuntime,
                            expectedBackends: destination.expectedBackends ||
                                lane.expectedBackends || [],
                            requiresDocumentedFsr4UnavailableCondition:
                                lane.requiresDocumentedFsr4UnavailableCondition === true,
                            fallbackQualification: lane.fallbackQualification || {
                                required: false, satisfied: true,
                                unavailableCondition: null,
                            },
                        },
                    });
                }
            }
        }
        return {
            schemaVersion: "renderscale-tuning-execution-plan-v1",
            variant,
            runId,
            buildId,
            entries,
        };
    }

    let boundary = positioning.boundary;
    const summary = { ok: true, status: "COMPLETE", variant, runId,
        traceCapability: variant === "amd" ? null : { status: "not_applicable" },
        lanes: [] };
    let passSequence = 0;
    const selectedLanes = lanes();
    retain(`${runId}:execution-plan`, executionPlan(selectedLanes));
    if (variant === "amd" && selectedLanes.some((lane) => lane.runnable)) {
        try {
            summary.traceCapability = await retainAmdTraceCapability();
        } catch (error) {
            summary.ok = false;
            summary.status = "INTERRUPTED";
            summary.error = error instanceof Error ? error.message : String(error);
            summary.failure = error && typeof error === "object" &&
                error.diagnostic ? error.diagnostic : null;
            retainLiveResult(summary);
            return summary;
        }
    }
    for (let laneIndex = 0; laneIndex < selectedLanes.length; laneIndex += 1) {
        const lane = selectedLanes[laneIndex];
        const laneSummary = { id: lane.id, status: lane.runnable ? "COMPLETE" : "BLOCKED", passes: [] };
        summary.lanes.push(laneSummary);
        if (!lane.runnable) continue;
        for (let pass = 1; pass <= 2; pass += 1) {
            passSequence += 1;
            const ownerState = { baseline: null, measured: null, cpu: null };
            let cleanupAttempted = false;
            const passSummary = { pass, status: "RUNNING", rows: [] };
            laneSummary.passes.push(passSummary);
            try {
                const base = await baseline(
                    boundary, lane, laneIndex + 1, pass, ownerState);
                boundary = base.boundary;
                passSummary.baseline = {
                    satisfied: base.waiter.satisfied === true,
                    outcome: base.waiter.outcome || null,
                    nonStableNote: base.nonStableNote,
                    ownership: base.ownership,
                };
                if (base.nonStableNote) {
                    notify({ lane: lane.id, pass, phase: "baseline",
                        ...base.nonStableNote });
                }
                await armOwners(base, lane, laneIndex + 1, pass,
                    passSequence > 1, ownerState);
                for (const row of matrix.transitions) {
                    const completed = await transition(
                        boundary, lane, laneIndex + 1, pass, row, ownerState);
                    boundary = completed.boundary;
                    passSummary.rows.push({
                        ordinal: row.ordinal,
                        receiptKey: `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`,
                        ...completed.projection,
                        recovery: completed.recovery,
                        sourceRecoveryReceiptKey:
                            completed.sourceRecoveryReceiptKey,
                    });
                }
                cleanupAttempted = true;
                passSummary.cleanup = await cleanup(lane, pass, ownerState);
                passSummary.ownership = ownerState;
                passSummary.status = "COMPLETE";
                if (pass === 1) await cooldown(lane, pass);
            } catch (error) {
                let cleanupFailure = null;
                if (!cleanupAttempted) {
                    cleanupAttempted = true;
                    try {
                        passSummary.cleanup = await cleanup(
                            lane, pass, ownerState);
                    } catch (cleanupError) {
                        cleanupFailure = cleanupError &&
                            typeof cleanupError === "object" ?
                            cleanupError.diagnostic || {
                                status: "UNRESOLVED",
                                reason: cleanupError.message || String(cleanupError),
                            } : { status: "UNRESOLVED",
                                reason: String(cleanupError) };
                        passSummary.cleanup = cleanupFailure;
                    }
                } else if (error && typeof error === "object" &&
                    error.diagnostic) {
                    cleanupFailure = error.diagnostic;
                    passSummary.cleanup = cleanupFailure;
                }
                summary.ok = false;
                summary.status = "INTERRUPTED";
                laneSummary.status = "INTERRUPTED";
                passSummary.status = "INTERRUPTED";
                passSummary.error = error instanceof Error ?
                    error.message : String(error);
                const originalFailure = error && typeof error === "object" &&
                    error.diagnostic ? error.diagnostic : null;
                passSummary.failure = originalFailure && cleanupFailure &&
                    cleanupFailure !== originalFailure ?
                    { ...originalFailure, cleanup: cleanupFailure } :
                    originalFailure || (cleanupFailure ?
                        { cleanup: cleanupFailure } : null);
                passSummary.ownership = ownerState;
                retainLiveResult(summary);
                return summary;
            }
        }
    }
    retainLiveResult(summary);
    return summary;
}
