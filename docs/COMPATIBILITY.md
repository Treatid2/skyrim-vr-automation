# Compatibility and boundaries

## PowerShell

PowerShell 7 or later is required. The controllers use modern JSON conversion
features and return structured JSON suitable for another automation layer.

## CSX and DevBench

`devbench-control` is a client, not the in-game server. It expects a running CSX
build to publish `runtime.json` and implement MCP protocol `2025-03-26` on the
loopback interface. The runtime metadata path may be supplied explicitly, by
`CSX_DEVBENCH_RUNTIME_PATH`, or by `devBenchRuntimePath` in
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`.

`profiler-control` uses that same runtime contract to collect and compare the
resolved CSX GPU/CPU timer block. Its totals are not whole-frame GPU time.

`coc-stability` requires the server-side render-scale qualification begin,
dispatch-mark, and wait actions. It stops when the exact waiter contract is
unavailable instead of substituting loading-menu checks, client polling, or
fixed delays.

`render-scale-qualification` requires the intended DLL and Skyrim VR session to
be running already; its entrypoint does not build, deploy, launch, restart, or
reload them. It binds the exact live runtime/build identity, verifies any
supplied artifact binding, and depends on the server-side render-scale
qualification waiter, upscaling and feature APIs, HMD-submission screenshot
sequences, stress diagnostics, and CPU telemetry. Its frozen protocol includes
all five DLSS trace actions introduced by
`b46edeaed14c41ad41225641c3a4943f1db25db6`: `dlss_trace_status`,
`dlss_trace_reset`, `dlss_trace_start`, `dlss_trace_stop`, and
`dlss_trace_read`. A server that does not advertise the full contract fails
preflight. Render-scale status must expose the live D3D adapter vendor, device,
and driver identity; those values must agree with the selected vendor matrix
and fixture manifest.

Protocol revision 4 also requires a Codex CLI installation that can provide
original image inputs and schema-constrained output with `gpt-5.6-sol`. The
same invocation runs three batches for each of two blinded, swapped
presentation passes. Model access, schema, timeout, confidence, disagreement,
and evidence-integrity checks fail closed. Render-scale latch is evaluated only
from owner-bound telemetry. Accepted local and PR results exit 0, quality
failure exits 2, and infrastructure failure exits 4.

## MO2

MO2 Control reads a configuration matching
`tools/mo2-control/config/machine.example.json`. Resolution is deterministic:
explicit `-ConfigPath`, `SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`, then the legacy ignored
checkout-local file. The selected source is reported and no alternate profile,
executable, or configuration is silently substituted. Isolated tests do not
require a live MO2 installation.

## SteamVR null-HMD

The controller's conventional defaults target a standard Steam installation.
Nonstandard installations must pass `-SettingsPath` and `-SteamVRRoot`. The
null-HMD profile is repository-relative and is therefore portable.

## Deliberate exclusions

This repository does not contain CSX binaries, shaders, compiled shader caches,
MO2 mods, presets, game files, SteamVR settings, runtime secrets, or collected
test evidence. Those remain local operational inputs or outputs.
