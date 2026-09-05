# Static COC protocol

## Fixed identity and milestone availability

This is the preserved static 20-transition COC assay. It is not permission to
change runtime code, profile selection, or pinned reference rows.

- Initial positioning cell: `WindhelmExterior01`.
- Odd transitions: `WhiterunDragonsreach`.
- Even transitions: `WindhelmExterior01`.
- Canonical waiter: `milestone: "strict"`, `timeoutMs: 30000`; this is a
  post-dispatch maximum, not a fixed delay.
- The initial, unmeasured Windhelm positioning scenario retains its separate
  10,000 ms server wait.
- VR FPS Stabilizer owns profile selection; omit `target` from every waiter.

Before arming, resolve the candidate DLL from the
explicit DevBench runtime metadata for this run (`artifactPath` or `dllPath` and `artifactSha256`), hash
that exact local file, and require the values to agree. Never select an AIO by
name, search MO2, scan for a plausible DLL, or reuse a prior Ghidra candidate.
Verify the exact running DevBench-enabled candidate DLL and its 64-character
producer Build ID. Call the registered top-level
`communityshaders.renderscale` tool and require its typed schema or descriptor
to accept the `strict`, `presentation`, and `cleanup` milestones. If the tool
is not typed, use the DevBench-control route to invoke that same registered
tool. Do not substitute client timing, an old waiter, or a second console COC.

## Arm phase

At the main loading window, call the managed native-headless Ghidra controller
once with `start -ProgramPath <runtime-metadata candidate DLL>`. It reuses its
owned session only for the same path and SHA-256; otherwise it gracefully stops
that owned session and reimports the supplied candidate. Bind the exact Skyrim
PID and Build ID to the DevBench receipt and native-headless Ghidra MCP receipts.
Require the controller's `binaryListReady: true` and
`programMatchesExpectation: true`
receipt: it records the imported artifact SHA-256 and confirms the active
executable path through the read-only `list_binaries` MCP call.
Do not require PyGhidra or `eval_python` activation. Arm one owned ProcDump exception collector
and preserve its state path and capture directory only after the exact dump root
passes `dump-write`: a unique controller-owned probe must create, write, and
remove successfully. Require CDB/WinDbg and dump storage. A failed `dump-write`
receipt blocks the arm; do not retry it. If any receipt is missing, report `not
armed`; do not send a COC. A new
PID, endpoint, compilation, or failed identity check invalidates an old arm
receipt.

## Initial positioning

With a fresh arm receipt, submit exactly one async server scenario:

```json
{
  "action": "run",
  "async": true,
  "continueOnError": false,
  "steps": [
    { "wait": 10000 },
    {
      "tool": "console",
      "args": { "action": "exec", "command": "coc WindhelmExterior01" }
    }
  ]
}
```

While its server wait runs, record exact producer Build ID and DLL provenance.
After Windhelm loads, call `communityshaders.menu` `prepare_coc` once with that
Build ID. It may apply only the runtime FOV/TAA fixture, must enable debug
logging from info-or-less-verbose, and must not save or alter upscaling.

## Measured 102-step scenario

Submit exactly one asynchronous DevBench scenario with
`continueOnError: false`:

1. render-scale stress `reset` and `start` with the exact Build ID;
2. for each ordinal 1 through 20, append these five server-side steps:
   1. `qualification_status` with the expected Build ID, proving no foreign
      owner is being overrun;
   2. `qualification_begin` with that ordinal as a unique nonzero transition
      ID, a run-unique owner ID, and the expected Build ID;
   3. `qualification_dispatch` with the same ownership, exactly one
      `cocCellEditorId`, and `startPerformanceTelemetry: true` only for ordinal
      1. Dispatch owns the COC and reads server QPC immediately before it;
   4. `qualification_wait` with the same ownership, exact destination,
      `milestone: "strict"`, `timeoutMs: 30000`, expected Build ID, and the
      fixture only when `prepare_coc` established protocol ownership;
   5. `status` with the expected Build ID, retaining the completed transition's
      bounded preparation trace and confirming the stress capture remains
      active before the next owner is armed.

The scenario therefore contains 2 + (20 x 5) = 102 steps. Do not add fixed
inter-transition waits, client polling, a separate console COC, a second
waiter, or profile mutation. Semantic milestone failures are preserved receipts;
an actual failed server step, ownership loss, stale build, dead game, or
transport failure stops later COCs.

For every measured block, `qualification_dispatch` must immediately precede
`qualification_wait`. Dispatch executes the COC and captures its QPC origin
before the waiter can run. The waiter must return as soon as strict is
satisfied; `timeoutMs: 30000` only bounds a faulty or incomplete transition.
`dimensionsMatch` is producer-owned CSX evidence; automation must retain it
without calculating, overriding, or repairing it.

On an operator interruption while the game control plane is responsive, call
`qualification_cancel` only with the active transition's exact transition ID,
owner ID, and Build ID. Never abandon that ownership and begin another
transition. After a CTD, hang, or lost main thread, issue no further main-thread
call; preserve and analyze the already-armed dump.

## Analysis and ledger

For every strict receipt record:

- `presentationStable`, failure mask/reasons, elapsed ms/frames;
- `cleanupDrained`, failure mask/reasons, elapsed ms/frames;
- `strictSatisfied`, failure mask/reasons, elapsed ms/frames;
- `outstandingCleanupDebt`, `timing`, `frames`, `observation`, and producer /
  Build ID provenance.
- normalized `resourcePublication`: current, current/completed/published
  generations, expected/published width and height, `complete`,
  `deferredSetupAcknowledged`, and D3D device/context matches.
- normalized, transition-epoch-filtered `status.preparation`, retaining the raw
  event objects, ring/session/QPC metadata, outcomes/reasons, and all timings
  for queued requests, admission/early exits, shader-cache deferral, SSS/SSGI
  prewarm, DLSS/FSR/FSR4 preparation, D3D creation, total preparation,
  request-to-prepared, and prepared-to-creator.

On timeout also retain `timedOutMilestone`, all milestone masks/reason arrays,
the last observation, and outstanding cleanup debt. Report presentation,
cleanup, strict, and cleanup-tail (`strict - presentation`) timing per
transition, plus median/p95/max for all four. Report retry, stretch, hard
failure, OOM, device-loss, fidelity, vendor-failure, and bounds-mismatch totals;
rank cleanup debt by frequency and accumulated tail.
Do not infer a missing resource-publication or preparation field from another
telemetry value; preserve it as missing evidence.

Strict frames remain the release result: Dragonsreach <= 24, Windhelm <= 20,
overall <= 22, worst <= 24, retries <= 9, session stretch observations <= 428,
consecutive stretch frames <= 18, and all hard/fidelity/vendor/bounds failures
must be zero. Presentation and cleanup-tail numbers diagnose the delay; they do
not weaken the strict gate. Append a new candidate row to
`docs/development/vr-render-scale-iteration.md` only after a completed run,
using `n/a` for counters the producer did not emit.
