# AMD render-scale tuning protocol

This is the AMD public-API correctness and measurement assay. It runs three
separate backend lanes and never runs the Simple CSM matrix or mutates a
profile through `communityshaders.renderscale`.

## 1. Bind and prepare

The AMD `SKILL.md` owns runtime-only `prepare_coc`, positioning, lane baseline,
handoff, and the measured live loop before this file is read. Read this file
only after a pass completes or is interrupted, for cumulative evidence,
guarded finalization, and reporting. Do not repeat live reads or add another
preflight phase.
Sections 2 through 4 audit actions already executed by the live skill; never
replay them when this file is loaded for finalization.

Use the installed plugin's direct DevBench MCP tools exclusively for every AMD
lane baseline, transition, evidence read, and guarded cleanup. Do not enumerate
tools, audit schemas, use a controller, switch lanes, or generate a local
orchestration script. If one of the named direct calls is unavailable, stop
with `plugin_direct_unavailable`; there is no fallback transport.

Require `status.adapter.available: true` and AMD vendor ID `0x1002`/4098 in the
positioning `communityshaders.renderscale status` result. This is the bound
active D3D adapter; do not substitute generic process inventory or a
description string. Retain the fixture receipt and the single positioning
scenario response.

Require public capabilities to expose FSR and every matrix quality mode before
any baseline. A missing method or quality is `BLOCKED`; do not substitute a
nearby supported state.

The public snapshot serializes each enum as `{ "value", "name" }`. Preserve
that raw object in evidence, but build the next `apply.target` from the
effective profile's `name` fields only: `method.name`, `qualityMode.name`,
`dlssProfile.name`, and `fsrRuntime.name`. Never submit a raw wrapper object,
numeric enum, defaulted field, or an inferred provider value. At a settled
boundary, require complete configured, requested, effective, and stable public
profiles with no active operation; requested/effective/stable must agree with
the exact completed target for every destination. The render-scale
controller's applied/stable resource records are separate physical evidence.
At native resolution they remain inactive with backend `none`, but retain the
exact logical method and never replace a public profile.

The live skill passes packaged `matrix.v1.json` unchanged to the deterministic
runner in the positioning orchestration cell. Do not reopen, revalidate, or
summarize the matrix while reading this protocol.

## 2. Select and isolate the three lanes

Run each supported lane as a separate 31-transition measurement session in
this order:

1. `explicit_fsr4`: configured `fsrRuntime: fsr4`; physical backend must be
   `fsr4_runtime`.
2. `explicit_fsr3`: configured `fsrRuntime: fsr3`; physical backend must be
   `fsr_host` or `fsr_runtime`.
3. `fsr4_to_fsr3_fallback`: configured `fsrRuntime: fsr4`; a documented live
   FSR4-unavailable condition and fallback flag must be present; physical
   backend must be `fsr_host` or `fsr_runtime`.

Use the public capabilities and unavailable-condition masks, never AMD model
names, to determine whether a lane is runnable. If FSR4 is unavailable, mark
the explicit-FSR4 lane `BLOCKED`; this is expected on AMD hardware without
supported FSR4 execution. If no natural or advertised safe FSR4-unavailable
condition exists, mark the fallback lane `BLOCKED`. Never corrupt resources,
exhaust memory, disable hardware, or fabricate a condition to force it. A
blocked lane does not prevent another independently valid lane from running.

## 3. Establish each lane baseline

For the first lane, reuse the authoritative post-position API snapshot. For a
later lane, reuse the preceding lane's guarded terminal snapshot. Require
complete configured and effective profiles, physical stable evidence, and no
active operation. Clone the effective profile through its
`name` fields; set only `method: fsr`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and the lane's configured
`fsrRuntime`; preserve dormant `dlssProfile` in the public apply target. The
strict FSR waiter target includes `fsrRuntime` and omits dormant
`dlssProfile`. Run one synchronous (`async: false`),
fail-closed mutation scenario: reset then start the short baseline-only stress
session, then `qualification_begin`, then
`qualification_dispatch` with
`startPerformanceTelemetry: false`, then the public API `apply` as the
immediately following step, then the strict FSR Hoshipa
`qualification_wait` as the final step. Use the shared contract's exact six
labels and wrapper paths. Bind the apply to the snapshot's exact
`stateRevision`, exact Build ID, unique lane-baseline client and command IDs,
`purpose: direct`, and `persistence: runtime_only`.

The final waiter step uses the same owner and transition, the full
dispatch-relative `timeoutMs: 20000`, exact target and foveation fixture, and
`milestone: strict`; never calculate or pass a client-side remaining budget.
Do not add an independent operation wait. After the complete scenario returns,
require
coherent FSR evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, the lane's physical backend, clean mutation
and lifecycle state, and no terminal failure. Require `milestoneTimings` and
`replacementTimeline` in this terminal receipt as directed by the shared
contract; they are output evidence, not tool-description fields.

When that labeled waiter subreceipt is terminal and safe, use the shared
contract's one synchronous handoff scenario to stop the
baseline-only stress owner and arm the fresh measured stress, texture lifetime,
load presentation, and profiler owners in its short ownership sequence.
An unsatisfied receipt records its non-stable presentation state before the
handoff. A missing or unsafe waiter subreceipt bypasses handoff and permits
only the baseline stress owner's guarded stop.
Retain each stateful receipt; provider lifecycle,
resource publication, preparation, fidelity, stereo, retry, failure, memory,
and queue remain status evidence. For the first lane, do not issue a separate
CPU/GPU reset: transition 1 dispatch requires both captures inactive and
atomically resets/starts them. Before each later lane, after the preceding
lane's guarded stop receipt, serialize exactly one CPU reset and one GPU reset
to clear its measurements and require
both captures inactive. In the first measured mutation scenario, call profiler
API `clear_history` immediately before dispatch; do not use bounded
`start_capture` or invent `frameCount`. Dispatch then starts CPU/GPU capture on
its QPC/frame. Stop only that pass's owned sessions
after transition 31. Do not combine capture windows across passes or lanes.

Execute each runnable lane's exact matrix twice in the same Skyrim process.
Call them `pass 1` and `pass 2`; use IDs unique across every lane and pass and
never alter the matrix, pacing, completion deadline, cell, fixture, or lane
provider rules.

After a lane's pass 1 transition 31, stop and preserve only pass 1's owned
telemetry under `raw/pass-1/finalization`. Record a raw cooldown-start memory
snapshot, then run exactly one
synchronous server-owned 10,000 ms wait containing no mutation or telemetry
action. Record a raw cooldown-end snapshot and require the same PID and Build
ID, advancing world frames, no active public operation, drained cleanup debt,
and no leaked owner or capture. Do not require memory usage to decrease during
cooldown; pressure and growth are evidence, not a mutation gate.

Repeat only section 3's fail-closed lane-baseline mutation and strict waiter
with new IDs, without another COC or its pass 1 handoff. After strict baseline
cleanup, arm fresh pass 2 owners and serialize exactly one CPU reset and one
GPU reset after confirming pass 1's captures are inactive. Pass 2 transition 1
is the new CPU/GPU timing origin. Execute all 31 transitions once more;
section 6 performs the single guarded pass 2 stop before advancing to another
lane. Do not start a third pass. A semantic pass 1 failure does not suppress
pass 2 when control, identity, ownership, liveness, and cleanup remain safe;
an interrupted or unsafe pass 1 stops that lane before further mutation and
asks the user.

## 4. Exact public-API transition primitive

For each matrix entry, use IDs unique across the entire AMD run and preserve
every response even when it is anomalous.
Use the same caller-generated `transitionId` and `ownerId` for that entry's
begin, dispatch, wait, and any cancellation; never reuse either pair.

1. Use the preceding strict terminal receipt's authoritative final public
   snapshot as this row's precondition. Require the exact Build ID, complete
   configured/requested/effective/stable profiles, no active operation, and no
   unresolved physical mutation. Lane transition 1 uses the terminal lane-
   baseline receipt. Do not issue a separate settle scenario, snapshot,
   operation read, or status call. Start this row's mutation scenario
   immediately after the preceding terminal receipt; its first step is the sole
   server-owned 5,000 ms wait.
2. Require complete configured, requested, effective, and stable API profiles
   in that terminal snapshot,
   exact requested/effective/stable agreement, and no active operation.
   Construct its complete API target from the effective profile's `name`
   fields; mutate only `method`, `qualityMode`, and
   `renderScaleMode` from the destination. For FSR entries also set the lane's
   configured `fsrRuntime`. The public apply target preserves `dlssProfile`
   and the lane runtime as dormant state on None and TAA entries. The strict
   waiter target carries only active `fsrRuntime` for FSR and neither provider
   setting for None/TAA. Record the separate
   render-scale controller applied/stable resource keys as physical telemetry;
   for a native target they must be inactive with backend `none` and retain
   that target's exact method.
3. Materialize the terminal-snapshot-derived string target and every guarded
   apply argument before submitting one synchronous (`async: false`) server
   scenario with `continueOnError: false`. Its first step is `wait` with
   exactly 5,000 ms.
   Its consecutive mutation steps then are `qualification_begin`, the lane-
   transition-1 profiler start when applicable,
   `qualification_dispatch`, `communityshaders.upscaling_api` `apply`, and the
   target-correlated `qualification_wait` as the final step. Label the last two
   steps `profile-apply` and `qualification-wait`.
   No wait, snapshot, client round trip, menu action, or other tool may appear
   between dispatch and apply. Scenario steps cannot interpolate earlier
   results, so no snapshot-dependent value may be deferred to scenario
   execution. Set `startPerformanceTelemetry: true` only on
   lane transition 1 so CPU/GPU counters and the transition QPC/frame share the
   actual apply's timing origin. Set it false on every other transition.
4. Apply only the constructed target with the preceding terminal snapshot's
   `stateRevision`, exact Build ID, unique `clientId` and `commandId`,
   `purpose: direct`, and `persistence: runtime_only`. Require API status and
   result status `success`, `idempotentReplay: false`, admitted state revision
   equal to the snapshot revision, normalized target exact, and disposition
   exactly `queued`. `rejected`, `applied_synchronously`, `no_change`, a
   stale revision, producer mismatch, embedded error, restart requirement, or
   non-retryable admission failure is a control failure: cancel the owner only
   if needed, preserve receipts, and stop further mutations. The only exception
   is the shared `tooling_false_positive` path for an authoritatively proven
   never-dispatched safety rejection; issuing that row once is not a replay.
   Never retry an admitted or ambiguous request, recover by reapplying, or
   substitute a matrix row.
5. The final scenario step is `qualification_wait`. For FSR destinations, pass
   the full
   dispatch-relative `timeoutMs: 20000`; never calculate or pass a client-side
   remaining budget. This is the one shared 20,000 ms monotonic deadline from
   dispatch, not a second window. It must return upon its first successful
   receipt. Use the
   exact FSR target, lane runtime, fixed foveation fixture, and
   `milestone: strict`. Map quality strings to values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. The `vendor_native` FSR Native
   AA target has native API render-scale state but must still prove
   fixed-resolution FSR evaluation. Its public requested/effective/stable
   profiles must all equal the exact target. Its render-scale controller
   resource key remains inactive with backend `none`; that resource key is
   never FSR-execution evidence. Read native-vendor proof from top-level
   `nativeVendorExecution`; for an older producer that has not projected that
   field, read the identical `observation.nativeVendorExecution` object
   instead. The selected object must report `required: true` and
   `sameFrameBothEyesValid: true`, with each eye's `presentationFrame` equal to
   its `dispatchFrame` and one shared nonzero `dispatchSerial` for the
   combined-stereo FSR dispatch. Both eyes and `actualBackend` must identify
   the same provider accepted by the active lane: `fsr4_runtime` for explicit
   FSR4, `fsr_host`/`fsr_runtime` for explicit FSR3, or
   `fsr_host`/`fsr_runtime` with `actualRuntimeFallbackObserved: true` for the
   FSR4-to-FSR3 fallback lane. Preserve the receipt values; do not derive them
   from the render-scale resource key. Exact foveation and coherent two-eye
   native presentation remain required. A missing or mismatched native FSR
   receipt is a failure, not `INCONCLUSIVE`.
   The direct tool transport must outlive the current server waiter budget by
   five seconds without changing the shared 20-second measurement deadline. A
   successful waiter still returns immediately and never waits out that
   envelope.

   Store the exact scenario envelope before decoding or extracting any step.
   On failure, link the compact row interruption to that raw receipt and expose
   only explicitly reported failed-step/error fields. Keep the first
   unreported step separate; never claim that an unreported step failed.
   The interrupted live result must enumerate the retained receipt keys and
   preserve every earlier completed row/pass for offline materialization.

   When baseline recovery is semantically rejected after its scenario returns,
   embed the runner's bounded recovery assessment in the interruption. Preserve
   apply acceptance, waiter and milestone states, decoded failure masks/reasons,
   safe-terminal blockers, controller state, evidence presence, and terminal
   generation/epoch identity. This projection is diagnostic only: it must not
   add calls, waits, gates, retries, or change the recovery decision.

   If the mutation-and-wait scenario response is lost, apply the shared
   contract's owner-correlated recovery rule immediately. Never replay the
   scenario, apply, or waiter. Recover matching terminal `lastEvidence` from
   the already-running server scenario. Require `active: false` and matching
   owner/transition IDs before classification or cleanup. This
   recovery rule applies to both vendor and native qualification waits. If no
   terminal receipt can be recovered within the original deadline plus its
   five-second receipt bound, preserve the IDs and transport receipt, stop
   future DevBench calls, and ask the user.
6. For None and TAA, use the same final scenario `qualification_wait` in
   Dragonsreach with the full dispatch-relative `timeoutMs: 20000`. Pass
   `milestone: strict` and the exact native target:
   `method: none` or
   `method: taa`, `qualityMode: 0`, and `renderScaleMode: false`; omit
   `dlssProfile`, `fsrRuntime`, and the waiter `foveation` field. This is a
   native target, not a manufactured FSR target. The configured fixture
   remains telemetry, but inactive vendor execution is correct and cannot be
   a foveation mismatch. The target-correlated server barrier requires the
   authoritative requested/effective/stable profiles to equal that target,
   render scale to
   remain disabled, no active operation, advancing coherent native
   presentation, and either `idle/idle` or `active/active` native controller
   state. Native TAA legitimately reports `active/active`. Its physical
   render-scale resource key remains inactive with backend `none` but retains
   method TAA. Do not poll `operation` or start a second 20-second window.
   Use the apply operation and final snapshot embedded in the terminal waiter;
   require its target and effective profile to match, its state to be
   `completed`, and no active operation. Do not issue a separate read. The
   waiter
   closes the timing owner; do not call `qualification_cancel` after any
   terminal waiter receipt. Cancellation is only for an owner that has not
   entered its waiter. Require public requested/effective/stable profiles to
   remain exact in the terminal snapshot and preserve the separate inactive
   native physical key as telemetry.
   The terminal waiter receipt closes the timing bracket and is not a render
   failure.
7. Preserve the terminal waiter response handle immediately and derive only
   the shared contract's compact safety/classification projection. Do not read
   operation/event history, status, another snapshot, preparation records, or
   cumulative telemetry before starting the next row.

During the measured loop, retain only the exact terminal waiter response in
the client response store and the compact transition projection in context.
Do not create per-row files or update `receipt-index.json` before the next
apply. At pass finalization, materialize the exact terminal responses under
`raw/transitions/<lane>/transition-NN/`, collect operation/events, final
status, preparation, telemetry, and provider-lifecycle history once, correlate
it by transition ID/QPC/frame, and write and hash the complete evidence bundle
in one local batch. A response-store handle is permitted during the live loop
but every retained terminal response must be a decoded raw file in the
completed bundle.
This per-transition evidence requirement does not duplicate `prepare_coc` or
the positioning scenario. Materialize their stored exact receipts once under
`raw/startup` during finalization. Missing startup evidence is explicitly
`startup_evidence_incomplete`, forbids a ledger append, and never replays the
startup calls or changes completed row classifications.

A semantic strict timeout, unsatisfied milestone, or native-stability timeout
is a recorded transition `FAIL` or `INCONCLUSIVE`, not permission to hide the
row or retry it. Record the shared `nonStableNote` with the terminal
presentation disposition and eye/controller state. Continue with the next
matrix row when the terminal waiter
proves the game responsive, the qualification owner closed, no active
operation or unresolved physical mutation, and exact PID/build ownership.
Do not demand a second snapshot or status receipt for those same facts.
If the terminal waiter instead proves the exact scene remains loaded but the
operation or physical mutation is stuck, preserve the failed row and attempt
one reset to the active lane's existing FSR Hoshipa starting profile. Use a
fresh qualification owner and the render-scale iteration `apply` action so the
reset can supersede the stuck public request. The reset is not a measured row
and does not retry or revise the failed destination. Continue only after its
strict waiter is satisfied and safe. Device loss, OOM, lost
scene/ownership/build or transport, missing terminal evidence, or a
rejected/unstable reset stops the run.

A completed transition-level physical-contract, presentation, lifecycle, or
both-eye fidelity mismatch makes that row `FAIL`; it does not by itself make
control unsafe. Once its terminal receipt is preserved and the conditions
above are clean, continue to the next matrix row so the assay retains the
build's error history. A stuck operation, unresolved mutation, or producer
terminal failure uses the one reset above when its exact terminal/scene
ownership remains provable. Stop directly for device loss, OOM, identity or
transport loss, missing terminal evidence, or lost ownership; stop after any
reset that is rejected or does not stabilize.

Preserve the terminal receipt first on every stop path. While direct control
remains callable, finalize immediately: stop only task-owned trace, profiler,
and telemetry sessions with their exact returned guards and verify them
inactive. A cleanup failure is a separately recorded anomaly and never
authorizes another apply, retry, recovery, or substitution. When transport is
genuinely unavailable, retain the guards and ask the user before later cleanup.

Every entry has exactly one begin, one dispatch, one apply, and one terminal
qualification receipt from the same strict waiter for every destination. The
public API is the sole mutation path. Do not open the CS menu and do not
call `communityshaders.renderscale` action `apply` for a baseline or matrix
destination. The single reset described above is the only exception. No
external frame-timing source is used.

For every entry, distinguish the pre-mutation interval from destructive
mutation using the producer's `physicalMutationStarted` evidence, whose first
true observation is provider invalidation, dirtying, teardown, or destruction
(not merely engine-target creator entry). Before it becomes true, a queued,
deferred, rejected, or preparing replacement must retain the exact proven old
stereo presentation: current generation, provider resource, D3D device, and
both-eye path must remain exact, or a completed stereo output must retain
explicit ownership and immutability proof. In an ordinary world frame, a
queued or refused replacement alone must not select black keepalive or stretch.

Once destructive mutation begins or a new contract is published, the old
provider and completed output are no longer admissible without continuing
ownership and immutability proof. Require both eyes to converge on the newly
published generation before a normal vendor presentation passes. Recovery,
stretch, quarantine, or keepalive is permitted only as a protected fail-closed
outcome. A mixed eye, mixed generation, wrong resource/device/generation,
stale old-provider dispatch after mutation, or ordinary-world fallback caused
solely by pre-mutation replacement admission is a transition `FAIL`.

## 5. Completion and evidence rules

For scaled FSR, require requested, effective, stable, and physical profiles to
agree; scaled dimensions; coherent both-eye FSR presentation; exact provider
generation and resource ownership; and strict completion. For `vendor_native`
FSR Native AA, require exact public requested/effective/stable profiles and
fixed-resolution FSR execution at native dimensions. The render-scale
controller resource key is inactive with backend `none`; its logical method
must still be FSR, and top-level
`qualification_wait.nativeVendorExecution` is authoritative for same-frame,
both-eye FSR execution. If that projection is absent, use the identical
`qualification_wait.observation.nativeVendorExecution` object from older
producers. Take `actualBackend`, the per-eye dispatch frames and shared serial,
and `actualRuntimeFallbackObserved` directly from the selected object. Never
substitute the render-scale resource backend. Apply the active lane's provider
rules:
`fsr4_runtime` for explicit FSR4, `fsr_host`/`fsr_runtime` for explicit FSR3,
and `fsr_host`/`fsr_runtime` plus observed runtime fallback for the fallback
lane. A missing or mismatched native FSR receipt is a failure. Record first
physical match, first coherent stereo
presentation, `presentationStable`, `cleanupDrained`, and strict completion
separately. Use the one strict receipt's `milestoneTimings`; preserve
presentation, cleanup, and strict first-observation frame/QPC/elapsed values,
the signed presentation-to-cleanup delta, `cleanupTailMs`/frames, and
`sameObservation`. Equal values count as a measured zero tail only when
`sameObservation: true`; they are never filled from strict completion.

For None and TAA require the public operation target and
requested/effective/stable profiles to match the complete target;
`qualityMode: native_aa`; `renderScaleMode: false`; native dimensions;
producer-native physical-contract evidence; advancing coherent in-world
target-correlated native `qualification_wait` receipt; no unresolved physical
mutation; and no FSR evaluation treated as active presentation. Their
inactive backend-`none` render-scale resource key is recorded separately and
must retain the exact target method. If exact native presentation generation is unavailable,
record `generationEvidence: "not_exposed"` and retain raw dimensions but do not
calculate native or `dimensionsMatch` booleans. Native-generation evidence is
optional: mark only that evidence facet `INCONCLUSIVE`; do not relabel a core
`PASS`, make control unsafe, or block the next row solely because it is absent.
When every required native contract check passes and only exact native
generation is unavailable, the transition classification must remain `PASS`;
record `nativeGenerationEvidence: INCONCLUSIVE` with reason `not_exposed`.

None, TAA, and FSR Native AA are distinct contracts: None has neither FSR nor
TAA, TAA is native non-vendor TAA, and FSR Native AA performs native-resolution
FSR evaluation.

Every transition record must retain direct raw paths for:

- lane ID, pass number, transition ordinal, dispatch/marker frame and QPC, API
  revisions, operation ID, disposition,
  admission route, replacement admission state and all reasons;
- first physical match, first coherent both-eye presentation, presentation,
  cleanup, and strict frame/QPC timings;
- current/completed/published publication generations; expected and published
  dimensions; `complete`; deferred-setup acknowledgement; D3D device/context
  matches; and producer `dimensionsMatch` without protocol-side arithmetic;
- configured runtime, desired/authoritative/stable-resource/lifecycle/actual-
  dispatch/both-eye backends, fallback flag, provider/resource generations,
  selected disposition, mutation state, and per-eye paths;
- admission and early exits; shader-cache waits; SSS/SSGI prewarm; DLSS, FSR,
  and FSR4 preparation; D3D creation; total preparation;
  request-to-prepared and prepared-to-creator latency;
- retries, consecutive stretch frames, queue/work gate, retirement and cleanup
  debt, memory admission, failure/fallback masks, vendor results, and terminal
  state;
- per-lane CPU/GPU telemetry and profiler capture, plus all stress, fidelity,
  stereo, lifetime, load-presentation, and trace session identities.

During finalization, extract every scalar, null, and empty container from every
JSON receipt below `raw/` into `evidence-values.csv`. Use one row per value with
its relative source path, lane/pass/ordinal when present, RFC 6901 JSON Pointer,
JSON type, and JSON-encoded value. Do not use a curated field allowlist or drop
false, zero, null, or empty values. The compact transition table must also
expose dispatch, terminal, and first-mutation frame/QPC plus per-eye generation,
transition epoch, and resource revision. These diagnostic deltas never
synthesize a missing mutation-boundary receipt or change a row verdict.

Project every `replacementTimeline` facet independently into `summary.json`,
`transitions.csv`, and the rendered report. Use these prefixes exactly:
`dispatch_`, `blocked_pre_mutation_`, `last_pre_mutation_`,
`first_physical_mutation_`, `first_post_mutation_`,
`first_new_generation_proven_`, and `terminal_`. Never combine proof,
admission, disposition, generation, or ownership fields from different
facets. Preserve each facet's complete raw object in the terminal waiter.
This includes the facet-local `selectedPresentationDisposition`; never move it
to another facet.

Report preparation admission separately from replacement-mutation admission.
CS-menu preparation reasons such as wrong origin or method ineligibility are
`preparationAdmission: not_applicable`; they do not by themselves mean that
public-API mutation was blocked. Use the producer's authoritative
`replacementMutationAdmission` status, reason mask, and reasons.

Retain `presentationCycleAudit`, all disposition counters, and the four
decisive violation counters with their first-offender identity. A coherent
post-mutation `PresentationStretch` during transition cooldown remains visible
in the raw disposition and mixed-or-unproven counters, but is not a decisive
`postMutationUnprovenStereoSubmitted` violation. Pre-mutation, mixed,
boundary-spanning, or unprotected stretch remains decisive. A partial eye
observation is not a submitted mixed stereo pair. Render and evidence verdicts
remain separate. Task 2 evidence is `PASS` only when every required facet is
present, the authoritative audit is complete, and all four counters are zero;
it is `FAIL` only for an exact recorded violation and `INCONCLUSIVE` for missing
or overflowed evidence. Missing `firstPhysicalMutation` is valid only when
`mutationExpectation` is explicitly `not_required`; otherwise it is
`INCONCLUSIVE`. Do not synthesize a missing facet from terminal status.

For None and TAA, correlate the nonzero replacement transaction generation at
the physical-mutation boundary with an exact native presentation whose contract
and provider generations are both zero. Require the same request, transition
epoch, device, dimensions, positive publication generation and resource
revision, plus coherent matching left/right eye identity. Do not require the
transaction generation to equal native generation zero. FSR proofs retain the
published vendor-generation rule, and all post-mutation old-generation
rejection remains strict.


Report phase-counter authority separately as `MATCHED`, `MISMATCHED`, or
`INCOMPLETE`. Keep every nonzero counter visible as a reported pipeline
observation. A counter is an authoritative violation only when the audit owner,
qualification transition, stress session, mutation-boundary ownership token,
and first-offender phase ordering agree. An explicit disagreement is
`MISMATCHED`; a missing authority or ordering fact is `INCOMPLETE`. Both make
Task 2 `INCONCLUSIVE`, not `FAIL`, while retaining the exact mismatch reason and
raw counter. Never rewrite a mismatched counter to zero.
Emit status and reasons per reported counter; one `MATCHED` exact violation
remains a `FAIL` even if a different counter is `MISMATCHED` or `INCOMPLETE`.
Treat `presentationCycleAudit.evidenceComplete` only as storage-retention
status. Require dispatch, matching audit ownership, actual eye observations,
all four decisive `violations` counters, and schema revision 14 or newer before
calling transition evidence complete. Raw mixed/unproven totals stay
diagnostic. Preserve an offline DLL/build-manifest verification receipt in the
run bundle; missing proof affects reporting completeness, not render truth.
Supply the exact resolved DLL and manifest to the offline finalizer through
`--artifact-path` and `--manifest-path`, never through a new live startup gate.
Preserve server-QPC phase durations for dispatch to blocked/preparation,
blocked/preparation to first physical mutation, first physical mutation to
the first exact new generation, new generation to cleanup drained, and
presentation to strict completion. Retain the raw apply, waiter, operation,
preparation, full timeline, audit, and AMD isolation receipts plus relative
paths and hashes. Materialize and hash them only during pass finalization.
Index their relative raw receipt paths plus hashes without rewriting receipts.

Project final method, quality, render-scale mode, and state revision from the
terminal waiter's authoritative stable profile. For scaled FSR rows, project
the actual backend from the physical-stable/actual-dispatch evidence; for FSR
Native AA rows, project it only from `nativeVendorExecution`; for None and TAA
it is `none`. Never fill these PASS fields from an inactive native resource
key, and write `not_exposed` rather than JSON null when the producer did not
expose a facet. Report `PresentationStretch` selections and their consecutive
frames/recovery as anomalies even when the row passes. Likewise, report absent
duplicate-constants or evaluation-failure counters as `not_exposed`, never as
zero.

Use these exact finalization mappings in both `summary.json` and
`transitions.csv`:

- `finalMethod`, `finalQuality`, `finalRenderScaleMode`, and
  `finalStateRevision` come from the terminal waiter's authoritative stable
  profile and state revision;
- CSV `physical_mutation_started` comes only from
  `replacementTimeline.firstPhysicalMutation.physicalMutationStarted`, never
  `lastPreMutation`;
- CSV `actual_backend` comes from physical-stable/actual-dispatch backend for a
  scaled FSR row, `nativeVendorExecution.actualBackend` for FSR Native AA, and
  `none` for None/TAA.

These fields must not be JSON null on a `PASS`. When the owning producer facet
is absent, write `not_exposed`, mark `reporting_contract_incomplete`, and retain
the row's render classification separately.

Expose recovered stretch explicitly in every output. Add these per-row fields
to `summary.json` and `transitions.csv` and show them in the rendered transition
tables:

- `presentationStretchSelected`: true when
  `firstPhysicalMutation.selectedPresentationDisposition` is
  `PresentationStretch`;
- `presentationStretchConsecutiveFrames`: the producer's maximum consecutive
  stretch-frame count for that transition, or `not_exposed`;
- `presentationStretchRecovered`: true only when stretch was selected and the
  terminal receipt has `satisfied: true`, `presentationStable: true`, and
  top-level `cleanupDrained: true`, and the row is a `PASS`. Preserve the
  structured `outstandingCleanupDebt` object as raw detail; never compare that
  object directly with numeric zero;
- `presentationStretchRecoveryFrame` and
  `presentationStretchRecoveryElapsedMs`: the terminal `milestoneTimings`
  presentation first-observation frame and elapsed value after stretch was
  selected, or `not_exposed`.

Add a `presentationStretchAnomalies` summary containing selected, recovered-
PASS, and unrecovered counts plus the lane/pass/ordinal/from/to list. Render
that list even when every affected row ultimately passes. Derive the count from
the receipts; never hardcode an expected number. A recovered stretch remains
an anomaly rather than a failure unless its duration, failure mask, ownership,
or fidelity violates this protocol.

Perform one bounded DLSS trace capability lifecycle before the first AMD lane:
status, reset, start, stop, and read. Require zero DLSS dispatch records. A
missing trace action is `unsupported`; an exposed action that fails is a
control failure. Retain the complete lifecycle envelope so its action receipts
and empty raw read can be materialized during finalization. Do not start a DLSS
trace during AMD matrix transitions. Missing lifecycle evidence forbids a
ledger append but does not change completed AMD row classifications.

Unsupported preparation providers are `n/a`, never zero. Preserve raw values
before summarizing. Archive any log before reading it under the repository's
log-preservation contract.

## 6. AMD verdict and output

FSR Native AA must remain distinguishable from TAA and None. TAA and None must
restore native dimensions without treating FSR as active presentation.
Explicit FSR4 must physically use `fsr4_runtime`; explicit FSR3 must use
`fsr_host` or `fsr_runtime`. In the fallback lane, configured FSR4 and resolved
FSR3 must remain separate facts, and a coherent documented fallback is not a
failure. Returning from TAA or None must restore the lane's intended backend.
Never accept stale FSR generation/resource identity after mutation.

After every complete or interrupted pass, run the shared ownership-guarded
finalization. Retrieve cumulative operation/event/status/telemetry data and
`dlss_trace_status` once, materialize the runner-retained terminal and trace
receipts, persist stop/final-status responses under that pass's `finalization`
directory, then invoke the packaged shared render-scale finalizer at
`tools/renderscale-tuning-finalizer/finalizer.js`. Use one read-only scenario
with `continueOnError: true` and validate each
labeled result independently. Every tool step in that scenario must place its
tool input in `args`; never use `arguments`. Before dispatch, reject a batch
unless every tool step has an `args` object containing its explicit `action`,
for example:

```json
{
  "label": "renderscale-status",
  "tool": "communityshaders.renderscale",
  "args": {
    "action": "status",
    "expectedBuildId": "<exact-build-id>"
  }
}
```

This validation is finalization-only and must not insert another read, wait,
or gate between measured rows or passes. Treat an unsupported optional
operation or event history action as `not_exposed`; it must not abort the later
status, telemetry, or cleanup reads. During live finalization,
its `collectTracePages` helper obtains the maximum page size from the live
producer schema, pages with `afterSequence` while `moreAvailable` is true, and
rejects gaps, duplicates, overwritten requests, or build/session changes.
Never supply an invented client limit. Materialize each raw page before
validating it. Offline restart uses the retained per-row trace evidence and
does not issue a live read. The finalizer must be restartable from the exact
run/build/session-owned retained files and must never replay an in-game
transition. It writes `summary.json`, `transitions.csv`,
`evidence-values.csv`, `report.md`, and `receipt-index.json` atomically only
after validation. Do not hash or render per
row. An evidence root containing only `summary.json` and `transitions.csv` is
incomplete and cannot support a ledger append. Append one uniquely headed
result column per completed two-pass lane.

If the live runner stops at baseline before any measured row, retain
`raw/live-result.json` and the exact baseline waiter receipt. Run the same
offline finalizer with the exact run ID, Build ID, and expected row count. It
must emit `INTERRUPTED`, zero dispatched rows, reporting `INCOMPLETE`, and
memory `repeat_not_completed` without issuing another DevBench call.

Keep `assayExecution`, `render`, per-transition `task2Evidence`, and `reporting`
independent. A finalization failure sets reporting to `INCOMPLETE` without
rewriting a completed render `PASS`. Task 2 is never aggregated into one
verdict: preserve every row classification and report only the `PASS`, `FAIL`,
and `INCONCLUSIVE` counts. Do not calculate an overall verdict from those
counts. When a required mutation has no
`firstPhysicalMutation`, report `missing_required_mutation_boundary` and make
Task 2 `INCONCLUSIVE`; preserve its phase counters as non-authoritative raw
observations. With a valid boundary, all existing post-boundary failure rules
remain strict.

### Memory confirmation result

Produce a dedicated memory table with columns for pass 1 start/end/delta,
cooldown start/end/delta, pass 2 start/end/delta, and the pass-2/pass-1 growth
ratio. Include process private MiB, system commit MiB, DXGI process usage MiB,
memory pressure, live tracked texture count, and estimated live tracked
texture MiB. Preserve the raw start/end receipts for both passes and both
cooldown snapshots; never substitute the final status for a missing boundary.
Within each lane, store transitions under `raw/pass-1/transitions` and
`raw/pass-2/transitions`, and store the six memory boundaries under
`raw/memory`. Index every file in `receipt-index.json`.
Write a `memoryConfirmation` object to `summary.json` containing
`passesCompleted`, `cooldownMilliseconds`, the three boundary groups, all
computed deltas and ratios, `predicateInputs`, and `verdict`. Include `pass`
in every `transitions.csv` row.

Compute a ratio only when the pass 1 delta is positive; otherwise report
`n/a`. Classify memory separately from render correctness:

- `retention_signal` requires pass 2 process-private and system-commit growth
  each to be at least 75 percent of its positive pass 1 growth, plus positive
  pass 2 DXGI growth or an increase in pass 2 live texture count or bytes.
- `initialization_dominated` requires pass 2 process-private and system-commit
  growth each to be no more than 25 percent of its positive pass 1 growth and
  no positive pass 2 increase in DXGI usage, live texture count, or live
  texture bytes.
- Every other complete comparison is `inconclusive`. A missing repeat is
  `repeat_not_completed`, makes the assay `INTERRUPTED`, and forbids a ledger
  append.

Always emit the memory table and `memoryConfirmation` object, including for an
interrupted pass. When pass 2 never ran, set `passesCompleted` to the actual
count, set `verdict: repeat_not_completed`, identify the unavailable boundaries,
and state that no leak/retention conclusion is possible. Never omit the object
or serialize its verdict as null.

Neither `retention_signal` nor Normal final pressure proves or disproves a
leak. Print the memory classification, its exact predicate inputs, and the
render verdict separately. Memory growth alone never changes a transition's
`PASS`/`FAIL` classification, and the protocol never starts a third pass.

### Ledger append transaction

Treat each comparison-ledger column append as one transaction. Use exactly
`docs/development/vr-render-scale-comparison-ledger.csv`; never search for a
ledger. Read and parse it once after both passes for the comparison finish,
retain its original hash, and compose the
complete candidate before any ledger write. Reject the candidate unless it has
the same ordered metric rows and row count, exactly one additional rightmost
column, a unique nonempty header, and zero changed pre-existing parsed cell
values under ordinal comparison. Do not normalize, reorder, or otherwise
rewrite an existing cell.

Require these five distinct metric rows before composing the candidate:
`runtime_device_loss_failures`, `runtime_oom_failures`,
`runtime_producer_terminal_failures`,
`vendor_native_qualification_failures`, and
`credible_liveness_timeouts`. If any row is absent, preserve the run evidence,
do not modify the ledger, and report `ledger_failure_schema_outdated`.

Also require `memory_confirmation_passes`,
`memory_process_private_mib_pass1_pass2_ratio`,
`memory_system_commit_mib_pass1_pass2_ratio`,
`memory_dxgi_usage_mib_pass1_pass2_ratio`,
`memory_live_textures_pass1_cooldown_pass2`,
`memory_live_texture_mib_pass1_cooldown_pass2`,
`memory_pressure_pass1_cooldown_pass2`, and
`memory_confirmation_verdict`. Store both pass deltas and the ratio in the
three growth cells as `<pass1-delta>/<pass2-delta>/<ratio>`. Store resource
and pressure cells as
`<pass1-end>/<cooldown-start>-><cooldown-end>/<pass2-start>-><pass2-end>`.
The ledger must never collapse the memory classification into the render verdict.

Populate those rows from preserved receipts, never from the number of
transitions classified `FAIL`:

- Count device loss and OOM only when the runtime reports those exact terminal
  conditions.
- Count producer terminal failures only when the producer reports a terminal
  failure. A qualification-terminal result is not a producer terminal failure.
- Count a vendor-native qualification failure when native vendor execution
  proof is absent or mismatched without device loss, OOM, or producer terminal
  evidence. This records a qualification/observer failure, not a runtime-hard
  failure.
- Count a credible liveness timeout only when the shared deadline expires and
  independent bound-operation or game-progress evidence proves a genuine
  stall. A transport failure, missing observation, or observer mismatch is not
  a credible liveness timeout.

Print all five counts separately in the summary and result tables and retain
the underlying transition reasons. The legacy `hard_transition_failures` and
`hard_failures_oom_device_loss` rows are ambiguous; if present, write
`n/a; legacy aggregate disabled` in the new result cell rather than a failure
total. Never sum qualification or liveness results into a runtime-hard metric.

Apply the validated candidate with a single in-place `Update File` operation
for the ledger path. Never combine `Delete File` and `Add File` operations for
that path in one `apply_patch`, and never delete and recreate the ledger. If the
append cannot be represented as one in-place update, stop before modifying the
ledger and report `ledger_append_unrepresentable`; retain the run evidence and
do not rerun the assay.

After the write, parse the ledger again and repeat every candidate invariant,
confirm that the original hash changed, and run `git diff --check`. Report
`ledger_append_validation_failed` rather than claiming an append if any check
fails. A ledger finalization failure does not invalidate or permit rewriting
the preserved assay evidence.

### Result tables

Produce separate tables for:

1. AMD explicit FSR4.
2. AMD explicit FSR3.
3. AMD FSR4-to-FSR3 fallback.
4. AMD TAA and None transitions, separated by lane.

Keep chat output compact: print pass/lane totals, terminal failure counts,
timing aggregates, cleanup-tail aggregates, stretch/retry anomalies, memory
classification, and evidence links. Store the complete row tables and raw
receipts in the evidence bundle; do not emit megabytes of decoded receipts or
all row objects through chat.

Show pass 1 and pass 2 side by side for every transition. Preserve each
pass's classification and timings, and report whether every failure or anomaly
recurred, recovered, or appeared only in the repeat. Never average the passes
or replace either pass with the memory classification.

For TAA/None separate vendor-to-TAA, vendor-to-None, TAA-to-vendor,
None-to-vendor, and TAA-to-None results. Include native restoration,
creator/mutation duration, first coherent native presentation, cleanup, and
stale-provider evidence. Never average None, TAA, and FSR Native AA.

Classify every transition and lane `PASS`, `FAIL`, `BLOCKED`, or
`INCONCLUSIVE`. Preserve semantic anomalies and continue only while control,
PID, build, required tools, and mutation ownership remain valid. A
qualification-terminal row failure is not a producer terminal failure. Stop
the current lane on a scenario abort without terminal evidence, failed reset,
unrecoverable transport/control failure, identity mismatch, device loss, OOM,
or leaked owner/session. Apply the one bounded reset above for an exact
terminal row with a stuck operation or mutation. Do not stop solely because a
completed row recorded a physical or fidelity mismatch, and do not let one
lane's blocked precondition invalidate another lane.

If a lane ends early, label every entry that was never dispatched `NOT RUN`,
never `BLOCKED`. Reserve `BLOCKED` for a row whose required admission or
precondition failed before its mutation. Report that lane as `INTERRUPTED`
while retaining the exact classifications of completed rows; do not convert it
to overall `FAIL` merely because later rows were not run. Do not append a
ledger column for an interrupted lane. Print the complete tables and evidence
paths, then stop; do not start another protocol.
