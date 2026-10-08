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
15 seconds reserved for probe/colour/Calendar cleanup (the final5 of that
workflow for calendar release/readback), plus a separate final3-second slice
inside the same original deadline: up to2 seconds for the original MCP session
DELETE and1 second for terminal journal/in-memory JSON finalization.
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

Session closure is admitted only before its cutoff and uses cancellable HTTP
with a millisecond timeout capped to the smaller of2 seconds or its remaining
allowance. There is no integer-second rounding or fresh timeout after expiry.
`not_attempted_deadline_exhausted`, `cleanup_timed_out` and other close failures
are unverified/indeterminate, never Calendar restoration proof. Partial
measurement and custody evidence remain in the result. A404 means only that the
session is absent, not that Calendar or probe state was restored.

On both success and exception paths, the operation outcome is first retained
in memory. The original MCP sessions are closed before any terminal journal
I/O; then exactly one terminal journal combines outcome and session cleanup.
Pre-dispatch intent journals remain unchanged. `finalJournalAttempted` is set
only at actual write-action admission, not by a preceding timestamp sample;
`finalJournalDisposition` distinguishes skipped, failed, timely and late writes.
A write that starts before the deadline but finishes after it is retained as
late evidence with `evidenceJournalFinalized=false`, without replay.

The terminal journal is not started after the original deadline. If that
allowance is exhausted, the controller returns already retained in-memory
evidence with an explicit unfinalized-journal warning rather than starting new
disk I/O. Local journal/JSON work uses the reserved slice with admission and
postcondition checks; this is a cooperative application deadline, not a hard OS
interrupt guarantee for an individual filesystem call or JSON serialization.
Reported deadline overrun is failure/indeterminate, never a silently extended
budget or total-time qualification. Public offline timing fixtures include final
journal/output time; runtime qualification remains separate.
These are Auto-Tools lifecycle responsibilities, not an instruction for callers
to revert/rebuild retained environments or perform bespoke shared cleanup.

Completion qualifies evidence/custody only. Calibration, empirical jitter strata,
within/between-phase noise analysis and scientific precision remain the experiment
owner's work. No causal AE conclusion, exposure/history convergence, pixel
invariance, whole-resource equivalence or atomic cross-service join is implied.
