# Simple COC protocol

## Fixed assay

- Running game: Skyrim VR with the player loaded.
- Initial position: `WindhelmExterior01`, followed by one server-owned
  10,000 ms stabilization wait.
- Measured transitions: exactly 20 COCs, odd transitions to
  `WhiterunDragonsreach` and even transitions to `WindhelmExterior01`.
- Pacing: one server-owned 10,000 ms wait before every measured COC.
- Fixture: foveated center `0.3`, vendor dispatch enabled, periphery-TAA
  center `0.3`, periphery TAA enabled, outer scale `0.7`.
- Diagnostics: developer mode active and an `info` or less-verbose CSX log
  level raised to `debug`; an already-more-verbose level remains unchanged.
- Qualification: one strict waiter per transition, 30,000 ms timeout, no
  target profile. VR FPS Stabilizer owns profile selection.
- Scenario: one async DevBench scenario with `continueOnError: false`.
- Setup: `prepare_coc` first and alone; position after core readiness; perform
  profiler proof, telemetry reset, and capture arming only after exact-cell
  positioning; never repeat successful setup.
- Profiler: when `communityshaders.profiler_api` is exposed, prove embedded
  errors abort a scenario, preserve its initial enabled state, and enable it
  before the measured scenario. A `disabled` arm receipt is fatal, but
  profiler readiness never gates the unmeasured positioning COC.
- Output: append one commit-headed column to
  `docs/development/vr-render-scale-comparison-ledger.csv`.

## 1. Bind DevBench and the build

Call DevBench health and require `SkyrimVR.exe`, `vr: true`, a live PID, and a
loaded player. Read the producer through `communityshaders.upscaling_api`
`snapshot`. Preserve the full Build ID, full source commit, source description,
dirty flag, configuration, shader-cache ABI, compiler identity, PID, and port.
Also retain the deployment-bound artifact SHA-256 when runtime metadata exposes
it. Its absence does not block the assay, but it blocks later Ghidra artifact
selection rather than permitting a guess.

As soon as health and the exact Build ID are bound, start one direct
`communityshaders.menu` call with
`{"action":"prepare_coc","expectedBuildId":"<exact Build ID>"}` as the first
stateful call. Require its successful, fully valid receipt before making
another stateful call. Then refresh only the live scenario, console, menu,
inspect, and selected-assay public-API contracts needed to position safely.
Only independent read-only calls may run concurrently in this core group. Do
not call the profiler service, run its negative scenario, or reset, start, or
arm telemetry before positioning. A telemetry-only 503 must not block the unmeasured
positioning COC.

Require `ready: true`, `promptRequired: false`, and `persisted: false`. The
`after` receipt must prove:

- `vr: true` and `inGame: true`;
- `developerMode.active: true`, with logging at `debug` or an already-more-
  verbose level;
- foveated vendor dispatch enabled with center area `0.3`;
- periphery TAA enabled with center area `0.3` and outer scale `0.7`;
- startup-active VR FPS Stabilizer.

The call may idempotently change only developer logging and the runtime
FOV/TAA fixture. It must not save settings or change method, quality, preset,
render scale, or any other Stabilizer-owned policy. A rejected call, missing
fixture field, non-ready receipt, persisted change, or producer mismatch stops
the run.

Before any COC, tell the user that DevBench and the fixture are ready and print
the exact Build ID and source commit. Continue automatically after this update.
Bind every Community Shaders call to that exact Build ID. Fixture setup is
outside the measured window, which begins only at transition 1's atomic
`qualification_dispatch`.

## 2. Position at Windhelm

Run one server scenario containing:

1. `console` with `coc WindhelmExterior01`;
2. a 10,000 ms server wait.

After it completes, require the exact Windhelm editor ID and a loaded player.
Do not count this positioning COC among the 20 measured transitions.

## 3. Arm all relevant render-scale telemetry

Choose exactly one live DevBench transport before the first live call. When the
plugin-provided direct MCP tools are callable, use them exclusively and treat
their exposed tool descriptions as the live schema inventory.
Do not run the bundled controller's `list`, open another loopback session, or
switch transport lanes during the run. The bundled controller may be the sole live lane only when
direct MCP was unavailable before the first live call.

After exact-cell verification, query each required or optional telemetry lane
once through the selected transport. Only independent read-only calls may run
concurrently. Do not repeat core discovery that already returned a complete
receipt and do not perform a global schema refresh.

Do not generate or edit task-local orchestration scripts during live preflight
or baseline setup. Load the installed protocol once, use its fixed actions
directly, and preserve returned receipts under the evidence directory. Evidence
files are not orchestration scripts.

When `communityshaders.profiler_api` is exposed, prefer it over the legacy
profiler tool and complete this measurement-admission gate:

1. Call `registry` and `snapshot` with `contractMajor: 1`, unique
   `clientId`/`commandId` values, and the exact Build ID. Require registry
   `capture.requiresEnabled: true`, snapshot `ok: true`,
   `result.status: "success"`, and `result.available: true`. Preserve
   `result.enabled` as the initial state. These two read-only calls may run
   concurrently.
2. After both reads pass, run one synchronous, one-step scenario alone with
   `continueOnError: false` whose
   only step calls `communityshaders.profiler_api` `start_capture` with
   `contractMajor: 1`, unique client/command identity, and the exact Build ID,
   but omits only the required `frameCount`. Require scenario `ok: false`,
   `aborted: true`, `stepsRun: 1`, step `ok: false`, and embedded error code
   `invalid_field`. This non-mutating proof must pass before any baseline,
   upscaling apply, or measured transition.

Do not perform any profiler readiness wait before positioning. If the first
post-positioning profiler `registry` or `snapshot` read is transient, retry only
that unresolved read on the selected transport within one bounded 10-second
outer budget and return on its first successful receipt; this is never a fixed
delay. On the direct lane, issue direct read-only retries and
do not open a bundled-controller session or call its
`toolAvailable`/`serviceReady` waits. On
the controller fallback lane, one `serviceReady` wait may use
`-TimeoutSeconds 10` and `-MaxTransientRetries 0` for the same read-only action.

If direct health succeeds while a redundant controller attempt returns a
transport error, preserve the controller receipt as a runner-path anomaly and
continue exclusively on the direct lane. Do not start a controller readiness
wait or classify the assay as blocked. If the selected lane itself remains
unavailable, stop before the first baseline, apply, or measured transition and ask
the user. Do not repeat the positioning COC or begin another readiness wait.

Do not call `set_enabled` or `start_capture` during discovery or the negative
proof. When the versioned API is absent, read the legacy profiler status once
and preserve its initial enabled state.

After the negative proof passes, or immediately after discovery when the
versioned API is absent, reset each supported telemetry lane whose contract
defines a reset. Run those stateful reset calls one at a time, require and keep
each receipt, and do not retry a reset that succeeded. Do not start a capture
during reset; CPU and GPU counters start only from transition 1's atomic
dispatch.

Required capture lanes are:

- render-scale stress events and transition metrics;
- strict qualification timing and health receipts;
- CPU performance telemetry;
- GPU performance telemetry;
- DLSS dispatch trace when the producer exposes it;
- texture-lifetime telemetry when the producer exposes it;
- load-presentation probe when it is exposed as a bounded DevBench capture;
- Community Shaders profiler status/timers when available.
- render-target resource-publication telemetry from the same render-scale
  status/qualification observation as each transition.
- bounded render-scale preparation telemetry, including raw events plus all
  admission/early-exit, shader-cache, SSS/SSGI prewarm, DLSS/FSR/FSR4, D3D,
  total, request-to-prepared, and prepared-to-creator timings.

After exact-cell verification, stateful telemetry actions are serialized in a
short ownership sequence immediately before transition 1: start stress, then
each exposed trace, lifetime, and probe capture, then pre-arm the selected
profiler lane. Before arming, require the measurement-admission CPU/GPU reset
receipts to show both captures inactive; do not issue another CPU/GPU reset.
Require and preserve each receipt before the next stateful action. Only
independent read-only schema or status checks may run concurrently;
never fan out `start`, `reset`, or `set_enabled` calls. Do not retry an action that
already returned an ownership receipt.

Pre-arm the selected profiler lane after its preceding stateful receipts:

- For `communityshaders.profiler_api`, call `set_enabled` with
  `contractMajor: 1`, `enabled: true`, unique client/command identity, and the
  exact Build ID. Require `ok: true`, `result.enabled: true`, plus a nested
  snapshot with `status: "success"`, `available: true`, and `enabled: true`.
  Do not call `start_capture` yet.
- Only when the versioned API is absent and the legacy
  `communityshaders.profiler` tool is exposed, call `enable` with the exact
  Build ID, require `enabled: true`, then call `status` and require
  `status.enabled: true`.

Wait for and validate every arm receipt before submitting the measured
scenario; profiler pre-arming is not a step hidden inside that submission. Do
not run another discovery or reset cycle. Transition 1 must set
`startPerformanceTelemetry: true`, which starts CPU and GPU telemetry on the
same dispatch frame as the first measured COC. Later transitions set it to
false.

Do not call memory trim, apply an upscaling profile, change a preset, or enable
an unbounded screenshot/readback stream. Those alter the assay rather than
measure it. If a named optional lane is absent, record `unsupported`; if it is
present but fails to arm, stop rather than silently downgrade the run.

## 4. Run the measured scenario

Start a fresh render-scale stress session. Generate one unique owner from the
Build ID and UTC time. For transition IDs 1 through 20, append this block:

1. `qualification_begin` with the exact owner and transition ID;
2. `{ "wait": 10000 }`;
3. On transition 1 only, when `communityshaders.profiler_api` was selected,
   call `start_capture` with `contractMajor: 1`, `frameCount: 300`,
   `clearHistory: true`, unique client/command identity, and the exact Build
   ID. Require `ok: true`, a nonzero `result.captureId`, and
   `result.state: "running"`;
4. `qualification_dispatch` with `cocCellEditorId` set to the odd/even
   destination; use `startPerformanceTelemetry: true` only on transition 1;
5. `qualification_wait` with the same owner/transition, exact expected editor
   ID, fixed foveation fixture, `milestone: "strict"`, `timeoutMs: 30000`, and
   no `target` field;
6. render-scale `status` with the exact Build ID. Retain its bounded
   `status.preparation` trace, filtered to the transition epoch returned by the
   waiter. This read occurs after strict completion and is not another waiter.

The profiler API step is omitted when that API was absent. Its `disabled` or
other `ok: false` result must abort the scenario before
`qualification_dispatch`; the preflight negative probe proved that this
installed DevBench honors that boundary. Never reinterpret exposed-but-
disabled as `unsupported` and never dispatch transition 1 after a failed
profiler step.

From the strict receipt's render-scale observation, extract current,
current/completed/published generations, expected/published width and height,
`complete`, `deferredSetupAcknowledged`, `deviceMatches`, and `contextMatches`.
Preserve missing fields as missing evidence; do not infer them from profile or
stereo telemetry.

Preserve the preparation ring/session/QPC metadata and original event objects,
including identity, generations, D3D device, profile, dimensions, frames,
occurrences, outcome/reasons, QPC duration, bytecode compilation, and D3D
creation. Summaries may aggregate those records but must not replace them.

The dispatch itself issues the only COC for that transition. Never add a
separate console COC. An exact block therefore produces one timing origin, one
COC, one strict result, and one post-wait telemetry snapshot. There must be
exactly 20 dispatch receipts, 20 waiter receipts, and 20 preparation status
receipts, plus exactly one profiler API capture receipt when that API was
selected.

Preserve every result, including semantic anomalies. A successful waiter may
report an unsatisfied milestone; that is measured evidence. Stop future COCs
only when DevBench aborts the scenario or reports a transport, PID, build, or
required-tool failure.

## Frozen-image forensic branch

When an aborted scenario leaves the game frame counter stationary and
main-thread calls time out, stop all future COCs. Make one ownership-guarded
cleanup attempt, retain any off-thread status that still responds, and do not
restart, terminate, suspend, or resume Skyrim. The `simple coc` trigger alone
does not authorize debugger work. This branch is explicit-only: enter it only
after the user says `frozen Ghidra` or otherwise explicitly requests Ghidra
analysis of the current frozen session. A freeze or main-thread timeout by
itself must never launch, install, open, import into, or attach Ghidra.

Before reading any affected log, preserve and verify it under the configured
log archive policy. If Ghidra analysis is authorized, invoke the bundled
`scripts/Start-FrozenGhidra.ps1` once with `-UserAuthorized`, the user's exact
authorization statement, the bound Build ID and artifact SHA-256, the exact
active MO2 `modlist.txt` and mods directory, and the trusted Community Shaders
repository root. Pass configured Ghidra/Java/project paths only when needed by
the managed controller.

The helper performs one identity decision. It resolves the enabled physical
`CommunityShaders.dll` provider from the exact profile without reading the MO2
virtual DLL, verifies the adjacent `CSX.BuildManifest.json` and artifact through
Community Shaders' canonical provenance verifier, and requires the expected
Build ID, SHA-256, and byte length. Build ID and artifact SHA-256 are the
cryptographic producer identity; source description and branch names remain
display evidence and never select a candidate.

The same helper derives `CSX-<16 Build-ID hex>-<16 artifact-hash hex>` and calls
the managed Ghidra controller with that project name and physical DLL. Require
its combined receipt to report `ok: true`, the exact project name, artifact
path/hash, and `programMatchesExpectation: true`. A `starting` state means
analysis is still initializing; retain the receipt and do not attach or choose
another program. Any identity mismatch blocks forensics without changing the
game.

Use the already-registered CDB path with `-pvr` for a non-invasive,
non-suspending live stack snapshot; Ghidra maps its addresses through the
verified program. Preserve the bound PID, module base, runtime address/RVA,
main-thread OS ID, stack, source line, relevant optimized locals, lock
ownership, raw debugger output, and helper receipt. Do not arm breakpoints or
alter target state. If the COC dispatch exists but no destination-cell or
render-scale event follows, classify the transition as interrupted before
render-scale measurement and never synthesize timing or retry values.

## 5. Extract and finalize

After transition 20, while the exact control plane remains responsive:

1. Read health, final scene, upscaling snapshot, render-scale status,
   qualification status, profiler status, and all armed telemetry statuses.
   For the versioned profiler API, read `capture_status` and `timers` with
   `contractMajor: 1`, unique client/command identity, the exact Build ID, and
   the exact transition-1 capture ID; preserve incomplete or failed capture
   state.
2. Stop CPU, GPU, stress, trace, texture-lifetime, probe, and profiler captures
   only with the ownership guards returned when they started.
3. Restore the profiler enabled state only when this run changed it. For the
   versioned API, call `set_enabled` with `contractMajor: 1`, `enabled: false`,
   unique client/command identity, and the exact Build ID only when the initial
   snapshot was disabled; require a successful disabled snapshot. Apply the
   equivalent guarded legacy `disable` only when its initial status was
   disabled.
4. Retain the complete stress record, all 20 qualification results, trace and
   lifetime records, and the final health snapshot.

For Dragonsreach, Windhelm, and overall, calculate strict stabilization mean
frames and worst frames from the 20 waiter receipts. Sum recoverable retries
and classify their reasons. Also extract:

- fixed waits, scenario elapsed time, and harness overhead;
- presentation, cleanup, and strict timing per transition;
- hard failures, OOM, device loss, fidelity mismatches, lifecycle failures,
  and backend deferrals;
- session/lifetime stretch observations, completed episodes and frames,
  maximum stretch frames and QPC duration, vendor failures, and bounds
  fallbacks;
- render/output dimensions, scale, profiles, both-eye validity, lifecycle,
  latch/contract generations, full resource-publication telemetry, and final
  cell;
- per-transition and session preparation-stage events and timings, including
  ring overwrite/coalescing evidence;
- memory pressure, process-private growth, trims, retirement/fence state, and
  pending cleanup;
- CPU queue hold/wait metrics, strong-packet counters, GPU capture counters,
  trace results, texture-lifetime results, probe results, and profiler timers.

Stabilization means, worst frames, and retry totals are mandatory. If any is
missing, classify the run as interrupted and do not append a completed CSV
column.

## CSV contract

Read `docs/development/vr-render-scale-comparison-ledger.csv`. Keep `metric` as
the first column and never replace the pinned main-VR PrePR19 or RC166 columns.
Append the new run as the rightmost column. Use the full source commit as the
header; if that commit already exists, use
`<full-commit>__<yyyyMMddTHHmmssZ>` so CSV headers remain unique while the
commit stays visible at the top.

Populate every existing metric. Add new metric rows for newly emitted harness
data rather than discarding it, filling earlier columns with `n/a`. Use
`unsupported` only for a lane the loaded producer does not expose and `n/a`
only for information the producer genuinely did not emit. Include the full
Build ID, source description, dirty state, fixture, scenario identity, and
verdict. Edit the CSV with `apply_patch`, parse it after editing, and run
`git diff --check`. Do not build or run repository tests.

Add rows for preparation availability, retained/overwritten/coalesced counts,
and each named stage's record/occurrence count plus duration, bytecode, and D3D
timing summaries. Keep the complete raw preparation events in run evidence;
the CSV is a comparison view, not their replacement.

Finally, tell the user the run verdict and print the complete comparison table
for the two pinned references plus the newly appended run.
