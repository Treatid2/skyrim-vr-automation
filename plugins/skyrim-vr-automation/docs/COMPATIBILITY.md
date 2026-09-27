# Compatibility and boundaries

## PowerShell

PowerShell 7 or later is required. The controllers use modern JSON conversion
features and return structured JSON suitable for another automation layer.

## CSX and DevBench

`devbench-control` is a client, not the in-game server. It expects a running CSX
build to publish `runtime.json` and implement MCP protocol `2025-03-26` on the
loopback interface. The runtime metadata path must be supplied explicitly or by
`CSX_DEVBENCH_RUNTIME_PATH`.

`profiler-control` uses that same runtime contract to collect and compare the
resolved CSX GPU/CPU timer block. Its totals are not whole-frame GPU time.

`render-scale-qualification` additionally requires the render-scale,
upscaling, feature, screenshot, scenario, console, and inspect DevBench tools
declared by its bundled protocol. It rejects an incomplete or identity-drifting
runtime before qualification mutations.

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
