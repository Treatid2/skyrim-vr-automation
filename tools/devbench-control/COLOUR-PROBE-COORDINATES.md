# Native colour-probe coordinates

This is a source-bound decoding note, not a new API, native schema rename,
capture runner or calibration service. It applies to CSX source
`f4fe744560df1aa890e90f8b794c28983f156c14`,
`src/Features/Upscaling/ColourPipelineProbe.cpp`, Git blob
`d7211f6e13e170175489b4d4897281e2032f2fe0`.

## Crop-local versus original-resource coordinates

Each stage/eye copies its source rectangle into a staging texture whose size is
the crop width/height. The destination copy starts at staging coordinate (0,0).
The native `samples[].sourcePixel` pair is local to this mapped staging crop,
despite the field name. `source.activeRectangle` separately retains the original
source texture's x/y origin and crop dimensions.

For a retained sample with local coordinates (localX, localY):

- Address the mapped staging bytes at
  `localY * mapped.RowPitch + localX * bytesPerPixel`.
- Only when reporting a coordinate in the original source resource, compute
  `(activeRectangle.x + localX, activeRectangle.y + localY)`.

Never add the source origin to staging memory addressing or local bounds.
Use the native mapped RowPitch, which may include padding; width times
bytesPerPixel is not a substitute. Bytes per pixel and channel decoding must
come from the admitted storage/decode format, not the channel count. Preserve
raw little-endian hex, explicit nulls and the original coordinate fields.
The API returns sampled bytes, not an addressable live staging buffer.

The native 17-by-17 grid chooses localX/localY over [0,width-1] and
[0,height-1]. Validate grid/sourcePixel correspondence within the crop before
adding the origin for an absolute-coordinate report. Normalized grid positions
are not original-resource pixel coordinates.

## Right-eye example

An admitted right-eye crop can have activeRectangle.x=1512 while its first
sourcePixel is [0,0]. The first pixel's staging byte offset is 0, not
1512 times bytesPerPixel. If activeRectangle.y=0, its absolute source-resource
coordinate is [1512,0]. A nonzero source y origin is also excluded from staging
addressing. Treat origins, dimensions, subresources and formats independently
for every stage/eye; do not borrow left-eye geometry or assume all stages match.

This executable arithmetic example uses a synthetic padded stride and format
size, not a claim about the live right-eye format or its RowPitch:

<!-- coordinate-example -->
```powershell
$rectangle = @{ x = 1512; y = 0; width = 1512; height = 1680 }
$sample = @{ sourcePixel = @(0, 0) }
$bytesPerPixel = [uint64]8
$rowPitch = [uint64]12288 # synthetic: 12096 payload bytes plus padding
$localX = [uint64]$sample.sourcePixel[0]
$localY = [uint64]$sample.sourcePixel[1]
if ($localX -ge $rectangle.width -or $localY -ge $rectangle.height) {
    throw 'Sample is outside the local crop.'
}
$stagingByteOffset = $localY * $rowPitch + $localX * $bytesPerPixel
$absoluteSourcePixel = @(($rectangle.x + $localX), ($rectangle.y + $localY))
if ($stagingByteOffset -ne 0 -or $absoluteSourcePixel[0] -ne 1512) {
    throw 'Source origin was incorrectly used in local addressing.'
}
[pscustomobject]@{
    stagingByteOffset = $stagingByteOffset
    absoluteSourcePixel = $absoluteSourcePixel
    sourcePixel = $sample.sourcePixel # original retained pair, unchanged
}
```

`Test-ColourProbeCoordinates.ps1` executes this repository-owned example and
checks additional synthetic nonzero-row, padded-stride and nonzero-origin cases.
It does not call DevBench, reopen capture scratch or rerun a native capture.

## Source and qualification limits

In the pinned source, staging dimensions are set at lines442-446, the cropped
source box is copied to destination origin0 at lines460-463, and source x/y are
retained separately at lines470-472. Map reads the staging texture at line574;
local grid coordinates and byte addressing are at lines606-610. The serialized
sourcePixel pair is at lines624-628, with the source activeRectangle serialized
at line747. Line references are for that exact commit/blob, not future heads.

Mapping's corrected offline audit retained its original harness failures and
did not replay live calls. The source clarification concerns coordinate
semantics only. Valid addressing or capture completion does not establish
temporal settling, camera equivalence, causal brightness changes, display
luminance, performance neutrality, or Skyrim/OS HDR behavior. Experiment setup,
calibration and scientific interpretation remain with the experiment owner;
shared cleanup/restoration remain Auto-Tools' responsibility.
