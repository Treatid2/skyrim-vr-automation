---
name: profiler-control
description: "Collect bounded CSX GPU and CPU profiler samples through DevBench and compare preserved captures. Use for render-time measurements, shader-state comparisons, enabled-versus-disabled-versus-unloaded experiments, timer baselines, or profiler evidence reports."
---

# Profiler Control

Read `../../tools/profiler-control/README.md` completely before capturing or
comparing data. Use these entry points:

```text
../../tools/profiler-control/Measure-CSXProfiler.ps1
../../tools/profiler-control/Compare-CSXProfiler.ps1
```

## Capture contract

1. State in commentary that this skill governs profiling. Apply
   `$devbench-control` when endpoint discovery or tool schema inspection is
   needed, and `$mo2-control` when a game lifecycle or mod-state transaction is
   in scope.
2. Establish the exact build, MO2 profile, scene, HMD mode, resolution, shader
   state, warm-up, sample count, and interval before comparing captures.
3. Supply `ContextJson` with the exact environment and treatment. A capture
   enables the CSX profiler, so that mutation requires the user's run or
   measurement authority; a request to review existing data does not.
4. Before enabling or sampling the profiler, require the central controller to
   read the registered standalone `skyrimvrupscaler.temporalProbe` status and
   prove a neutral physical state and ownership epoch. Recheck the same epoch
   throughout the capture. A changed, legacy, or unproven probe fails closed;
   profiler restoration still runs and never disarms the probe.
5. When `communityshaders.profiler_api` is exposed, call `snapshot`, preserve
   the initial enabled state, then call `set_enabled` with `enabled: true` and
   require its nested snapshot to be available and enabled before
   `start_capture`. Treat `disabled` from `start_capture` as a failed capture,
   never as unsupported or a successful arm. Restore the initial enabled state
   after the bounded capture when control remains responsive.
6. Write to a dedicated evidence directory outside live MO2 overwrite and
   shader-cache trees. Keep raw JSON; summaries alone cannot be re-analysed.
   Preserve the collector's before/after normalized resource-publication
   telemetry and render-scale preparation trace with the timer data. Keep raw
   preparation events and stage summaries for admission/early exit,
   shader-cache deferral, SSS/SSGI, DLSS/FSR/FSR4, D3D creation, total,
   request-to-prepared, and prepared-to-creator. Missing fields are evidence,
   never inferred.
7. Compare at least two raw captures with matching context fingerprints and
   identify the reference explicitly. Reject captures without at least three
   unique fresh frames or with non-finite metrics.
   Treat the total as the active CSX profiler block, not whole-frame cost. Do
   not sum correlated timer deltas into a fictional independent total.

Failed or partial captures are evidence. Record reconnects, missing timers,
scene drift, compilation activity, CTDs, and state changes instead of silently
retrying or substituting a different run.
