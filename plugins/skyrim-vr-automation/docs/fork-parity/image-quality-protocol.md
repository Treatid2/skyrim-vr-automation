# Fork image-quality protocol

This protocol defines the visual half of the CSX/Open Shaders comparison. It
uses the same scene identity as the Tracy run, but image acquisition always
runs outside the timed Tracy window.

The source matrix is `matrix_int-ext-weather-coc` from
`build/tracy-vr-automation` at commit
`29cf460613e0f56956c0e739cc504b2e9c4e75d1`. Record the matrix SHA-256 emitted
by the runner with every result; the branch name alone is not an identity.

## Existing foundation

The available automation already supplies two useful contracts:

-   the Tracy matrix fixes six cells, weather, time, warm-up, settling, state
    hashes, repetition labels, and COC stability barriers;
-   screenshot contract `csx.screenshot` version 1 provides asynchronous HMD
    capture, coherent eye planes, multi-output lossless images, game-frame
    scheduling, final manifests, artifact hashes, and explicit
    failure/drop/fallback state.

The preserved `fidelstab` screenshot recipe supplies a service preflight: 16
game-frame samples at six-frame intervals, pause policy `hold`, skip
backpressure with at most ten consecutive skips, failure policy `continue`,
`sdr_srgb` output, a required manifest, and no preview video. The published
cost/benefit runs then established the comparison recipe used below: 12 raw
left/right BMP pairs at ten-game-frame spacing. It completed without drops,
whereas short-cadence PNG compression caused backpressure.

The CSX cost/benefit methodology is published on
`origin/feat/preset-calibration-automation` at commit
`39b8b56324be66f5b290e894409edda7e35f1a1c`, principally under
`docs/development/preset-automation/`. It establishes the rules used here:

-   visual review uses a pinned image-capable model and fixed protocol;
-   timing and image acquisition are separate experiments;
-   raw left/right lossless eye captures are authoritative and combined views
    are derived;
-   A/B/A return-to-baseline and reversed ordering separate an effect from
    scene drift;
-   correctness constraints apply before optimization; and
-   the result is a multi-objective evidence vector and Pareto frontier, not a
    weighted scalar quality score.

The published cost measurements are currently AMD-specific. This protocol
reuses their experimental method, not their numeric costs. Maintain a separate
frontier per GPU architecture/device and driver, and do not generalize an AMD
cost ranking to another vendor without measuring it there.

These contracts make the capture attributable and repeatable. They do not by
themselves define which image looks better, so this document adds capture
qualification, blinding, review objectives, and a dominance rule.

## Recorded automation guidance

> "Find a scene with the problem and tell Sol to take snapshots."

> "Sol is good at understanding images. 'Quality' isn't defined:
> multi-objective fitness landscape + Pareto frontier."

Treat the image model as a blinded fault localizer and paired evaluator, not as
an oracle or ground-truth metric. Every reported defect must identify the
case, eye, frame range, and region; state confidence; and propose a testable
renderer hypothesis. A hypothesis becomes a finding only after the capture,
reverse-order, and targeted-ablation evidence supports it.

## Instrumentation precondition

The pinned CSX head contains DevBench tool `communityshaders.screenshot`,
which implements the `csx.screenshot` contract. The pinned OS head does not
contain the versioned screenshot service. A comparison must not call the
service for CSX and silently use a desktop-mirror or legacy-menu capture for
OS.

Use visual-only builds made from each pinned fork head with the same screenshot
contract and HMD-submission acquisition semantics. The OS visual build requires
a minimal screenshot-service instrumentation port. Preserve the source patch,
artifact SHA-256, DevBench runtime binding, contract response, and capability
response for both builds. The port must not change shaders, feature settings,
upscaler state, HMD submission bounds, or colour processing outside capture.

The exact-head Tracy builds remain authoritative for performance. Do not run
the screenshot sequence during a Tracy capture, and do not use a visual-only
instrumented OS build as exact-head performance evidence.

Before the first comparison, call `capabilities` on both builds and require:

-   contract `csx.screenshot`, major 1, with the schema revision recorded;
-   source `hmd_submission`;
-   views `left_eye` and `right_eye`;
-   BMP and the `sdr_srgb` colour contract;
-   game-frame scheduling and multi-output capture;
-   an absolute destination with overwrite policy `never`.

If either build cannot satisfy the same descriptor, the visual comparison is
blocked. Do not fall back to `desktop_mirror`: it is not the same pre-distortion
HMD image and may have a different crop, eye, resolution, or colour path.

## Matrix cases

Use all six cases without changing their cell, weather, or hour:

| Case                   | Visual focus                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| `exterior-clear-noon`  | distant detail, terrain, skylighting, shadow edges, bloom and foveal transition             |
| `exterior-heavy-rain`  | Wetterness/Wetness Effects, wet grass, puddles, rain, ripples and reflections               |
| `forest-clear-noon`    | foliage and alpha detail, shimmer, thin geometry, shadows and peripheral stability          |
| `water-clear-noon`     | reflection/refraction, shoreline transitions, specular stability and water detail           |
| `interior-many-lights` | local-light detail, bloom, shadow stability, exposure and depth-culling visibility          |
| `exterior-fog`         | low-contrast reconstruction, haloing, banding, volumetric stability and distant silhouettes |

SSGI remains disabled by the iteration-zero settings, so the matrix's original
SSGI focus label is not scored. Fork-native effects that are enabled by the
comparison profile do count: the aim is to assess the complete image each fork
delivers, not identical shader math.

## Per-case capture procedure

For each fork, iteration, case, and repetition:

1. Reach the matrix runner's exact-cell `upscalingStable` barrier.
2. Apply and lock the case weather and game hour. Require exact observed cell,
   weather key/editor ID, inactive weather transition, and positive matching
   render/display dimensions.
3. Capture the normalized feature and upscaling states and their SHA-256
   values. They must match the corresponding comparison profile and remain
   unchanged after image acquisition.
4. Use the matrix's 10-second settle and one untimed 30-second stationary
   warm-up. Shader compilation, loading recovery, upscaler transition, and
   screenshot worker backlog must all be inactive before submission.
5. Submit `sequence_start` with `sequence.useSettings = false` and:
    - 12 frames;
    - `game_frames`, interval 10, start delay 0, pause policy `hold`;
    - skip backpressure, maximum 10 consecutive skips;
    - failure policy `continue`;
    - source `hmd_submission`, fallback `reject`;
    - native-size `left_eye` and `right_eye` outputs from the same acquisition,
      with no crop or resize;
    - lossless BMP with `sdr_srgb` for every output;
    - an empty absolute task evidence directory and overwrite `never`;
    - a required frame manifest and no preview video.
6. Tag the request with matrix hash, case ID, repetition, fork profile,
   iteration, build ID, and phase (`static` or `motion`).
7. Poll the request to a terminal state, acknowledge the terminal receipt, and
   preserve the final manifest, every BMP, DevBench binding receipt, pre/post
   state snapshots, and screenshot capability response.

One initial sequence per case is sufficient for exploration. A final winner
requires the balanced sequence schedule below for every case and repetition:

```text
A-before -> B -> A-return
B-before -> A -> B-return
```

Redeploy and settle the named build at every arrow; never switch settings in
place and call it an independent phase. The first cycle compares B with the
mean of its flanking A captures, and the reversed cycle compares A with the
mean of its flanking B captures. Use three independent complete repetitions of
both cycles for a final decision. This guards against warm-up, weather,
exposure, animation, and run-order drift.

## Static and motion evidence

The checked-in matrix scenario is stationary. Its sequences are valid for
spatial reconstruction, ambient animation, rain/water motion, exposure, bloom,
materials, and gross stereo faults. They are not sufficient by themselves for
a final temporal-upscaling or foveal-boundary decision.

Before declaring a winner, repeat the same six cases with one task-owned,
versioned DevBench VR recording that performs a modest deterministic head/camera
sweep. Preserve the recording and its SHA-256, and replay it identically for
both forks. It must cross high-contrast geometry, foliage, water/specular
detail, and a near disocclusion through the fixed foveal boundary. If no such
recording has been selected and preserved, mark motion, disocclusion, and
foveal-transition assessment `not qualified`; the comparison cannot stop.

The screenshot capture remains separate from Tracy even when the same motion
recording is used for both.

## Capture qualification gate

A sequence is comparison-quality only when all of the following are true:

-   the matrix, case, condition, feature-state, upscaling-state, motion-recording,
    build, runtime, and screenshot-contract identities are complete and match;
-   the terminal manifest is `final` and the parent request is `completed`;
-   all 12 scheduled frames were acquired and written, with zero dropped,
    failed, cancelled, or fallback frames;
-   every ordinal has exactly one left-eye and one right-eye BMP;
-   source resolved to `hmd_submission` with `fallbackUsed = false`;
-   left and right planes are valid and coherent for the same compositor cycle;
-   input/output dimensions, submitted bounds, orientation, DXGI format,
    tonemap decision, and `sdr_srgb` contract agree across compared builds;
-   every artifact exists, decodes, has the declared dimensions and nonzero size,
    and matches its recorded SHA-256;
-   the feature and upscaling state hashes before and after acquisition match.

An invalid capture is rerun and never scored. A capture failure is not a visual
defect unless the receipt is valid and the defect exists in the written HMD
submission image.

## Derived comparison products

Keep source BMPs immutable. Write all derived material to a separate directory
and record the tool versions and arguments that produced it.

For each matched case/repetition create:

-   a neutral-label A/B full-frame viewer at 1:1 pixels;
-   synchronized left-eye and right-eye views;
-   a lossless side-by-side stereo view derived from the two source eyes;
-   integer-zoom crops for the center, foveal-boundary band, and far periphery;
-   fixed normalized scene-specific regions of interest reused for both forks;
-   a 12-frame synchronized loop and a contact sheet containing at least
    ordinals 1, 6, and 12;
-   unclamped linear-RGB difference and temporal-residual maps for diagnosis.

Do not sharpen, denoise, tone-map, register, spatially warp, or use lossy video
before review. Full-frame display scaling must be identical. Pixel inspection
uses integer zoom; any convenience preview is non-authoritative.

## Automatic diagnostics

Automatic analysis is a guard and localization aid, not the winner vote.
Record at least:

-   black/near-black frame fraction and clipped-shadow/highlight fraction;
-   decoded dimensions, colour metadata, and eye/compositor coherence;
-   luma/chroma histograms and exposure drift;
-   edge acutance and overshoot/undershoot in fixed high-contrast regions;
-   frame-to-frame luma and edge residuals in static regions;
-   foveal-boundary residual energy and far-periphery temporal variance.

Apply the published A/B/A drift analysis separately to each eye. For each
phase, take the temporal median in RGB. Let `before` and `returned` be the two
captures of the flanking build and define:

```text
reference = (before + returned) / 2
luma(rgb) = 0.2126 R + 0.7152 G + 0.0722 B
effect = abs(luma(candidate) - luma(reference))
drift = abs(luma(before) - luma(returned))
stable = drift <= 2 and max_temporal_delta <= 2
visible = effect >= 2
above_drift = effect > max(2, 2 * drift)
```

The luma thresholds are code values in the decoded 8-bit `sdr_srgb` evidence.
Record the sampling stride, temporal-window definition, stable-pixel fraction,
visible-effect fraction, above-drift fraction, and effect mean, median, p95,
and p99. Preserve diagnostic panels rather than altering source images.

An apparent difference is repeatable only if its direction agrees in the
forward and reversed cycles and in at least two of three repetitions. Require
left/right agreement for binocular or geometry claims; record legitimate
eye-local content separately instead of averaging it away.

More sharpness or more temporal change is not automatically better. A high
edge score can be ringing, and rain, foliage, water, particles, or exposure
changes can make temporal residuals legitimate.

For rain, water, foliage, and other animated content, also record consecutive-
frame absolute-luma deltas and the fraction above 1, 2, and 5 code values per
eye and fixed 3-by-3 image region. These diagnose where activity occurs; their
ordering does not itself rank temporal quality because legitimate scene motion
can dominate the energy.

Reuse the established implementations
`tools/analyze-visual-ablation.py` and
`tools/analyze-wetness-temporal-sequences.py` from the pinned calibration
commit above, or a reviewed successor with its commit and content hashes
recorded. They are analyzers, not an authority to collapse the evidence into a
winner score.

Do not use cross-fork PSNR, SSIM, MS-SSIM, or LPIPS as an overall quality
ranking. Neither fork is a ground-truth reference, and legitimate changes to
lighting, bloom, wetness, water, and reconstruction phase will be counted as
error. If a native/DLAA reference is later captured for each fork, those
metrics may describe each fork's upscaling degradation relative to its own
reference, but remain diagnostic rather than the final fork vote.

## Blinded model assessment

Blind the fork identity and randomize A/B presentation independently for each
case/repetition while keeping both eyes and all 12 frames from one sequence
together. Preserve the sealed mapping and reveal it only after the scorecard is
complete.

Review the full image, center, boundary, periphery, both eyes, and 12-frame
loop. Run two blinded passes with the displayed A/B order swapped. If an
objective's sign reverses between passes, record it as indeterminate unless a
new, independently randomized repetition resolves the disagreement. Frames
are evidence within one sequence; they are not sixteen independent votes.

Use the following paired scale, always expressed as candidate minus reference:

| Score | Meaning                                  |
| ----: | ---------------------------------------- |
|  `-2` | candidate is materially worse            |
|  `-1` | candidate is slightly but clearly worse  |
|   `0` | tie, imperceptible, or inconsistent      |
|  `+1` | candidate is slightly but clearly better |
|  `+2` | candidate is materially better           |

Assess an unweighted evidence vector. Do not add its components together:

| Objective               | What to assess                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| Correctness/structure   | missing or substituted content, geometry, depth, occlusion and material correctness          |
| Reconstruction/detail   | center detail, thin geometry, aliasing, texture stability, ringing and oversharpening        |
| Temporal/history        | shimmer, ghosting, trails, disocclusion and rain/water/foliage stability                     |
| Foveation/periphery     | seam visibility, transition stability, peripheral clarity and distraction                    |
| Stereo consistency      | eye asymmetry, divergent detail, disparity discontinuity and geometry mismatch               |
| Scene-specific fidelity | the case's water, wetness, bloom, lighting, shadow, fog or foliage focus                     |
| Tone/colour             | exposure, shadow/highlight retention, colour stability and banding                           |
| Scene coverage          | whether the claimed advantage survives all relevant matrix conditions and motion evidence    |
| Confidence/maturity     | repeatability, reverse-order agreement, eye agreement, capture validity and unresolved risks |

Mark an objective `N/A` only when it cannot occur in the case. Mark a visible
difference `0` when it remains within the measured drift/temporal uncertainty,
not when its direction is inconvenient.

## Sol-assisted review method

Give the image model neutral candidate labels, the immutable original-detail
left/right frames, lossless loops, and fixed integer-zoom crops. Never ask for
a decision from thumbnails, recompressed chat previews, or the derived
difference panel alone.

Use two passes:

1. **Fault localization:** without fork identities or performance results,
   identify visible anomalies and the exact eye, ordinal/frame range, and ROI.
   Separate observation from a likely producing pass or renderer hypothesis.
2. **Paired preference:** compare the same evidence under the objective vector
   and `-2..+2` scale, then repeat with A/B display order swapped.

Record each model finding as structured data containing:

-   model/runtime version and prompt/protocol revision;
-   objective, case, repetition, A/B/A phase, eye, frame range, and normalized
    ROI;
-   paired sign/severity, confidence, and concise visible description;
-   likely producer/pass, competing explanations, and the next discriminating
    ablation or scene to capture.

The model may propose a focused follow-up scene when a matrix image exposes a
likely failure mode. Add that scene to the cost/benefit library with a stable
DevBench recording, condition/state hashes, and provenance; do not silently
replace or cherry-pick the six canonical matrix cases. If original-resolution
inspection is unavailable, or the preference changes when labels/order are
swapped, mark the observation unqualified or tied.

## Visual blockers

The following are hard blockers when present in a valid capture and either
severe once or reproducible in at least two of three repetitions:

-   black or substituted eye, wrong eye order, stretched geometry, or material
    left/right asymmetry;
-   missing geometry, depth-culling pop, or persistent disocclusion hole;
-   a plainly visible foveal hard seam or distracting peripheral transition;
-   severe shimmer, ghosting, smearing, ringing, or stereo divergence;
-   materially broken water, wetness, bloom, lighting, shadow, or fog output;
-   clipping or colour conversion that destroys scene information.

A blocked profile cannot be called better-looking regardless of advantages in
other objectives. Record whether the issue is renderer output, capture
instrumentation, or unresolved; only renderer output counts against the fork.

## Pareto visual-decision rule

Apply capture and correctness gates first. Then retain a case/objective sign
only when all applicable evidence agrees:

-   the effect is above the measured A/B/A drift and temporal-noise floor;
-   forward and reversed deployment orders have the same direction;
-   at least two of three independent repetitions reproduce it;
-   both eyes agree when the claim is binocular or geometry-related; and
-   the blinded review remains consistent when A/B presentation is swapped.

The retained ratings form a visual evidence vector. Do not average objectives,
cases, eyes, or model passes into a scalar that can hide a regression. Candidate
`X` visually dominates candidate `Y` only when X is no worse than Y in every
applicable qualified objective and is clearly better in at least one.

For this comparison, X is **at least slightly better-looking** only when:

-   X has no hard visual blocker;
-   X has no repeatable negative result in any applicable case/objective;
-   X has at least one repeatable `+1` or `+2` result;
-   the blinded holistic check agrees wherever the objective vector reports a
    visible difference and is negative in no qualified case; and
-   the result has medium-or-higher model confidence.

Differences within drift, uncertainty, or the perceptual indifference region
are ties, not wins or losses. Reverse the signs and apply the same rule to Y.
If each candidate wins a different objective, both remain on the Pareto
frontier: there is no visual winner and iteration continues. Never trade away a
qualified visual regression by compensating for it with unrelated strengths.

Performance remains a separate objective vector, including GPU central/tail
cost, CPU cost where relevant, and stability. A final winner must visually
dominate and be the fastest qualified tested profile; a profile that is faster
but visibly worse is only a cost/quality tradeoff point on the frontier.

## Scope boundary

No human viewing or judgment participates in this test. The winner claim is
limited to the captured pre-distortion `hmd_submission` images and the measured
performance lane. Headset lenses, panels, post-submission compositor/driver
processing, and physical binocular comfort are outside the claim; they cannot
be inferred from this evidence and are not a hidden acceptance gate.

## Iteration and stopping

Iteration zero compares the aligned Quality profiles without spending visual
headroom. Later iterations may change one fork-native performance lever at a
time. Capture and review both forks again under the same complete protocol; do
not compare a new candidate against stale images from a different matrix,
recording, runtime, or screenshot contract.

If the leading fork has more visual quality than required, performance settings
may be made more aggressive until it retains the slight lead. A faster profile
that loses visual dominance has crossed the acceptable frontier and is not the
winner.

This document qualifies the visual objective only. The alternating optimizer,
measurement-validity gates, reciprocal exhaustion proof, and final joint
visual/performance stopping rule are defined in
[`reciprocal-search-protocol.md`](reciprocal-search-protocol.md). An image
result that passes here cannot become an anchor until its corresponding
performance and lifecycle evidence also qualifies there.

## Minimum scorecard record

Preserve, for every iteration:

-   pinned fork heads and visual-instrumentation commits/artifact hashes;
-   matrix file/hash, screenshot contract/capabilities, runtime/HMD identity,
    GPU architecture/device/driver, render dimensions, motion recording/hash,
    and analysis-runtime identity;
-   both SettingsUser files and normalized feature/upscaling state hashes;
-   every terminal receipt, final manifest, source BMP, and derived-product
    manifest;
-   capture qualification result and exclusions with reasons;
-   blinded mapping, pass order, structured findings, objective ratings, notes,
    blockers, model/runtime version, and prompt/protocol revision;
-   per-eye A/B/A drift diagnostics, reverse-order/repetition agreement, the
    retained evidence vector, Pareto dominance relation, and lead/tie decision;
-   the Tracy evidence used for the corresponding performance decision.
