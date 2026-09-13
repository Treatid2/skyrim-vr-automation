# CSX/Open Shaders VR comparison profile

This directory contains the first-pass, matched-settings profiles for a
controlled VR comparison of Community Shaders Extended (CSX) and Open
Shaders (OS). The profiles are pinned to these source snapshots:

| Fork          | Commit                                     | Commit time                | Reported version |
| ------------- | ------------------------------------------ | -------------------------- | ---------------- |
| CSX `main-VR` | `d748e1089e4f696cb8d34ffc3a6154c279586a17` | 2026-08-26 18:50:38 +01:00 | `CSX 3.19-VR`    |
| OS `main`     | `6f532ca3ecf5bc63324e7ad5b9aa526fce8dabff` | 2026-08-26 10:24:52 UTC    | `2.10.0`         |

Their merge base is `b3db5a75`, with 1,636 CSX-only and 3,815 OS-only
commits at the pinned heads. Do not reuse the profiles against later heads
without rechecking schemas and defaults.

The two files are intentionally separate. The same JSON cannot express the
two upscaling implementations correctly: the Quality enum, DLSS-preset enum,
render-scale switch, and foveation model all have different schemas.

## Files

-   `csx-d748e108/SettingsUser.json`: install as the CSX
    `Data/SKSE/Plugins/CommunityShaders/SettingsUser.json`.
-   `open-shaders-6f532ca3/SettingsUser.json`: install in the same relative
    location when the OS package is active.
-   `image-quality-protocol.md`: machine-only screenshot acquisition, model
    assessment, and visual Pareto rules.
-   `reciprocal-search-protocol.md`: unattended alternating best-response search,
    validity gates, and winner rule.
-   `reciprocal-search.template.json`: campaign manifest that must be filled and
    hashed before an automated search.

Keep a copy of the user's original file. Every setting marked as a boot
disable or used by upscaling, foveation, render scale, and stereo
optimizations requires a complete game restart.

## Comparison contract

The first run holds the high-level output contract fixed:

| Property                      | CSX                                       | OS                                               | Matched result                     |
| ----------------------------- | ----------------------------------------- | ------------------------------------------------ | ---------------------------------- |
| Upscaler                      | `upscaleMethod = 3`                       | `upscaleMethod = 3`                              | DLSS                               |
| Preset                        | `qualityMode = 3`                         | `qualityMode = 1`                                | Quality, 2/3 linear render scale   |
| DLSS model                    | `dlssPreset = 1`                          | `presetDLSS = 2`                                 | Preset K                           |
| Render-scale/performance path | `renderScaleMode = 1`, `perfMode = 1`     | `renderAtUpscaleRes = true`, `vrRenderScale = 0` | Enabled; preset-derived input size |
| Sharpening                    | RCAS, `0.7`                               | RCAS enabled, `0.7`                              | Same requested sharpness           |
| Reflex                        | low latency and markers on, boost/cap off | same                                             | Same policy                        |
| Foveation                     | vendor sub-dispatch plus periphery TAA    | subrect DLSS plus temporal periphery AA          | Enabled, quality-biased treatment  |
| Frame generation              | off                                       | off                                              | Excluded in VR                     |

`vrRenderScale = 0` in OS means Auto, not native resolution. With
`renderAtUpscaleRes = true`, Auto derives its input size from the Quality
preset. CSX expresses the same mode with `renderScaleMode` and the legacy
`perfMode` compatibility field.

The runtime/HMD output resolution is outside `SettingsUser.json`. Set the
same SteamVR per-application resolution, headset refresh rate, OpenVR
recommended render size, game window size, and any driver-level scaling for
both packages. Before accepting a trace, verify the logs or runtime
diagnostics report the same per-eye output dimensions and a 0.666667 Quality
input scale.

Do not stack an OpenComposite or other external upscaler on either profile.
CSX blocks its render-scale path while an OpenComposite-owned upscaler is
active, and double scaling would invalidate the input-resolution match. If
`VRFpsStabilizer.ini` is present, its Interior and Exterior conditional rows
must reproduce the JSON's DLSS Quality/K/render-scale and feature states, or
its CSX profile sync must be inactive. Verify that state after each cell
transition; the JSON alone cannot prevent a conditional override.

## Foveal-area matching

OS uses the `Center 75%` rectangle in each eye:

```
x = 0.125, y = 0.125, width = 0.75, height = 0.75
area = 0.75 * 0.75 = 0.5625 eye area
```

CSX uses a power-4 superellipse rather than a rectangle. Its unit-area
coefficient is:

```
Gamma(1.25)^2 / Gamma(1.5) = 0.9270373387
```

The configured CSX linear scale is therefore:

```
sqrt(0.5625 / 0.9270373387) = 0.7789555034
```

This makes the nominal visible high-quality foveal area 56.25% per eye in
both forks. The boundary shape is not identical: CSX is a rounded power-4
superellipse and OS is a 75% rectangle. That irreducible implementation
difference must be inspected in the visual pass.

This is a visual-coverage match, not a claim that the raw dispatch rectangles
contain the same number of pixels. CSX dispatches a rectangular bound around
the superellipse, expands it for the 0.05 feather, and aligns it to shader
thread groups. OS dispatches its configured rectangular subregion and blends
over a 64-pixel feather. Record the runtime dispatch/input dimensions in
Tracy: any extra bounding/padding work is an implementation result, not a
reason to shrink one fork's visible high-quality area in pass one.

CSX enables its heavier periphery TAA across the entire area outside the
center (`periphery_taa_outer_scale = 1.0`). OS uses temporal smooth periphery
AA, bilinear background stretch, and a 64-pixel feather. These are the
highest-quality comparable treatments without turning the foveated path off.

## Feature-parity policy

Shared rendering features remain loaded and use matched settings where their
schemas overlap. Equivalent controls are mapped even when they live in
different features:

| Functional surface     | CSX                                 | OS                               | Profile treatment                                 |
| ---------------------- | ----------------------------------- | -------------------------------- | ------------------------------------------------- |
| Lighting/atmosphere    | Adaptive Balance                    | OS Utility                       | Identity multipliers                              |
| Water appearance       | Adaptive Balance profiles           | OS Utility water controls        | Identity multipliers                              |
| Vanilla bloom          | Adaptive Balance profile bloom      | OS Utility bloom                 | Default enhancement enabled                       |
| Vanilla depth of field | CS Utility                          | OS Utility                       | Neutral/unlocked                                  |
| Water depth behavior   | Unified Water switch                | Native OS Unified Water behavior | CSX `UseOpenShadersDepthBehaviour = true`         |
| Wet surfaces/rain FX   | Wetterness                          | Wetness Effects                  | Both fully enabled with fork-native quality paths |
| Scene overrides        | Adaptive Balance location overrides | OS Scene Settings manager        | No active overrides                               |

All five CSX Adaptive Balance profiles are identity profiles and location
overrides are empty. This prevents time, interior type, or location from
changing the lighting contract while still exercising the corresponding CSX
implementation. Their bloom profiles use the same intensity, halo,
saturation, tint, and compression values as the enabled OS Utility Default
bloom preset. OS Utility is otherwise set to the same identity values.

OS Scene Settings are stored outside `SettingsUser.json`. For pass one,
`Data/SKSE/Plugins/CommunityShaders/SceneSettings/InteriorOnly.json` must be
absent or contain an empty array, and the
`SceneSettings/InteriorOnly/` overwrite directory must contain no active JSON
overrides. Also remove or pause any feature/weather override in either fork
that would replace values from these profiles. A later quality-matching pass
may use Scene Settings, but its exact override files then become part of the
test input and must be preserved with the result.

The following non-shared rendering features are hard-disabled at boot:

-   OS only: `CloudRelight`, `Effects11`, `ExponentialHeightFog`,
    `HDRDisplay`, `PostProcessing`, `Skin`, and `VanillaFresnel`.
-   Shared but deliberately excluded from pass one: `ScreenSpaceGI`. The two
    implementations and their current qualification/default policies differ
    enough that including it would dominate the comparison.

Developer UI/render hooks are also hard-disabled: `CSEditor`,
`PerformanceOverlay`, `RenderDoc`, and `WeatherPicker`. `Screenshot` stays
loaded for the later visual pass but must not be invoked during a timed
trace. OS `RemoteControl` stays loaded solely as a control-plane equivalent
to CSX/DevBench automation; it is not a rendering feature. Record that
exception if a fully manual run hard-disables it.

`Extended Materials/ExtendShadows` is set to zero because that CSX extension
has no OS counterpart. Shared Extended Materials paths remain enabled.

CSX Wetterness is the functional successor to OS Wetness Effects. The legacy
CSX `WetnessEffects` feature is force-disabled by the AIO policy, so the
profile hard-disables that legacy path and enables Wetterness. OS enables
Wetness Effects and has no Wetterness feature.

Both functional equivalents are fully enabled rather than reduced to their
smallest common subset. CSX keeps its modern wet-reflection path,
weather-driven drying, post-rain response, wet-grass lighting, distance fade,
and feathered foveated-detail optimization. OS keeps its Wetness Effects
surface, wet-grass roughness, raindrops, splashes, custom ripples, and vanilla
ripples. Each uses its pinned-head defaults for numeric artistic controls.

This intentionally measures what each fork can deliver, not identical shader
math. Use dry weather for the primary upscaling trace so dynamic rain state
does not obscure the upscaler result. Run rain as a separate, labeled
Wetterness/Wetness Effects comparison and assess its captured visual result
alongside its performance rather than treating a lower frame time alone as a
win.

## Implementation optimizations

Implementation-level optimizations are allowed even when only one fork has
them. This is intentional: the comparison asks what each implementation can
deliver at the same visible quality contract, not whether their internal
render graphs are identical.

Enabled in CSX:

-   exterior and interior depth-buffer culling;
-   balanced bounded temporal recovery for depth-culling misses;
-   single-cascade interior sun shadows;
-   foveated lighting, SSR, water parallax, and dynamic cubemap work;
-   foveated Wetterness detail without a hard cutoff;
-   dynamic-cubemap visibility throttling;
-   foveated and stereo-synchronized screen-space shadows;
-   fast, incremental, reduced-frequency skylighting probe updates;
-   optimized Unified Water meshes.

Enabled in OS:

-   exterior and interior depth-buffer culling;
-   foveated SSR;
-   VR stereo stencil culling/G-buffer reprojection;
-   foveated and stereo-synchronized screen-space shadows.

Every CSX foveated hard cutoff remains off. OS stereo reprojection uses its
conservative source defaults. Debug views, stereo final-color blending, and
diagnostic logging are off. These optimizations are accepted only if the
visual pass shows no material loss or stereo artifact.

## Extracted default differences

These differences are why copying either fork's defaults is not a fair test:

| Setting                     | CSX default at pinned head                    | OS default at pinned head                     | Profile choice                                |
| --------------------------- | --------------------------------------------- | --------------------------------------------- | --------------------------------------------- |
| Quality enum                | `3` = Quality                                 | `1` = Quality                                 | Fork-specific enum, same 2/3 scale            |
| DLSS preset                 | K                                             | Default/automatic                             | Explicit K in both                            |
| DLSS sharpening             | RCAS `0.9`                                    | off, `0.0`                                    | RCAS `0.7` in both                            |
| FSR sharpening              | `0.9`                                         | `0.0`                                         | `0.7` in both                                 |
| Reflex                      | low latency/markers on                        | all off                                       | low latency/markers on                        |
| FSR4 runtime                | on                                            | off                                           | on; inert for the DLSS run                    |
| Frame generation            | off                                           | on                                            | off                                           |
| Foveation                   | off; 0.3 center; periphery TAA off            | off; Gaussian stretch, temporal AA, hard edge | enabled as described above                    |
| Interior depth culling      | on                                            | off                                           | on                                            |
| Depth-culling temporal mode | Balanced bounded recovery                     | Native result                                 | CSX Balanced; OS has no switch                |
| Cloud-shadow opacity        | `0.8`                                         | `0.5`                                         | `0.8`                                         |
| Basic grass brightness      | `0.75`                                        | `0.8`                                         | `0.75`                                        |
| Vanilla bloom enhancement   | profile intensity `0`                         | Default preset, disabled                      | Default preset enabled in both                |
| Wetness implementation      | Wetterness; legacy Wetness Effects forced off | Wetness Effects                               | Both complete paths enabled                   |
| Grass wet roughness         | Wetterness glossiness `60` = roughness `0.4`  | `0.12`                                        | Fork-native defaults retained                 |
| Sky Sync alternate sun path | on                                            | off                                           | on; fork-specific remaining defaults retained |
| Post-processing suite       | absent                                        | present; several subpasses default on         | OS feature hard-disabled                      |

The source defaults are the baseline for omitted keys. Explicit entries in
the profiles normalize known cross-fork differences and make every critical
comparison control auditable.

## Tracy performance pass

The authoritative route for both performance and visual evidence is
`matrix_int-ext-weather-coc` from `build/tracy-vr-automation` at commit
`29cf460613e0f56956c0e739cc504b2e9c4e75d1`. Preserve its six cases, COC
transition order, weather, hour, timing, state hashes, and capture labels. Do
not substitute a shorter generic route for one fork.

1. Use the exact matrix cell/weather/hour inputs, HMD pose or recorded input,
   refresh rate, SteamVR resolution, reprojection policy, game INIs, load
   order, driver, GPU clocks/power policy, and background processes.
2. Install one fork and its matching JSON. Fully restart Skyrim VR and
   SteamVR if the runtime's render-size contract changed.
3. Let all shader compilation finish. Traverse the complete route once to
   populate shader, pipeline, texture, and streaming caches. Do not interrupt
   an apparently quiet shader build.
4. Confirm the loaded commit/package, hard-disable states, DLSS Quality/K,
   actual input/output dimensions, foveal crop, and optimization states from
   logs or DevBench before timing.
5. Run the complete `matrix_int-ext-weather-coc` route without menus, screenshots,
   overlays, or RenderDoc. Capture at least three bounded Tracy samples after
   warm-up and compare both whole-route and matching checkpoint medians plus
   95th/99th percentile frame time. Report CPU and GPU separately and relate
   the result to the selected HMD frame budget.
6. Repeat from a clean process with the other fork. Preserve each fork's
   compatible shader cache rather than sharing incompatible compiled output.

Do not change Quality, foveal coverage, sharpness, or feature toggles between
forks during this first pass.

The search target is maximum performance subject to a visual constraint: the
candidate must remain at least slightly better-looking than the other fork at
the fixed upscaling contract. A faster but visually worse profile has not won;
use the iterative loop below to spend or recover visual headroom.

## Iterative Tracy and image-quality loop

Use the same two JSON files and exact `matrix_int-ext-weather-coc` cases. Its
established state and capture labels define the comparison matrix; do not add
an unmatched scene to only one fork. The complete capture-validity, blinding,
drift-control, objective-vector, blocker, repeatability, and Pareto-dominance
rules are defined in
[`image-quality-protocol.md`](image-quality-protocol.md).

For unattended optimization, use the reciprocal incumbent/challenger state
machine, measurement validity gates, and fail-closed stopping rule in
[`reciprocal-search-protocol.md`](reciprocal-search-protocol.md). Materialize
and hash `reciprocal-search.template.json` before round zero; null or
placeholder fields block a run.

Capture static and moving sequences per eye at its checkpoints, including:

-   high-contrast geometry crossing the foveal boundary;
-   foliage, hair, alpha-tested detail, and specular highlights;
-   water reflection/refraction, shoreline transitions, and rain if the chosen
    secondary route includes it;
-   disocclusions and near-camera objects that stress OS stereo reprojection;
-   head motion that exposes temporal shimmer, ghosting, seams, or stereo
    mismatch.

Use automated diagnostics and blinded model assessment for center detail,
peripheral stability, boundary visibility, motion stability, and stereo
consistency. No human viewing or judgment participates. The first result is a
matched-settings comparison, not a claim about headset-lens or panel quality.

Run performance and image capture as separate repetitions of the same route;
the screenshot/sequence pipeline must not run inside the timed Tracy sample.
For every iteration:

1. Start both forks from clean processes with their compatible warmed caches.
2. Collect the bounded Tracy repetitions and calculate CPU/GPU median,
   95th, and 99th percentile frame times.
3. Repeat the route outside Tracy's timed window and collect synchronized
   left/right screenshots plus motion sequences through the imaging pipeline.
4. Review the images as an unweighted evidence vector for correctness, center
   detail, periphery detail/stability, temporal artifacts, foveal seam
   visibility, water/wetness, tone, and stereo consistency. Use the balanced
   A/B/A and B/A/B schedule; preserve the raw eye images and pipeline output.
5. If neither profile meets the stopping criterion below, change one
   fork-specific lever supported by the visual evidence, restart, and repeat
   the complete pair.

Iteration zero keeps DLSS Quality, output resolution, sharpening, and visible
foveal area fixed. Later iterations keep the DLSS Quality input resolution
fixed but may spend demonstrated visual headroom through foveal coverage,
feather/periphery treatment, hard-cutoff policy, stereo reprojection, or
other fork-native performance controls. CSX depth-culling Performance Mode is
one such later lever: it removes bounded recovery work but may briefly hide a
newly visible object during head motion. Change one logical lever at a time
and record its old/new value, rationale, and expected effect.

Do not discard earlier results or silently redefine the baseline. If one
fork starts with better image quality, increase only that fork's performance
aggressiveness until it either still looks better and becomes faster, or the
visual advantage is exhausted. If one starts faster, improve its visual
settings until it either still remains faster and becomes better-looking, or
the performance advantage is exhausted.

Declare a winner when the same tested profile is:

-   at least slightly, repeatably better-looking in the preserved
    screenshot/sequence assessment; and
-   maximally faster within the tested tuning envelope: the limiting frame-time
    improvement is larger than run-to-run noise, and every remaining plausible
    one-step performance increase either removes the visual lead or fails to
    improve the measured bottleneck.

Use GPU frame time as the primary upscaling metric when GPU-bound and CPU
frame time when CPU-bound; the non-limiting side must not materially regress.
“Maximally faster” means the best verified point among the tested controls,
not an unmeasured theoretical maximum. If no profile is both visually ahead
and faster, preserve the frontier and continue iterating.

## Known residual differences

-   Foveal boundaries are rectangle versus power-4 superellipse. Their visible
    areas match, but dispatch bounding and padding costs do not necessarily
    match.
-   CSX periphery TAA and OS temporal periphery smoothing are different
    algorithms.
-   OS stereo reprojection has no identical CSX implementation; CSX has more
    feature-specific foveated work reductions.
-   CSX Balanced depth culling can recover a bounded set of newly visible
    objects; OS uses its native culling result and has no matching mode switch.
-   Sky Sync and Subsurface Scattering expose fork-specific controls and
    internal paths. The profiles match shared controls and retain safe
    fork-specific defaults.
-   Wetterness and Wetness Effects share the user-facing role but use different
    puddle/drying/reflection implementations. Rain is therefore a separate
    qualified scenario, not part of the primary upscaling number.
-   Exact input pixels depend on runtime rounding of the common 2/3 scale.
    Runtime-reported dimensions, not the nominal percentage, are authoritative.
