# Saved image-analysis validation

Measured CSX source: `b4c97884f0945d55e293d4ee96f23281502f3671`.
Build ID: `5a830231b804014c6a8404d37cc7358a552b34af053141bfbfa6b18ade611123`.
Older OS still source: `313277eed7546a024c35d5e7f6b80e52f719c3eb`.
These identities describe the images, not later renderer history rewrites.

The offline rerun verified 625 burst PNGs, six CSX stereo stills and six OS
reference stills. The analyzer produced 108 separate eye/region/phase
summaries and 48 zone-contained native SSIM scores. Raw evidence stays in
the retained comparison campaign; it is not committed to automation.

| View | Initial hold | Sweep | Final hold | Excluded camera artifacts |
| --- | --- | --- | --- | --- |
| Entrance | 1–22 | 23–59 | 60–87 | None |
| Main hall | 1–27 | 28–75 | 76–110 | None |
| Upper gallery | 5–25 | 26–64 | 65–91 | Prefix 1–4 |
| Guardian Stones | 1–26 | 27–68 | 69–113 | Reset/tail 114–120 |
| Riverwood approach | 1–21 | 22–49 | 50–83 | Reset/tail 84–112 |
| Riverwood endpoint | 1–20 | 21–47 | 48–75 | Reset/tail 76–105 |

These one-based ordinals are historical evidence, never reusable phase
windows. Image review covered every atlas in reduced contact sheets and
selected native-size adjacent pairs/triples in both eyes. No visible UI was
observed in those regions. Native fine-artifact review was sampled; it does
not certify absence of every temporal artifact. All routes retained complete
usable phases, so no recapture was needed for these analysis corrections.

The older OS settings and measured-source shader show a rectangular inward
64-pixel feather and Gaussian blur plus temporal smoothing. CSX uses an
outward squircle feather. Their sampled transition bands do not overlap.
Rectangles at 1512×1680 per eye were: shared center (564,712,384,256), CSX
band (1134,712,75,256), OS band (1070,712,64,256), and shared safe outer
(1222,1200,139,256). Scores preserve separate band ownership. Lower change
and higher SSIM do not establish better quality.

Validation performed:

- `python tests/test_image_quality_analysis.py`: 10 tests passed, including
  native pixel fixtures, zone containment, border exclusion, changed mask
  offsets/dimensions, disjoint bands, hash failures and phase/pair selection.
- Both real capture inputs completed through `image_quality_analysis.py`;
  every selected hash and acquisition/geometry check passed.
- The host adapter linked DevBench `Ssim.cpp` unchanged. Rescoring all 36
  original rectangles reproduced all original native scores exactly
  (maximum absolute error 0), before selecting corrected rectangles.
- Native scorer source SHA-256:
  `207f337702ea5b0bfceb6b29fac987f314af0f06c121095f15451779cdf3953c`.

The fresh OS temporal comparison remains pending acquisition. Historical
CSX effective per-image mask status was not recorded; saved settings/model
provenance is retained as such. No per-frame camera pose was recorded, so
numeric pose-aligned ghosting/stereo-quality ranking is not established.
Neither limitation requires new instrumentation for the qualitative
comparison. No renderer build, game operation or performance run was made
for this validation.

## Adversarial review and regression validation

Scope remained the saved-image analyzer and its protocol. No renderer,
capture cadence, acquisition timeout or production instrumentation changed.
The review corrected these cases before the fresh OS comparison:

- Relative and relocated sequence paths now share the artifact resolver.
  Existing original copies cannot override the selected capture; path escapes
  and ambiguous relocations fail explicitly.
- The largest-rectangle search now applies the minimum SSIM window while
  searching. A larger thin strip no longer hides a usable 8-by-8 rectangle.
- Rectangular crop coordinates must resolve to exact pixels, with explicit
  pixel metadata supported for quantized crops. Silent rounding is removed.
- Empty sequences, malformed geometry, unsupported image orientation/encoding,
  inconsistent stereo colour metadata and pixel-buffer overflow are rejected.
- Every planned frame/eye/zone row must exist once with matching timestamp,
  pixel count and finite measurements. Scorer coverage and verdicts are also
  checked; partial output cannot receive a completion receipt.
- Evidence and executable/source hashes are pinned before processing and
  verified again before completion. Output hashes accompany the receipt.

DRY review retained DevBench's existing SSIM implementation and the single
mask-selection function. No second scoring formula, image decoder or mask
model was introduced. Sequence and artifact relocation now use one helper.

Validation after these corrections:

- `python tests/test_image_quality_analysis.py`: 17 tests passed, including
  malformed receipt fixtures, missing/duplicate/non-finite metrics, scorer
  mismatches, relocation with both copies present, fractional crops, smaller
  valid rectangles, input mutation during processing and C# overflow guards.
- Both complete saved-route analyses passed again: 625 burst frames,
  six CSX stills, six OS references, 108 phase summaries and 48 SSIM scores.
- All frame metrics, temporal summaries, score requests/results and
  region/phase audits were byte-identical to the prior verified outputs.
  The interpretation and measured results above remain unchanged.
- Completion receipts pinned 301 interior and 350 exterior evidence files;
  all seven derived-file hashes in each receipt were independently checked.

The new receipts are in the retained campaign's `interior-adversarial` and
`exterior-adversarial` directories. Original inputs, images and previous
analysis outputs remain preserved.
