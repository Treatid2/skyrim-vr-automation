# Fixed-AE temporal baseline

`Invoke-DevBenchControl.ps1 colour-baseline-window` admits the existing actual
AE/HDR flags and collects one finite condition, 1..16 captures under one calendar
hold and one actual MCP session. It does **not** call `fsr_color_contract set`,
even for cleanup. The separate `colour-window` on/off/on contract is unchanged.
No native rebuild, SDK input setters, forced jitter, camera/quality/render-scale
changes, replay, renewal, REST downgrade or session replacement is permitted.

Use the same runtime/artifact/build/identity and evidence parameters as
[colour-window](COLOUR-WINDOW.md), but select `colour-baseline-window`. Supply
exactly these nine plan fields via `-ColourPlanJson`:

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

Completion qualifies evidence/custody only. Calibration, empirical jitter strata,
within/between-phase noise analysis and scientific precision remain the experiment
owner's work. No causal AE conclusion, exposure/history convergence, pixel
invariance, whole-resource equivalence or atomic cross-service join is implied.
