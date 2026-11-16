# Saved stereo image analysis

Use `image_quality_analysis.py` after acquisition, with Python 3.11+ and
PowerShell 7 on Windows. It reads existing PNGs and receipts; it never
connects to Skyrim, starts Tracy, or captures another image. The C# pixel
engine uses PowerShell's System.Drawing assemblies. No Python packages
need to be installed.

```powershell
python tools/devbench-control/image_quality_analysis.py `
  --input '<evidence>/image-analysis-input.json' `
  --output '<new-derived-output-directory>' `
  --ssim-exe '<existing-host-scorer>/score-saved-images.exe'
```

Use `--measure-only` for initial phase review. It emits all frame metrics
without a temporal summary. Review the images, annotate actual phases in
the input, and run into a new output directory. Neither mode overwrites raw
receipts or earlier analysis. Do not classify phases automatically from
raw frame change: water, particles and actors can move in a camera hold.

## Input contract

The JSON schema is `stereo-image-analysis-v1`. Paths are explicit parameters
relative to this JSON; raw receipt paths may remain absolute. Relocated
evidence must retain its capture directory name and internal layout. No
directory glob chooses a sequence or build. Sequence-manifest relative paths
start at the capture directory; relative artifact paths start beside their
owning receipt. Relocated absolute receipt paths always resolve inside the
selected copy, even if the old copy still exists. Escapes and ambiguous
relocations are rejected.

- `run`: capture directory with a `comparison-native-images-v2` manifest
  named `image-manifest.json`; `imageManifestSha256` pins it.
- `mask`: `source:{path,sha256}`, `model`, `fields`, and
  `effectiveRuntimeVerified`. `fields` maps names below to JSON pointers
  in the source receipt. Set the runtime flag true only with actual route
  status proving the effective mask. Saved settings alone leave it false;
  computations remain descriptive.
- Model `squircle` also supplies `power`; fields are `area`,
  `horizontalScale`, `feather`, `leftX`, `leftY`, `rightX`, `rightY`.
  Offsets are relative to eye UV (0.5,0.5). This is the outward-feather
  model from `FoveatedMask.hlsli`.
- Model `rectangle-inward` supplies fields `leftX`, `leftY`, `leftW`,
  `leftH`, their `right` equivalents, plus `featherPixels`, `maskMode`,
  `blendMode`. This is the rectangular `SubrectBlendCS` path. Crop UVs
  must resolve to the actual submitted-eye pixel rectangle; do not use
  an unverified requested crop when the renderer aligns/quantizes it.
  `cropUnits` defaults to `uv`; fractional pixel results are rejected rather
  than rounded. Use `cropUnits: "pixels"` and pointers to the effective
  integer X/Y/W/H fields when the renderer quantizes the crop.
  Unsupported shapes or source transforms fail explicitly.
- `regionPolicy`: `centerDistanceMax` (e.g. 0.9), `outerDistanceMargin`
  (e.g. 0.1 beyond the squircle feather), `safeUvMin`, `safeUvMax`. Safe
  bounds must lie inside [0.1,0.9]. These are analysis selections.
- `regionLabels`: actual `center`, `transition`, `outer` method names.
- `views`: exactly the selected manifest's views, each with `view`,
  `sequenceSha256`, and `phases`. Each phase has `name`, one-based inclusive
  `first`/`last`, `firstTimestampUs`/`lastTimestampUs` from the acquisition
  receipt, and an image-review `basis`. Required order: `initial-hold`,
  `sweep`, `final-hold`; each needs at least three frames for two pairs.
  No universal seconds-based window is substituted. Empty phases are
  allowed only for measurement/review.
- Optional per-view `reference:{path,sha256}` selects an existing stereo
  reference. Also supply `referenceMask` with independent geometry,
  `similarityThreshold`, and `referenceRole` when scoring references.
- `visualReview` records findings and actual image coverage. A computed
  metric is not a visual-review pass. Keep reviewed paths/hashes, the
  camera recipe and native-detail selections with the run.

The analyzer verifies hashes, dimensions, native HMD source, same-cycle
stereo, frame/timestamp continuity and fixed atlas geometry. Both samples
of each adjacent pair must be in the same reviewed phase. This excludes
prefix camera jumps, phase-boundary motion and suffix camera restoration.
All raw frames remain available for diagnosing exclusions.
Missing phase review or a required scoring executable is reported before
pixel processing. These are offline analysis requirements; they do not
change capture duration or invalidate preserved images.

## Reference scoring

`ScoreSavedImages.cpp` is only a host adapter for the existing DevBench
`Ssim.cpp`/`Ssim.h`. Build it once in an existing C++20 developer environment
against DevBench source and its stb/nlohmann include directory:

```powershell
cl /std:c++20 /EHsc /O2 /MD /I'<devbench>/src' /I'<dependency-includes>' `
  tools/devbench-control/ScoreSavedImages.cpp '<devbench>/src/Ssim.cpp' `
  /Fe:score-saved-images.exe
```

Retain source/header and executable hashes. This uses DevBench's decoder
and overlapping-window SSIM unchanged. `golden-requests.json` also contains
the normalized region arguments usable by live DevBench `capture`.

A shared reference rectangle must belong to the actual zone in both
images. If transition bands do not overlap, requests name separate
`candidate` and `reference` band rectangles. Each compares identical screen
coordinates, but is **not** a same-zone-to-same-zone score. Never combine
these into one transition ranking. No usable region is an error rather
than an excuse to score a mixed rectangle.
The rectangle search requires both dimensions to cover DevBench's 8-pixel
SSIM window; a larger, thin strip cannot hide a smaller valid rectangle.

## Outputs and interpretation

`analysis-receipt.json` is published only after every planned measurement
and reference score is validated. Missing/duplicate rows, inconsistent
timestamps or sample counts, non-finite values and incomplete scorer output
are errors. The receipt records hashes of all selected evidence, executed
analysis tools and derived outputs. Inputs/tools are pinned before use and
rechecked before completion. A partial output directory without this
receipt is diagnostic evidence, not a completed analysis; preserve it and
rerun into a new directory after correcting the cause. `computed` means
the metrics are complete, not that image quality passed visual review.

`temporal-per-eye.csv` separates eye, region and phase, with pixel/pair
counts, median/p95 luminance change and pair cadence. No statistic pools
eyes. `frame-metrics.csv` retains all frames and static edge/luminance
measures. Luminance is an integer 8-bit RGB-weighted approximation on a
two-pixel grid. Gradient neighbors also belong to the selected zone.
Numbers differ slightly from older scripts that sampled fewer edge pixels
or crossed region boundaries.

Lower stationary change means less variation, not necessarily better
quality: blur, darkness and animation affect it. SSIM measures similarity,
not quality. Sweep change includes camera motion. Scalar left/right change
agreement is not a stereo-stability score. Review native moving edges in
both eyes; exact pose-matched numeric ghosting claims require pose telemetry
or validated image registration.

Independently review both builds' phases and compare their overlapping
useful time spans and cadence before any cross-build temporal claim. A
contact sheet can reveal gross camera changes/UI; it cannot establish
absence of fine shimmer. Inspect native-size adjacent crops and record
the sampled frames for detailed quality findings.

Validation: `python tests/test_image_quality_analysis.py`. Tests use
temporary synthetic evidence and never contact the game.
