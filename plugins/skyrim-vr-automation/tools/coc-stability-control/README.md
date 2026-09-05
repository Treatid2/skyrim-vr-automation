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
