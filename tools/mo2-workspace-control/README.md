# MO2 test workspace control

This tool gives each automation task a unique MO2 profile cloned from an
explicitly configured, known-good `defaults.testProfileSource`. It never uses
the ordinary session default as an implicit template. The complete `saves`
tree from that maintained source profile is copied and verified into every new
task profile so ordinary access requests remain usable. Fresh creation is
fail-closed unless that source also has one valid default world-entry fixture.
The fixture is the maintained route into the loaded game world; alternate
locations may then be reached with guarded `coc`/`cow` commands.

Profile discovery, hashing, fixture verification, copying, and post-copy
verification share one command-wide tree-operation deadline. The controller
also enforces explicit file, directory, depth, and aggregate-byte limits and
rejects reparse points. Exceeding any budget returns a bounded failure before a
new clone is committed; the limits are configurable through the corresponding
`-MaxProfile*` and `-TreeOperationTimeoutSeconds` parameters.

Before `create`, run `prepare-source` under the same MO2 access lease. It scans
overwrite recursively for every directory named `ShaderCache` or beginning
`ShaderCache.`, including the legacy `ShaderCache.Previous` and
`ShaderCache.Swap` trees. If any exist, it moves their complete relative trees
into one newly named MO2 mod and enables that mod in the stable source profile
under an exact modlist backup and receipt. `create` refuses to clone while any
such directory remains in overwrite.

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

Workspaces are durably owned by `-TaskId` (or `CODEX_THREAD_ID` /
`CODEX_TASK_ID`), not by one access lease. `create` makes and selects a fresh
profile. `list-task` reports retained profiles. `resume` rebinds one exact
retained workspace to a newly owned lease and selects it without refreshing it
from the primary profile. See `../../docs/MO2-TASK-WORKSPACES.md`.

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
`refresh-fixture`, `prepare-source`, and `retire` remain one-shot because they
replace shared metadata, move overwrite trees into a shared stable mod, or
recursively remove exact owned paths.

`adopt` is also one-shot: it transfers one ready workspace from the exact
released `-PreviousAccessId` to a distinct active lease only after closed-state,
stable-source, and task-profile fingerprint proofs. It is the recovery route
when an otherwise valid workspace outlives its transient access lease.

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> prepare-source -AccessId <literal-access-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> list-local-work-mods -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> list-task -TaskId <stable-task-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -TaskId <stable-task-id> -Label modlist-test -WorkspaceContent Modlist -SavePolicy MainMenuOnly -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -TaskId <stable-task-id> -Label csx-api -WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModId csx-aio-local-devbench -SavePolicy MainMenuOnly -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> resume -AccessId <new-literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create-mod -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -ModName "Codex Weather API Test 20260822" -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> register-mod -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <literal-workspace-id> -ModName "Codex Weather API Test 20260822" -ModDirectory "<exact-mod-directory>" -WinningPaths "SKSE\Plugins\CommunityShaders.dll" -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> release-access -AccessId <literal-access-id> -Compact
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

One default fixture is mandatory for every fresh clone, regardless of
`SavePolicy`. The installer or list maintainer must first load that save in the
maintained source profile, record it in `defaults.newGameFixtureManifest`, and
obtain `fixture-valid`. Creation records static integrity as
`data.sourceIntegrity`, reports the declaration as `data.worldEntryFixture`,
verifies it again in the copied tree, and sets `data.copiedWorldEntrySave`.
`integrityVerified` proves exact profile/save bytes; it does not imply
`runtimeQualified`. This is a clone-time integrity guarantee only: `resume`
preserves a task's prior profile exactly and does not claim its save still works
after task-local edits.

`VerifiedFixture` additionally authorizes that exact fixture as the
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
discovery state is not a tool error for inspection, but it blocks fresh
`create`. The doctor treats anything other than `fixture-valid` as a failed
setup prerequisite. `refresh-fixture` is the separately authorized repair path:
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
may have advanced since the clone. Before deleting a task profile, `retire`
atomically selects and verifies its stable source in `ModOrganizer.ini`, keeps
the exact prior INI bytes and receipt, and only then removes the task profile.
Workspace manifests and results expose `profileName`, `profileDirectory`, and
`modListPath` while retaining the legacy `profile` and `profilePath` fields.
Calling MO2 `release-access` alone preserves the workspace for later `resume`.
The deprecated workspace `release` command is retained only to return safe
recovery guidance; it fails before mutation and never deletes a profile.

`-WinningPaths` changes `register-mod` into an enabled winning-provider
transaction. `ensure-mod-wins` can subsequently re-check and reposition only a
mod already proven task-owned by that workspace. Winner proof intentionally
covers enabled loose-file providers in the exact profile. Overwrite, unmanaged
game files, and archives still require separate VFS evidence.

Use `-WinningPathsFile` for multiple paths in a direct approval-compatible
invocation; the format matches the profile controller. Every result also
reports `data.configuration` with the exact selected config path, source, and
candidate precedence.
