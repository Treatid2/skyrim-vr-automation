# MO2 Control

MO2 Control is the shared, machine-readable entry point for Codex tasks that
inspect or validate the Skyrim VR Mod Organizer 2 installation.

`validate-closed` is the explicit closed-state spelling of `validate
-RequireClosed`; both commands are read-only and return the same proof.

Version `0.9.0` retains cooperative access arbitration and adds a durable,
session-scoped controller bundle, explicit profile identity fields, retained
failed-to-run dialog cleanup, bounded launch
pending state, helper-to-runtime PID adoption, structural Unlock handling, and
exact-session `terminate-game` deadlock recovery. Recovery preserves MO2 and
requires RootBuilder restoration before success. Test tasks should use
`../mo2-workspace-control` to create or resume a durable task-owned clone of
the configured stable source profile; the ordinary session default is not
inferred as a safe template.

Version `0.6.0` added cooperative access arbitration across independent tasks
while retaining exact-profile `open`, MO2-only cooperative `close`, and
`recover-close` for a stranded pre-session MO2, including one protected by the
caller's already-owned access-only lease. Cooperative close verifies the
configured executable path, addresses only the exact MO2 PID, invokes MO2's
structured exact `File` → `Exit` command, invokes only a button whose normalized
accessible name is exactly `Unlock`, and otherwise requests normal closure of
visible MO2-owned modal windows. It never closes Tullius,
Notepad++, or another editor and never force-terminates. Existing retained-MO2
game cycling and explicit safe-gated termination remain available.

`open` and `launch` accept `-StartOnly`: they write their exact session receipt,
start only the intended process, return immediately with the session/evidence
path, and direct the caller to poll `status`. When `status` proves the one exact
adopted MO2 process and its visible `MainWindow`, it advances an `opening`
session to durable `mo2-open` so a later game launch is valid. A missing session
ID is a structured `missing-session-id` precondition instead of a PowerShell
binding failure. Launch classifies the exact `Failed to write settings` dialog
and cooperative close acknowledges only its exact `OK` button.

`status` first retains a new launch in bounded `launch-pending`. After that
grace it identifies a closed or headless owner with active RootBuilder
`BuildData.json` as `rootbuilder-recovery-required`. `recover-rootbuilder`
performs one recorded exact-profile launch; the caller then uses normal `stop`
so RootBuilder can restore its deployment through the exact Unlock path. It
never deletes deployment data.

Validation also resolves a registered executable stored under MO2's `mods`
directory back to its owning mod. Launch is blocked when that exact mod is
disabled, missing, or ambiguous in the requested profile.

DevBench, SKSE-plugin, and other extension-dependent sessions must pass
`-RequireSKSE` to both `validate` and `prepare`. The controller identifies
`skse_loader.exe`/`sksevr_loader.exe` as SKSE-capable and rejects a registered
entry that directly launches `SkyrimVR.exe`. `prepare` persists this requirement
in the session manifest and lock, and every later `launch` revalidates it so a
session cannot silently fall back to the plain game executable.

Overwrite is scanned recursively for `ShaderCache` and `ShaderCache.*`
directories. Inspection classifies active, rollback (`.Previous`), temporary
swap (`.Swap`), and other legacy trees and marks swap state older than one hour
as stale. Validation blocks launch whenever any such tree remains, regardless
of ordinary file-count thresholds; use workspace `prepare-source` to move the
complete trees into an enabled stable-profile mod first.

## Quick start

Read `APPROVALS.md` before submitting an elevated command. Controllers report
their exact direct invocation under `data.approval`; use its literal
`reusablePrefix` when eligible. Approval requests must not use `$tool`,
`$controller`, `-Command`, a pipeline, or a constructed command string.

Using the direct command shape (`<absolute-...>` values must be replaced with
literal paths before execution):

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> help -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> inspect -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> request-access -Label upscaling-api-tests -TaskId <stable-task-id> -RuntimeRoute OCU -EstimatedMinutes 20 -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> validate -AccessId <literal-access-id> -RequireClosed -RequireSKSE -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> prepare -AccessId <literal-access-id> -Label upscaling-api-run -RequireSKSE -Compact
```

Use `-Compact` for one-line JSON. Override the configured defaults only with an
exact name:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> validate -Profile <exact-profile-name> -Executable "Launch MGO - Do Not Unlock" -RequireClosed -Compact
```

Exit code `0` means the command completed without a failed check. Exit code `2`
means validation was blocked or the tool itself failed. Warnings do not change
the exit code, but must be reviewed before a state-changing operation.

## Package layout

- `Invoke-MO2Control.ps1` — stable command-line entry point.
- `MO2Control.psm1` — inspection and validation implementation.
- `config/machine.example.json` — portable configuration template.
- `config/machine.local.json` — supported legacy ignored local paths and safety limits.
- `%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json` — preferred stable
  per-user configuration, independent of a checkout or plugin cache version.

Configuration precedence is explicit `-ConfigPath`,
`SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user path, then the legacy local
file. The result reports the selected source under `data.configuration`.
- `schemas/result.schema.json` — output contract.
- `MO2-RUNBOOK.md` — operating and recovery guidance.
- `tests/Test-MO2Control.ps1` — isolated fixture tests plus optional live checks.
- `sessions/` — optional location for the configured durable single-owner lock;
  never a capture store.

## Current contract

`inspect` reports:

- configured paths, profiles, exact selected profile, and registered
  executables;
- MO2, game, and VR runtime processes;
- bounded overwrite file count and byte usage;
- active and quarantined RootBuilder JSON state;
- fast D: session staging and L: archive availability;
- session-lock state.

`validate` adds blocking checks for the requested profile and executable,
registered binary and working directory, active RootBuilder JSON, overwrite
safety limits, storage, and (with `-RequireClosed`) MO2/game process state.

Profile fallback is never accepted as success. Quarantined
`*.corrupt-*.json` files are retained evidence and are warnings, not active
RootBuilder failures.

## Cooperative access lifecycle

`request-access` atomically acquires the one shared MO2 lock and returns an
`accessId` bearer credential plus a distinct public `leaseId`. Every request
must select exactly one `-RuntimeRoute`: `OCU`, `SteamVR`, or `SteamVRNull`.
`OCU` is incompatible with both SteamVR routes. `SteamVRNull` is SteamVR with
the null HMD and is mutually exclusive with physical `SteamVR`. The selected
route is retained on the lease and copied into prepared session evidence so
runtime controllers can enforce it without inference. Retain the
`accessId` privately. `-TaskId` (alias `-ReporterTaskId`) records an optional
stable task identity; when omitted it resolves `CODEX_THREAD_ID` or
`CODEX_TASK_ID` if available. If another task owns the lock, `access-busy`
reports only the public lease identity, owner label/state, and advisory release
estimate; it never discloses or echoes an access credential. `-WaitSeconds` can
perform a bounded retry, but no task is queued indefinitely.

`prepare` and every launch revalidate the exact selected profile against the
leased route. OCU requires exactly one enabled provider containing
`root\openvr_api.dll` plus an OpenComposite marker. SteamVR and SteamVRNull
require every profile-local root OpenVR replacement to be disabled. Discovery
fails closed when provider identity is ambiguous; declaring a route never
overrides the profile's actual runtime files.

`-EstimatedMinutes` is useful coordination metadata, not a deadline. The tool
never expires, steals, or transfers a lease because its estimate elapsed.
`renew-access` refreshes the recorded activity time and can replace the
estimate. `access-status` reports availability and exact ownership.
Session owner liveness is bound to both process ID and process start time, so a
reused PID cannot make an abandoned session appear live.

Every task must call `release-access` as soon as it no longer needs MO2. This
includes compilation, source editing, result analysis, report writing, and any
other phase that does not operate MO2 or Skyrim. Do not hold the lease merely
because the overall task remains active. `release-access` proves MO2, Skyrim,
and RootBuilder deployment are inactive before removing the lock. It does not
delete the task workspace: profile state and saves remain available for an
explicit later `resume` under a newly acquired lease.

If a task disappears while retaining a lease, `recover-access` requires the
exact `accessId`, explicit `-ConfirmAbandoned`, and the same closed-state proof.
An overdue estimate is never sufficient evidence of abandonment.

The normal explicit flow uses these separate direct calls. Read each JSON
result, then substitute its literal returned identity into the next command:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> request-access -Label weather-api-tests -TaskId <stable-task-id> -RuntimeRoute SteamVRNull -EstimatedMinutes 20 -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> validate -AccessId <literal-access-id> -RequireClosed -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> prepare -AccessId <literal-access-id> -Label weather-api-run -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> release -SessionId <literal-session-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> release-access -AccessId <literal-access-id> -Compact
```

For backward compatibility, `prepare` without `-AccessId` still acquires an
implicit single-session lease, and `release` removes it as before. When an
explicit lease is used, `release` retains access and returns
`session-released-access-retained`; the task must then either prepare another
session or call `release-access`.

## Session lifecycle

`prepare` requires a closed game/MO2 state, validates one exact profile and
registered executable, and creates a durable evidence manifest on staging
storage. It either binds the caller's exact access lease or, for legacy callers,
atomically acquires an implicit lease. It also copies the exact entry point,
modules, and resolved configuration into the session evidence directory and
returns `controllerPath`. Use that path for the rest of the lifecycle so a
plugin reinstall cannot invalidate an active session. `launch` requires the returned session
identity and uses MO2's supported command line:

```text
ModOrganizer.exe --profile NAME run --executable NAME
```

`open` starts only `ModOrganizer.exe --profile NAME`, proves the exact process
path and a visible `MainWindow`, and does not run the registered game executable.
Immediately after process creation it writes `mo2-open-started.json` and marks
the owned session `opening`. If the caller's outer timeout expires before UIA
readiness, a later `status`, `close`, or `recover-close` still has durable PID,
path, argument, and timestamp evidence for exact-process adoption.
`status` is bounded and mutates only the durable `opening` to `mo2-open`
transition after exact process and visible-main-window proof. `stop-game`
requests normal closure of the owned game/loader while preserving the exact
owner MO2 PID, allowing controlled relaunches. After the game exits it first
observes the exact session-owned MO2 PID for a bounded stability window,
allowing a delayed post-stop dialog to arrive. It then acknowledges only a
structurally classified retained `Failed to run` dialog; an unknown modal returns
`game-stopped-needs-attention` without touching it. If MO2 exits immediately
after the game, `stop-game` returns `mo2-exited-after-game-stop`, sets
`releaseRequired`, and refuses to represent the session as relaunchable. `close`
refuses while a game/loader exists and cooperatively resolves
MO2's structured `File` → `Exit` path and visible modal chain, including the VFS
`Unlock` prompt. `stop` first closes the game and then uses the same MO2
resolver. `release` ends only the exactly owned session after proving MO2 and
the game are closed, while retaining the evidence directory. It removes an
implicit lease or returns an explicit lease to access-only state. All mutation
commands have `-WhatIf`. Evidence
collection, archive verification, profile mutation, cache management, and
recovery remain deferred until separately bounded.

Use `-NoExit` when embedding the entry script in a larger PowerShell host; a
failed command then returns structured JSON without terminating that host.

The retained cycle is:

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> stop-game -SessionId <literal-session-id> -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <literal-controllerPath> launch -SessionId <literal-session-id> -Compact
```

Resume is accepted only from a bounded stopped/failure state, with no game
process and exactly one MO2 process matching the session's original owner PID.

`terminate` is intentionally distinct from `stop`: it force-terminates only
MO2 processes owned by the active session, and only after proving that no game
or loader process is running and no RootBuilder `BuildData.json` remains.

Visible `open`, `close`, `recover-close`, `stop-game`, and `stop` operations must
run as the logged-on user on the interactive Windows desktop. In Codex this
means using the approved elevated execution route. A sandbox call returns
`interactive-desktop-required` before opening MO2 or creating a recovery lock.
Run `release` through the same identity that created a recovery session so its
retained evidence can be updated before the lock is removed.
