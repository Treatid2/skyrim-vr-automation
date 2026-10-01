# MO2 test workspace control

This tool gives each automation task a unique MO2 profile cloned from an
explicitly configured, known-good `defaults.testProfileSource`. It never uses
the ordinary session default as an implicit template. The complete `saves`
tree from that maintained source profile is copied and verified into every new
task profile so ordinary access requests remain usable. A valid default
world-entry fixture is required only when creation requests
`-SavePolicy VerifiedFixture`; `MainMenuOnly` and `FreshGame` remain available
without one. The fixture is the maintained deterministic route into the loaded
game world; alternate locations may then be reached with guarded `coc`/`cow`
commands.

Profile discovery, hashing, fixture verification, copying, and post-copy
verification share one command-wide tree-operation deadline. The controller
also enforces explicit file, directory, depth, and aggregate-byte limits and
rejects reparse points. Exceeding any budget returns a bounded failure before a
new clone is committed; the limits are configurable through the corresponding
`-MaxProfile*` and `-TreeOperationTimeoutSeconds` parameters. The default file
budget is 100,000 so the maintained MGO profile fits with safety headroom;
callers may still select a lower explicit bound for smaller profiles.

`prepare-source` performs the one-time legacy-cache migration. With an owned
lease and all MO2/runtime processes closed, it moves every Overwrite
`ShaderCache`, `.previous`, and `.swap` tree into a newly enabled mod in the
stable source profile. The operation is transactional and rejects reparse-point
sources; `-WhatIf` reports the planned mutation without moving anything.
`create` snapshots the exact Overwrite `backup` tree and later cache `prepare`
snapshots the exact Overwrite `ShaderCache` tree.

The task must own an MO2 access lease. MO2, Skyrim, loaders, and active
RootBuilder deployment must be closed before `create`, `resume`, `register-mod`,
or `retire`. Release any evidence session before mutating the workspace. All
commands accept `-Compact` for one-line JSON.

Workspace mutations serialize on the control-root transaction lock. Creation,
resume, and retirement write their recovery journal before the first mutation;
resume and retirement also persist an exact manifest preimage, and every parent
operation records the selected-profile subtransaction path in advance. The next
non-preview command resolves every nonterminal journal before command-specific
reads. It either finalizes a completely committed creation, restores the exact
pre-state, or fails closed on unsafe paths or unclassified drift. Recovery is
bounded by the same traversal budgets and never searches outside the configured
workspace, profile, and mods roots.

Runtime-output re-arm recovery uses a durable two-phase owner-release
checkpoint. It records that exact output restoration finished while the owner
marker is still verifiable, then releases the marker. A restart between those
steps may finish the parent manifest and selection rollback without recreating
ownership. Failed child restoration instead remains `recovery-required`, keeps
its marker and snapshot evidence, and cannot be promoted to a verified parent
rollback.

Workspaces are durably owned by `-TaskId` (or `CODEX_THREAD_ID` /
`CODEX_TASK_ID`), not by one access lease. `create` makes and selects a fresh
profile. `list-task` reports retained profiles. `resume` rebinds one exact
retained workspace to a newly owned lease and selects it without refreshing it
from the primary profile. If the exact retained owner marker still exists,
resume validates its bytes, task, workspace, immutable ownership ID, and
Overwrite path, then rebinds that unchanged active transaction to the new
closed-state lease. All output paths must match the configured exact Overwrite
mapping. Interrupted active rebind recovery requires the original task and
workspace plus a current closed-state lease, and restores the exact manifest
before another resume. If the prior lease completed its output transaction, every
resume—including one under the same access ID—first verifies the exact cache
and backup plans, completions, snapshot and restore lineage, preserved working
trees, and restored live Overwrite state. It then publishes a fresh owner
marker, snapshots, evidence paths, and completion paths before returning ready.
See
`../../docs/MO2-TASK-WORKSPACES.md`.

`list-task` advertises a workspace as resumable only when its profile exists,
its retained manifest contains the complete supported runtime-output contract,
and it has one machine-checked transition: `rebind-active-output` for its exact
live owner marker or `rearm-completed-output` for exact terminal completion
evidence. Foreign owners, changed markers, incomplete evidence, and legacy
contracts remain preserved under `unavailableWorkspaces` with a precise
`resumeBlockReason`; `resume` fails before profile selection or manifest/profile
mutation. Malformed task-owned manifests are reported there instead of being
silently skipped. If a task has retained records but none is resumable,
`list-task` returns `retained-workspaces-unavailable` and explicitly forbids a
replacement without reviewed migration or retirement authority. Do not
silently recreate such an environment.

Creation binds the task to MO2 Overwrite with an exact owner marker. It removes
both the selected game executable and `Synthesis` entries from the cloned
profile's `custom_overwrites` section. It snapshots the pre-task `backup` tree
and materializes every enabled loose-provider path into `overwrite\backup`
without replacing an existing Overwrite file. Shader-cache catalog `prepare`
must use `-BindToOverwrite`; it snapshots `overwrite\ShaderCache` and
materializes every enabled provider path there. New-area files then use MO2's
ordinary Overwrite route, while paths that already existed in a mod also have
an Overwrite winner. First launch requires exact prepared hashes; retained game
cycles may grow both trees while preserving complete provider coverage.

## Modlist and local-work choices

Fresh workspace requests distinguish the original maintained modlist from
optional local builds. Run `list-local-work-mods` first. It reads the exact
catalog named by `defaults.localWorkModCatalog`, validates every configured mod
directory and source-profile marker, and reports stable candidate IDs plus
availability reasons. It never infers a candidate from a directory-name glob.

Use `-WorkspaceContent Modlist` for no local-work candidates. Use
`-WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModId <id>` for one or
more exact available candidates; a JSON string array may instead be passed via
`-LocalWorkModIdsFile`. Creation disables every other catalogued candidate in
the cloned profile. Candidates sharing an `exclusionGroup` cannot be selected
together. This permits two CSX AIO candidates from the same local head: a
release-equivalent build with `DEVBENCH_BRIDGE` off and an automation build
with it on. Public release behavior is represented by the former.

The source profile and shared mod directories remain unchanged. The resolved
catalog path/hash, requested IDs, candidate metadata, and applied profile
markers are retained in the workspace manifest. `resume` preserves them; a
different selection requires a fresh workspace. `list-task` reports each
retained workspace's content mode and selected candidate IDs so a caller can
choose the right preserved profile without reopening it.

For elevated use, follow `../mo2-control/APPROVALS.md`. Every result reports a
literal command-specific `data.approval.reusablePrefix`. `create`,
`register-mod`, and `ensure-mod-wins` are eligible for narrow reusable approval;
`refresh-fixture`, `complete-output`, and `retire` remain one-shot because they
replace shared metadata, restore snapshotted Overwrite state, or recursively
remove exact owned paths. `prepare-source` is also one-shot because it moves
legacy shader-cache trees out of shared Overwrite state.

`resume` is the supported retained-workspace recovery route. It rebinds one
exact ready workspace to the caller's new active lease only after closed-state,
stable-source, task identity, and task-profile fingerprint proofs. It is
one-shot because it replaces the workspace's retained ownership metadata.

### Explicit candidate output requalification

`requalify-output -ConfirmCandidateChanges` is the separate closed-state
transition after intentional candidate registration changes the task profile
or winning CSX DLL/manifest/ABI. Ordinary `resume` never performs this refresh.
First reacquire access and `resume` the exact workspace; then preview and invoke
this command with that same access ID, task ID, and workspace ID. It requires
the exact active owner marker, both original **prepared** cache/backup plans
and their intact physical snapshot baselines, no completion in progress, no
MO2/game/loader, no evidence session, and a qualified runtime route. Missing,
corrupt, foreign, legacy, or partially completed contracts fail before mutation.

The controller snapshots both current working trees for exact rollback, then
uses the existing transaction primitive to restore both original baselines
while physically preserving the displaced output. This output is classified
`superseded-unverified`, never promoted or called known-working. Original
plans, snapshots, manifest bytes, and ownership-marker bytes are retained;
`runtimeOutputHistory` links the supersession journal and restore receipts.
Only after validating both committed restores does it release the old marker
and derive a new generation from the actual current winning DLL and verified
build manifest. No expected build ID or old OFF/ON variant is hardcoded. Profile
markers, task mods, saves, settings, source profiles, and unrelated Overwrite
content are not edited. Original pre-task directory-existence semantics remain
binding, including when both `ShaderCache` and `backup` were absent.

Success is `output-requalified-cache-prepare-required`, **not launch-ready**.
Use the returned fresh `runtimeOutput.cachePrepareArguments` for ordinary
catalog `prepare` with the actual shader-source/runtime compatibility metadata.
Then require normal MO2 preparation/first-launch isolation checks and
`-RequireSKSE`. Old cache-plan arguments are no longer valid. The new backup
provider shadow is materialized by requalification; the cache shadow is
materialized by subsequent catalog prepare. Completion of the new generation
restores the original pre-task baselines through the normal strict gates.

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <source-Invoke-MO2WorkspaceControl.ps1> requalify-output -AccessId <owned-access-id> -TaskId <original-owner-task-id> -WorkspaceId <exact-workspace-id> -ConfirmCandidateChanges -WhatIf -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <same-source-Invoke-MO2WorkspaceControl.ps1> requalify-output -AccessId <same-owned-access-id> -TaskId <same-owner-task-id> -WorkspaceId <same-workspace-id> -ConfirmCandidateChanges -Compact
```

A failure restores the exact prior working trees, marker, and manifest, retaining
all displaced evidence. If rollback cannot be verified, it reports
`recovery-required` and leaves a nonterminal journal; it never declares a
successful rollback or launches. Recovery is integrated into the next
controller command, but this transaction requires the caller's exact active
closed-state access lease. If access was released, reacquire it and pass the
new `-AccessId` to exact `resume`; its recovery hook restores the preimage before
it rebinds the retained workspace. A foreign
owner or active process fails closed. No plugin rotation is needed when a task
explicitly invokes this source controller; installation remains deferred while
any live protocol is active. This is a one-shot mutation, not a reusable broad
approval or permission to rewrite evidence manually.

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> prepare-source -AccessId <literal-access-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> list-local-work-mods -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> list-task -TaskId <stable-task-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -TaskId <stable-task-id> -Label modlist-test -WorkspaceContent Modlist -SavePolicy MainMenuOnly -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -TaskId <stable-task-id> -Label csx-api -WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModId csx-aio-local-devbench -SavePolicy MainMenuOnly -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> resume -AccessId <new-literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> complete-output -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create-mod -AccessId <new-literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -ModName "Codex Weather API Test 20260822" -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> register-mod -AccessId <new-literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -ModName "Codex Weather API Test 20260822" -ModDirectory "<exact-mod-directory>" -WinningPaths "SKSE\Plugins\CommunityShaders.dll" -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> release-access -AccessId <new-literal-access-id> -Compact
```

The normal end state is the retained workspace plus a released access lease.
Run, turn, or task completion does not authorize resetting the cloned profile,
removing its task-local changes, or retiring it. Reacquire access and use
`resume` with the exact workspace ID when work continues.

`retire` is an explicit-discard operation, not part of the normal workflow. Use
it only after direction to discard or replace that exact environment, or when a
separately stated retention policy proves it obsolete:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> retire -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -CleanupOwnedMods -Confirm:$false -Compact
```

`create-mod` must precede `register-mod`. It creates the exact empty directory
and ownership marker that authorize the workspace to populate and later
register that mod. Deploy files only inside the returned `data.modDirectory`,
then pass that exact path back to `register-mod`; pre-existing mods cannot be
claimed by this route.

`SavePolicy` describes what the test is authorized or expected to do; it no
longer controls which source saves are copied. `MainMenuOnly` never authorizes
loading a save. `FreshGame` records that a genuine New Game action is required;
this release does not synthesize that action, and `coc APStartCell` is
explicitly not equivalent. See `../../docs/BREEZEHOME-SAVE.md` for the current
maintained fallback starting point.

Every fresh clone receives and hashes the complete stable source save tree.
`MainMenuOnly` and `FreshGame` do not require, select, or authorize a declared
world-entry fixture: their result reports `worldEntryFixture: null` and
`copiedWorldEntrySave: false`. Creation still records static source/copy
integrity as `data.sourceIntegrity`. `integrityVerified` proves exact
profile/save bytes; it does not imply `runtimeQualified`. This is a clone-time
integrity guarantee only: `resume` preserves a task's prior profile exactly and
does not claim its save still works after task-local edits.

`VerifiedFixture` requires and authorizes one exact fixture as the
deterministic automation form of “new game”. It uses
`-FixtureManifestPath`, or `defaults.newGameFixtureManifest`, and selects
`-FixtureId` or the manifest's `defaultFixtureId`. The manifest fingerprint must
match the exact stable source profile. Every listed save/co-save is verified by
path, size, and SHA-256 before and after the complete save-tree copy. Other
source saves remain available, but the result reports the selected fixture ID,
location, and `loadName` as the deterministic target for a later game-load
adapter. See `save-fixtures.example.json` for the portable schema.

Use `fixture-status` to compare the manifest's expected stable-profile
fingerprint and declared save hashes with their current actual values without
changing anything. When no manifest is configured, or the configured file is
missing, `fixture-status` returns `fixture-not-configured` or
`fixture-manifest-missing` with the exact configuration property, portable
example path, current stable-profile fingerprint, and creation guidance; this
discovery state is not a tool error for inspection. It blocks only
`VerifiedFixture` creation; `MainMenuOnly` and `FreshGame` remain available.
The doctor reports fixture readiness separately rather than treating it as a
prerequisite for every save policy. `refresh-fixture` is the separately
authorized repair path:
it requires the exact access lease and closed-state proof, preserves the prior
manifest and a receipt, refreshes only the selected declared fixture, and
verifies the postcondition. It never invents a replacement save path.

At creation the tool records every existing mod directory. A workspace may
register only an exact mod directory absent from that snapshot. It refuses to
claim, edit, replace, or delete a pre-existing shared mod. The task may change
only enable/disable markers in its own cloned profile. Shared package updates
must be installed under a new mod name and selected additively in the primary
profile; retained task profiles are not rewritten. On every resume the tool
adds newly observed, non-owned mod directories to the workspace's protected
shared-mod inventory. Cleanup is restricted to
the exact generated profile and registered task-owned mods; the stable source
may have advanced since the clone. Only after explicit discard, replacement, or
policy-proven obsolescence may `retire`
atomically selects and verifies its stable source in `ModOrganizer.ini`, keeps
the exact prior INI bytes and receipt, and only then removes the task profile.
Workspace manifests and results expose `profileName`, `profileDirectory`, and
`modListPath` while retaining the legacy `profile` and `profilePath` fields.
Calling MO2 `release-access` alone preserves the workspace for later `resume`.
After the game and MO2 close, catalog `complete` preserves generated
`ShaderCache` evidence and restores its pre-task tree. Then workspace
`complete-output` preserves the generated `backup` tree, restores its pre-task
tree, and releases the Overwrite owner marker. `retire` requires both exact
completion receipts and never deletes the Overwrite directory.
Backup completion and interrupted-completion recovery revalidate the committed
restore's immutable transaction identity, committed journal, and snapshot lineage, the live
baseline, and the physical preserved task output before publishing completion
or releasing ownership. Conflicting or malformed restore evidence remains
nonterminal and retains the task's recovery authority.
Zero generated shader-cache files are accepted only as non-promoted
`failed`/`unverified` cleanup, never as known-working output. The workspace
independently verifies the exact prepared provider-shadow hash, original
physical snapshot, preserved physical working tree, canonical restore receipt,
and committed journal bound to the same snapshot and output generation.
`restore-noop` additionally requires the exact snapshot `cache.before` path and
matching original/prepared hashes; an identical tree at another path is not
equivalent proof. `complete-output`, completed-generation `resume`, and
retirement use this same validation. Missing or changed evidence fails closed
without releasing the owner or changing the retained profile. A successful
cleanup allows later resume into a fresh output generation; it does not promote
the failed cache or certify it as working.
Restoring shared runtime state is independent and must not rewrite or retire
the retained workspace. Virtual Desktop and `VirtualDesktop.Streamer` never
block profile mutation or SteamVR null-HMD; an enabled profile-local
OCU/OpenComposite provider is the conflicting `SteamVRNull` route.
The deprecated workspace `release` command is retained only to return safe
recovery guidance; it fails before mutation and never deletes a profile.

`-WinningPaths` changes `register-mod` into an enabled winning-provider
transaction. `ensure-mod-wins` can subsequently re-check and reposition only a
mod already proven task-owned by that workspace. Winner proof intentionally
covers enabled loose-file providers in the exact profile. Overwrite, unmanaged
game files, and archives still require separate VFS evidence.

Use inline `-WinningPaths` for one path only. Native `pwsh -File` argument
binding can collapse comma-separated quoted values into one string, so use
`-WinningPathsFile` for every multi-path direct or approval-compatible
invocation; the format matches the profile controller. Every result also
reports `data.configuration` with the exact selected config path, source, and
candidate precedence.
