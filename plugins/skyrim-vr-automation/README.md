# Skyrim VR Automation Toolkit

This repository provides external PowerShell automation for repeatable Skyrim
VR development and testing. The controls cover Mod Organizer 2, SteamVR's null
HMD, profile transactions, and reusable compiled shader-cache management. CSX DevBench is an
optional integration rather than the identity or boundary of the toolkit.

## Included tools

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
  strict ownership of newly created mods. Its local-work catalog offers an
  explicit modlist-only baseline or selected local builds without changing the
  maintained source profile.
- `tools/steamvr-null-control` — transactional null-HMD apply/restore and
  bounded SteamVR shutdown, with a required application-observed standing
  head-pose qualification and opt-in exact-driver isolation for conflicting
  OpenVR display redirectors.
- `tools/steamvr-head-pose-control` — install, inspect, update, and independently
  qualify the bundled SteamVR head-pose provider used by null-HMD sessions.
- `tools/devbench-control` — a small MCP client for the DevBench endpoint
  exposed by a running CSX build, with listener/process/build/artifact binding
  and normalized semantic results.
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
- `tools/build-test-control` — CTest-aware branch testing with a direct-test
  fallback when a configured build contains test binaries but registers none.

The preserved null-HMD profile is `profiles/steamvr-null.profile.json`. The
provider is a native SteamVR server driver because SteamVR needs a valid head
pose before Skyrim and CSX DevBench exist. DevBench may later update its
versioned shared-memory pose contract, but it is not the bootstrap provider.

## Codex plugin

The repository publishes a Codex marketplace plugin. Its seven skills connect a
new task to the bundled implementations and their operational contracts:

- `$feedback-control` records unexpected automation behaviour and concrete
  enhancement requests in a durable local queue; it never publishes them.
- `$mo2-control` routes MO2 inspection, exact-profile lifecycle management,
  and transactional profile edits.
- `$steamvr-null-hmd` routes backed-up SteamVR null-HMD apply/restore and
  bounded runtime shutdown.
- `$devbench-control` discovers and calls the exact loopback DevBench MCP API.
- `$profiler-control` captures bounded GPU/CPU timer evidence and compares runs.
- `$shader-cache-control` prepares tasks from compatible known-working compiled
  caches, restores prior state, promotes verified results, and compares trees
  by SHA-256.
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

## Local setup

The repository contains no tracked machine paths or credentials. The preferred
MO2 configuration is independent of the checkout or plugin cache. Initialize
it with the bundled doctor:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 init
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

Then edit `%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`. An explicit
`-ConfigPath` or `SKYRIM_VR_AUTOMATION_CONFIG` can select another file.
Before setup is ready, live-load one known-good save in the maintained source,
declare it through `defaults.newGameFixtureManifest`, and require both
`fixture-status` and the doctor's `prime-profile-world-entry-integrity` check to pass.
See `docs/INSTALL-CODEX.md` and `docs/BREEZEHOME-SAVE.md`.

Optional local builds are declared through
`defaults.localWorkModCatalog`. Copy
`tools/mo2-workspace-control/local-work-mods.example.json` to an ignored local
path, replace its exact mod names, then use `list-local-work-mods` before fresh
workspace creation.

DevBench runtime discovery is supplied either explicitly or through an
environment variable:

```powershell
$env:CSX_DEVBENCH_RUNTIME_PATH = 'C:\Path\To\overwrite\SKSE\Plugins\devbench\runtime.json'
.\tools\devbench-control\Invoke-DevBenchControl.ps1 list
```

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
