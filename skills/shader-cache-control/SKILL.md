---
name: shader-cache-control
description: "Select, seed, preserve, promote, inventory, and compare CSX compiled shader-cache trees with exact compatibility metadata and receipts. Use for avoiding unnecessary shader recompilation in a Skyrim VR task, preparing or completing a task cache, extending known-working cache baselines, shader-family output comparisons, compilation-state evidence, or determining which files differ between controlled runs."
---

# Shader Cache Control

Read `../../tools/shader-cache-control/README.md` completely. Use:

```text
../../tools/shader-cache-control/Compare-CSXShaderCache.ps1
../../tools/shader-cache-control/Invoke-CSXShaderCacheTransaction.ps1
../../tools/shader-cache-control/Invoke-CSXShaderCacheCatalog.ps1
```

## Comparison contract

1. State in commentary that this skill governs the cache comparison.
2. Accept only two preserved snapshot directories. Never point the comparer at
   a cache that the game or compiler can still mutate.
3. Keep snapshots and generated reports outside live MO2 overwrite, RootBuilder
   data, and active compiled-shader directories.
4. Record the exact build, preset, shader state, scene/run, and capture time for
   both trees. Hash results establish file identity, not semantic equivalence.
5. Preserve JSON and CSV output with the corresponding profiler and MO2
   evidence. Do not delete or normalize cache files to make comparisons align.

Comparison is read-only with respect to both inputs. For an explicitly
authorized live-cache test, first run `providers`, then `snapshot`; use
`verify` after the run. `restore` requires MO2/Skyrim closed and preserves the
displaced physical tree before completing. Cache unloading, clearing, or
replacement is never implied by a request to compare caches.

## Task cache lifecycle

1. For a Skyrim task that may compile CSX shaders, determine the exact cache
   path, shader-cache ABI, game runtime, render path and family, bytecode
   compatibility class,
   shader-source SHA-256, effective feature-set SHA-256 when available, build
   identity, preset SHA-256, and task tags. Physical and null SteamVR may share
   a render family, while physical SteamVR, null SteamVR, and OpenComposite may
   share the explicit `skyrimvr-d3d11` bytecode class. A supplied feature-set
   fingerprint must still match. Do not infer semantic
   compatibility from names or timestamps.
2. With MO2 and Skyrim closed, call catalog `prepare` before the MO2 session.
   For an MO2 task workspace, bind the exact profile, mods root, and physical
   Overwrite cache with `-BindToOverwrite` and
   `-RequireMaterializedOutput`. Prepare must copy every enabled-provider
   `ShaderCache` path into Overwrite in MO2 priority order, without replacing
   existing Overwrite or seed files. Require the
   hash-verified provider-shadow receipt and `preparedTreeSha256`; a sentinel
   directory proves only the first new path and cannot contain later writes to
   paths that already exist in a lower provider. Retain
   `shader-cache-task.plan.json` with the task evidence. No compatible match is
   nonfatal unless the task requires `-RequireMatch`. Do not bypass a
   target-lock timeout or a recovery refusal: they mean another caller owns the
   cache or the live tree no longer matches the journal's exact identities.
3. Never clear a live cache merely to get a clean experiment. Use the task plan
   and exact seeding transaction. A source mismatch requires both
   `-AllowSourceMismatch` and a written `-CompatibilityReason`; it never
   bypasses ABI, runtime, bytecode-class, feature-set, known-working, or
   required-tag gates.
4. After MO2 and Skyrim are closed, call catalog `complete` before releasing
   the task workspace. It preserves the task result and restores the exact
   pre-task cache. The workspace controller's `complete-output` command
   separately preserves generated `backup` content, restores the exact pre-task
   tree, and releases the Overwrite owner marker. Promote only after the run
   provides affirmative evidence that the result is known-working.
5. Preserve the plan, transaction receipts, completion receipt, catalog
   manifest, source/build/preset identities, profiler evidence, and any cache
   comparison report together. Do not delete content-addressed objects or edit
   immutable manifests by hand.
6. Keep the default bounded inventory limits unless an observed, reviewed cache
   requires a larger explicit bound. A limit or deadline failure is a safety
   result, not permission to switch to an unbounded recursive scan. Reparse
   points are never valid cache contents.
