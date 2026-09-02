# MO2 automation runbook

## Purpose and authority

This runbook is the operational source of truth for Codex-assisted MO2 work on
the Skyrim VR installation. The local machine configuration is
the resolved machine configuration; do not rediscover paths or guess profile and
executable names when the package can report them.

Version 0.8.0 provides cooperative cross-task access leases, read-only
inspection, single-owner `prepare`, exact
`open` and `launch`, bounded `status`, graceful `stop-game`, MO2-only
cooperative `close`, stranded-instance `recover-close`, and graceful full
`stop`, durable per-session controller snapshots, exact retained-dialog cleanup,
immediate start receipts, and attributable RootBuilder recovery. A successful validation
authorizes no mutation by itself. Changes still require the user's task to put
the relevant MO2 state, mod files, game files, or captured artifacts in scope.

Each independent test task owns a durable profile from the explicit
`defaults.testProfileSource` through `../mo2-workspace-control`. The stable
source is distinct from the ordinary session default and from experimental
alternate profiles. Workspaces inherit a verified copy of the stable source's
complete saves tree and its mandatory default world-entry fixture, survive
access-lease yields, and never own mods that predate their creation. The
fixture is qualified at fresh-clone time only; a resumed task profile is
preserved without any promise that its save remains loadable after task edits.

## Machine configuration

The exact MO2 root, configuration, profile, registered executable, staging
location, archive, process names, and safety limits live in the ignored
the doctor-reported configuration. Start from `config/machine.example.json`; do not
commit the resulting machine file.

Machines with multiple portable MO2 installations keep one exact config per
modlist through `../modlist-control`. Inspect and select the intended name
before preflight. A persisted exact selection is allowed; choosing the first
config, assuming that `main` means safe, or falling back to the UI-selected
profile is not.

Before any elevated invocation, read `APPROVALS.md`. Use a direct literal
`pwsh.exe -NoProfile -NonInteractive -File <entrypoint> <subcommand>` shape and
the result's `data.approval.reusablePrefix`. Variables in this runbook describe
returned data only; they must not hide the executable, entry point, or
subcommand in an approval request.

`prepare` creates a uniquely named session directory in the configured staging
location after authorization. The configured archive remains optional until
bounded collection and verified archive commands are implemented. The game
install and overwrite are not long-term diagnostic stores.

## Non-negotiable rules

1. Address MO2 by exact profile and exact registered executable name. Never
   treat MO2's fallback profile as success. For DevBench or any SKSE-dependent
   run, use `-RequireSKSE` during validation and preparation; a plain
   `SkyrimVR.exe` entry is not an equivalent launcher.
2. Before editing MO2 state, require MO2 and the game to be closed. VR runtime
   processes may remain live unless the operation specifically requires them
   closed.
3. Run one automation owner at a time. Acquire access before preparing or
   operating MO2. Do not launch a second attempt while the first lease, MO2, or
   game process is unresolved.
4. Do not repeatedly retry a failing launch. Inspect processes, logs,
   RootBuilder JSON, and overwrite first.
5. Use the configured staging location for files needed during a session. At
   the tidy end, move eligible captures and diagnostics to the configured
   archive. Preserve provenance with a manifest; do not flatten filenames from
   different sessions.
6. Never automatically delete or bulk-move unclassified overwrite content.
   Overwrite can contain generated mod state as well as disposable captures.
7. Preserve corrupt RootBuilder JSON as timestamped evidence outside active
   state. Do not silently delete it.
8. Treat screenshots as visual evidence, logs as behavioral evidence, and
   crash dumps as crash evidence. Keep their timestamps and test identity
   together.

## Standard preflight

Run:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> inspect -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> validate -RequireClosed -Compact
```

Proceed with a state-changing setup only when:

- `state` is `ready` or, after explicit review, `degraded`;
- the exact requested profile exists; a different UI-selected profile is a
  warning because `launch` passes the requested profile explicitly;
- the exact registered executable exists once, and its binary and working
  directory exist;
- every active RootBuilder JSON file parses;
- no live MO2/game process conflicts with the change;
- overwrite is understood and below the blocking limits;
- any warning is explicitly accounted for.

Current safety limits are configuration, not cleanup targets. A blocked
overwrite means “classify and relocate safely,” not “delete until green.”

## Access arbitration

Before any planned MO2 use, request the shared resource:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> request-access -Label short-task-name -EstimatedMinutes 20 -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> validate -AccessId <literal-access-id> -RequireClosed -Compact
```

If another task owns it, `state` is `access-busy`. The response includes its
label, whether a session is bound, and any estimated release time. The estimate
is advisory only. It never expires a lease or authorizes another task to take
over. A caller may use a short bounded `-WaitSeconds`, or return to other work
and retry later.

Hold access only while operating MO2, Skyrim, its profile, or a live test
session. Release it during code compilation, source editing, offline cache
analysis, report writing, or any other phase that does not require MO2:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> release-access -AccessId <literal-access-id> -Compact
```

This yields only the scarce access lease. It deliberately preserves the task's
workspace profile, saves, options, and task-owned mods for a later `resume`.

The task remains responsible for its lease even when the estimate is overdue.
Use `renew-access` to update coordination metadata. Use `recover-access` only
after the owner is positively classified as abandoned, and only with the exact
AccessId plus `-ConfirmAbandoned`; recovery also proves MO2/game closure and no
active RootBuilder deployment.

## Automated preparation

Discover the stable task identity's retained workspaces, then explicitly create
or resume one while holding access. On the first request, prepare the configured
stable source and create a task workspace. On later requests, select an exact
retained WorkspaceId or explicitly request a fresh clone. Pass the returned
task profile explicitly to `prepare`.
`prepare-source` now reports existing cache trees without moving them. Creation
binds the workspace to snapshotted MO2 Overwrite output, removes the cloned
profile's game and `Synthesis` custom-overwrite mappings, and materializes the
enabled `backup` provider union there. Cache catalog preparation does the same
for `ShaderCache`. Fresh creation also requires `fixture-status` to be
`fixture-valid` for the maintained source's default world-entry save:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> prepare-source -AccessId <literal-access-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> fixture-status -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> list-task -TaskId <stable-task-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -TaskId <stable-task-id> -Label short-test-name -SavePolicy MainMenuOnly -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> resume -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <exact-retained-workspace-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> complete-output -AccessId <literal-access-id> -TaskId <stable-task-id> -WorkspaceId <exact-workspace-id> -Confirm:$false -Compact
```

After each live use, release the evidence session and access lease but retain
the workspace. Use workspace `retire` only when its profile is no longer
wanted. A task must never edit, replace, or delete a pre-existing shared mod;
it may change existing mod markers only in its own cloned profile. Primary-list
updates install a new mod name and change primary-profile markers additively.

Preview first, then bind a session to the owned access lease:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> prepare -AccessId <literal-access-id> -Label short-test-name -RequireSKSE -WhatIf -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> prepare -AccessId <literal-access-id> -Label short-test-name -RequireSKSE -Compact
```

`prepare` requires closed state, validates the exact profile/executable pair,
creates `session.json`, captures the exact controller modules and resolved
machine configuration under the session, and binds it to the exact access
lease. Use the returned `controllerPath` for every command that owns that
session; it remains valid if a plugin update replaces the versioned cache from
which `prepare` was called. `prepare` does not change MO2's selected profile or
mod list. Legacy callers may omit AccessId;
that creates an implicit one-session lease which `release` removes.
When `-RequireSKSE` is supplied, that requirement is durable session state and
`launch` revalidates it before starting MO2.

## Manual preparation for unimplemented mutations

1. Confirm the prior game and MO2 processes are closed.
2. Run preflight and save the JSON result with the session notes.
3. Create one directory in the configured staging location using a sortable UTC timestamp and a
   short test label, for example `20260819T050000Z-csx-pr17-coc-cycle`.
4. Record at minimum:
   - profile and executable;
   - CSX commit/build/package identity;
   - active runtime (SteamVR/OpenXR/VDXR/OCU as applicable);
   - GPU and relevant upscaler/render settings;
   - intended scenes or test actions;
   - preflight result.
5. Make only the requested, attributable mod-list/package change. Do not mix
   unrelated list maintenance into the same session.
6. Re-run `validate -RequireClosed` after the change. If it fails, do not launch.

## Exact launch and monitoring

Open only the exact MO2/profile UI when no game launch is wanted:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> open -SessionId <literal-session-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> close -SessionId <literal-session-id> -Compact
```

These visible-window operations must run as the logged-on interactive user
(the approved elevated execution route in Codex). `close` refuses while a game
or loader is present. It may invoke the exact accessible control named
`Unlock`; it never closes Notepad++, Tullius, or another crash-log editor.

Launch only with the identity returned by `prepare`:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> launch -SessionId <literal-session-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> status -SessionId <literal-session-id> -Compact
```

The implementation uses MO2's official `--profile NAME run --executable NAME`
syntax and waits for the configured game process to be observed. It does not
reconstruct the loader path or mutate the selected profile.

For repeated measurements in one owned session, retain MO2 and cycle only the
game:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> stop-game -SessionId <literal-session-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> launch -SessionId <literal-session-id> -Compact
```

`stop-game` never force-terminates and must prove the game/loader closed while
the original MO2 owner PID remains. Relaunch refuses a different or additional
MO2 process. MO2 may accept the official run request through a short-lived
helper; helper exit is therefore non-terminal and polling continues until the
game appears or the bounded timeout expires.

After launch:

- confirm exactly one expected MO2/game process chain;
- note first-run dialogs immediately because they block unattended launch;
- distinguish “application started” from “game reached a known scene”;
- monitor bounded process and log state rather than recursively scanning the
  game tree or overwrite in a loop;
- on a hang or crash, stop retries and collect evidence from that attempt.

A VR runtime being live does not prove which runtime path the game used. Record
the actual route independently.

## Tidy session end

1. Request graceful close with the literal session controller's `stop
   -SessionId <literal-session-id>`, then confirm with
   `validate -RequireClosed`. `stop` never force-terminates. If it returns
   `stop-incomplete` because the retained MO2 owner has no closeable window,
   use the same durable controller for the bounded escalation `stop-game`,
   `terminate`, then `release`; the
   latter two commands prove game/RootBuilder absence and exact lock ownership.
   `release -SessionId` ends the evidence session. For an explicitly requested
   lease it deliberately retains access, so call `release-access -AccessId`
   immediately unless another MO2 session is about to begin.
2. Collect only files attributable to the session. Common sources include:
   - CSX/SKSE/MO2 logs;
   - crash dumps from configured diagnostic locations when in scope;
   - screenshots or video captures;
   - generated API/performance results.
3. Keep actively analyzed material in staging only as long as needed.
4. Move completed-session captures and diagnostics to a same-named directory
   in the configured archive. Include a manifest containing source path, archived path, byte
   size, timestamp, and preferably SHA-256.
5. Verify the archived copy before removing the source. Do not remove game or
   mod-generated files merely because they appeared during the session.
6. Run `inspect` again and attach the post-session result to the notes.

## Failure and recovery matrix

### Missing profile or fallback warning

Symptom: MO2 says the selected profile does not exist and chooses a different
profile.

Response: stop. Do not acknowledge the fallback and continue automation. Close
MO2, verify the exact profile directory and `selected_profile`, then run
`validate -RequireClosed`. A fallback is a failed precondition even if MO2 can
launch.

### Persisted legacy task profile

Symptom: `inspect` reports that MO2 selects a `Codex Task -` profile whose
workspace has no runtime-output isolation contract.

Response: do not launch that profile. Close Skyrim and MO2, acquire the exact
access lease, validate closed state, preview workspace
`recover-legacy-selection`, and run it with the reported workspace ID. The
operation selects the configured stable source and retains the legacy profile,
mods, cache, manifest, exact INI backup, and recovery receipt.

### `Cannot start -r`

Symptom: MO2 tries to open a path such as `...\MO2Root\-r`.

Meaning: launch arguments were routed into the program/path position or parsed
by the wrong layer.

Response: stop reconstructing the command line. Use the exact registered MO2
executable entry. Record the attempted invocation. Do not add more quoting or
flags speculatively.

### RootBuilder JSON decode error

Symptom: `JSONDecodeError`, often while RootBuilder handles an about-to-run
event.

Response:

1. Close MO2/game and run validation.
2. Identify the exact active invalid JSON file; do not assume every RootBuilder
   file is corrupt.
3. Preserve the invalid file as timestamped `.corrupt-YYYYMMDD-HHMMSS.json`
   evidence outside active state before allowing regeneration.
4. Validate again, then perform one controlled launch.

The known quarantined 171,385-byte `BuildData.corrupt-20260817-073210.json` is
diagnostic evidence and should not be reintroduced as active state.

### `failed to receive data from secondary process: Unknown error`

Meaning: the UI message alone does not prove whether the child failed before
launch, the game failed later, or RootBuilder completed work but lost its
status channel.

Response: do not retry immediately. Inspect the process tree, MO2 and
RootBuilder logs, active JSON validity, game start evidence, and timestamps.
Classify the outcome first. Close residual processes before another attempt.

### `Failed to write settings`

Meaning: MO2 displayed a known blocking settings-write dialog before the game
was observed. The controller reports `launch-blocked-dialog`, preserves the
exact window text/buttons, and does not pretend the launch succeeded.

Response: use `close` or `stop` with the retained session ID. Cooperative close
invokes only the exact `OK` button for this known dialog, then continues normal
MO2 shutdown. Inspect the settings path/permissions before another launch.

### Stranded RootBuilder deployment

Symptom: `status` reports `rootbuilder-recovery-required` and identifies one
active `BuildData.json` after MO2/game closure.

Response: retain the session and preview `recover-rootbuilder -SessionId ...
-WhatIf`. The real command performs one exact-profile launch; finish with normal
`stop`/Unlock and verify `BuildData.json` is absent. This route does not delete
or rewrite RootBuilder metadata directly.

### Main-thread deadlock

If `stop-game` cannot close a launch-recorded game process, preview and run
`terminate-game -SessionId ...`. It terminates only exact PID/name/path/start
identities recorded by that launch, retains MO2, invokes only exact `Unlock`,
and withholds success until RootBuilder removes `BuildData.json`.

`coc APStartCell` is not a New Game action. A `FreshGame` baseline requires a
genuine Skyrim initialization route; until one is automated, classify it as an
attended or unsupported step rather than substituting COC.

### MO2 command helper exits before the game appears

Symptom: the process started for `ModOrganizer.exe --profile ... run ...` exits
successfully while the retained MO2 UI remains open, and Skyrim appears a few
seconds later.

Meaning: an existing MO2 instance accepted the command asynchronously. The
helper lifetime is not the launch postcondition.

Response: keep the original MO2 owner identity and continue the bounded wait
for the configured game process. If the timeout expires, report `launch-failed`
with both the helper exit data and the current process inventory; do not assume
the helper exit itself was a crash.

### Retained MO2 owner does not accept graceful close

Symptom: `stop` closes Skyrim but returns `stop-incomplete`; the exact MO2 owner
PID remains responsive and may have an empty window title.

Response: rerun `close -SessionId $sessionId` through the logged-on interactive
user. The resolver re-inventories visible MO2 windows, expands exact `File`,
invokes exact `Exit`, invokes exact `Unlock` when present, and normally closes
MO2 without closing the editor retaining a
VFS handle. If it still reports `close-incomplete`, retain the audit, prove the
game/loader set is empty, and only then consider explicit `terminate`. Finish
with `release`; a process-name-wide kill is unnecessary.

### Retained MO2 shows a Failed to run dialog

Symptom: after Skyrim closes or fails to start, the retained exact MO2 owner
shows a modal whose structure and text classify it as `failed-to-run`.

Response: run the literal session controller's `stop-game -SessionId
<literal-session-id>`. The controller
targets only that structurally classified dialog, invokes its exact `OK` or
`Close` control (or closes that exact known dialog), and records
`mo2-retained-dialog-cleanup.json`. An unknown modal is never dismissed and
returns `game-stopped-needs-attention` for attended handling.

### Stranded MO2 has no automation session

Symptom: MO2 was opened manually or by an earlier failed parameter set, no
session lock exists, and a modal/VFS state prevents ordinary shutdown.

Response: acquire access, then preview and run
`recover-close -AccessId <literal-access-id> -Label "reason"` through the
logged-on interactive user. It accepts exactly one process whose executable
path equals the configured `ModOrganizer.exe`, refuses while a game/loader or
another lock exists, creates a retained recovery audit, and uses the same exact
`File` → `Exit`, exact `Unlock`, and normal-modal-close policy. The recovery
result also returns a durable `controllerPath`; use it for `release` and every
other command owning that recovery session. Run `release` using the same identity after
closed-state proof, then release the retained access lease. Notepad++ and
Tullius are outside the target set.

### MO2 resource use grows abnormally

Response: stop launching and stop recursive monitoring. Inspect overwrite size,
diagnostic/capture destinations, repeated child processes, and logs. Preserve a
small diagnostic sample, then classify and relocate session artifacts. Do not
let screenshots, videos, or continuously produced diagnostics accumulate in
the game folder or overwrite.

### Transition hang or game crash

Response: preserve the scene/action, runtime route, settings, logs, and dump.
Determine whether the failure reproduces without the candidate CSX build before
calling it a CSX failure. Mod-list crashes are still recorded, but they do not
justify unrelated CSX changes.

### First-run/runtime dialog blocks automation

Response: treat the run as attended setup, not an automated result. Record the
choice and repeat from a clean preflight before accepting measurements.

## Current known validation state (2026-08-19)

At initialization, exact profile/executable checks and all four active
RootBuilder JSON checks passed. The tool found one quarantined corrupt
RootBuilder artifact. It also found 8,977 overwrite files using approximately
11.0 GB, exceeding the configured 5 GiB blocking threshold. Therefore this
installation is correctly reported as blocked for automated mutation until the
overwrite contents are classified and safely rationalized.

## Adding state-changing commands

Add commands in this order:

1. `prepare -WhatIf`: acquire a single-owner lock, validate closed state, create
   a session manifest, and stage an attributable package/profile change.
2. `launch`: invoke one registered MO2 entry with argument arrays, capture PID
   lineage, and prove a postcondition such as a game process or known API state.
3. `collect`: copy an allowlisted evidence set into the configured session directory
   with hashes and source metadata.
4. `archive`: copy to the configured archive, verify hashes, then remove only verified movable
   session artifacts when authorized.

Each command must be idempotent, bounded, JSON-reporting, and safe to resume
after interruption. No command may silently fall back to a different profile,
delete unclassified overwrite content, or launch while another session owns
the lock.
