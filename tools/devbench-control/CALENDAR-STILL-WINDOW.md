# Finite calendar-held stereo still window

`Invoke-DevBenchControl.ps1 calendar-still-window` is a typed, finite composition
of native **still** captures under the original same-session calendar lease.
It is not a continuous screenshot sequence, exact uniform cadence, physics
freeze, exposure treatment, quietness assay or scientific-map acceptance.

Supply `-StillSeriesPlanJson`, `-CalendarOwner`, complete pinned runtime/artifact/
build identity, `-MaxTransientRetries 0`, an explicit `-EvidenceDirectory`, and
20..180 seconds total timeout. The calendar hold must cover that total timeout.
Do not also supply generic tool arguments, observations, colour plans, expected
error overrides or `RequirePerformanceNeutral` (neutrality is mandatory inside
this workflow rather than an optional outer claim).

The plan has exactly these seven fields:

```json
{
  "schemaVersion": 1,
  "expectedBuildId": "<exact 64-character lowercase build SHA>",
  "expectedCellFormId": 1,
  "outputDirectory": "<existing absolute owned capture directory>",
  "sampleCount": 4,
  "minimumArmIntervalMilliseconds": 1000,
  "requestTimeoutMilliseconds": 10000
}
```

Cell is a positive uint32; count is2..16, arm spacing250..10000ms and each
original request gets at most1000..20000ms, clipped by the original work deadline.
The minimum acquisition span must also cover `(count-1)*armSpacing`; actual
acquisition timestamps/frame IDs/cycles and actual coverage are retained. Slower
RPCs can lengthen the span. Compare actual coverage across experiments; do not
rename unequal durations as equal-duration traces. No capture is replayed to
repair spacing or qualification. Infeasible minimum spans refuse before capture.

The neutrality check above is **standalone temporal-probe performance neutrality**,
not current controller/HMD pose neutrality. Mapping must separately admit its
calibrated stationary endpoints and actual tracked observations through a coherent
producer schema. Capability advertisement alone does not authorize an `observe`
enum bypass. Until that independent contract is supplied, do not call this series
a post-position pose-qualified or quiet scientific comparison.

Each unique command requests HMD-submission/no-fallback, left/right PNG SDR-sRGB,
no clipboard, unique exact paths and overwrite-never. Fresh compiler first/after
snapshots and neutral standalone-probe registration/epoch checks bracket each
capture. Exact original request/client/command/build/service ownership and a
settled terminal native publication are required. Both files are independently
size/hash/stability checked, max64MiB each, with deadline checks during hashing.
Original raw replies and guards are published before later qualification; the
terminal result retains all dispatched commands, reads, errors and final receipts.

No subsequent capture is armed after a failed boundary. A known nonterminal
request is cancelled once and observed to settled terminal publication within
the reserved cleanup budget. An acceptance lost before a qualified request ID
stays **indeterminate**: no replay, guessed cancellation, alternate session or
claim of successful screenshot cleanup. Original calendar release and fresh
prior-rate restoration still run before MCP session closure. Their truth stays
separate from image/measurement success. Do not use session disconnect as proof
of restoration. Native expiry/scene loss or unknown cleanup cannot be promoted
to a qualified series.

Mapping owns live execution, capture scratch acquisition, retention and release.
Use a protected capture allocation for unique PNGs and raw receipts. Promote and
hash-verify required output before release; never read released scratch paths.
No native compilation, package installation or game launch is part of this source
controller. `Test-CalendarStereoStillEntryPoint.ps1 -FixtureRoot <managed general
scratch> -PythonEntry <stable Python shim>` qualifies synthetic public transport
and ownership behavior only; fixture PNG signatures are not real engine images.
