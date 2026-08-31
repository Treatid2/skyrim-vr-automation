# Skyrim VR Automation Toolkit

This repository provides external PowerShell automation for repeatable Skyrim
VR development and testing. The controls cover Mod Organizer 2, SteamVR's null
HMD, profile transactions, and reusable compiled shader-cache management. CSX DevBench is an
optional integration rather than the identity or boundary of the toolkit.

## Included tools

- `tools/modlist-control` — fail-closed registration and persistent selection
  of exact named MO2 machine configurations.

- `tools/doctor` — configuration discovery, environment validation, and
  non-overwriting initialization of the stable per-user MO2 config.
- `tools/feedback-control` — durable local reporter/maintainer feedback with
  atomic receipts, lifecycle events, deduplication hints, and explicit
  sanitized export.
- `tools/mo2-control` — exact-profile MO2 inspection, cooperative cross-task
  access leases, and a bounded single-owner launch lifecycle.
- `tools/mo2-profile-control` — transactional toggling of an exact MO2
  `modlist.txt` marker and guarded registration of a newly deployed mod.
- `tools/mo2-workspace-control` — stable-source ShaderCache evacuation plus
  unique task profiles cloned from that explicit source, with a verified copy
  of its complete saves tree, a mandatory integrity-verified world-entry save, and
  strict ownership of newly created mods.
- `tools/steamvr-null-control` — transactional null-HMD apply/restore and
  bounded SteamVR shutdown, with a required application-observed standing
  head-pose qualification and opt-in exact-driver isolation for conflicting
  OpenVR display redirectors.
- `tools/steamvr-head-pose-control` — install, inspect, update, and independently
  qualify the bundled SteamVR head-pose provider used by null-HMD sessions.
- `tools/devbench-control` — a small MCP client for the DevBench endpoint
  exposed by a running CSX build, with listener/process/build/artifact binding
  and normalized semantic results.
- `tools/render-scale-qualification` — the bounded
  `csx-render-scale-pr-v1` COC, menu-transition, and stereo visual suite for
  local and PR render-scale qualification, with unattended image evaluation,
  deterministic evidence, and generated summaries.
- `tools/profiler-control` — repeatable DevBench profiler capture and
  multi-state comparison reports.
- `tools/shader-cache-control` — provider discovery, physical cache
  snapshot/restore transactions, compatibility-ranked known-working cache
  catalogs, task seeding/restoration/promotion, and comparison reports.
- `tools/capture-interaction-control` — correlated full-state recording, latest
  committed stereo-frame observations, named atomic actions, direct DevBench
  passthrough, and UTC-safe save-boundary waits.
- `tools/process-control` — bounded exact-process execution with classified,
  evidence-backed retries for known transient failures.
- `tools/coc-evidence-control` — exception-triggered crash coverage plus an
  explicit, classified full-dump route for a visually confirmed hang.
- `tools/coc-stability-control` — the one-shot post-Windhelm fixture, parallel
  baseline, monotonic deadline, and exactly-once 20-transition dispatcher.
- `tools/build-test-control` — CTest-aware branch testing with a direct-test
  fallback when a configured build contains test binaries but registers none.

The preserved null-HMD profile is `profiles/steamvr-null.profile.json`. The
provider is a native SteamVR server driver because SteamVR needs a valid head
pose before Skyrim and CSX DevBench exist. DevBench may later update its
versioned shared-memory pose contract, but it is not the bootstrap provider.

## Codex plugin

The repository publishes a Codex marketplace plugin. It registers the
loopback `devbench_vr` MCP server directly and its seventeen skills connect a
new task to the bundled implementations and their operational contracts:

- `$feedback-control` records unexpected automation behaviour and concrete
  enhancement requests in a durable local queue; it never publishes them.
- `$mo2-control` routes MO2 inspection, exact-profile lifecycle management,
  and transactional profile edits.
- `$steamvr-null-hmd` routes backed-up SteamVR null-HMD apply/restore and
  bounded runtime shutdown.
- `$devbench-control` discovers and calls the plugin-provided loopback DevBench
  MCP API. NVIDIA and AMD render-scale tuning require this direct lane and do
  not fall back to the bundled controller.
- `$coc-stability` queues the 10-second Windhelm start first, fills that wait
  with parallel identity reads, applies its post-load debug/FOV/Stabilizer gate
  once, and runs all 20 command-timed transitions in one anomaly-accumulating
  server batch without weakening the exact-cell or two-eye fidelity predicate.
- `$simple-coc` runs the measured 20-transition Windhelm/Dragonsreach assay
  with ten-second pacing and the full CPU/GPU/render-scale evidence contract.
- `$simple-coc-5` runs the same measured COC assay with five-second pacing.
- `$simple-csm` positions once at Dragonsreach and applies the canonical
  hardware-specific 25-step CS menu matrix with five-second pacing and the
  same telemetry and evidence extraction.
- `$renderscale-tuning-nvidia` runs the exact 33-transition NVIDIA public-API
  matrix twice in one process, separated by a bounded memory cooldown.
- `$renderscale-tuning-amd` runs each 31-transition explicit-FSR4, explicit-
  FSR3, and documented FSR4-to-FSR3-fallback lane twice in one process.
- `$static-coc` runs the preserved 20-transition COC assay with one strict,
  30-second milestone wait per transition and reports presentation and cleanup
  timing without weakening the canonical strict gate.
- `$fidelstab` runs the preserved paced Breezehome fidelity and stability
  protocol.
- `$render-scale-qualification` attaches to the intended DLL that is already
  running in game and completes the bounded qualification in one invocation.
- `$profiler-control` captures bounded GPU/CPU timer evidence and compares runs.
- `$shader-cache-control` prepares tasks from compatible known-working compiled
  caches, restores prior state, promotes verified results, and compares trees
  by SHA-256.
- `$perftune-upscaling` runs the server-owned NVIDIA or AMD Upscaling cost
  sweep, including raw cooldown telemetry and None-relative results.
- `$capture-interaction-control` provides a current-frame observation/action
  loop over correlated DevBench state, stereo screenshots, and input receipts.

Install from the public Git marketplace:

```text
codex plugin marketplace add Treatid2/skyrim-vr-automation --ref main
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

The reproducible marketplace package lives under
`plugins/skyrim-vr-automation`; canonical sources remain at repository root.
See `docs/INSTALL-CODEX.md` for upgrades, removal, and release pinning. Restart
Codex after installing or updating.

From a repository checkout, the bounded updater also detects and repairs a
stale local marketplace registration, then hash-verifies the installed copy:

```powershell
.\scripts\Install-CodexMarketplacePlugin.ps1 -ConfirmSafeCacheRotation
```

Run the installer only after every automation protocol in every chat is
terminal, then fully reload Codex or VS Code. Installation replaces versioned
cache paths, and a new chat in the same host can retain the prior catalog.

## Local setup

The repository contains no tracked machine paths or credentials. The preferred
MO2 configuration is independent of the checkout or plugin cache. Initialize
it with the bundled doctor:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 init
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

For one MO2 installation, edit
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`. For multiple portable
modlists, register and select exact named configs instead:

```powershell
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 register -Name main -ConfigPath C:\staging\main.json
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 select -Name main
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 list
```

An explicit `-ConfigPath`, `SKYRIM_VR_AUTOMATION_CONFIG`, or
`SKYRIM_VR_AUTOMATION_MODLIST` can override the persisted selection. The
resolver never chooses an arbitrary named config.

Before setup is ready, live-load one known-good save in the maintained source,
declare it through `defaults.newGameFixtureManifest`, and require both
`fixture-status` and the doctor's `prime-profile-world-entry-integrity` check
to pass. See `docs/INSTALL-CODEX.md` and `docs/BREEZEHOME-SAVE.md`.

DevBench runtime discovery is supplied explicitly, through an environment
variable, or by `devBenchRuntimePath` in the stable per-user
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`:

```powershell
$env:CSX_DEVBENCH_RUNTIME_PATH = 'C:\Path\To\overwrite\SKSE\Plugins\devbench\runtime.json'
.\tools\devbench-control\Invoke-DevBenchControl.ps1 list
```

Run the render-scale qualification only after the intended DLL is loaded,
Skyrim VR is in game, and the controlled start scene is stable. Prepare one
non-example `fixture.example.json` copy with the controlled
save/camera/stabilizer/GPU/HMD identities and exact SHA-256 values. Its live
adapter vendor, device ID, and driver must agree with DevBench. Select the
fixture explicitly, with `CSX_RENDER_SCALE_FIXTURE_PATH`, or place it at the
stable default:

```text
%LOCALAPPDATA%\SkyrimVRAutomation\render-scale-qualification\fixture.json
```

With the stable runtime and fixture configured, local qualification is one
command. The wrapper discovers and binds the exact running Build ID, verifies
the live GPU identity, creates a unique evidence directory, and never builds,
deploys, or launches the game:

```powershell
.\tools\render-scale-qualification\Start-CSXRenderScaleQualification.ps1
```

The same operation is available conversationally through
`$render-scale-qualification`: launch the intended DLL and game yourself, enter
the controlled start scene, then say `start render-scale qualification`. A
contextual `start` is also sufficient after those conditions have already been
established in the conversation.

Explicit runtime, fixture, and output locations remain available:

```powershell
.\tools\render-scale-qualification\Start-CSXRenderScaleQualification.ps1 `
    -RuntimePath C:\Runtime\devbench\runtime.json `
    -FixtureManifestPath C:\Evidence\render-scale-fixture.json `
    -EvidenceDirectory C:\Evidence\render-scale-local
```

A local run returns `LOCAL_PASS` and `qualification-summary.md`; it is not PR
evidence. PR mode additionally requires an accepted baseline from the same
protocol and fixture with a different exact Build ID:

```powershell
$baselineBuildId = '<64-character baseline CSX build ID>'
.\tools\render-scale-qualification\Start-CSXRenderScaleQualification.ps1 `
    -PrMode -BaselinePath C:\Evidence\render-scale-baseline `
    -ExpectedBaselineBuildId $baselineBuildId
```

Protocol revision 4 has a hard 600-second end-to-end pass limit. It runs the
20-transition load-synchronized COC assay, a 30-second recovery, the ordered
25-transition menu assay, a second 30-second recovery, and three one-minute
HMD-submission capture sequences. Dispatch-to-stability time starts at the
owner-bound server QPC mark, and each top-level MCP result is checked before
the next mutation.

Visual evaluation is part of the same invocation. The Codex CLI runs
`gpt-5.6-sol` for three replicates in each of two blinded, independently
swapped presentation passes: six batches in total. It assesses sharpness,
blur, shimmer, stereo alignment, equal eye scale, and corresponding geometry.
Render-scale latch is decided from owner-bound stress and CPU telemetry, not
from image appearance. Low confidence, indeterminate output, swapped-pass
disagreement, model failure, or evidence-integrity failure fails closed.

The evidence directory hash-binds every immutable producer artifact, all 144
PNG captures, model requests and responses, execution receipts, the generated
visual review, and the final report. PR evidence also bundles the validated
comparison baseline without recursively copying older comparisons. The
required DLSS trace lifecycle remains fixed to commit
`b46edeaed14c41ad41225641c3a4943f1db25db6` and includes
`dlss_trace_status`, `dlss_trace_reset`, `dlss_trace_start`,
`dlss_trace_stop`, and `dlss_trace_read`.

`PASS` and `LOCAL_PASS` return exit code 0. A valid negative or inconclusive
quality result returns `FAIL` with exit code 2. Runtime, fixture, baseline,
model, schema, timeout, or evidence-integrity failures return
`INFRASTRUCTURE_ERROR` with exit code 4.

For SteamVR, pass nonstandard paths with `-SettingsPath` and `-SteamVRRoot`.
The bundled null-HMD profile is resolved relative to the controller script.

The toolkit remains independent of any source tree it exercises.

## Safety model

Run inspection or a dry run before mutation. MO2 commands require exact access,
profile, executable, and session ownership. Each test task first evacuates any
legacy `ShaderCache*` trees from overwrite into an enabled stable-source mod,
then uses its own cloned workspace profile and may remove only mods that its
workspace proved were new;
tasks release MO2 access whenever
they can continue without it. Null-HMD apply takes an exact backup and
restore verifies its receipt; optional display-driver isolation also preserves
and hash-verifies the exact OpenVR registration file and refuses drift before
restoration. Profile edits are exact-marker transactions;
cache restoration retains the displaced tree and verifies both sides before
cleanup. Nothing here deletes unclassified MO2 overwrite content or shader
caches.

Unexpected automation behaviour is submitted through `feedback-control`.
Tasks receive a durable `AUTO-...` receipt; only the maintainer triages,
resolves, or deliberately exports a sanitized record. Queue contents stay
local and are never sent to GitHub automatically.

Run the isolated suite with:

```powershell
.\tests\Test-Toolset.ps1
```

Support, privacy, terms, compatibility, clean-install, and release contracts
are documented in the repository root and `docs/`.

The optional MO2 live check is read-only:

```powershell
.\tests\Test-Toolset.ps1 -IncludeLiveMO2
```

## Project status and disclaimer

This is an independent, unofficial community project. It is not affiliated
with or endorsed by Bethesda Game Studios, ZeniMax Media, Valve, Mod Organizer
2, Community Shaders, CSX, or OpenComposite. Product and project names are used
only to identify compatible software; their trademarks belong to their
respective owners.

The tools can modify local MO2 profiles and SteamVR settings. Review the safety
model and keep the generated backups and receipts. The software is provided
without warranty.

## License

Copyright (C) 2026 Treatid2.

This project is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version (`GPL-3.0-or-later`). See
[LICENSE](LICENSE) for the complete terms.
