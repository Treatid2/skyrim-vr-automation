---
name: perftune-upscaling
description: "Run the automated Skyrim VR Community Shaders Upscaling cost sweep when the user says perftune upscaling. Measures the NVIDIA or AMD matrix relative to None and prompts NVIDIA users for J, K, L, M, F, or E."
---

# Perftune Upscaling

Attach to the already-running in-game Skyrim VR session. Do not build, deploy,
launch, load a save, change cells, or substitute another benchmark.

## Immediate status

Use only the named direct `mcp__devbench_vr__*` tools. Do not enumerate tools,
run local discovery, or inspect a fallback before attaching.

When the direct `mcp__devbench_vr__skyrimvrupscaler_temporalProbe` tool is
exposed, the first live call is exactly `{"action":"status"}` to that tool.
Require schema 3 or later, `performanceDistorted: false`,
`physicalStateKnown: true`, and a nonnegative integer `performanceEpoch`; retain
that epoch without disarming or otherwise mutating the probe. A malformed or
legacy registered probe blocks the sweep. If the direct probe tool is not
exposed, treat the standalone probe as not registered.

Then call `mcp__devbench_vr__communityshaders_performance_tuning` with exactly `{"action":"status"}`.
Bind its producer Build ID and retain transport session identity when present.
If the tool is unavailable, the response is malformed, or `readiness.ready`
is not true, stop. Require the reported adapter/runtime capability.

Do not call `prepare_coc` or alter COC, position, FOV, TAA, foveation,
developer mode, logging, debug state, or any unrelated setting.

## Selection and start

On NVIDIA, show `J, K, L, M, F, E` and ask the user to type one letter. Wait
for the reply without starting or choosing a default; reject any other value.
On AMD with FSR4 available, do not ask for a DLSS profile.

Call the same tool once with `action: start_upscaling_sweep`, the bound
`expectedBuildId`, and:

- NVIDIA: `matrix: nvidia` plus the chosen `dlssPreset`.
- AMD: `matrix: amd` with no `dlssPreset`.

Accept only an explicit `accepted: true`. The server owns menu closure, every
temporary Upscaling change, timing, FSR4 fallback detection, and restoration.
It displays the compact desktop/HMD countdown; tell the user to keep still.

## Monitor and report

Poll status with the bound Build ID and bounded waits. Advance
`traceAfterSequence` from the last raw
trace record so cooldown and wait-period Game/GPU/CPU timings remain readable.
Do not recalculate the server's statistics.

When the standalone probe was registered, read its status before every poll,
immediately after any transport-session change, and after the terminal receipt.
Reject every measured result unless the probe remains physically neutral and
its `performanceEpoch` exactly matches the retained value throughout.

Stop on `completed`, `failed`, or `cancelled`. On user cancellation, send one
`cancel` with the bound Build ID and verify a terminal receipt. Never retry a
failed case, switch matrix, substitute a method, or claim completion without
that receipt.

Report the producer Build ID, adapter/matrix, selected NVIDIA profile when
applicable, terminal state, a compact table of all None-relative results with
delta, standard error, significance and missing-sample annotations, and one
short cooldown/wait stability note from the raw trace.
