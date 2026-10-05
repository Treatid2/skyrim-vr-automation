# Finite FSR colour measurement with calendar custody

`Invoke-DevBenchControl.ps1 colour-window` is a narrowly typed MCP composition,
not a generic mutation allowlist. Existing `calendar-window` remains read-only.
Select one supported transport before the workflow: this controller cannot be
opened alongside an established direct lane. No REST downgrade or session rebind
is permitted. Source availability is not installed-plugin refresh or live PASS.

The experiment owner admits the exact retained environment and runtime, sets
FSR4 Quality/render-scale-off and calibrates the scene before this workflow. The
window verifies successful FSR4 path3 dispatch, not quality-mode selection or
render-scale-off itself. It does not change either setting, camera, save,
weather, world scale, caches, SteamVR or MO2. Do not treat metadata as proof of
calibration or a cross-service atomic join.

## Public command

Use the exact answering runtime/artifact/build and an explicit retained evidence
directory, `-MaxTransientRetries 0`,20..180 seconds total budget and holdMs at
least that total budget. Final15 seconds are reserved for cleanup; probe cleanup
cannot consume the final five seconds needed for calendar release/readback.

```powershell
$plan = @{
    expectedBuildId = '<exact-64-lowercase-hex-build-id>'
    expectedRevision = 1 # fresh admitted status, never an old example's value
    expectedCellFormId = 123 # actual calibrated scene's native numeric cell ID
    highDynamicRangeInput = $true
    capturesPerCondition = 2 # positive integer1..4
    metadata = @{
        calibratedScene = '<owner calibration receipt or exact description>'
        experiment = 'FSR4 Quality, RS off; autoExposure on/off/on'
        calibrationReceipt = '<retained current pose/tracking/stereo receipt>'
        profileAdmissionReceipt = '<current FSR4 Quality/RS-off admission>'
    }
} | ConvertTo-Json -Depth 20 -Compress
& '<bundle>/Invoke-DevBenchControl.ps1' colour-window `
    -RuntimePath '<exact-current-runtime.json>' `
    -ArtifactPath '<exact-deployed-CommunityShaders.dll>' `
    -ExpectedArtifactSha256 '<exact-sha256>' -ExpectedBuildId '<exact-build-id>' `
    -ExpectedRuntimeIdentityJson '<current admitted complete identity JSON>' `
    -CalendarOwner '<task owner>' -CalendarHoldMilliseconds 90000 `
    -ColourPlanJson $plan -MaxTransientRetries 0 -TimeoutSeconds 90 `
    -EvidenceDirectory '<new retained evidence directory>' -RequireSuccess
```

The plan requires the six top-level fields shown above. Only the optional
`burnIn` and `minimumElapsedMillisecondsBetweenCaptureArms` fields below may
also be supplied. Metadata is an object
with a nonempty `calibratedScene` string, at most15000 UTF8 bytes before the native
arm adds its own contract snapshot. Owner metadata slots may contain the
calibration, tracking, stereo, profile and scene receipts. No arbitrary action,
script, observation list, tool argument or expected-error override is admitted.

## Optional bounded engineering burn-in and inter-arm spacing

Existing six-field plans retain their dispatch-only settlement behavior. Neither
that settlement nor the optional coverage below proves internal vendor exposure
or history convergence. No native rebuild, input setter or hidden convergence
field is required or inferred.

```powershell
$timedPlan = $plan | ConvertFrom-Json -AsHashtable
$timedPlan.burnIn = @{
    minimumElapsedMilliseconds = 8000
    minimumObservedCpuFrameIdAdvancePerEye = 180
    minimumDistinctFreshSuccessfulBothEyeObservations = 6
    maximumElapsedMilliseconds = 20000
}
$timedPlan.minimumElapsedMillisecondsBetweenCaptureArms = 1000
$timedPlan.capturesPerCondition = 4
$timedPlanJson = $timedPlan | ConvertTo-Json -Depth 20 -Compress
# Use this JSON as ColourPlanJson with total TimeoutSeconds180 and hold180000ms.
```

`burnIn` requires exactly those four positive, actual integer fields. Minimum
elapsed must be less than maximum elapsed; maximum is at most20000ms. Frame-ID
advance is at most uint32.MaxValue; fresh-observation count is at most2000.
Optional inter-arm spacing is an actual integer1..10000ms. Strings, Booleans,
fractions, nulls, unknown fields and invalid bounds refuse before mutation.
Either option is independent. No implicit burn-in or spacing is added to old plans.

After each admitted set, the maximum20s budget includes startup dispatch matching.
Minimum elapsed starts at the first matching stereo observation, conservatively
after a valid context is observed, using a monotonic clock. Count that baseline
once, then require both eye CPU frame IDs, dispatch serials and QPCs to advance
strictly for another distinct sample. Duplicate snapshots, serial-only changes
and unmatched startup/transient observations are retained but do not count.
Freshness here means advancement relative to retained successful snapshots, not
an atomic claim about the engine's current frame. Serial deltas do not reveal
the number of successfully rendered eye frames; that count stays null.

Every matched sample must retain exact revision/context/flags, both eyes,
dimensions and configured/effective sharpness. Context/signature or compiler
drift invalidates coverage rather than restarting it. Preserve original startup,
burn-in and spacing replies/classification separately in each condition/capture.
Coverage deadlines never extend the original work budget or its reserved cleanup.
Incomplete burn-in stops all subsequent arms/conditions; initially matched native
dispatch remains a distinct fact, not a successful measurement or converged state.
Captures require CPU-frame/serial/QPC advancement beyond the final burn-in sample.

Spacing is conservative: at least the requested monotonic interval from the
previous positively qualified arm reply to the next arm intent, across conditions
as well as within them. This is not synthetic vendor timing. Native captured frame
and dispatch QPC remain authoritative capture evidence. Fresh compiler/colour and
calendar guards remain active while waiting; no accepted action is replayed.

The example permits12 captures/120 pages but does not promise they fit worst-case
native timeouts. All work must fit the original180s total, with its final15s
reserved for shared cleanup. Thresholds are declared experimental coverage
choices, not SDK settlement guarantees or statistical significance criteria.
Experiment owners still evaluate repeatability, drift and calibrated scientific
postconditions separately. Optional future native input telemetry is not implied
by this policy; do not infer reset/jitter/frame-time or exposure internals.

Run `Test-ColourTimingCoverage.ps1` for typed/real-clock offline fixtures; no
live environment, calibration, native history or exposure claim is made by it.

## Native sequence and guards

On exact217, `preExposure=1.0`, `exposureResourceBound=false` and
`sourceColorContractChanged=false` are source literals, not dynamic measurements.
They remain in raw receipts but are not settlement gates or exposure/source-transfer
science evidence. Requested/context flags, revision, active runtime context and
successful eye records are the dynamic gates.

1. Fresh complete runtime/build/artifact and exact calendar/colour/probe schema
   admission, current source binding and exact calibrated cell; no existing
   calendar or probe custody may be adopted. One native finite calendar hold.
2. On/off/on: each set carries the exact build and prior request revision CAS,
   fixed HDR input, positive native acceptance and the exact resulting revision.
   Same-value set may keep its revision. Never replay an accepted or lost set.
3. Bounded current status settlement requires valid runtime context and both
   successful eyes on the same frame/context generation/path/dimensions/flags,
   eye indices0/1 and ordered serial/QPC evidence. Inactive host context is not
   required to become valid on path3. Context/flags/revision/eye mismatch aborts;
   missing valid runtime/dispatch evidence stays unsatisfied only within deadline.
4. Each condition captures1..4 times. Arm once with unique captureId and exact
   revision/build; retain its generation. Native deadline remains15 seconds and
   120 readback frames. The client also bounds all completion/page reads to the
   earlier of15 seconds from arm intent and the original work deadline; it
   cannot extend the native frame policy or infer unexported frame counters.
5. Retain all five stages × two eyes with exact captureId/generation, schema3,
   frame, immediate context and successful per-eye dispatch attribution; require
   all ten mapped slots and all289 raw17×17 sample records per page. Keep raw
   storage hex and explicit null decoding; no gamma/transfer conversion or
   synthetic scene/submission epochs. Reads of a partial/failed page do not pass.
   Native probe-read `dispatch.path` is the exact string
   `Runtime FSR4 (amd_fidelityfx_upscaler_dx12.dll)`, retained unchanged in both
   page and slot dispatches. The separate colour-status contract uses numeric
   path3. Neither numeric3 nor string`"3"` qualifies a probe-read page. This is
   source-bound to native ColourPipelineProbe DispatchMetadata/Dispatch and
   FidelityFX path-label serialization (including admitted f4), not a coercion
   or support for arbitrary future path labels.
6. Fresh compiler snapshots bracket each set and each complete capture; same
   service/build/revision/counters required. Compiler failures abort without
   cache manipulation, build, load replay or runtime repair. Fresh calendar
   custody/current binding/rate-zero checks bracket each colour action.
7. Persist each native RPC reply (including original MCP text) and compiler
   boundary to a uniquely named JSON receipt before semantic promotion or
   destructive probe reset. Preserve accepted actions and their evidence even
   when a later boundary fails. No mutation replay or generic scheduler-success
   substitute is permitted.

## Cleanup is owned by Auto-Tools

A source-bound native failed probe status remains a failed measurement. After
typed schema and exact captureId/generation/revision qualification, the terminal
diagnostic retains the native error plus CPU frame, queued/expected stage-eye
slots, mapped slots and staging bytes. The exact failed status is retained in its
capture record before cleanup. Matching producer failure is not labelled foreign
producer; foreign/malformed status cannot gain this qualified classification.

Successful capture resets only its exact owned captureId/generation once and
requires fresh idle generation+1 readback. On failure, retained diagnostics/pages
remain separate from success. A confirmed owned probe may be observed boundedly
until native complete/failed, then reset once. An active probe cannot be reset;
an attempted/lost reset is never replayed. Unknown arm identity is not adopted.
Unproven probe cleanup is explicit, not an instruction for Mapping to invent a
cleanup procedure. No partial or failed capture is made complete by cleanup.

Calendar finally always retains original owner/lease/binding/captured prior rate,
releases on the same actual MCP session within the original cleanup deadline and
requires native restoration plus fresh readback. Known scene loss can qualify
restoration independently but never measurement continuity. Native engine failure,
crash or disconnect cannot be promised away: cleanup is bounded and its result
is verified or explicitly unresolved, not a guaranteed successful restoration.

Inspect separately: `data.measurement.ok`, each capture's `complete`,
`probeCleanup.verified`/`probeResetVerified`, `data.continuityVerified`,
`data.restorationVerified`, `indeterminate`, and top-level `sessionCleanup`.
Session deletion is not calendar restoration. Failed measurement with successful
restoration remains failed. The final autoExposure state is the experiment's
retained environment. Legacy six-field failed sequences may leave their last
accepted state and do not silently revert it. Explicit timing plans instead
request bounded restoration of the original admitted requested AE state, separately
reported as `colourCleanup`: fresh same-session revision/flags read, at most one
exact CAS restore if needed, and fresh requested-state readback. This does not
assert vendor-history convergence or restore an old revision number. Uncertain
mutations, foreign revision/scene/lease, unresolved probe custody or lost restore
prevent compensation/replay and remain explicitly unverified. AE/probe cleanup
shares the original bounded cleanup phase; the final5s remain reserved for calendar
release/readback. A failed burn-in remains failed even if restoration succeeds.

All source/fixture success is offline. Independent owner live admission remains
required; scientific colour, headset, pixels, exposure convergence, performance
neutrality and vendor timing acceptance remain the experiment owner's judgement.
