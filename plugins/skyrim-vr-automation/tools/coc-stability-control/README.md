# COC stability control

`Invoke-CocStabilityControl.ps1` owns the post-Windhelm critical path of the
fixed Skyrim VR COC assay. It verifies the exact DevBench/Skyrim identity and
live crash collector, calls `prepare_coc` once, launches the baseline reads in
parallel, and starts one async 20-transition scenario either when the complete
baseline passes or at the ten-second monotonic deadline.

The watchdog runs independently from the baseline requests and claims an
atomic dispatch marker before calling DevBench. Consequently, a slow or stuck
baseline cannot prevent the measured scenario from being submitted, and an
early baseline completion cannot race the watchdog into submitting it twice.
Every DevBench interaction is bound to the admitted process ID and start time.
A restarted process or another server at the endpoint is rejected before the
requested action. A known foreign stress, CPU, or GPU telemetry owner aborts
both dispatch paths instead of being reset by the scenario.

The dispatch journal exists before asynchronous submission. Its terminal state
distinguishes explicit rejection, unknown remote outcome, local claim failure,
ownership interruption, and known acceptance. If publication after acceptance
fails, the result still returns the exact owner, run ID, endpoint, process
identity, receipt, and intended state path; callers must reconcile that run
before retrying.

VR FPS Stabilizer exclusively owns profile selection. The controller never
calls a CSX upscaling mutation and deliberately omits `target` from every
`qualification_wait`; each receipt records the coherent profile selected after
dispatch. `protocol.v1.json` contains only the route and fidelity fixture.

After `run` returns, retain its state path and use `status` to obtain the final
server transcript:

```powershell
pwsh ./tools/coc-stability-control/Invoke-CocStabilityControl.ps1 run `
  -ExpectedPid 1234 -ExpectedBuildId ('a' * 64) `
  -CollectorStatePath 'D:\Evidence\coc-evidence-state.json' `
  -EvidenceRoot 'D:\Evidence\coc-run' -Compact

pwsh ./tools/coc-stability-control/Invoke-CocStabilityControl.ps1 status `
  -StatePath 'D:\Evidence\coc-run\coc-...\coc-stability-state.json' `
  -Compact
```

Only `run` may apply the runtime-only fixture or enqueue the measured scenario.
`status` is read-only apart from its DevBench status request.
Terminal execution is reported as `complete` only when all mandatory wait and
status receipts are attributable and structurally complete. Otherwise status
returns `evidence-partial` while preserving the transcript and missing-field
inventory.
