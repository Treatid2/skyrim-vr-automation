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

The plan accepts exactly six top-level fields shown above. Metadata is an object
with a nonempty `calibratedScene` string, at most15000 UTF8 bytes before the native
arm adds its own contract snapshot. Owner metadata slots may contain the
calibration, tracking, stereo, profile and scene receipts. No arbitrary action,
script, observation list, tool argument or expected-error override is admitted.

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
retained environment; a failed sequence may leave its last accepted state and
must not silently revert it.

All source/fixture success is offline. Independent owner live admission remains
required; scientific colour, headset, pixels, exposure convergence, performance
neutrality and vendor timing acceptance remain the experiment owner's judgement.
