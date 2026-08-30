# Reciprocal closed-loop fork search

This protocol turns the fixed CSX/Open Shaders comparison into an unattended,
alternating best-response search. It optimizes one fork against the other
fork's last qualified candidate, freezes the result as the next reference, and
then reverses roles.

No failed, partial, stale, frozen, or merely queued operation is measurement
data. Only a candidate whose complete performance and image evidence passes
every validity gate may become an incumbent or comparison anchor.

## Claim boundary

"Best possible" means the best verified point in a finite, versioned search
space. It is not a claim about every theoretically possible setting. The
campaign must enumerate each allowed value or a finite coarse-to-fine grid,
and must retain every tested, pruned, invalid, and untested point with its
reason.

A winner is declared only after the other fork has completed a reciprocal
best-response search against it and failed to produce a non-dominated answer.
If both forks retain different advantages after the declared spaces are
exhausted, the honest result is a Pareto frontier with no winner. Automation
must never manufacture a winner by averaging away a regression or accepting a
broken run.

## Fixed campaign contract

Freeze these fields before round zero:

-   fork heads, built DLLs/packages, artifact SHA-256 values, and adapter builds;
-   canonical SettingsUser baselines and each fork's allowed search space;
-   matrix file and SHA-256, automation commit, controller schemas, and analysis
    code/model versions;
-   exact MO2 modlist, task workspace source, save fixture, load order, INIs,
    runtime lane, HMD profile, eye geometry, output resolution, refresh rate,
    reprojection policy, GPU, driver, clocks, power policy, and background-load
    policy;
-   DLSS, Quality input scale, preset K, render-scale/performance mode on,
    foveation on, and the same runtime-reported output resolution;
-   bloom and the complete fork-native Wetterness/Wetness Effects paths on;
-   the six `matrix_int-ext-weather-coc` conditions and the deterministic motion
    recording used by the image protocol; and
-   no human viewing or judgment.

The search may change only paths declared in that fork's search-space
manifest. Fork-native performance controls are allowed. Foveal geometry,
feathering, periphery treatment, hard cutoffs, culling policy, and stereo work
may be searched after the matched-area baseline, but the upscaler, Quality
input scale, output size, and requirement that foveation remain enabled are
immutable.

An undeclared state difference invalidates the candidate. A declared candidate
setting difference is not drift and must not be rejected merely because its
settings hash differs from the opponent.

## Candidate identity

Every candidate is immutable and identified by a canonical hash over:

-   fork ID and source head;
-   DLL/package identity and SHA-256;
-   complete SettingsUser JSON and boot-disable state;
-   normalized effective feature and upscaling snapshots;
-   shader source, cache ABI, cache tree, preset, and build identities;
-   search-space revision and exact changed lever values; and
-   fixed campaign-contract hash.

Never reuse a label for different bytes. Never mutate an accepted candidate in
place. A derived candidate names its parent and the one logical lever or
declared interaction it changes.

Deduplicate exact candidate hashes. Prior within-candidate evidence may be
reused only under the identical campaign contract and validity revision. A new
opponent anchor still requires a fresh balanced cross-fork comparison; do not
declare a best response from images or traces paired against an older anchor.

## Alternating state machine

Let `A0` and `B0` be the aligned profiles in this directory. Choose and record
the first mover; the final confirmation is order-balanced regardless of that
choice.

Before optimizing either fork, fully qualify both baselines and run balanced
`A0/B0/A0` and `B0/A0/B0` comparisons. This establishes the initial noise,
drift, and cross-fork objective vectors. If either baseline cannot complete the
same contract, round zero is blocked; the other fork cannot optimize against a
fictional or partial reference.

```text
B0 anchors Optimize(A, B0) -> A1
A1 anchors Optimize(B, A1) -> B1
B1 anchors Optimize(A, B1) -> A2
                         ...
```

Each arrow may publish only a `qualified` candidate. Invalid attempts are
quarantined below the arrow and do not move the reference.

Search exhaustion is keyed by moving fork, opponent-anchor hash, search-space
hash, and validity-protocol hash. A changed anchor opens a new best-response
round even when the candidate graph itself is unchanged.

The controller follows this logic:

```text
anchor = qualified baseline of the non-moving fork
moving = first mover

repeat:
    result = BestResponse(moving, anchor)
    if result has no qualified candidate:
        stop blocked; preserve the last qualified anchor
    anchor = result.best_verified_candidate
    publish the moving fork's Pareto archive and exhausted-space proof
    swap moving fork
until reciprocal winner rule is satisfied or both spaces are exhausted
```

Use an append-only campaign ledger. After interruption, resume from the last
fully qualified anchor, never from a `running`, `measured`, `invalid`, or
partially assessed candidate.

## `BestResponse(fork, anchor)`

### Candidate generation

Start from the fork's last qualified incumbent. Generate candidates in this
order:

1. single binary implementation/performance switches;
2. discrete foveation, feather, periphery, culling, and quality-policy levels;
3. coarse-to-fine numeric refinement inside declared bounds; and
4. declared pairwise interactions among non-dominated single-factor results.

Change one logical lever per edge. Coupled fields, such as OS crop width,
height, and centered offsets, are one logical lever. Assume monotonic behavior
only after at least three ordered qualified points show the same direction;
otherwise enumerate the declared grid.

### Evaluation stages

1. **Static validation:** parse the JSON; reject unknown keys, invalid enums,
   out-of-range values, broken coupled geometry, changed fixed fields, or a
   label that aliases different bytes. Deduplicate an exact candidate hash and
   reuse only evidence allowed by the identity rule above.
2. **Screening:** run one complete matrix block, including its three internal
   repetitions of all six cases, plus a separate image sequence. A hard
   correctness defect or clear domination may prune a point, but a partial
   matrix cannot advance it. Internal repetitions estimate one process run;
   they are not independent clean-process blocks.
3. **Qualification:** run three independent clean-process blocks. If a
   comparison remains inside the measured noise/drift interval, extend both
   candidates symmetrically to five and then seven blocks.
4. **Confirmation:** run balanced `parent/candidate/parent` and
   `candidate/parent/candidate` orders, then compare the survivor against the
   external anchor using the same balanced order.

Maintain the complete Pareto archive. A screened candidate may be pruned only
when a qualified candidate is no worse in every applicable objective and
better in at least one, or when the candidate violates a hard gate. Record the
dominating candidate or exact gate failure.

### Selecting the next anchor

First reject candidates with correctness, stability, provenance, or visual
regressions. Among survivors, retain separate per-case visual, GPU, CPU, tail,
transition, and resource objectives.

Prefer performance candidates lexicographically after Pareto filtering:

1. lowest worst-case p95 fraction of the applicable VR frame budget;
2. lowest worst-case median frame time across the six cases;
3. lower p99/tail and transition cost;
4. lower non-limiting CPU/GPU cost without a regression; and
5. lower-risk implementation when measured results remain indistinguishable.

This policy chooses one reproducible anchor without hiding raw objectives.
"Maximally faster" means no untested one-step neighbour remains in the
declared graph that could preserve visual dominance and improve the limiting
performance objective.

## Measurement validity state machine

Every measurement moves through these states:

```text
planned -> deployed -> launched -> conditioned -> warmed
        -> captured -> validated -> assessed -> qualified
```

Any failed transition goes to `quarantined`, with the raw evidence retained.
Only `qualified` measurements enter optimization or statistics.

### 1. Deployment and process identity

-   Acquire one MO2 access lease and create a unique task profile from the exact
    configured test-profile source. Use a verified save fixture when the route
    requires a deterministic loaded baseline; COC is not a New Game substitute.
-   Change candidate/fork packages only while Skyrim and MO2 are closed. Prove
    the exact task-owned winning providers for the DLL, SettingsUser file, and
    shader cache. Reject a fallback profile, additional MO2 owner, unmanaged
    winning DLL, or unexpected archive/overwrite provider.
-   Launch through the retained session controller. Bind the exact game PID,
    executable, DevBench endpoint, producer build ID, DLL path, and artifact
    SHA-256. A visible process is not sufficient.
-   For repeated blocks retain the owning MO2 process and cycle Skyrim through
    `stop-game` and `launch`. Use a clean game process for every independent
    qualification block.
-   Release the evidence session and MO2 access lease while performing offline
    trace, image, model, statistical, or search analysis. Reacquire exact access
    before the next deployment; an expired estimate never transfers ownership.

### 2. Tool and service readiness

-   List the authoritative tools and validate their current schemas before the
    first candidate of each build.
-   Require the canonical fork adapter, state snapshot, upscaling stability,
    screenshot, profiler, scene, weather, scenario, and console capabilities.
-   Wait for registration and a read-only service-ready action with a bounded
    timeout. Bind every response to the expected producer and artifact.
-   Treat missing, duplicate, mismatched, retry-exhausted, or semantically failed
    tools as blocked. Transport success without semantic success is not a pass.

### 3. COC and scene liveness

Exactly one cell transition may be unresolved. `queued: true` proves admission
only; it never proves completion.

For every requested transition:

1. Record source cell, server dispatch timestamp, engine/world frame, and
   render/present frame.
2. Submit one exact `coc <destination>` command.
3. Wait through the fail-closed `upscalingStable` barrier with the exact
   destination cell. Require a loaded player, no blocking menu, three
   consecutive coherent samples, and at least ten advancing world frames.
4. Require positive render/display dimensions, valid coherent left/right
   presentation, requested/effective/stable upscaling agreement, and no
   relatch, fallback, recovery, retirement, device loss, or vendor work.
5. Record the first stable server timestamp and final state. Only then may the
   controller issue another COC.

The default scene deadline is 180 seconds. A timeout, unchanged source cell,
non-advancing frame counter, stale pre-transition state, missing eye, or
upscaler recovery state invalidates the complete case. Stop the matrix at that
point; do not queue the next COC or turn the elapsed timeout into a performance
sample.

During every 30-second scenario, require a completed scenario receipt and
monotonic engine/render/present progress from the arming boundary to the final
sample. The trace must contain new rendered frames over the declared duration.
A responsive DevBench listener with a frozen game world is not valid data.

### 4. Exact condition and state

Before and after every capture require:

-   exact cell editor ID;
-   exact weather key and editor ID, active lock, and no weather transition;
-   exact requested hour before capture;
-   matching output and input dimensions and HMD geometry;
-   the candidate's expected normalized feature and upscaling hashes; and
-   no menu, loading state, pending settings, diagnostics, or undeclared
    override.

Feature and upscaling hashes must match before and after a candidate capture.
Across different candidates the hashes may differ only at declared search
paths. Compare their immutable output-contract hash rather than incorrectly
requiring identical complete settings.

### 5. Shader-cache and warm-state gate

-   Give each fork/candidate compatibility lane its own task-owned winning cache
    provider. Never share CSX and OS compiled output.
-   Bind cache ABI, runtime, render path, shader-source hash, build ID, preset
    hash, and tree identity. Seed only a compatible known-working snapshot.
-   Complete one untimed matrix warm-up. Require shader compilation, disk-cache
    hold/rebuild, worker backlog, history initialization, resource recovery, and
    screenshot/profiler work to be inactive before arming.
-   Prove cache/log quiescence and effective `Using disk cache` state. If the
    candidate needs new permutations, let them finish outside measurement and
    create a new cache identity.
-   Preserve and complete the cache transaction only after Skyrim and MO2 close.
    A missing materialized cache is a failed routing proof, not an empty success.

### 6. Tracy performance gate

Use the pinned `Measure-TracyVRMatrix.ps1` capture path for each candidate,
with screenshots, image encoding, RenderDoc, preview, and CSX/OS profiler
capture disabled during the timed Tracy window.

Accept a trace only when:

-   the matrix and scenario hashes match the campaign;
-   the scenario reports `done` and every step reports success;
-   the trace and raw export exist, decode, hash correctly, cover the requested
    duration, and contain monotonically advancing frames/timestamps;
-   frame, CPU, and GPU sample counts meet the declared minimum and contain no
    empty, stale, duplicate, or pre-arming samples;
-   the scene/condition and candidate state remain valid after capture; and
-   no crash, device loss, compilation, relatch, fallback, screenshot, profiler,
    or measurement-tool overlap occurred.

Preserve whole-frame median, p95, p99, missed-budget counts, and CPU/GPU
separation per case. A valid high-cost or stuttering trace remains real data
and must not be discarded as an outlier.

### 7. Profiler diagnostic gate

Run bounded profiler captures separately from Tracy and image acquisition.
Keep raw JSON, not only summaries. Accept only resolved unique samples newer
than the arming frame; record reconnects, slot refusals, empty timer arrays,
missing timers, and compilation activity.

Compare at least the candidate and its explicit reference as raw captures;
never feed aggregated summaries back into the profiler comparator.

Profiler totals describe the active instrumented profiler block, not whole
frame time. Do not add correlated timer deltas into a fictional total or use a
profiler-only saving as the winner metric.

### 8. Image and model-assessment gate

Apply `image-quality-protocol.md` without modification:

-   use equivalent versioned `hmd_submission` capture on both forks;
-   acquire raw left/right lossless BMP sequences outside Tracy;
-   require final manifests, all artifacts and hashes, zero drops/failures,
    coherent eyes, and no fallback;
-   use A/B/A drift masks, reversed order, repeated evidence, and the fixed
    deterministic motion recording; and
-   use only the pinned blinded image model and objective-vector/Pareto result.

No candidate with missing visual evidence may become an anchor. The current OS
head lacks the required versioned screenshot service, so unattended winner
selection remains blocked until the visual-only OS adapter provides the same
contract and is artifact-bound.

## Invalid data, retries, and stability failures

Classify failures before retrying:

-   **Infrastructure invalid:** controller transport loss, unrelated runtime
    outage, evidence-disk failure, or a proven harness defect. Preserve the run,
    repair the cause, perform a clean restart, and allow one attributed retry.
-   **Candidate stability failure:** reproducible crash, hang, device loss,
    non-converging upscaler, invalid stereo, cache failure, or scene transition
    failure that occurs only with the candidate. It is a hard stability
    objective failure, not a slow performance value.
-   **Unresolved:** provenance cannot distinguish infrastructure from candidate.
    Quarantine it and do not score or automatically retry it.

Never silently replace a missing case, shorten a run, discard a valid slow
sample, or loop retries until one passes. Two attributable occurrences in
three clean attempts make a candidate stability-failed and ineligible to win.

## Statistical qualification

The independent unit is a clean-process measurement block, not an individual
frame. Start with three paired blocks and extend both candidates to five and
seven only when needed.

For every case and metric:

-   calculate paired candidate-minus-reference differences;
-   retain medians, p95, p99, median absolute deviation, and the 95% block-level
    confidence interval;
-   measure return-baseline drift from both deployment orders;
-   require the effect direction to agree in forward and reverse order; and
-   call an effect real only when its interval excludes zero and its magnitude
    exceeds both measurement precision and return-baseline drift.

Outlier rules are fixed before opening results. Invalid traces may be excluded
only by a validity gate that does not inspect whether the value is favourable.
Valid extreme values remain part of the tail and stability evidence.

Performance candidate X dominates Y only when X is no slower beyond
uncertainty in every applicable case/limiting metric and is repeatably faster
in at least one, with no material CPU, GPU-tail, transition, memory, or
stability regression. Visual dominance follows the separate image protocol.

## Reciprocal winner and stopping rule

Candidate X wins only when all of these are true:

1. X and opponent Y are fully qualified under the same campaign contract.
2. X visually dominates Y: no repeatable negative objective and at least one
   repeatable positive objective.
3. X performance-dominates Y and is the best verified candidate in X's
   exhausted declared search graph.
4. Y has completed a full best-response search against that exact X and cannot
   produce a qualified candidate that removes X's joint dominance.
5. X remains the same anchor for two consecutive reciprocal rounds.
6. A final clean-process `X/Y/X` and `Y/X/Y` campaign reproduces both visual
   and performance directions above drift with unchanged identities.

If a new best response appears, it becomes the next anchor and the loop
continues. If neither fork jointly dominates when both finite spaces are
exhausted, publish the non-dominated frontier and stop with `no-winner`; do not
weaken the gates.

## Required controller implementation

The existing matrix runner already supplies much of the CSX capture gate,
including exact conditions, before/after state hashes, bounded scenario
execution, and the three-sample/ten-frame `upscalingStable` barrier. A complete
closed-loop controller still needs:

1. a canonical fork-adapter interface that normalizes CSX
   `communityshaders.*` and OS `openshaders.*` discovery, state, profiler,
   cache, and upscaling evidence;
2. the equivalent versioned screenshot service in the OS visual build;
3. immutable candidate generation/deployment plus exact winning-provider
   proof;
4. a server-side capture liveness record tying scenario completion to
   advancing engine/render/present frames;
5. a comparator mode that requires state stability within a candidate but
   permits declared settings differences across candidates; and
6. an append-only search ledger, Pareto archive, reciprocal scheduler, and
   deterministic model-assessment adapter.

Until those adapters exist, the fixed matrix can qualify individual CSX runs,
but it cannot honestly perform the requested unattended two-fork search.

## Minimum campaign record

Preserve:

-   filled campaign manifest and hash, search spaces, graph coverage, and first
    mover;
-   every candidate manifest/settings file, parent edge, deployment receipt,
    effective-state snapshot, and cache transaction;
-   MO2 access/workspace/session IDs, exact profile/provider proof, runtime
    bindings, tool schemas, and artifact hashes;
-   every COC dispatch/stability receipt, condition snapshot, liveness record,
    raw Tracy trace/export, raw profiler capture, and screenshot manifest/image;
-   every validity gate result, quarantine/retry classification, statistical
    comparison, model finding, and Pareto decision; and
-   per-round anchor, frontier, exhausted/pruned/untested search points, final
    balanced confirmation, and winner/no-winner reason.
