# COC stability control

`Invoke-CocStabilityControl.ps1` owns the post-Windhelm critical path of the
fixed Skyrim VR COC assay. It verifies the exact DevBench/Skyrim identity and
live crash collector, launches the baseline reads in parallel, and starts one
async 20-transition scenario only after every ownership and readiness result
arrives within the ten-second admission deadline. An incomplete or faulty
baseline fails closed before `prepare_coc` or scenario mutation.
Each worker records a monotonic completion timestamp and the controller checks
the final baseline decision against the same deadline. The three fixture gates
must be actual non-null Booleans with values `true`, `false`, and `false` for
`ready`, `persisted`, and `promptRequired`; truthy strings and nulls are rejected.
Known pre-dispatch fixture failures retain the completed baseline and terminal
failure in the state journal. If that final publication fails, the same evidence
is returned in-memory with the publication error.

Every DevBench interaction is pinned to the canonical endpoint, its exact
listener PID, and the admitted Skyrim start time. The server scenario acquires
qualification ownership before stress reset/start, and those diagnostic steps
carry the same owner ID. A restarted process, substitute endpoint, or foreign
stress, CPU, or GPU telemetry owner is rejected before diagnostic mutation.

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
status receipts are attributable and structurally complete. The admitted
protocol bytes and SHA-256 are stored in the journal, so later status cannot be
reinterpreted through a replaced configuration file. Otherwise status returns
`evidence-partial` while preserving the transcript and missing-field inventory.
