# Fidelstab protocol

## Fixed fixture and settings

- Save fixture:
  `Save14_078AF723_0_5368657A617272696E65356767_Tamriel_000036_20260824155234_1_1`
- Begin each method in `WhiterunBreezehome` / Breezehome.
- Player reference: `0x14`.
- Breezehome interior exit door: `0x000166A9`.
- Breezehome exterior entry door: `0x0001A6F9`.
- Close the CSX menu and all engine menus, including `HUD Menu`, before each
  formal run, profiler capture, and image sequence.
- Render-scale mode: active.
- Quality mode: 3 (`quality`).
- Render eye dimensions: 1644x1826.
- Display eye dimensions: 2468x2740.
- `foveatedVendorDispatch`: true.
- FOV+ / foveated center: 0.3.
- Periphery TAA: enabled.
- Periphery TAA center: 0.3.
- Periphery TAA outer scale: 0.7.
- DLSS profile: K / 1.
- Preserve the configured FSR runtime policy. Verify the actual dispatch
  backend and fallback state; do not silently force FSR3 when FSR4 selection is
  pending.

Verify the producing build ID, source commit, shader-cache ABI, settings,
dimensions, scene, player-loaded state, menu state, requested/effective/stable
method, actual dispatch backend, and both-eye validity before counting a run.

## Method order

Run DLSS first, capture its profiler evidence and HMD images, and only then
switch to FSR. Run the identical FSR protocol and capture its profiler evidence
and HMD images. Do not restart Skyrim between methods unless recovery requires
it and the user authorizes the restart.

When switching methods, wait until the requested, effective, and stable method
agree, render-scale state is active, dimensions are exact, both eyes are valid,
and the actual backend has converged. Discard any diagnostic session used only
to make the switch; reset and start a fresh session for the formal run.

## Two paced door runs per method

For one formal run, use one server-side DevBench scenario containing exactly 20
alternating door transitions. Start inside Breezehome, so transition 1 uses the
interior exit door. Odd transitions use `0x000166A9`; even transitions use
`0x0001A6F9`.

For every transition, execute this exact order:

1. Call `ObjectReference.Activate` on the door with player `0x14` as the
   activator and the default activation flag (`false`).
2. Wait for `Loading Menu` to open.
3. Wait for `Loading Menu` to close.
4. Wait until `playerLoaded`.
5. Wait until `noBlockingMenu`.
6. Wait exactly 5,000 ms, except after transition 20.

This produces 119 scenario steps: 20 activations, 20 menu-open waits, 20
menu-close waits, 20 player-loaded waits, 20 no-blocking-menu waits, and 19
five-second pauses. Run asynchronously and monitor through direct DevBench MCP
without injecting additional game actions or changing timing.

Start a fresh render-scale diagnostic session immediately before the scenario.
Stop it immediately after successful completion and preserve the record. If any
step fails or times out, exclude the whole run. Do not substitute console
teleports, direct cell movement, faster pacing, or a different waiter.

After run 1, wait exactly 20,000 ms through DevBench. Verify Breezehome and
close `HUD Menu`, then repeat the identical 119-step run as run 2.

## Robustness and stretch evidence

For each run preserve and report:

- completed steps and transitions;
- elapsed time and start/end frame;
- method, backend, contract generation, transition epoch, render/display
  viewport, and final frame token;
- resource-publication current state; current, completed, and published
  generations; expected and published dimensions; `complete`, deferred-setup
  acknowledgement, and D3D device/context matches;
- the stress-stop `status.preparation` trace with its raw bounded events,
  session/ring/QPC metadata, and stage summaries for queued requests,
  admission/early exits, shader-cache deferral, SSS/SSGI prewarm,
  DLSS/FSR/FSR4 preparation, D3D creation, total preparation,
  request-to-prepared, and prepared-to-creator;
- fidelity mismatch count;
- duplicate-constants and coalesced-duplicate counts;
- session vendor-failure stretched-eye observations;
- session bounds-mismatch original-fallback observations;
- allowed presentation-stretch eye observations;
- maximum consecutive presentation-stretch frames;
- the measured duration of the maximum stretch only if timestamps or a
  measured frame interval support it; otherwise report frames and say why no
  time conversion is claimed;
- final left/right presentation path and both-eye recovery;
- relevant thread identity, compositor cycle, and frame/cycle information when
  exposed;
- failures, retries, device loss, out-of-memory, lifecycle, and retirement
  state.

Do not call expected transition-stretch observations vendor failures. Keep
allowed transition stretches, vendor-failure stretches, and bounds fallbacks
separate.

## Two 300-frame CPU/GPU captures

After both door runs, close `HUD Menu`. Collect exactly two sequential bounded
300-frame captures. For each capture:

1. When `cpu_performance_*` is exposed, reset and start the dedicated CPU
   capture immediately before the bounded profiler capture.
2. Start a 300-frame CSX profiler capture with clean history.
3. Wait through DevBench until all 300 frames are submitted and resolved.
4. Stop the dedicated CPU capture, then read its status/results.
5. Immediately query the completed CSX capture before starting the next one,
   because completed captures may be evicted.
6. Preserve CPU and GPU results for `Upscaling::SubmitStageUpscale`, including
   average, p95, p99, history count, and capture ID. Also retain relevant
   per-thread or per-cycle CPU diagnostics exposed by the dedicated tool.

If the tested build does not expose `cpu_performance_*`, use the matched CSX CPU
profiler as the CPU source and state that limitation. CPU is the primary
comparison; GPU is contextual secondary evidence.

## HMD image sequence

Capture images after each method's profiler work and before changing away from
that method. Use the asynchronous screenshot API with:

- `sequence.useSettings`: false;
- 16 frames;
- game-frame schedule, interval 6 frames, start delay 0;
- pause policy `hold`;
- skip backpressure with maximum 10 consecutive skips;
- failure policy `continue`;
- source `hmd_submission`, fallback `reject`;
- absolute task evidence directory and overwrite `never`;
- side-by-side PNG output with `sdr_srgb` colour contract;
- frame manifest required;
- preview video not requested.

Require 16 acquired and written frames with zero failures and drops. Inspect at
least frames 1, 8, and 16 for stereo geometry, stretched-eye presentation,
black substitution, asymmetry, moiré, and frame-to-frame instability. Preserve
the manifest and every image.

## Comparison and evidence rules

- Use a fresh task-owned winning loose ShaderCache provider and sentinel for
  each build. Never modify a user-owned cache.
- Complete the cache transaction after game and MO2 shutdown and before
  releasing the workspace. Fail closed and retain the task if real files did
  not materialize or provider binding changed.
- Preserve exact raw identities, settings, scenario records, profiler results,
  CPU-performance results, image manifests, and summaries under a task evidence
  root.
- Compare builds only when fixture, settings, pacing, method, viewport, and
  capture procedure match.
- Report CPU changes first, GPU changes second, and robustness separately. Do
  not claim a performance gain without comparable measurements.
