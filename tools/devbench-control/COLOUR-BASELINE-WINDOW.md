# Fixed-AE temporal baseline

`Invoke-DevBenchControl.ps1 colour-baseline-window` admits the existing actual
AE/HDR flags and collects one finite condition, 1..16 captures under one calendar
hold and one actual MCP session. It does **not** call `fsr_color_contract set`,
even for cleanup. The separate `colour-window` on/off/on contract is unchanged.
No native rebuild, SDK input setters, forced jitter, camera/quality/render-scale
changes, replay, renewal, REST downgrade or session replacement is permitted.

Use the same runtime/artifact/build/identity and evidence parameters as
[colour-window](COLOUR-WINDOW.md), but select `colour-baseline-window`. Supply
these nine required plan fields via `-ColourPlanJson`. The only additional
optional field is the actual Boolean `captureReadBrackets` described below:

```powershell
$plan = @{
    expectedBuildId = '<exact-64-lowercase-hex-build-id>'
    expectedRevision = 1 # fresh actual admitted status
    expectedCellFormId = 123 # current owner-calibrated scene
    highDynamicRangeInput = $true # actual admitted flag, not an instruction to set
    autoExposure = $true # actual admitted flag; false is also supported
    capturesPerCondition = 16 # TOTAL capture count for the one fixed condition
    metadata = @{ calibratedScene = '<owner calibration receipt>' }
    burnIn = @{
        minimumElapsedMilliseconds = 8000
        minimumObservedCpuFrameIdAdvancePerEye = 180
        minimumDistinctFreshSuccessfulBothEyeObservations = 6
        maximumElapsedMilliseconds = 20000
    }
    minimumElapsedMillisecondsBetweenCaptureArms = 1000
} | ConvertTo-Json -Depth 20 -Compress
# Use -TimeoutSeconds180 -CalendarHoldMilliseconds180000 -MaxTransientRetries0
# with the exact controller source lane and an explicit new EvidenceDirectory.
```

Burn-in and spacing are required here, with the same strict integer/coverage
bounds as the timed on/off/on lane. They measure engineering coverage, not vendor
convergence. Current requested flags, exact revision, successful FSR4 stereo
dispatches, context/dimensions/sharpness, healthy compiler brackets and fresh
calendar process/load/cell/storage custody must remain qualified. All ten
stage-eye pages per capture retain native `submittedInputs`: actual reset,
jitter offset and frame-time delta. Missing/unavailable/malformed telemetry
refuses; it is never synthesised or labelled a controlled jitter phase.

The total invocation budget remains20..180 seconds, including discovery and
15 seconds reserved for cleanup (the final5 for calendar release/readback).
Before hold, declared minimum burn-in plus inter-arm spacing must fit the
remaining work budget with request headroom. This is a necessary lower-bound
check, NOT a promise that16 captures finish: each capture's existing15-second
ceiling and all RPCs are clipped to the original work deadline. Partial evidence
is retained, further arms stop, and no budget silently expands.

The service resets only positively owned probes, verifies unchanged admitted
AE/HDR by reads, releases its original calendar lease and verifies prior-rate
restoration, then separately reports MCP session close. It cannot compensate for
foreign colour changes by writing the contract. Lost mutation acknowledgements,
foreign custody and unavailable restoration remain explicit; never replay.
These are Auto-Tools lifecycle responsibilities, not an instruction for callers
to revert/rebuild retained environments or perform bespoke shared cleanup.

## Optional capture-associated read brackets

Add `captureReadBrackets = $true` to the plan to opt in. Absent or Boolean false
preserves the previous plan and makes no extra reads; strings, numbers, objects,
unknown plan keys and use on the on/off/on lane are refused. Fresh discovery
must expose the typed camera/get and inspect scene/lights selectors plus bounded
scene scope/limit before a calendar hold is dispatched. This does not widen the
generic read allowlist, admit caller-selected observations or enable mutations.

For each capture the service sequentially calls `camera {action:get}`, then
`inspect {kind:scene}`, then `inspect {kind:lights,scope:scene,limit:64}` before
arm and after native completion, on the SAME original MCP session and calendar
hold. No `formId`, `selected`, concurrent observation, nested hold, simulation
freeze, SDK setter or new transport is used. Before reads use the original work
deadline; after reads and pages share the original capture ceiling. Extra work
reduces available coverage; partials stop further arms without an extension.

Each `capture.readBrackets` entry uses
`schema:auto-tools.colour-capture-read-bracket.1`, retains ordered native replies,
immutable RPC paths, UTC intent/receipt and monotonic elapsed time bounds,
qualification/availability and partial errors. Separate immutable
`colour-read-bracket.<unique-id>.json` receipts are finalised after the window,
including failed partials. Receipt publication errors stay explicit alongside
the completed operation/raw RPC evidence; they never authorize replay.

The before-arm bracket knows the intended captureId, but neither a native arm
generation nor captured CPU frame exists yet. It is retrospectively associated
ONLY after positive exact arm acceptance and native completion:
`generationKnownAtRead:false`, `generationBindingBasis:native-arm-acceptance-after-read`,
and `cpuFrameKnownAtRead:false` remain explicit even when the final generation/
capturedCpuFrame is attached. Refusal before arm retains null generation/frame.
Those are capture-association fields, NEVER the read's own native frame stamp.
After-completion records use the positively owned generation and captured frame.
`atomicRenderFrameEquivalent:false` applies to both. Camera/scene/light reads
are separate main-thread observations; equal endpoints cannot prove interval
invariance, eye-matrix equivalence or causal association.

Retain the actual native `gameHour`/`daysPassed` in each scene reply and the
calendar status values in the surrounding immutable RPC trace. The original
within-window calendar lease/readback/custody guard stays in force. A retained
workspace does not establish equal hours, weather or lighting across runs;
different observed hours are a scene-condition boundary, not a controlled
numerical effect comparison. These observations never set time or freeze
simulation, and do not claim whole-scene invariance from a calendar hold.

Scene cell/player loss, malformed typed values, explicit native/MCP errors,
read failures and late replies stop the assay while preserving raw evidence
and independent service-owned cleanup. Native omitted scene time/weather stays
unavailable rather than invented. Bounded scene lights retain the actual
shadowSceneNode[0] source, unavailable/truncated coverage and raw light values;
valid unavailable/truncated lists are observations, not all-light completeness
or visibility proof. Unavailable camera transform remains a failed observation.
The unchanged scientific precision gate belongs to the experiment, not this
schema. Native per-frame matrices/exposure metadata may be added separately,
but is not fabricated from these brackets or required to enable this option.

Completion qualifies evidence/custody only. Calibration, empirical jitter strata,
within/between-phase noise analysis and scientific precision remain the experiment
owner's work. No causal AE conclusion, exposure/history convergence, pixel
invariance, whole-resource equivalence or atomic cross-service join is implied.
