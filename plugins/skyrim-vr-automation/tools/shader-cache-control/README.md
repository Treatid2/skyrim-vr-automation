# CSX compiled shader-cache control

`Compare-CSXShaderCache.ps1` inventories two preserved cache trees by relative
path, byte size, and SHA-256. It writes a compact JSON/Markdown summary plus a
CSV containing every added, removed, or content-changed file.

`Invoke-CSXShaderCacheTransaction.ps1` handles live physical cache trees as
attributable transactions. It can enumerate every MO2 mod that provides the
cache path, snapshot and verify an exact tree, seed a verified baseline, or
restore it while preserving the displaced tree and both inventories. Snapshot,
seed, and restore refuse to run while MO2, Skyrim, or the SKSE loader is active.
Recursive inventory is reparse-point-free and bounded by file count, bytes,
depth, and an absolute deadline. The shared transaction/catalog primitive emits
periodic progress, records per-file sizes and hashes, and returns the applied
limits with its inventory. Snapshot receipts bind the exact cache parent, leaf,
path, and baseline hash before they authorize a destructive seed or restore.
Mutation callers serialize through a bounded lock derived from the canonical
live-cache path. A deterministic per-user control directory owns the
authoritative journal; evidence journals are mirrors, not ownership
partitions. Before every snapshot, seed, or restore, the next lock owner
reconciles any nonterminal operation by accepting only the exact original or
requested tree, restoring and verifying the displaced original, and retaining
uncommitted staging/replacement trees in sibling recovery quarantine paths.
Unknown target drift or a missing exact original fails closed for manual
recovery.

`Invoke-CSXShaderCacheCatalog.ps1` composes those primitives into reusable task
cache management. It stores immutable, content-addressed cache objects and
separate snapshot manifests carrying the cache ABI, game runtime, render path,
shader-source hash, explicit bytecode compatibility class, optional build,
preset, and effective feature-set hashes, normalized tags, status,
and receipt provenance. There is no mutable index to repair: `list` validates
the manifests and derives the catalog view from disk.

```powershell
.\Compare-CSXShaderCache.ps1 `
  -ReferencePath '.\enabled\ShaderCache' `
  -CandidatePath '.\unloaded\ShaderCache' `
  -ReferenceLabel enabled `
  -CandidateLabel unloaded `
  -OutputDirectory '.\comparison'
```

This is read-only with respect to both cache roots. Keep snapshots outside the
live MO2 overwrite tree so harness safety limits measure active state rather
than evidence copies.

```powershell
.\Invoke-CSXShaderCacheTransaction.ps1 providers `
  -ProfilePath 'D:\MO2\profiles\Profile\modlist.txt' `
  -ModsPath 'D:\MO2\mods' -DeepInventory `
  -EvidenceDirectory 'D:\Evidence\provider-inventory'

.\Invoke-CSXShaderCacheTransaction.ps1 snapshot `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction' -Confirm:$false

.\Invoke-CSXShaderCacheTransaction.ps1 verify `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction'

.\Invoke-CSXShaderCacheTransaction.ps1 seed `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -SourceCachePath 'D:\Preserved\Compatible Baseline\ShaderCache' `
  -ExpectedSourceTreeSha256 '<exact inventory hash>' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction'
```

## Reusing known-working caches between tasks

Configure a permanent catalog outside MO2 and the checkout:

```json
{
  "storage": {
    "shaderCacheCatalog": "D:\\SkyrimVRAutomation\\ShaderCacheCatalog"
  }
}
```

`-CatalogRoot` takes precedence, followed by
`CSX_SHADER_CACHE_CATALOG_ROOT`, the configured path, `CODEX_HOME`, and the
user-local application-data fallback. A catalog candidate is never accepted
from its label alone. The hard compatibility gates are known-working status,
exact shader-cache ABI, game runtime, bytecode compatibility class, required
tags, and—by default—exact shader-source SHA-256. Supply
`-FeatureSetSha256` whenever an effective feature-set fingerprint is available;
then an absent or different fingerprint is a hard exclusion. Among compatible
candidates, exact source, feature-set, build, preset, and observed render-path
matches rank first. Within one render family, the request's provenance class
(`vr-steamvr-*` or legacy `steamvr-*`) ranks ahead of broader verified coverage
and recency. `select` returns both the ranking and explicit exclusion reasons.

The exact render path remains immutable provenance and an exact-match ranking
signal. The default `skyrimvr-d3d11` class deliberately permits reuse across
SteamVR physical, SteamVR null-HMD, and OpenComposite when every bytecode input
matches; use a different explicit class when a route is proven bytecode-affecting.

First admit a receipt-proven snapshot:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 capture `
  -SourceCachePath 'D:\Evidence\known-good\cache.before' `
  -ExpectedSourceTreeSha256 '<exact cache tree hash>' `
  -SourceReceiptPath 'D:\Evidence\known-good\shader-cache-transaction.receipt.json' `
  -ShaderCacheAbi '<exact ABI>' `
  -ShaderSourceSha256 '<exact source-tree SHA-256>' `
  -FeatureSetSha256 '<exact effective feature-set SHA-256>' `
  -BuildId '<build identity>' `
  -PresetSha256 '<preset SHA-256>' `
  -Tags quality,full-render `
  -SnapshotStatus known-working `
  -Label 'quality full-render known good' `
  -Confirm:$false
```

Prepare a closed task cache immediately before launching MO2:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 prepare `
  -CachePath 'D:\MO2\overwrite\ShaderCache' `
  -ProfilePath 'D:\MO2\profiles\Codex Task - Example\modlist.txt' `
  -ModsPath 'D:\MO2\mods' `
  -BindToOverwrite `
  -WorkspaceId '<workspace identity>' `
  -OwnershipId '<ownership identity>' `
  -OwnerMarkerPath 'D:\MO2\overwrite\.codex-workspace-output-owner.json' `
  -OwnerMarkerSha256 '<exact owner-marker SHA-256>' `
  -EvidenceDirectory 'D:\Evidence\task-id\shader-cache' `
  -ShaderCacheAbi '<exact ABI>' `
  -ShaderSourceSha256 '<exact source-tree SHA-256>' `
  -FeatureSetSha256 '<exact effective feature-set SHA-256>' `
  -BuildId '<build identity>' `
  -PresetSha256 '<preset SHA-256>' `
  -RequiredTags quality,full-render `
  -RequireMaterializedOutput `
  -Confirm:$false
```

`prepare` always snapshots the caller's exact current cache first. It then
selects the best compatible known-working snapshot and seeds it only when it is
different. With no match it safely leaves the current tree in use; add
`-RequireMatch` when a task must not proceed without a catalog baseline.
Repeating `prepare` with the same immutable cache, evidence, and catalog
identities reconciles and returns the existing prepared plan.
A retry from the earlier `snapshot-preserved` boundary must first revalidate
the canonical snapshot receipt, its preserved physical baseline and the current
cache against the plan's `beforeTreeSha256`. A reconciled Overwrite owner also
requires that same live tree to match its retained reconciled baseline. Any
drift refuses before seeding, provider shadowing or plan advancement, preserving
the plan, receipt, owner and changed cache for recovery; retry does not rebase
the generation. A no-drift retry continues the original preparation.


Fresh `prepared` and `already-prepared` responses provide the bounded four-field
`data.task.completionArguments` parameter object: `Command=complete`, exact
`CatalogRoot`, `CachePath` and `EvidenceDirectory`. Retain and forward that object
across execution hosts instead of re-resolving environment/configuration defaults.
Its paths come from the admitted plan; catalogue provenance remains in
`data.storage` and the durable plan's `catalog`. Dry-run and failed preparation
do not provide completion authority. The object does not select a working-set
status, grant promotion, replace a lease, or waive closed-state/owner/restore
checks. An explicitly wrong root continues to fail before cache restoration.

For a parsed JSON receipt, convert the parameter object to a PowerShell hashtable
before splatting; do not interpolate it into a shell command:

```powershell
$completionParameters = @{}
foreach ($property in $prepareReceipt.data.task.completionArguments.PSObject.Properties) {
    $completionParameters[$property.Name] = $property.Value
}
$completionParameters.WorkingSetStatus = 'unverified' # classify this exact run
$completionParameters.Confirm = $false
& $catalogController @completionParameters
```

Here `$catalogController` is the exact supported controller path selected for
that workflow. Native `-File` wrappers must forward the same explicit three
paths plus the `complete` command as separate arguments. Ambient defaults are
conveniences for initial selection, not cross-host completion identities.

### Opt-in same-task preserved working-cache resume

To resume a completed **unverified** working cache from the same retained MO2
workspace, add both `-ResumeCompletionPath <shader-cache-task.completion.json>`
and `-ExpectedResumeCompletionSha256 <exact file SHA-256>` to `prepare` in a
**new** evidence directory. This explicit source takes precedence over catalog
selection for this preparation only. The normal `selection` remains an honest
known-working catalog result; the separate `resume` receipt identifies the
unverified source. A cold target reports `seed-same-task-unverified`, and an
already-identical target reports `use-current-resume-exact`. Omitting this
option retains the existing known-working-only default. `select` never admits
these task results.

Resume requires `-BindToOverwrite`, the exact currently verified workspace and
ownership IDs, unchanged profile path/hash and mods/cache roots, and the exact
Community Shaders DLL and manifest identities. The prior session's owner-marker
hash may differ: a new marker is verified independently, not mistaken for the
old session. ABI, shader-source hash, build, game runtime, bytecode class, exact
render path, tags, and optional feature/preset fingerprints must agree with
the original plan. A supplied fingerprint cannot substitute for an absent old
one. Unknown fingerprints remain explicitly unknown in the resume receipt;
matching nulls do not establish effective-feature or preset equivalence.

The controller validates the completed/restored plan, original snapshot,
unique committed restore receipt and existing journal, and the preserved
tree's bounded file/hash/byte inventory. Failed, promoted, incomplete,
foreign-owner, incompatible, missing, empty, ambiguous or drifted evidence
refuses **before** snapshot/seed; it never silently falls back to a cold cache.
Historical proof validates preserved data, not today's shared live baseline,
and never repairs an old journal. `-WhatIf` validates without mutation.
`-AllowSourceMismatch` and `-RequireMatch` cannot be combined with this option;
the latter retains its meaning of requiring a known-working catalog match.
Prepared-plan retries must retain the same pinned resume proof.

The existing seed transaction snapshots the **new** pre-task tree and runs
normal provider shadowing. Completion preserves the task result and restores
that new baseline. Resume never changes the old completion or publishes an
unverified global catalog object. Later promotion still requires independently
affirmative known-working evidence and explicit `complete -Promote` authority.
Same-task here means the same retained workspace/ownership identity, not an
arbitrary label or a new task borrowing another task's directory. It does not
guarantee CSX will accept every bytecode file, avoid recompilation, or reproduce
visual results. Retain native cache-validation and compile logs separately.

With `-BindToOverwrite`, `prepare` binds the exact profile hash, mods root, and
physical `overwrite\ShaderCache` path. After optional seeding it inventories
all enabled providers in exact modlist priority order and copies every missing
provider path into Overwrite. Existing Overwrite or seed files remain
authoritative. Every copied source is checked for stability and the target is
SHA-256 verified; complete path coverage and the final `preparedInventory` are
then written to `shader-cache-provider-shadow.receipt.json`. The task plan
records the corresponding `preparedTreeSha256`; consumers must validate both
artifacts and require their hashes to agree. This full shadow is required
because MO2
writes modifications to the original provider of an existing virtual path;
new paths naturally use Overwrite, but existing mod paths must first be made
Overwrite winners. `-CacheModName` remains available for older explicitly
bound loose-mod workflows and cannot be combined with `-BindToOverwrite`.

MO2 session authorization reads this receipt and independently inventories the
current providers. Before the first launch, the live Overwrite cache must match
`preparedTreeSha256` exactly. A retained game cycle may add or update files in
Overwrite, but every relaunch still requires all current provider paths to
remain shadowed.

After the game and MO2 are closed, complete the cache transaction:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 complete `
  -CachePath 'D:\MO2\overwrite\ShaderCache' `
  -EvidenceDirectory 'D:\Evidence\task-id\shader-cache' `
  -WorkingSetStatus known-working `
  -Promote -Label 'verified task result' `
  -Confirm:$false
```

`complete` preserves the task-produced cache, restores the exact pre-task tree,
and records a completion receipt. Promotion is opt-in and is refused unless the
caller explicitly classifies the task result as `known-working`. An unverified
or failed task result is still preserved as evidence but is not added to the
catalog. If the failed or unverified run left the live cache byte-for-byte equal
to its prepared baseline, zero newly generated files does not block cleanup,
even when preparation required materialized output. Exact bindings and restore
proof remain mandatory; no cache writes are manufactured and no promotion is
allowed. If that tree also equals the pre-task snapshot, `complete` verifies
both trees and commits a `restore-noop` receipt instead of moving identical data.
When seeding/provider shadowing changed the prepared baseline, it preserves that
working tree and performs the normal exact pre-task restoration. Known-working
completion with required materialization still refuses zero generated output. A
shader-source mismatch remains excluded unless
`-AllowSourceMismatch` is accompanied by a concrete `-CompatibilityReason`;
this exception does not bypass ABI, runtime, bytecode-class, feature-set, status,
or tag gates.
Repeated `complete` calls return the immutable existing completion. A retry
after restoration but before completion publication accepts only one committed
restore receipt and committed journal proving the exact snapshot lineage, restore transaction
identity, cache path, live baseline, and physical preserved working tree. A
stored receipt pointer is revalidated to the same standard. Malformed, foreign,
missing, drifted, or ambiguous receipt-shaped evidence leaves the plan pending
for recovery and never triggers a replacement restore. Receipt-only no-op
recovery is an explicit validator mode and accepts only the canonical
`restore-noop` operation spelling; operation casing cannot select a weaker
proof path. Its receipt and journal must also name the exact preserved-baseline
path recorded by the original snapshot; another evidence-root directory with
identical bytes cannot substitute for that snapshot-bound identity.

`prepare` and `complete` return bounded output by default: cache identities,
file and byte counts, tree hashes, state, and receipt paths remain inline, while
per-file `entries`, provider-shadow `copied`, and `alreadyPresent` arrays remain
only in the durable plan, provider-shadow, transaction, and completion receipts.
Omission flags distinguish absent detail from zero files; aggregate coverage
counts remain inline on fresh and already-prepared responses.
`-Compact` additionally removes JSON
whitespace. Use `-IncludeInventoryEntries` only for a caller that explicitly
needs the potentially very large per-file arrays in the command response.

`seed` requires the existing snapshot receipt for the same live cache and
evidence directory, verifies the exact source tree, stages it, swaps it into
place, and preserves the displaced live tree. A deliberately compatible
seed source may use any non-root directory name; its exact expected tree hash
is mandatory. `ShaderCache` remains the default and required leaf for the live,
destructively swapped target. A deliberately compatible
cache-contract change may use `-ShaderCacheAbiOverride`, but only together with
an explicit `-CompatibilityReason`; the original and replacement ABI, reason,
source identity, seeded identity, and displaced identity are retained in the
seed receipt. This exception is for proven non-bytecode changes, not a way to
silence an unknown ABI mismatch.

`providers` also accepts an exact relative loose-file path through
`-RelativeCachePath` (for example
`SKSE\Plugins\CommunityShaders.dll`). It enumerates every physical provider,
marks the earliest enabled mod provider as the winner among enabled loose mods,
and explicitly leaves overwrite, unmanaged-file, archive, and runtime
deployment resolution to separate VFS evidence. `-DeepInventory` returns only
the bounded file count, byte count, and tree hash inline. When
`-EvidenceDirectory` is supplied, the complete entry list is written to
`providers.inventory.json`; use `-IncludeInventoryEntries` only when a caller
explicitly needs that potentially large list in the command response.

Restore never silently discards the current tree: it copies the displaced
contents into the evidence directory, verifies that copy, and only then removes
the temporary sibling used for the atomic swap. Seed and restore mirror unique
evidence journals while updating the one target-owned authoritative journal
before each filesystem move. Any pre-commit failure first
quarantines the uncommitted replacement, restores and hash-verifies the exact
displaced original, and reports `recovery-required` if that rollback cannot be
fully verified.

Same-task resume additionally requires the externally pinned completion to carry
the exact SHA256 of its finalized restored plan. Resume matches that digest
before parsing or using any compatibility request. Editing shader/build/feature/
preset/tag fields in a sibling plan cannot redefine the historical cache inputs.
Legacy completions lacking `planSha256` are ineligible for this opt-in mode;
do not rewrite them or infer historical trust from their current sibling plan.
Ordinary no-resume selection/completion and explicit known-working promotion
retain their existing contracts.

Run `Test-CSXShaderCacheControl.ps1` after changing comparison or transaction
logic, and `Test-CSXShaderCacheCatalog.ps1` after changing catalog selection or
task lifecycle logic.
