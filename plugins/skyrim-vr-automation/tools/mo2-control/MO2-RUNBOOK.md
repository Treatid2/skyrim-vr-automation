# MO2 automation runbook

## Purpose and authority

This runbook is the operational source of truth for Codex-assisted MO2 work on
the Skyrim VR installation. The local machine configuration is
the resolved machine configuration; do not rediscover paths or guess profile and
executable names when the package can report them.

Version 0.5.0 provides read-only inspection plus single-owner `prepare`, exact
`open` and `launch`, bounded `status`, graceful `stop-game`, MO2-only
cooperative `close`, stranded-instance `recover-close`, and graceful full
`stop`, immediate start receipts, and attributable RootBuilder recovery. A successful validation
authorizes no mutation by itself. Changes still require the user's task to put
the relevant MO2 state, mod files, game files, or captured artifacts in scope.

## Machine configuration

The exact MO2 root, configuration, profile, registered executable, staging
location, archive, process names, and safety limits live in the ignored
the doctor-reported configuration. Start from `config/machine.example.json`; do not
commit the resulting machine file.

`prepare` creates a uniquely named session directory in the configured staging
location after authorization. The configured archive remains optional until
bounded collection and verified archive commands are implemented. The game
install and overwrite are not long-term diagnostic stores.

## Non-negotiable rules

1. Address MO2 by exact profile and exact registered executable name. Never
   treat MO2's fallback profile as success.
2. Before editing MO2 state, require MO2 and the game to be closed. VR runtime
   processes may remain live unless the operation specifically requires them
   closed.
3. Run one automation owner at a time. Do not launch a second attempt while the
   first MO2 or game process is unresolved.
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

```powershell
Set-Location '<repository>\tools\mo2-control'
.\Invoke-MO2Control.ps1 inspect
.\Invoke-MO2Control.ps1 validate -RequireClosed
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

## Automated preparation

Preview first, then acquire the session lock:

```powershell
$preview = .\Invoke-MO2Control.ps1 prepare -Label "short-test-name" -WhatIf | ConvertFrom-Json
$prepared = .\Invoke-MO2Control.ps1 prepare -Label "short-test-name" | ConvertFrom-Json
$sessionId = $prepared.data.session.sessionId
```

`prepare` requires closed state, validates the exact profile/executable pair,
creates `session.json`, and atomically creates the single-owner lock. It does
not change MO2's selected profile or mod list.

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

```powershell
.\Invoke-MO2Control.ps1 open -SessionId $sessionId
.\Invoke-MO2Control.ps1 close -SessionId $sessionId
```

These visible-window operations must run as the logged-on interactive user
(the approved elevated execution route in Codex). `close` refuses while a game
or loader is present. It may invoke the exact accessible control named
`Unlock`; it never closes Notepad++, Tullius, or another crash-log editor.

Launch only with the identity returned by `prepare`:

```powershell
.\Invoke-MO2Control.ps1 launch -SessionId $sessionId
.\Invoke-MO2Control.ps1 status -SessionId $sessionId
```

The implementation uses MO2's official `--profile NAME run --executable NAME`
syntax and waits for the configured game process to be observed. It does not
reconstruct the loader path or mutate the selected profile.

For repeated measurements in one owned session, retain MO2 and cycle only the
game:

```powershell
.\Invoke-MO2Control.ps1 stop-game -SessionId $sessionId
.\Invoke-MO2Control.ps1 launch -SessionId $sessionId
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

1. Request graceful close with `stop -SessionId $sessionId`, then confirm with
   `validate -RequireClosed`. `stop` never force-terminates. If it returns
   `stop-incomplete` because the retained MO2 owner has no closeable window,
   use the bounded escalation `stop-game`, `terminate`, then `release`; the
   latter two commands prove game/RootBuilder absence and exact lock ownership.
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

### Stranded MO2 has no automation session

Symptom: MO2 was opened manually or by an earlier failed parameter set, no
session lock exists, and a modal/VFS state prevents ordinary shutdown.

Response: preview and then run `recover-close -Label "reason"` through the
logged-on interactive user. It accepts exactly one process whose executable
path equals the configured `ModOrganizer.exe`, refuses while a game/loader or
another lock exists, creates a retained recovery audit, and uses the same exact
`File` → `Exit`, exact `Unlock`, and normal-modal-close policy. Run `release` using the same identity after
closed-state proof. Notepad++ and Tullius are outside the target set.

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
