// SPDX-License-Identifier: GPL-3.0-or-later

async function runRenderScaleTuningLive(context) {
    "use strict";

    const {
        tools, store, notify, variant, runId, buildId,
        initialBoundary, capabilities, matrix,
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

    // A terminal qualification receipt uses the flat qualification snapshot.
    function terminalBoundary(waiter) {
        const snapshot = waiter.upscalingSnapshot;
        const profile = snapshot.effective;
        return {
            revision: snapshot.stateRevision,
            profile: {
                method: profile.method,
                qualityMode: qualityName[profile.qualityMode],
                renderScaleMode: profile.renderScaleMode,
                dlssProfile: profile.dlssProfile,
                fsrRuntime: profile.fsrRuntime,
            },
        };
    }

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
        steps.push(toolStep("qualification-wait", "communityshaders.renderscale", {
            action: "qualification_wait",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedCellEditorId: "WhiterunDragonsreach",
            timeoutMs: matrix.completionTimeoutMilliseconds,
            milestone: "strict",
            target: waiterTarget(target),
            foveation,
            expectedBuildId: buildId,
        }));
        if (!baseline && variant === "nvidia" && target.method === "dlss") {
            steps.push(toolStep("dlss-trace-stop", "communityshaders.renderscale", {
                action: "dlss_trace_stop", expectedBuildId: buildId,
            }));
            steps.push(toolStep("dlss-trace-read", "communityshaders.renderscale", {
                action: "dlss_trace_read", afterSequence: 0,
                limit: matrix.traceReadLimit, expectedBuildId: buildId,
            }));
        }
        return steps;
    }

    function safeTerminal(waiter, identifiers) {
        const facts = waiter && waiter.observation && waiter.observation.facts;
        return waiter && waiter.action === "qualification_wait" &&
            waiter.transitionId === identifiers.transitionId &&
            waiter.ownerId === identifiers.ownerId &&
            waiter.upscalingSnapshot && waiter.upscalingSnapshot.activeOperationId === 0 &&
            facts && facts.stressSession === true && facts.exactCell === true &&
            facts.loadedInWorld === true && facts.apiOperationClear === true &&
            facts.physicalMutationClear === true && facts.terminalClear === true;
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

    function matchesMutationBoundaryGeneration(boundaryGeneration, proofGeneration) {
        return nonNegativeInteger(boundaryGeneration) &&
            nonNegativeInteger(proofGeneration) &&
            (boundaryGeneration === 0 || boundaryGeneration === proofGeneration);
    }

    function exactTargetProof(proof, target) {
        if (!proof || proof.proven !== true || !target) return false;
        const vendorTarget = target.method === "dlss" || target.method === "fsr";
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
        const generationValidator = target.renderScaleMode ?
            positiveInteger : nonNegativeInteger;
        if (!generationValidator(proof.contractGeneration)) return false;
        if (vendorTarget && !generationValidator(proof.providerRuntimeGeneration)) {
            return false;
        }
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
                notRequiredProof.contractGeneration) &&
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
                    firstNewProof.contractGeneration) ||
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

    async function baseline(boundary, lane, laneIndex, pass) {
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
            const stressSessionId = waiter.baseline && waiter.baseline.stressSessionId;
            if (!safeTerminal(waiter, identifiers) || waiter.satisfied !== true ||
                !waiter.milestoneTimings || !waiter.replacementTimeline) {
                throw diagnosticError("baseline_failed",
                    scenarioFailure && scenarioFailure.diagnostic || null);
            }
            return { boundary: terminalBoundary(waiter), stressSessionId, waiter };
        }
        const entries = resultMap(response.root);
        const start = entries.get("baseline-stress-start");
        const stressSessionId = start && start.status && start.status.session.id;
        const waiter = entries.get("qualification-wait");
        if (!response.root.ok || !waiter || !safeTerminal(waiter, identifiers) ||
            waiter.satisfied !== true || !waiter.milestoneTimings ||
            !waiter.replacementTimeline) {
            await closeOpenQualification(identifiers);
            if (stressSessionId) {
                await renderScale({
                    action: "stop", expectedSessionId: stressSessionId,
                    expectedBuildId: buildId,
                });
            }
            throw diagnosticError("baseline_failed",
                scenarioDiagnostic(response.root, steps, receiptKey));
        }
        return { boundary: terminalBoundary(waiter), stressSessionId, waiter };
    }

    async function armOwners(baselineResult, lane, laneIndex, pass, resetPerformance) {
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
        const entries = requireScenario(response.root, steps, receiptKey);
        const start = entries.get("measured-stress-start");
        const sessionId = start.status.session.id;
        return sessionId;
    }

    async function transition(boundary, lane, laneIndex, pass, row) {
        const destination = matrix.destinations[row.destination];
        const target = targetFor(boundary, destination, lane.configuredFsrRuntime);
        const identifiers = ids(laneIndex, pass, row.ordinal, false);
        const steps = qualificationSteps(
            boundary, target, identifiers, false, row.ordinal === 1);
        const receiptKey =
            `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}:scenario`;
        let response;
        try {
            response = await scenario(steps, receiptKey);
        } catch (scenarioFailure) {
            let waiter;
            try {
                waiter = await recoverTerminal(identifiers);
            } catch {
                retain(`${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`, {
                    scenarioReceiptKey: receiptKey,
                    scenario: scenarioFailure && scenarioFailure.diagnostic || null,
                    waiter: null,
                    projection: null,
                });
                throw diagnosticError("transition_receipt_unavailable",
                    scenarioFailure && scenarioFailure.diagnostic || null);
            }
            const projection = transitionProjection(waiter, target);
            retain(`${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`, {
                scenarioReceiptKey: receiptKey,
                scenario: scenarioFailure && scenarioFailure.diagnostic || null,
                recoveredTerminal: true,
                waiter,
                projection,
                replacementTimeline: waiter.replacementTimeline || null,
                presentationCycleAudit: waiter.presentationCycleAudit || null,
            });
            if (!safeTerminal(waiter, identifiers)) throw new Error("transition_unsafe");
            return { boundary: terminalBoundary(waiter), waiter, projection };
        }
        const entries = resultMap(response.root);
        const waiter = entries.get("qualification-wait");
        const projection = waiter ? transitionProjection(waiter, target) : null;
        const diagnostic = scenarioDiagnostic(response.root, steps, receiptKey);
        retain(`${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`, {
            scenarioReceiptKey: receiptKey,
            scenario: diagnostic,
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
            traceStop: entries.get("dlss-trace-stop") || null,
            traceRead: entries.get("dlss-trace-read") || null,
        });
        if (!response.root.ok || !waiter) {
            await closeOpenQualification(identifiers);
            throw diagnosticError("transition_scenario_failed", diagnostic);
        }
        if (!safeTerminal(waiter, identifiers)) throw new Error("transition_unsafe");
        notify({
            lane: lane.id,
            pass,
            ordinal: row.ordinal,
            target,
            ...projection,
            outcome: waiter.outcome,
            elapsedMs: waiter.timing ? waiter.timing.elapsedMs : null,
        });
        return { boundary: terminalBoundary(waiter), waiter, projection };
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
            toolStep("amd-dlss-trace-stop", "communityshaders.renderscale", {
                action: "dlss_trace_stop", expectedBuildId: buildId,
            }),
            toolStep("amd-dlss-trace-read", "communityshaders.renderscale", {
                action: "dlss_trace_read", afterSequence: 0,
                limit: matrix.traceReadLimit, expectedBuildId: buildId,
            }),
        ];
        const response = await scenario(steps, receiptKey);
        const entries = requireScenario(response.root, steps, receiptKey);
        const read = entries.get("amd-dlss-trace-read");
        const capture = read && read.capture;
        const summary = capture && capture.summary;
        if (!capture || !summary || !Array.isArray(capture.records) ||
            capture.records.length !== 0 || summary.totalRecords !== 0 ||
            summary.setConstantsCalls !== 0 || summary.evaluateCalls !== 0) {
            throw new Error("amd_dlss_trace_not_empty");
        }
    }

    async function status(lane, pass, suffix) {
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
        const response = await scenario(steps, receiptKey);
        const entries = requireScenario(response.root, steps, receiptKey);
        return entries;
    }

    async function cleanup(lane, pass, stressSessionId) {
        const before = await status(lane, pass, "final-status-before-cleanup");
        const render = before.get("render-status").status;
        const cpu = before.get("cpu-status").cpuPerformance;
        const gpu = before.get("gpu-status").capture;
        const texture = before.get("texture-status").capture;
        const steps = [];
        if (render.session.active) {
            steps.push(toolStep("measured-stress-stop", "communityshaders.renderscale", {
                action: "stop", expectedSessionId: stressSessionId, expectedBuildId: buildId,
            }));
        }
        if (cpu.active) {
            const args = { action: "cpu_performance_stop", expectedBuildId: buildId };
            if (cpu.sessionId) args.expectedSessionId = cpu.sessionId;
            steps.push(toolStep("cpu-performance-stop", "communityshaders.renderscale", args));
        }
        if (gpu.active) {
            steps.push(toolStep("gpu-performance-stop", "communityshaders.renderscale", {
                action: "gpu_performance_stop", expectedBuildId: buildId,
            }));
        }
        if (texture.active) {
            steps.push(toolStep("texture-lifetime-stop", "communityshaders.renderscale", {
                action: "texture_lifetime_stop", expectedBuildId: buildId,
            }));
        }
        if (render.loadPresentationProbe.active) {
            steps.push(toolStep("load-presentation-stop", "communityshaders.renderscale", {
                action: "probe_stop", expectedBuildId: buildId,
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
        const receiptKey = `${runId}:${lane.id}:pass-${pass}:cleanup`;
        const response = await scenario(steps, receiptKey);
        requireScenario(response.root, steps, receiptKey);
        await status(lane, pass, "final-status-after-cleanup");
    }

    async function cooldown(lane, pass) {
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
        const unavailable = capabilities.fsrRuntimeUnavailableConditions;
        const fsr3 = (capabilities.supportedFSRRuntimeMask & 1) !== 0 &&
            unavailable[0].mask === 0;
        const fsr4 = (capabilities.supportedFSRRuntimeMask & 2) !== 0;
        const fsr4Unavailable = unavailable[1].mask !== 0;
        return matrix.lanes.map((lane) => ({
            ...lane,
            runnable: lane.id === "explicit_fsr4" ? fsr4 && unavailable[1].mask === 0 :
                lane.id === "explicit_fsr3" ? fsr3 : fsr3 && fsr4Unavailable,
        }));
    }

    let boundary = initialBoundary;
    const summary = { ok: true, status: "COMPLETE", variant, runId, lanes: [] };
    let passSequence = 0;
    const selectedLanes = lanes();
    if (variant === "amd" && selectedLanes.some((lane) => lane.runnable)) {
        try {
            await retainAmdTraceCapability();
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
            let stressSessionId = 0;
            const passSummary = { pass, status: "RUNNING", rows: [] };
            laneSummary.passes.push(passSummary);
            try {
                const base = await baseline(boundary, lane, laneIndex + 1, pass);
                boundary = base.boundary;
                stressSessionId = await armOwners(
                    base, lane, laneIndex + 1, pass, passSequence > 1);
                for (const row of matrix.transitions) {
                    const completed = await transition(
                        boundary, lane, laneIndex + 1, pass, row);
                    boundary = completed.boundary;
                    passSummary.rows.push({
                        ordinal: row.ordinal,
                        receiptKey: `${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`,
                        ...completed.projection,
                    });
                }
                await cleanup(lane, pass, stressSessionId);
                stressSessionId = 0;
                passSummary.status = "COMPLETE";
                if (pass === 1) await cooldown(lane, pass);
            } catch (error) {
                if (stressSessionId) {
                    try { await cleanup(lane, pass, stressSessionId); } catch { }
                }
                summary.ok = false;
                summary.status = "INTERRUPTED";
                laneSummary.status = "INTERRUPTED";
                passSummary.status = "INTERRUPTED";
                passSummary.error = error instanceof Error ?
                    error.message : String(error);
                passSummary.failure = error && typeof error === "object" &&
                    error.diagnostic ? error.diagnostic : null;
                retainLiveResult(summary);
                return summary;
            }
        }
    }
    retainLiveResult(summary);
    return summary;
}
