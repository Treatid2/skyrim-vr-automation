# Simple CSM protocol

Apply the complete Simple COC protocol without omission, with only the
replacements below. Where the base protocol conflicts, this file wins only for
the initial cell, measured mutation, transition count, pacing, DLSS-trace
lifecycle, and result grouping.

## Fixed assay

- Initial position: `WhiterunDragonsreach`, followed by one server-owned
  10,000 ms stabilization wait.
- Measured transitions: exactly 25 Community Shaders menu applies from the
  hardware-appropriate matrix in
  `tools/render-scale-qualification/protocol.v1.json`.
- Pacing: one server-owned 5,000 ms wait before every measured apply.
- Qualification: one strict waiter per apply, 30,000 ms timeout, with the exact
  target profile from that matrix entry.
- Scenario: one async DevBench scenario with `continueOnError: false`.
- Timing origin: `qualification_dispatch` immediately before the matching
  `apply`; no COC occurs in the measured scenario.
- Telemetry: every required Simple COC lane remains required and transition 1
  atomically starts CPU and GPU telemetry.
- Output: use the Simple COC evidence and CSV contract, grouped by menu method,
  quality mode, and overall instead of by alternating destination cell.

## 1. Bind and prepare exactly as Simple COC

Before the positioning COC, complete only Simple COC health and producer
binding, core control discovery, and the single runtime-only `prepare_coc`
call. The receipt must still prove debug logging and the FOV/TAA
`0.3/0.3/0.7` fixture. Do not query the profiler service or reset telemetry
until exact-cell positioning has passed. This setup phase must not change
method, quality, preset, render-scale state, or any VR FPS Stabilizer setting.

Use the active D3D adapter reported by the bound DevBench producer to select
the matrix: `nvidiaMatrix` for NVIDIA or `amdMatrix` for AMD. Do not use GPU
inventory, MO2 files, INI precedence, or VR FPS Stabilizer state to choose it.
Stop before mutation when the live adapter is missing, ambiguous, unsupported,
or disagrees with the producer.

Treat configured FSR runtime preference and physical backend identity as
separate facts. `fsrRuntime: "fsr4"` records the configured preference; it
does not prove that the active backend is `fsr4_runtime`. Capability fallback
may truthfully select `fsr_host` or `fsr_runtime` on NVIDIA and on AMD hardware
without supported FSR4 execution. Never predict the backend from adapter
vendor or model.

Load the canonical JSON relative to the installed plugin; do not copy,
reorder, deduplicate, substitute, or infer its entries. Require exactly 25
entries with ordinals 1 through 25. The NVIDIA matrix may contain DLSS and FSR;
the AMD matrix must be FSR-only.

## 2. Position at Dragonsreach

Run one server scenario containing:

1. `console` with `coc WhiterunDragonsreach`;
2. a 10,000 ms server wait.

After it completes, require the exact Dragonsreach editor ID and a loaded
player. This is the protocol's only COC and is not one of the 25 measured menu
transitions.

## 3. Arm the Simple COC telemetry lanes

Apply Simple COC section 3 after exact-cell verification. First complete its
single measurement-admission schema refresh, profiler fail-closed proof, and
serialized telemetry resets. Then serialize the short ownership sequence:
start the single fresh stress session, then texture-lifetime,
load-presentation, and each other supported capture; then pre-arm but do not
start the profiler capture. Reuse the measurement-admission CPU/GPU reset
receipts, require both captures to be inactive, and do not issue another
reset. Do not start CPU or GPU counters in that sequence; transition 1's
dispatch remains their sole timing origin. Preserve the profiler initial state
and pre-arm it exactly as Simple COC requires.

Replace only the base protocol's session-wide DLSS trace ownership:

- On NVIDIA, read `dlss_trace_status` once before the measured scenario. For
  each DLSS matrix entry, reset and start a bounded trace before its
  qualification block, then stop and read that same owned trace after the
  transition status receipt.
- On AMD, perform one bounded status/reset/start/stop/read capability lifecycle
  before the matrix and require zero DLSS dispatch records.

A missing optional trace action is `unsupported`. On NVIDIA, one capability
receipt plus `n/a (unsupported)` for every per-DLSS trace field satisfies only
the trace-lane requirement and does not make the run incomplete; all DLSS
transitions, statuses, and stabilization aggregates remain mandatory. An
exposed trace action that fails is a required-lane failure. On AMD, retain the
capability receipt and require zero DLSS trace dispatch records. Do not allow
two simultaneous trace owners.

## 4. Run the 25 measured menu transitions

Use the single render-scale stress session armed in section 3 and generate one
unique owner from the exact Build ID and UTC time. Queue one async scenario.
For each canonical matrix entry in ordinal order, append this block:

1. For a DLSS entry, reset and start its bounded DLSS trace.
2. `qualification_begin` with that owner and a unique transition ID derived
   from the ordinal.
3. `{ "wait": 5000 }`.
4. On transition 1 only, start the pre-armed profiler capture exactly as Simple
   COC requires.
5. `qualification_dispatch` with the same owner and transition ID. Set
   `startPerformanceTelemetry: true` only on transition 1 and false thereafter.
   Do not include `cocCellEditorId`.
6. Render-scale `apply` through `communityshaders.renderscale`, using exactly
   the entry's `method`, numeric `qualityModeValue`, and `renderScaleMode` as
   `enabled`. Bind the exact Build ID. For DLSS only, set `dlssPreset: 1`
   (preset K).
7. `qualification_wait` with the same owner and transition ID,
   `expectedCellEditorId: "WhiterunDragonsreach"`, the fixed foveation fixture,
   `milestone: "strict"`, and `timeoutMs: 30000`. Its `target` is the exact
   matrix profile: numeric quality mode and render-scale state, plus
   `dlssProfile: "K"` for DLSS. Omit `fsrRuntime` from every FSR waiter target;
   validate its configured value separately from physical backend evidence.
8. Render-scale `status` with the exact Build ID. Retain the transition-filtered
   preparation trace and full resource-publication telemetry exactly as Simple
   COC requires. For FSR, require `desiredBackend`, `authoritativeBackend`,
   `actualDispatchBackend`, lifecycle backend, stable resource keys, and both
   eye dispatches to converge on one of `fsr_host`, `fsr_runtime`, or
   `fsr4_runtime`. When configured FSR4 falls back, preserve the truthful
   fallback flag and do not classify the coherent FSR3/host backend as a latch
   failure.
9. For a DLSS entry, stop and read its owned bounded trace.

The dispatch receipt is the timing origin immediately preceding the apply.
There must be exactly 25 begin, dispatch, apply, waiter, and status receipts,
exactly one transition-1 profiler capture receipt when that API is selected,
and no measured COC receipt.

Preserve semantic anomalies exactly as Simple COC does. Stop future mutations
only when the scenario aborts or DevBench reports a transport, PID, build, or
required-tool failure. Never replace a failed or missing matrix entry, and
never send a direct recovery apply outside the measured scenario.

## 5. Stop and extract

Immediately after transition 25, apply Simple COC section 5 with these
substitutions:

1. Require the final scene to remain `WhiterunDragonsreach` and preserve the
   final profile expected by matrix entry 25.
2. Read final health, upscaling, render-scale, qualification, profiler, and all
   armed telemetry statuses; then stop only task-owned captures and restore
   only profiler state changed by this run.
3. Retain the complete stress record, all 25 qualification/status receipts,
   all per-DLSS traces or their explicit `n/a (unsupported)` entries, and every
   CPU, GPU, lifetime, presentation,
   resource-publication, preparation-stage, retry, failure, memory, queue,
   profiler, fidelity, and lifecycle field required by Simple COC.
4. Calculate strict stabilization mean and worst frames plus retry totals for
   each method and method/quality combination present in the matrix, plus the
   complete 25-transition assay. Record `n/a` for methods absent from the
   selected matrix. The present-method and complete-assay values are mandatory
   for a completed result.
5. Append one uniquely headed rightmost column to the Simple COC comparison
   ledger. Populate shared identity, timing, telemetry, preparation, fidelity,
   and verdict rows; add menu-specific rows for the matrix and aggregates.
   Mark destination-alternation-only rows `n/a` because this assay performs no
   measured COCs. Parse the CSV and run `git diff --check`; do not build or run
   repository tests.

Report the verdict and print the complete comparison table for the two pinned
references plus the new Simple CSM column. Stop there. Do not begin another
protocol or restore a profile outside the task-owned cleanup above.
