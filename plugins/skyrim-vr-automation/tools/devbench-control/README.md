# DevBench Control

## Bounded scene-light reads

Explicit `inspect {kind:lights,scope:scene,limit:<integer 1..64>}` admits only
the typed native16dac scene schema. Other selectors/radius/extra arguments are
not covered by this adapter. Read-only identity still requires the exact listener
and answering process; it never grants mutation identity. Exact source/list/budget
metadata, count/request/array consistency, finite light geometry and typed owner/
lineage fields qualify the bounded read. Unknown fields, error objects, type or
source drift refuse. Raw content remains unchanged.

`completionBasis:bounded-read-only` proves a schema-qualified observation only.
`observedSubsetComplete` follows the native truncation/budget/source evidence;
partial reads remain typed partial evidence. `wholeSceneCoverageProven` and
`visibleIlluminationProven` always remain false. Renderer membership, distance
order and source completeness are not evidence of static/visible illumination.
The pure exported classifier makes no calls or mutations; a later offline
classification never rewrites old failed controller output or replaces answering
runtime and non-error MCP provenance. Missing current schema refuses, not replay.


For captured-exec window IDs, immutable guarded reads and loss/truncation
admission, see [CONSOLE-WINDOWS.md](CONSOLE-WINDOWS.md). This qualifies evidence,
not the command's desired game effect; never replay an uncertain capture.

## Fixed-AE temporal baseline

Use `colour-baseline-window` for the narrowly typed, single-condition 1..16
capture baseline in [COLOUR-BASELINE-WINDOW.md](COLOUR-BASELINE-WINDOW.md).
It pins actual admitted AE/HDR, never writes the colour contract, requires actual
submitted reset/jitter/delta telemetry, and reuses finite same-session calendar,
probe custody, compiler/identity, burn-in and spacing guards. The total20..180s
budget includes service-owned cleanup; partial coverage is not scientific PASS.
The baseline-only Boolean `captureReadBrackets` opt-in adds sequential camera,
scene/time and bounded scene-light observations before arm/after completion on
that same session. It retains native generation association and ordered read
bounds, NOT atomic rendered-frame equivalence or simulation freeze. See the
baseline contract for unavailable/truncated coverage and immutable receipts.
It reserves the final3s within that budget for fractional-deadline MCP session
closure and terminal journal/in-memory output. Expired closure/journal admission
is explicit and unverified, not a new timeout. See the baseline guide for the
cooperative local-I/O boundary and separately retained restoration proofs.

## Typed finite colour measurement

Use `colour-window` only for the separate finite FSR autoExposure on/off/on
experiment described in [COLOUR-WINDOW.md](COLOUR-WINDOW.md). It retains one MCP
session and native calendar custody, fixed HDR input, exact revision/build CAS,
successful per-eye FSR4 dispatch settlement and ten owned stage-eye pages per
capture. Compiler/identity/partial-capture/calendar/probe/session cleanup outcomes
remain distinct. This does not broaden the read-only `calendar-window` allowlist,
set quality or render scale, take ownership from the live experiment, or qualify
scientific colour. No mutation replay or second transport lane is permitted.

## Finite same-session calendar observation

`calendar-window` is a bounded ownership composition in this controller, not
a second DevBench transport or a general scenario/mutation wrapper. Select the
controller MCP lane only when direct MCP is unavailable for that workflow
before its first live request (direct-only protocols remain direct-only). It
opens exactly one actual MCP session, discovers the native
calendar schema and complete runtime/artifact identity, reads fresh status,
copies the exact source binding into one finite hold, brackets 1..16 qualified
read-only observations with current calendar state, then releases the original
exact lease and verifies fresh prior-rate restoration before session close.
The hold's captured values—not an earlier status's date—are authoritative.

```powershell
.\Invoke-DevBenchControl.ps1 calendar-window -RuntimePath '<exact-runtime.json>' `
  -CalendarOwner '<task-owner>' -CalendarHoldMilliseconds 60000 `
  -CalendarObservationsJson '[{"tool":"inspect","arguments":{"kind":"scene"}},{"tool":"camera","arguments":{"action":"get"}}]' `
  -MaxTransientRetries 0 -TimeoutSeconds 60 -EvidenceDirectory '<owned-evidence>'
```

Supply build/artifact expectations as for other ownership-bearing calls. The
total invocation budget reserves its final 15 seconds for bounded same-session
cleanup. Hold maximum is 300000 ms; there is no renewal. Late responses fail
their phase deadline. Lost/already-started hold responses are reconciled once
by the same session and hold command ID: no replay, replacement session, REST
downgrade, or unrelated lease adoption. An absent/failed cleanup proof is
explicitly indeterminate. A failed observation may still have separately
verified restoration; it never becomes a successful observation window.

Cell drift invalidates observation continuity, but cleanup can independently be
verified in a different cell. Release still uses the original exact `lease.binding`
and lease ID on the same actual MCP session, with a distinct release command ID.
Native restoration must positively succeed after its private SameStorage/owned-zero
check. Both the release receipt and a fresh status must preserve process session,
PID, load generation and all six global IDs, retain the exact original lease and
captured rate, and show no outstanding custody and the restored prior rate; fresh
`lastTransition` must also affirm restoration with the same exact reason as the
release receipt. Supported positive reasons are only `released`, `expired`, and
`scene_lost`: native Tick may already have restored and retired the original
lease before explicit release, which then returns that same result without a
second write. A reason by itself never proves restoration; every custody and
fresh-readback guard still applies. Only the current contextual cell may
differ for cleanup proof. No current-binding substitution, foreign-rate overwrite,
generation adoption, lease disappearance inference or automatic retry is permitted.
Raw release/status remain evidence; public IDs do not expose or replace native
storage-address checks. Offline proof is not a live restoration guarantee.

This first interface admits only existing allowlisted non-mutating reads. It
does not start capture, arm probes, change quality/weather/physics, save, jump
time, or promise an atomic rendered frame or invariant lighting. Experiment
owners retain calibration and scientific acceptance. Native expiry needs a
serviced main thread; disconnect/crash is not verified restoration. Closing the
MCP session is separately reported, never substituted for calendar cleanup.
Source/offline validation does not qualify native runtime operation.

Run `Test-CalendarObservationWindow.ps1` for the finite offline RPC negatives
and public production-entry refusal tests.

## Bounded compiler readiness after an accepted load

`playerLoaded` proves the current loaded cell, not compiler initialization.
After the separately accepted load and exact-cell `playerLoaded` barrier, use
`Invoke-DevBenchControl.ps1 wait -Condition compilerHealthy` on the already
selected controller lane, with the same exact runtime/artifact/build pins,
an explicit `-TimeoutSeconds` budget and `-MaxTransientRetries 0`. It takes only
fresh shader snapshot reads; it never dispatches or repeats a load, camera
change or other target action. No `-Tool`, `-ArgumentsJson`, or identity skip
is accepted for this condition.

Only `COMPILER_HEALTHY_AT_SNAPSHOT` completes the barrier. Zero tasks remain
`COMPILATION_UNPROVEN`, not a compile failure; pending initialization/compilation
and recognized native read-unavailable states may be observed again within
the original absolute deadline. Actual failures/history, disabled custom shaders,
malformed, replayed, stale, foreign or changed-process/service evidence refuse
readiness. The receipt retains the last guard, exact process/build identity,
attempts and elapsed time; a timeout retains the unproven diagnosis without
extending its budget. No late positive read is accepted after the deadline.
If less than one second remains for another request, the barrier stops with
its last qualified diagnostic instead of inventing a new counter snapshot.

Readiness is compiler-snapshot scoped, not proof of correct pixels, full rendering
initialization, a stable scene or an atomic frame join. Continue to use
`-RequireCompilerHealthy` on the subsequent target so fresh before/after
boundaries bracket that target; a successful wait is not a reusable waiver.
On an established direct MCP lane, do not open this controller as a second
transport: use fresh exact shader snapshots and the exported pure classifier
in that same connection, with the experiment's fixed deadline and verified
runtime/service identity. Calibration remains the experiment owner's work.

## Current-session shader compiler admission

A successful API/readiness call is not healthy rendering. The existing native
`communityshaders.shader_api` `snapshot` contract (CSX ad8,
`csx.shader` 1.0/schemaRevision1) exposes actual compilation task counters,
current failed shader entries and bounded recent failure diagnostics. Auto-Tools
qualifies that exact typed request/receipt with matched command, producer and
service-session identity. Ordinary calls expose `semantic.compilerHealth` but
remain `completionBasis:read-schema-only`: even a valid failed/pending snapshot
is a successful diagnostic read.

On an already-selected controller lane, add `-RequireCompilerHealthy` to
`call` for a healthy image/performance evidence boundary. Keep exact
`-RuntimePath`, `-ArtifactPath`, `-ExpectedArtifactSha256`,
`-ExpectedBuildId` and the accepting `-ExpectedRuntimeIdentityJson`.
The flag requires complete verified listener/process/build/artifact identity;
it refuses identity bypasses, waits/list commands and expected-error overrides.
It discovers the current shader snapshot input schema and reads that service on
the **same actual MCP session/selected transport** as the target call, with new
command IDs (no idempotent replay). Failure, pending work, disabled custom
shaders, zero-task initialization, malformed/foreign/stale receipts or unproven
identity refuse the target **before dispatch**.

```powershell
# Read-only current-session admission; this does not launch or repair anything.
.\Invoke-DevBenchControl.ps1 call -Tool communityshaders.shader_api `
  -ArgumentsJson '{"contractMajor":1,"clientId":"mapping","commandId":"<fresh-uuid>","action":"snapshot","expectedBuildId":"<exact-build-id>"}' `
  -RuntimePath '<exact-running-runtime.json>' `
  -ArtifactPath '<exact-deployed-CommunityShaders.dll>' `
  -ExpectedArtifactSha256 '<expected-sha256>' -ExpectedBuildId '<exact-build-id>' `
  -RequireCompilerHealthy -MaxTransientRetries 0 -TimeoutSeconds 30 `
  -EvidenceDirectory '<owned-retained-evidence>'
```

For an admitted target, a second fresh snapshot brackets the call. Both
boundaries must pass and retain the same producer/service session/state revision
and task/source-compile/cache-hit counters. Native diagnostics and raw replies
remain in `data.compilerGuard`, `compilerGuardAfter`, `compilerWindow`;
the original target semantic receipt is retained as `data.targetSemantic`.
Only an admitted bracket **and** a successful target set
`data.healthyEvidenceAdmitted:true`. A failed post-boundary retains the
completed target/evidence, reports invalidation, and never replays, cancels,
clears caches, rebuilds, relaunches or alters the profile.

Native main-thread read timeout/service unavailability is `READ_UNAVAILABLE`,
not a known shader compilation failure. Retain the error and accept no counter
values. Cold compilation may legitimately be making useful progress while that
read is unavailable: healthy admission fails, but the gate does not stop or
restart compilation. The experiment owner retains its separately bounded startup
budget and current logs; this admission check never extends it.

Compiler status is scoped: `COMPILER_HEALTHY_AT_SNAPSHOT` is not proof of
correct pixels, complete Data-root/include/provider closure, future areas,
performance neutrality or scientific acceptance. `recentFailures` contains
history with epochs; absent current failure counts cannot silently clear that
history. Nonempty history fails healthy admission conservatively and remains
diagnostic evidence. Independently preserve exact current log identity,
compilation completion/failure records and stereo inspection. A window does not
prove every intermediate frame, and an asynchronous screenshot/sequence start
is **not** capture completion: guard its owned final request/status as well,
retain the start/end boundaries, and classify intervening failures diagnostically.
Timing/CPU/GPU measurements still require the separate
`-RequirePerformanceNeutral` guard.

On the direct MCP lane, call the exact exposed shader snapshot with a fresh ID;
use exported `Get-DevBenchShaderCompilerHealth` and
`Test-DevBenchShaderCompilerWindow` offline on those untouched receipts and
match them to the direct connection's separately verified current identity.
Do not open the bundled controller as a second lane. Parse retained native JSON
with `ConvertFrom-Json -DateKind String` on PowerShell 7.5+ to retain UTC strings.
The pure classifier proves schema/compiler state only; it cannot establish
current runtime identity or freshness by itself. Explicit diagnostic capture
remains permitted on the existing lane, but **no** successful unguarded capture,
API/readiness pass or failed compiler boundary authorizes healthy promotion.

Run `Test-ShaderCompilerHealth.ps1 -FixtureRoot '<managed-general-workPath>'`.
Its source-derived fixtures and test-owned loopback production entry prove
positive admission, failure/pending refusal with zero target dispatch, changed
post-boundaries with preserved target receipt, no replay and exact session
cleanup. They are offline validation, not a live ca3/ad8 health qualification.

## Finite same-session calendar observation

`calendar-window` is a bounded ownership composition in this controller, not
a second DevBench transport or a general scenario/mutation wrapper. Select the
controller MCP lane only when direct MCP is unavailable for that workflow
before its first live request (direct-only protocols remain direct-only). It
opens exactly one actual MCP session, discovers the native
calendar schema and complete runtime/artifact identity, reads fresh status,
copies the exact source binding into one finite hold, brackets 1..16 qualified
read-only observations with current calendar state, then releases the original
exact lease and verifies fresh prior-rate restoration before session close.
The hold's captured values—not an earlier status's date—are authoritative.

```powershell
.\Invoke-DevBenchControl.ps1 calendar-window -RuntimePath '<exact-runtime.json>' `
  -CalendarOwner '<task-owner>' -CalendarHoldMilliseconds 60000 `
  -CalendarObservationsJson '[{"tool":"inspect","arguments":{"kind":"scene"}},{"tool":"camera","arguments":{"action":"get"}}]' `
  -MaxTransientRetries 0 -TimeoutSeconds 60 -EvidenceDirectory '<owned-evidence>'
```

Supply build/artifact expectations as for other ownership-bearing calls. The
total invocation budget reserves its final 15 seconds for bounded same-session
cleanup. Hold maximum is 300000 ms; there is no renewal. Late responses fail
their phase deadline. Lost/already-started hold responses are reconciled once
by the same session and hold command ID: no replay, replacement session, REST
downgrade, or unrelated lease adoption. An absent/failed cleanup proof is
explicitly indeterminate. A failed observation may still have separately
verified restoration; it never becomes a successful observation window.

Cell drift invalidates observation continuity, but cleanup can independently be
verified in a different cell. Release still uses the original exact `lease.binding`
and lease ID on the same actual MCP session, with a distinct release command ID.
Native restoration must positively succeed after its private SameStorage/owned-zero
check. Both the release receipt and a fresh status must preserve process session,
PID, load generation and all six global IDs, retain the exact original lease and
captured rate, and show no outstanding custody and the restored prior rate; fresh
`lastTransition` must also affirm restoration with the same exact reason as the
release receipt. Supported positive reasons are only `released`, `expired`, and
`scene_lost`: native Tick may already have restored and retired the original
lease before explicit release, which then returns that same result without a
second write. A reason by itself never proves restoration; every custody and
fresh-readback guard still applies. Only the current contextual cell may
differ for cleanup proof. No current-binding substitution, foreign-rate overwrite,
generation adoption, lease disappearance inference or automatic retry is permitted.
Raw release/status remain evidence; public IDs do not expose or replace native
storage-address checks. Offline proof is not a live restoration guarantee.

This first interface admits only existing allowlisted non-mutating reads. It
does not start capture, arm probes, change quality/weather/physics, save, jump
time, or promise an atomic rendered frame or invariant lighting. Experiment
owners retain calibration and scientific acceptance. Native expiry needs a
serviced main thread; disconnect/crash is not verified restoration. Closing the
MCP session is separately reported, never substituted for calendar cleanup.
Source/offline validation does not qualify native runtime operation.

Run `Test-CalendarObservationWindow.ps1` for the finite offline RPC negatives
and public production-entry refusal tests.

## Phase-aware genuine New Game

The existing `call -Tool game` interface supports the native DevBench
4407a937 New Game contract without a second wrapper. Use exact JSON:
`{"action":"newGame","phase":"inspect"}`, then one request with
`phase:request` and a fresh UUID `requestId`, and one confirmation with the
same ID, `phase:confirm` and Boolean `confirmNewGame:true`. Request/confirm
require a ready/retained `FreshGame` workspace manifest and full runtime
identity; `MainMenuOnly`, `VerifiedFixture`, absent or unknown policies refuse.
Known-ID inspection uses `phase:inspect,requestId:<same-id>` and requires a
matching receipt rather than accepting a general menu snapshot.

Inspection qualifies typed menu state, including valid not-ready or closed
menus; callers must inspect `semantic.readyToRequest/readyToConfirm` before
dispatch. A staged request returns `completionBasis:staged-request`; a
confirmed dispatch returns `completionBasis:dispatch-only`. Neither proves
game initialization. Observe expected character creation and player/cell state
separately. Failures/expiry, malformed fields, foreign IDs and explicit errors
remain failures, even beside positive generic flags. Sticky unresolved
dispatch is retained with its exact ID and blocks fresh requests; do not replay
or infer non-execution from menu changes or elapsed time. Transport failures
after mutation dispatch remain indeterminate and are never retried.

Select one transport before this workflow's first call. If a complete direct
catalog's `game` action enum omits `newGame`, a separately selected supported
controller-only workflow may bind the explicit runtime/build/artifact and
discover the fresh typed schema through `list`. This pre-call unavailable-action
selection is not permission to switch after an uncertain call or tunnel through
`scenario`. Direct-only protocols remain direct-only. Missing current schema
means `toolSchemaUnresolved` with no dispatch, not a game/VR restart. Source
support does not imply the installed cache or host catalog has been refreshed.

Runtime `inspect health` has its own typed read contract. A non-error plain
health object requires positive bounded integral PID/port, non-empty executable,
integral frame/task counters and Boolean VR state; it need not invent a generic
`ok` marker. Explicit negative/malformed health still fails. Existing listener,
runtime metadata, executable, producer/build and artifact guards remain required.
The invocation journal retains the raw MCP result/text, parsed health and typed
qualification under `identityHealthProbe` before identity admission, including
failed health. This is diagnosis evidence, never permission to bypass identity
checks or attribute a manually launched process to an old MO2 session.
The health classifier is independent of generic action-classifier extensions:
outcome flags must be actual Booleans, status/code fields must be supported
typed outcomes, and non-empty `error`/`errors` take precedence over affirmative
markers. Incomplete legacy identity requires an explicit typed affirmative
marker; retryability alone is never success. A decoded MCP `isError` result is
retained and rejected even if its content otherwise looks like valid health.
`identityHealthFailedProbe` retains the last failed decoded probe when a later
successful health check replaces `identityHealthProbe`. Transport failure before
a decoded result exists remains a transport diagnostic, not a fabricated probe.
Bounded waits preserve typed health failure classification through session open
and identity refresh. Only classified transient failures may rebind, after
successful cleanup of the prior MCP session; malformed, guarded, terminal and
unknown failures cannot be made retryable by message text.

## Current native read contracts

Exact `communityshaders.menu {action:status}` qualifies one typed native
action/status/producer receipt, empty path and explicit null delegatedRequest.
Core menu/overlay/scene flags remain Booleans, counters unsigned telemetry and
placement values finite numbers, with a positive scale. A disabled/closed menu
is a valid observation; it is not interaction failure or proof of readiness.
Producer/build/source/ABI fields are retained and optional expectedBuildId must
match. Explicit errors, foreign/malformed/multiple receipts and mutation fields
fail. No synthetic generic `ok` is inserted into the original payload.
`semantic.qualifiedMenuStatus` is **read-schema-only**, not calibration,
visibility, rendering, setting/save success or deployment qualification.
Only exact status enters this adapter; mutation/read admission is not broadened.

Exact `input {action:capabilities}` accepts only the complete native
`devbench.input` 2.0 capability payload: ready/available Boolean keyboard v1
and tracked-set v1.1, all 102 canonical key/scancode bindings,
declared action sets, bounded positive integral limits, atomic hmd/left/right
devices and exact ownership/encoding/lifecycle metadata. Missing, foreign,
multiple, unready or malformed payloads fail even with a generic success flag.
`semantic.qualifiedInputCapabilities` is provided only after qualification;
capture uses that projection and keeps the untouched raw envelope. This does
not qualify any input mutation, recording start or observed physical pose.

Exact `communityshaders.fsr_color_contract {action:status}` accepts the native
typed requested flags/revision, both context states/generations, the successful
dispatch and two eye-dispatch records, producer identity and source-contract
flag. Optional `expectedBuildId` must match the producer. Invalid dispatch
sharpness/sharpening/QPC fields must be explicit nulls; valid dispatches require
finite numerical sharpness, positive dimensions/generations/serial/QPC and a
supported native FSR path. No generic `ok` marker is required. Explicit errors
still veto acceptance. Set receipts and mutation parameters do not qualify as
status. Acceptance is **read-schema-only**, not proof of matching requested
flags, current synchronized eyes, HDR admission, vendor convergence or runtime
artifact verification. Those postconditions belong to the experiment.

Exact `communityshaders.colour_pipeline_probe {action:status}` qualifies native
schema3 copied status with source-bound states, producer/build binding, uint64
generation/revision/QPC/payload counters, ten stage-eye slots, 1 GiB staging
payload ceiling and the 15-second native deadline. Initial idle zero generation
is valid; reset may leave a nonzero idle generation. Idle cleared fields and
active/completed slot/QPC consistency remain required. `cpuFrame` is explicit
null or positive uint32; schema3 scene/submission epochs must be explicit null,
because the producer withholds that attribution. Zero QPC is a native fallback,
not proof of timing quality. No generic `ok` marker is required; explicit failure
evidence still vetoes acceptance. `semantic.qualifiedColourProbeStatus` is
available only after qualification and the raw envelope remains untouched.
Only explicit exact status and optional `expectedBuildId` arguments are admitted;
arm, reset and capture-page read contracts are not extended. A successful read
is **read-schema-only**, not capture acceptance, sample quality, performance
neutrality, vendor convergence, epoch correlation, HDR admission or runtime
artifact verification. Native status may service its existing expiry policy;
the controller does not arm, reset or change that policy.

`upscalingStable` still requires genuinely revision-correlated API and
render-scale observations. Native f362 `renderscale/status` lacks the required
`status.upscalingSnapshot`; its physical controller revision is not the API
state revision. That combination fails closed, even when native frames advance
and the effective profile matches. Do not substitute controller revision, drop
the correlation check, or replay a mutation/wait to manufacture qualification.
Repair requires a native correlated snapshot or a proven same-runtime read
bracket; neither is claimed by these two read adapters.

Explicit `camera {action:get}` is read-only and requires one complete typed
observation: finite JSON position/pitch/yaw numbers, supported exact POV/backend,
uint32 stateId, and Boolean freeCam/freeCamOwned without contradictory ownership.
Unavailable/incomplete camera state fails; get qualification never applies to
drive, setPov or freecam. Calibration remains the experiment owner's job.

Render-scale `status.vendorWorkGate.state` is native uint64 packed telemetry,
not a string outcome or proof of stability. Only that exact path on an exact
status read receives numeric qualification; malformed types, explicit errors,
foreign actions and multiple payloads remain failures. Raw state is unchanged.

Screenshot capabilities accept the native Boolean-ok, csx.screenshot-major-1
contract envelope with schema/limits inside result, or the existing exact flat
v1 capability receipt. A successful classifier exposes qualifiedCapabilities
without replacing the raw envelope. Failed/foreign/malformed/multiple receipts
never expose a qualified projection.

The exact captured console query `getini "fVrScale:VR"` has an execution-only
receipt adapter (completed true, queued false, capturing true, exact command).
It does not establish a scale value. `console read` qualifies one bounded,
lossless fenced string-array receipt with count agreement, both markers and
non-timeout evidence; the print route also requires its active hook and zero
drops. Marker diagnostic text is retained. The caller must parse the actual
INISetting line, validate its value and relate it to the scene; neither console
adapter proves the command's desired game outcome or broadens other exec calls.

`Invoke-DevBenchControl.ps1` lists and calls the tools exposed by a running
CSX DevBench server. It prefers streamable-HTTP MCP and negotiates the REST
`/api/tools` and `/api/tool/<name>` facade when an older host returns 404 for
the invocation's first sessionless `/mcp` initialization. Once MCP succeeds,
that capability remains proven for the invocation: a later replacement
initialization cannot downgrade to REST and returns
`mcp-capability-regression` instead. Supply runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`; no machine-specific path is compiled into the
client.

For source-bound native colour-probe sample addressing, see
[COLOUR-PROBE-COORDINATES.md](COLOUR-PROBE-COORDINATES.md). Sample pixels are
crop-local; source texture origins do not belong in staging byte offsets.

```powershell
.\Invoke-DevBenchControl.ps1 list -RuntimePath 'C:\Path\To\runtime.json'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}' -RequireSuccess
.\Invoke-DevBenchControl.ps1 call -Tool 'measurement_tool' `
  -ArgumentsJson '{"action":"status"}' -RequirePerformanceNeutral
.\Invoke-DevBenchControl.ps1 wait -Condition noBlockingMenu -TimeoutSeconds 30
.\Invoke-DevBenchControl.ps1 wait -Condition noBlockingMenu `
  -DismissBlockingMenus InventoryMenu -MaxMenuDismissals 1 `
  -MinimumMenuStableSeconds 5 -TimeoutSeconds 30
.\Invoke-DevBenchControl.ps1 wait -Condition upscalingStable `
  -ExpectedCell WindhelmExterior01 -TimeoutSeconds 120 `
  -StableSamples 2 -MinimumStableFrameAdvance 5
.\Invoke-DevBenchControl.ps1 wait -Condition playerLoaded `
  -ExpectedCell WhiterunBreezehome -TimeoutSeconds 120
.\Invoke-DevBenchControl.ps1 wait -Condition mainMenuReady -TimeoutSeconds 30
.\Invoke-DevBenchControl.ps1 wait -Condition toolAvailable `
  -Tool communityshaders.profiler_api -TimeoutSeconds 600 `
  -ProgressLogPath C:\Evidence\CommunityShaders.log
.\Invoke-DevBenchControl.ps1 wait -Condition serviceReady `
  -Tool communityshaders.upscaling_api
```

The client communicates only with the loopback endpoint and reports structured
JSON. By default it binds the endpoint to the owning listener PID and DevBench's
off-thread `inspect health` identity before returning. Runtime metadata may add
`pid`/`processId` and `exe`/`executable`; supplied values become strict
expectations. An executable supplied as a canonical path is compared exactly
with the listener process path and by filename with DevBench health, whose
public contract reports a basename. Two supplied canonical paths must still
match exactly. Pass `-EvidenceDirectory` to preserve this binding with the run.
Each invocation writes a uniquely named binding receipt, so parallel calls do
not overwrite one another. Use `-EvidenceLabel` to give that receipt a stable
human-readable label within the unique filename. The receipt records whether
the exact call used `mcp` or `rest`; a fallback mutation keeps the same
indeterminate/no-replay safety rule as MCP.
The controller also persists an invocation journal before dispatch. It records
the requested tool and arguments, dispatch boundary, last verified runtime
identity, transport retries, and terminal result. If the target exits during a
synchronous call, the failed result returns `invocationEvidencePath` instead of
discarding the last known request boundary. Without an explicit evidence
directory these journals use the local Skyrim VR automation evidence root.
If failure occurs after dispatch, the result also reports `dispatchReached`,
`acceptedDataRetained`, and `indeterminate`. An accepted response retained
before a later evidence-write failure remains in `data` and in any recoverable
invocation journal; an unobserved mutation result remains explicitly
indeterminate rather than being converted to an ordinary failure.
Once a call has completed, a later journal-write failure never replaces its
payload or semantic outcome. The returned result instead carries
`evidenceWarnings` and `evidenceJournalFinalized: false`, alongside the final
`sessionCleanup` receipt. If a requested tool is absent from the authoritative
catalog, the controller reports `tool-unavailable` without dispatching it; a
requested performance-neutrality boundary is still measured and retained.
When available, add `buildId`, `artifactPath`/`dllPath`, and
`artifactSha256` to runtime metadata (or pass their explicit parameter
equivalents). The controller queries the CSX registry bridge and hashes the
deployed DLL, binding source build, physical artifact, endpoint, and process in
one evidence record.

Mutation-capable calls require that complete identity. The controller keeps a
strict, action-sensitive allowlist for read-only inspection: built-in
`inspect` kinds, `menu list`, `record status`, and tracked-input
observation/status. Those calls may proceed when listener and process identity
are verified even if build or deployed-artifact provenance is unavailable.
They do not broaden the mutation boundary.

Every `call` applies semantic qualification: `ok` is true only when both the
transport and the action-specific semantic contract succeed. `transportOk`
reports the transport result independently. `-RequireSuccess` additionally
requests an explicit diagnostic when a response has no recognized semantic
outcome; it does not relax or enable the semantic gate. For example, both calls
below return `transportOk=true` and `ok=false` when the transport succeeds but
the payload is semantically unverified; the second also requires the explicit
unverified-outcome diagnostic:

```powershell
& $tool call -Tool inspect -ArgumentsJson '{"kind":"unknown"}' -RuntimePath $runtime
& $tool call -Tool inspect -ArgumentsJson '{"kind":"unknown"}' -RuntimePath $runtime -RequireSuccess
```

Thus an API payload such as `idempotency_conflict` cannot be mistaken for
successful work with or without the switch.
The `communityshaders.profiler` bridge has a contract-specific adapter because
its legacy response does not carry a generic top-level `ok`: `status` must
contain a frame-bearing status object, while `enable` and `disable` must report
the requested observed state. This keeps profiler collection fail-closed
without misclassifying a valid bridge response as unknown.
Structured responses from allowlisted read-only calls establish a successful
read contract. `record start` has a separate adapter that requires
`action=start`, `recording=true`, and the requested correlation ID before
`-RequireSuccess` accepts the result. `record stop` requires the exact stop
action and a persisted recording path. Tracked-set `stop`/`releaseAll` requires
either exact already-inactive evidence or owner-bound completed restoration.
Weather `execute` treats top-level `ok` as envelope success only: the nested
result must report `status=success` and Boolean `applied=true`; preflight and
revision guards remain semantic failures.
The allowlist includes the exact structured `communityshaders.renderscale`
`status` response and the screenshot `capabilities` response. Screenshot
capabilities require the version-1 schema plus positive integral frame and
duration limits before clients may use them for mutation preflight. Screenshot
`status`, `settings_get`, `request_get`, `request_list`, and `events_poll` each
have an action-specific structured read contract. In particular, `request_get`
requires the exact requested ID, a non-empty state, and a Boolean terminal flag
for legacy flat receipts. Native `csx.screenshot` exact pairs 1.0/schemaRevision1
and 1.1/schemaRevision2 **still**
receipts instead qualify exact query/client/request/original-capture bindings,
producer build/session, native RequestRecord state, explicit UTC chronology,
settled publication, typed progress/output inventories and committed artifact
byte/hash/encoding evidence. Only then does `semantic.qualifiedScreenshotRequest`
derive terminal/requestSucceeded and flatten nested artifact metadata for frame
selection. The raw envelope is unchanged. Native sequence/sequence-frame receipts
are not qualified by this still adapter. `staging` is not an accepted native
RequestRecord state; unresolved publication and contradictory terminal evidence
fail closed. Typed source-bound historical capture errors/warnings remain in the
projection: a valid read of a failed capture is **not** successful capture.
The 1.1/schema2 source adds asynchronous sequence I/O lanes, not a different
still MakeReceipt shape. Unknown or mismatched minor/revision pairs refuse.
The derived receipt retains `nativeContract`; unchanged acquisition metadata,
raw envelope and every existing ownership/publication/artifact check remain.
Sequence `preparing` and sequence/sequence-frame receipts are not admitted by
this still-only adapter. Support is not screenshot science qualification.
Outer query errors and other nested failures still veto qualification. This is
owned-request observation only, not frame synchronization or science admission.
Replay completion receipts containing only scheduler facts such as `done`,
`runId`, and `stepsRun` are classified as
`scheduler-complete-unverified`, not semantic success. A replay response must
include explicit `semantic`, `postconditions`, `outcomeChecks`, or `assertions`
evidence before `-RequireSuccess` will accept it. This proves that the requested
interaction outcome occurred instead of merely proving that the scheduler ran.
Every member of an explicit outcome map must qualify; a false, null, empty, or
unsupported named sibling vetoes the whole result even when another sibling is
positive. Only non-empty `message`, `description`, and `label` fields are
treated as outcome metadata rather than checks.
Nested `error.code`, `status`, and `result.state` values are classified. Use
`-ExpectedErrorCode producer_mismatch` when a guarded rejection is the intended
test outcome. Acceptance requires one exclusive typed error envelope with that
exact top-level error code; additional outcomes, receipts, errors or contradictory
flags veto acceptance. Original guard rejection reasons remain retained separately.
Runtime health and producer identity content must be positively semantically
qualified before its fields contribute to mutation admission. Retryable semantic
identity failures use the same cleanup-qualified bounded rebind path as transport
retirement; failed ordinary producer candidates remain attributable and contribute
no producer identity while discovery may continue to a qualified sibling.
Transient HTTP 429/502/503/504 responses and timeouts use bounded
exponential retry and are preserved under `transportRetries`.

Menu and current-state waits qualify each contributing read response before
testing the barrier predicate. A failed or malformed probe is retained as a
semantic failure and cannot be replaced by synthetic readiness from apparently
nonblocking menus, a truthy loaded flag, or a matching cell. Positive
subsecond deadline budget remains available for one request; `wait-timeout` is
reported only after the absolute deadline has actually elapsed.

Every timing, frame-rate, CPU, or GPU capture must use
`-RequirePerformanceNeutral`. When the standalone upscaler temporal probe is
registered, the controller requires a proven neutral physical state and
ownership epoch before the target call. It reads the status again afterward and
rejects the result if the probe became active or the epoch changed. Legacy or
unproven status fails closed. The guard never disarms the probe; that is a
separate runtime mutation requiring its own authorization.

The exact Skyrim VR console command `tfc 1` is denied wherever it appears in a
tool argument tree because it has a confirmed player-camera null-write crash
path under null-HMD automation. Prefer a naturally stationary scene for
benchmarks. `-AllowUnsafeTfc1` exists only for an explicitly accepted crash-risk
experiment and is never implied by a normal scenario call.

State-changing `game` calls are also default-deny. Direct calls and nested
scenario steps for `load`, `loadLast`, or `save` require
`-WorkspaceManifestPath`. `MainMenuOnly` and `FreshGame` deny all three;
`VerifiedFixture` permits only `load` with the manifest's exact
`saveFixture.loadName`; `dir` is required and must be the workspace profile's
exact `saves` directory. The same rule covers console `load`/`save` commands,
which DevBench reroutes internally to the game tool. `-AllowUnprovenGameMutation` is an explicit policy
bypass for work outside a managed workspace; it is never inferred from copied
save availability.

`call` uses a 15-second request timeout by default. When the top-level tool
arguments contain `timeoutMs`, the controller automatically raises the request
timeout to at least `ceil(timeoutMs / 1000) + 5` seconds and reports the
effective value as `requestTimeoutSeconds`. It also extends the actual operation
deadline at dispatch to cover that server budget plus the receipt allowance,
and reports the effective deadline, duration, requested server timeout, and
remaining dispatch allowance. This does not extend the server's own
measurement deadline. Use `-MaxTransientRetries 0` for ownership-bearing
or otherwise non-replayable actions. If their response is lost, recover their
existing owner/status instead of sending the action again.

Each controller invocation tracks every Streamable HTTP MCP session it opens,
closes all of them before returning, and reports every outcome under
`sessionCleanup.sessions`. This prevents retries from leaking an earlier
session and exhausting DevBench's bounded session table. A cleanup 404 means
the server already retired the session and is successful. A wait will not bind
a replacement session while cleanup of the prior session is uncertain.

`wait -Condition noBlockingMenu` polls the menu tool client-side, ignores only
the explicitly listed `-IgnoredMenus` (HUD by default), and always reports the
actual timeout and final observation. This avoids the server-side `noMenu`
condition being held open forever by Skyrim's permanent HUD menu.
`-DismissBlockingMenus` optionally allows only the named blocking menu to be
closed, with `-MaxMenuDismissals` bounding each menu and
`-MinimumMenuStableSeconds` requiring a continuous clear interval afterward.
Message boxes and any unlisted blocking menu always prevent dismissal. This is
an explicit unattended-recovery action, not a background menu monitor.

`mainMenuReady` instead requires `Main Menu` to be open, permits Skyrim VR's
normal `Mist Menu` and `Fader Menu` overlays, and rejects every other menu
outside `-AllowedMainMenuMenus` (HUD, Main Menu, Mist Menu, and Fader Menu by
default). It represents a
usable front-end state without pretending that Skyrim's persistent menus have
closed.

`toolAvailable` repeatedly refreshes the authoritative tool inventory rather
than freezing the initial list. `serviceReady` additionally calls a controller-
qualified read-only probe and understands accepted and retryable service states,
including structured errors that explicitly declare `retryable: true`.
Retryability controls whether an unsatisfied observation may be polled again; it
never converts negative semantic evidence into readiness. The
controller inspects the authoritative
`inputSchema`: an empty object is used only when the schema permits it, while a
versioned service requiring `contractMajor`, `clientId`, `commandId`, and
`action` receives a generated `registry` (or `capabilities`) envelope. Unknown
required fields fail closed instead of dispatching a malformed or potentially
mutating probe. Explicit `-ArgumentsJson` is forbidden for `serviceReady`;
use `toolAvailable` when registration alone is sufficient, or add a reviewed
tool-specific probe adapter. Arbitrary non-empty responses remain unknown and
cannot establish readiness. Both
waits back off to `-MaxPollMilliseconds` and collect bounded PID/CPU/memory and
optional explicit-log samples. A missing target with increasing CPU is reported
as `api-waiting-behind-initialization`; a quiet missing target is
`api-absent-or-not-registered`.

The same `-TimeoutSeconds` value is the total transport budget for `list`,
`call`, and `wait`. Blocking calls such as a scenario with declared server-side
waits may therefore use the caller's full bounded budget instead of failing at
an unrelated fixed 15-second HTTP timeout. Mutation transport failures remain
indeterminate and are never replayed automatically. This includes a dispatched
MCP mutation whose HTTP response arrives but cannot be decoded; it returns the
same `indeterminate-mutation` reconciliation boundary as other unknown
post-dispatch outcomes.

All bounded waits keep explicitly transient 404/429/502/503/504, timeout, and
main-thread-busy probe failures as unsatisfied observations after the short
transport retry budget is exhausted. The outer deadline therefore survives a
normal load or compile transition, while non-transient probe failures still
terminate immediately and the last transient error remains in the result.
The initial MCP initialize/initialized/tools-list exchange is part of that same
outer wait state machine, so a temporarily unavailable listener cannot exhaust
the short transport budget before the requested timeout begins.
An invalidated MCP session is fully rebound within the same absolute wait
deadline. Periodic server session retirement is therefore not an independent
failure limit: `-MaxSessionRebinds` defaults to zero (deadline-only). Callers
may set a positive explicit churn cap when required; reaching it returns
`persistent-session-invalidated` with the count and last successfully decoded
observation. `-TimeoutSeconds` accepts explicit bounded waits up to one hour,
and ordinary deadline expiry returns `timeout` with the last successful state
observation rather than retrying a request that can no longer start. Transport
classification from health, registry, or capabilities identity probes is
preserved into that shared cleanup-qualified rebind boundary. A positive probe
that arrives at or after the absolute deadline is retained as a late diagnostic
observation and cannot satisfy the expired wait.

Codex can retain a direct MCP tool schema across replacement of the game and
DevBench runtime at the same loopback endpoint. Establish catalog currency at
connection initialization and after concrete staleness evidence, not before
every healthy call. Known runtime replacement or concrete schema drift
invalidates retained action/input schemas even when the tool name is unchanged.
Preserve historical metadata and mismatch evidence. Use a supported direct host
refresh/rebind only if actually available and bound to the expected answering
runtime; otherwise report `toolSchemaUnresolved` and perform no further stateful
dispatch using that schema. Missing/malformed discovery, absent action/schema,
or unproven identity also requires that refusal. Do not restart MO2, Skyrim,
SteamVR, or Virtual Desktop to refresh a catalog. Same-name replacement and
argument/schema mismatch do not themselves authorize a switch or replay.

Exact MCP error `-32602 Tool not found: <requested-name>` is staleness evidence,
but its text alone does not prove zero handler entry. Preserve the trusted
structured error envelope, requested tool/request identity, and answering
runtime identity; make no direct retry. Require version-bound server/connector
evidence proving pre-dispatch rejection for that correlated request. If proof
is unavailable, report `executionStateUnresolved`; do not switch lanes or
replay the uncertain call. Only with that proof, and where the governing
protocol permits the bundled lane, may the task select this controller as the
sole replacement lane: use the explicit runtime file, run `list`, verify
expected process/build identity, and proceed only when the fresh registry
contains the exact action and current input schema. Otherwise return
`toolSchemaUnresolved` without dispatch. No other error permits a
transport-lane switch; stricter direct-only protocols retain precedence.

`playerLoaded` is a current-state post-load barrier. After one separately
verified `game load` dispatch reports `queued: true`, call it with the exact
`-ExpectedCell`. It polls both `inspect state` and `inspect scene` until the
player is loaded in that cell. It does not wait for, or require observation of,
the transient unloaded-to-loaded edge because that edge can occur between
polls. The call adapter classifies an exact `action=load`, `queued=true`, and
matching save name as `game-load-dispatch-queued` with
`completionBasis=dispatch-only`; it does not claim that loading has completed.
A generic positive status never substitutes for that exact receipt, and any
contradictory error, extra payload, missing request identity, wrong action,
non-Boolean queue state, or mismatched save remains rejected.
A transport failure never causes the load mutation to be replayed.

Before a `communityshaders.render_map` `start`, capture the live `registry`
response and use `New-CSXRenderMapCapturePlan.ps1` with a workload JSON file.
The retained registry must be a successful response bound to the exact
`communityshaders.render-map` service (distinct from the
`communityshaders.render_map` callable tool), explicit contract major, producer build,
and source snapshot hash. The workload states positive integer JSON numbers for
expected duration, frames, event count, event bytes, scope depth, and every
catalogue observation family. The planner multiplies each by explicit headroom,
adds the registry's fixed catalogue allocation to the byte budget, rejects any
plan beyond the live service ceilings, and writes an immutable receipt
containing the selected bounds and rationale. Pass only a successful result's
`arguments` to `start`. If final hashing fails after receipt publication, the
failure result retains the committed path and withholds arguments so the exact
receipt can be reconciled. Any limit hit makes the evidence incomplete unless
saturation itself is the experiment.

The planner accepts an untouched retained controller response with exactly one
structured `data.content` payload, the native registry response, or an explicit
raw registry with producer provenance. It preserves the original snapshot hash
and service identity; it does not rewrite the registry or treat the tool name as
a service alias. Failed envelopes, foreign services/tools and multiple payloads
are rejected before issuing start arguments. Planning is offline and never
starts a capture or changes the running session.

`defaults.fixedCatalogueBytes` is the allocation for the registry's default
catalogue capacities, not a constant valid for arbitrary larger catalogues.
Until the producer publishes a per-catalogue sizing recipe, selected capacities
above any corresponding default return `catalogue-storage-unproven` and no
start arguments. At or below those defaults, the default allocation is retained
as a conservative upper bound. The event budget also admits the selected event
count multiplied by `defaults.eventStorageUnitBytes`, even when the caller's
event-byte estimate is smaller. A service ceiling is still an absolute limit.
Do not reduce a workload silently: the experiment owner must explicitly select
and justify smaller estimates, and saturation remains incomplete evidence.

An explicit owner-delivered source/PDB allocation recipe may qualify enlarged
catalogues without extrapolating defaults. Pass all five parameters together:
`-AllocationRecipePath`, `-ExpectedAllocationRecipeSha256`,
`-AllocationLayoutPath`, `-ProducerBuildManifestPath`, and
`-ExpectedProducerBuildManifestSha256`. Keep adjacent
`RenderMapAllocationRecipe.ps1` with the planner. JSON evidence is bounded to
256 KiB each and parsed from the same bytes as its SHA256. The caller pins the
trusted recipe and native manifest; the recipe pins the paired PDB-layout
receipt. Partial selection, malformed evidence or any identity mismatch fails
without falling back to default sizing.

The qualifier matches source commit/tree, owner BuildKey, PDB GUID/age and
paired DLL receipt; the native manifest connects source and DLL hash/size to
the fresh registry's producerBuildId. BuildKey and native buildId are distinct
identifiers, not interchangeable. The qualifier checks each catalogue term
against two paired-PDB record copies plus the source recipe's hash-entry/bool
budgets, checks the recipe's default accounting against the fresh registry,
and calculates costs from the actual selected capacities. It retains hashes,
source/build/PDB provenance and scope in `allocationEvidence`. This is a
hash-pinned owner derivation, not a new PDB inspection, runtime artifact
measurement, measured heap/RSS or successful collector allocation/capture.

Optional `-MaxBytes` retains an explicit byte budget such as 67108864. It must
fit the full headroom-sized workload and remain at or below both the fresh
registry ceiling and the qualified recipe ceiling. `requiredStorageBytes` and
`byteBudgetHeadroom` expose the accounting. Without this option, the planner
selects the calculated required budget. A recipe never raises registry limits:
the narrower native/recipe bound applies, including the65536 event maximum.
Native event selection/dependency expansion stays authoritative and receives
no catalogue-cost discount. Historical registry snapshots do not establish a
fresh runtime identity; retain a new registry for the actual start.

Use optional `-EventKinds @('draw','resource-flow','eye-submitted')` only for an
experiment-selected subset. Every name must be distinct and match the retained
registry's `eventKinds` exactly. Unknown/planned kinds, duplicates or an empty
selection are refused. Omitting the option preserves the native all-events
default. The plan retains requested names; the native start response owns any
dependency expansion and resolved selection. Filtering does not discount
catalogue allocation or promise that a trace cannot saturate.

`upscalingStable` is the fail-closed barrier for paced cell-transition tests.
It requires the exact `-ExpectedCell`, a loaded player, no blocking menu, and a
CSX profile that remains unchanged across advancing frames. Its public API
snapshot must share a state revision with the render-scale diagnostic snapshot,
and the physical render-scale status must agree with the effective profile.
Expected profiles and required physical-state telemetry use typed fields; JSON
strings cannot stand in for booleans or integer counters, and missing negative
state is never interpreted as inactive.
The destination's
requested settings determine the method, quality, and render-scale state; the
barrier does not impose a profile. When render-scale is active it additionally
requires its physical contract to be latched and active, both
eyes to be valid and vendor-evaluated on the same presentation path, clean
vendor lifecycle state, and no relatch, recovery, fallback, retirement, or
memory-trim work. Native-resolution DLSS, FSR, TAA/AA, and DLAA use the
authoritative upscaling service: requested and effective profiles must agree,
the controller state must agree with its transition state, and no active
physical render-scale contract or recovery condition may be present.
Native-resolution stereo confidence comes from consecutive advancing
world frames because the render-scale logger intentionally has no active
physical stereo contract in that mode.

The barrier never sends a console command and never repairs a failed state. An
unsatisfied or timed-out barrier fails the wait. A transition loop must stop at
that point and must not queue another `coc` command.

Runtime identity is refreshed after a waited-for service registers. The binding
reports listener process identity, every available CSX producer registry,
deployed artifact hash, completeness, and the exact missing fields.

Use `-ToolFilter` or `-NamesOnly` to reduce a large authoritative `list`
response. `-NoExit` keeps failures as structured JSON without terminating a
larger PowerShell orchestration host. A missing runtime file, identity mismatch,
or unreachable endpoint is a blocked result.

`DevBenchControl.psm1` exports two lossless render-scale telemetry normalizers.
`Get-DevBenchResourcePublicationTelemetry` retains publication generations,
expected/published dimensions, completion/deferred setup, and D3D identity.
`Get-DevBenchRenderScalePreparationTelemetry` retains the complete bounded
`status.preparation` event objects plus ring/session/QPC metadata and stage
summaries for queued requests, admission/early exits, shader-cache deferral,
SSS/SSGI prewarm, DLSS/FSR/FSR4 preparation, D3D creation, total preparation,
request-to-prepared, and prepared-to-creator. Its optional transition-epoch
filter selects exact producer events without inventing missing values.
