# CSX profiler control

`Measure-CSXProfiler.ps1` routes every profiler operation through the central,
identity-bound DevBench controller. It records the prior profiler enable state,
enables only when needed, and restores and verifies the exact prior state in a
`finally` path. Each accepted sample has a strictly advancing frame ID and
finite GPU/CPU metrics. A unique capture directory retains the raw JSON,
summary, timer CSV, DevBench invocation journals, and recovery receipt.

Only one capture may own a given runtime metadata target at once. The collector
uses a deterministic, bounded lease and verifies the complete DevBench process,
start time, build, and deployed artifact identity on every profiler response.
If that identity changes, it refuses to mix samples or mutate the replacement
runtime. Each raw sample carries the verified identity fingerprint. The lease's
deterministic control directory also owns a write-ahead transaction journal. A
later capture discovers a nonterminal predecessor before recording its own
pre-state: it restores the exact profiler state when the same runtime survives,
or terminally records that the old process was replaced without toggling the
new process.

Every non-restoration profiler call uses the central controller's
`-RequirePerformanceNeutral` guard. If the standalone temporal probe is
registered, each call requires a proven neutral physical state and unchanged
ownership epoch before and after dispatch. The capture also pins that epoch
across all warm-up and measured samples. Registration or epoch drift invalidates
the run, while the reserved restoration path remains available to restore the
profiler's prior state. Guard observations are retained in receipt and summary
schema 3; the collector never disarms the probe.

The collector also retains central-controller, read-only resource-publication
snapshots immediately before and after the measured interval: current,
current/completed/published generations,
expected/published dimensions, `complete`, deferred-setup acknowledgement, and
D3D device/context matches. An unavailable snapshot is explicit evidence and
does not invalidate the CPU/GPU capture.

Those same existing status calls retain bounded render-scale preparation
telemetry: raw events and ring/session/QPC metadata plus summaries for queued
requests, admission/early exits, shader-cache deferral, SSS/SSGI prewarming,
DLSS/FSR/FSR4 preparation, D3D object creation, total preparation,
request-to-prepared latency, and prepared-to-creator latency. The collector
does not poll or alter the render-scale profile to obtain this evidence.

```powershell
.\Measure-CSXProfiler.ps1 `
  -Label 'breezehome-enabled' `
  -EvidenceDirectory '.\evidence\<session>\profiler' `
  -ContextJson '{"environment":{"mo2Profile":"Task-42","scene":"Breezehome still","hmdMode":"null","renderResolution":"2112x2112"},"treatment":{"shaderState":"enabled"}}' `
  -Samples 120 -WarmupSamples 5 -IntervalMs 250 `
  -TotalTimeoutSeconds 300 -RestoreReserveSeconds 15
```

Supply DevBench runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`. No installation-specific path is built into the
collector.

`ContextJson` is mandatory. Its `environment` object identifies the MO2
profile, scene, HMD mode, and render resolution; `treatment` records the
intended variable such as shader state. The environment and exact runtime
identity form the comparison fingerprint.

`TotalTimeoutSeconds` bounds capture plus restoration. Sampling receives the
budget remaining before the reserved restoration window; the `finally` path may
use only the remaining total budget to verify and restore the prior profiler
enable state. `LeaseTimeoutSeconds` separately bounds admission behind another
capture of the same runtime.

`Compare-CSXProfiler.ps1` accepts two or more raw captures, removes unresolved
samples whose timer array is empty, and emits total and per-timer
JSON/CSV/Markdown comparisons. It also emits weighted per-frame estimates for
Screen Space Shadows, Skylighting, Volumetric Lighting, and Upscaling. Missing
features receive explicit zero rows, distinguishing absence from a lost row.
Aggregated `*.summary.json` input is rejected with a specific schema error.
Every input needs at least three unique fresh frames, finite metrics, and the
same environment/runtime fingerprint.

```powershell
.\Compare-CSXProfiler.ps1 `
  -InputPath @('.\enabled.raw.json', '.\disabled.raw.json', '.\unloaded.raw.json') `
  -OutputDirectory '.\comparison' `
  -ReferenceLabel 'enabled'
```

Interpret the total as the active CSX profiler block, not whole-frame render
time. Feature-state changes can alter render resolution and therefore the cost
of passes that remain; do not add timer deltas as if the rendering paths were
otherwise identical.

Run the synthetic regression suite after changing either script:

```powershell
.\Test-ProfilerControl.ps1
```

## Whole-runtime quiet windows

`Measure-SkyrimQuietWindow.ps1` records engine frame throughput and process CPU
use for Skyrim, SteamVR, Virtual Desktop, and the dashboard across a bounded
quiet window. It uses DevBench only for identity-bound frame boundaries; it
does not enable the CSX profiler.

```powershell
.\Measure-SkyrimQuietWindow.ps1 `
  -RuntimePath $runtimePath `
  -Condition 'null HMD; DevBench on; Whiterun clear' `
  -Scene 'WhiterunOrigin' `
  -OutputPath '.\evidence\quiet-30s.json'
```

`Compare-SkyrimPerformance.ps1` compares two or more such captures and writes
JSON, CSV, and Markdown. Comparisons are deliberately informational: establish
repeatability for a scene and runtime route before adding project-specific
thresholds.

```powershell
.\Compare-SkyrimPerformance.ps1 `
  -InputPath @('.\baseline.json', '.\candidate.json') `
  -ReferenceLabel 'baseline' `
  -OutputDirectory '.\comparison'

.\Test-SkyrimPerformance.ps1
```
