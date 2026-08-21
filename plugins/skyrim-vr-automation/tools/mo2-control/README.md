# MO2 Control

MO2 Control is the shared, machine-readable entry point for Codex tasks that
inspect or validate the Skyrim VR Mod Organizer 2 installation.

Version `0.5.0` retains exact-profile `open`, MO2-only cooperative `close`, and
`recover-close` for a stranded pre-session MO2. Cooperative close verifies the
configured executable path, addresses only the exact MO2 PID, invokes MO2's
structured exact `File` → `Exit` command, invokes only a button whose normalized
accessible name is exactly `Unlock`, and otherwise requests normal closure of
visible MO2-owned modal windows. It never closes Tullius,
Notepad++, or another editor and never force-terminates. Existing retained-MO2
game cycling and explicit safe-gated termination remain available.

`open` and `launch` accept `-StartOnly`: they write their exact session receipt,
start only the intended process, return immediately with the session/evidence
path, and direct the caller to poll `status`. A missing session ID is a
structured `missing-session-id` precondition instead of a PowerShell binding
failure. Launch classifies the exact `Failed to write settings` dialog and
cooperative close acknowledges only its exact `OK` button.

`status` identifies a closed or headless owner with active RootBuilder
`BuildData.json` as `rootbuilder-recovery-required`. `recover-rootbuilder`
performs one recorded exact-profile launch; the caller then uses normal `stop`
so RootBuilder can restore its deployment through the exact Unlock path. It
never deletes deployment data.

## Quick start

From this directory in PowerShell:

```powershell
.\Invoke-MO2Control.ps1 help
.\Invoke-MO2Control.ps1 inspect
.\Invoke-MO2Control.ps1 validate -RequireClosed
.\Invoke-MO2Control.ps1 prepare -Label "null-hmd-baseline" -WhatIf
.\Invoke-MO2Control.ps1 recover-close -Label "stranded-mo2" -WhatIf
.\Invoke-MO2Control.ps1 recover-rootbuilder -SessionId $sessionId -WhatIf
```

Use `-Compact` for one-line JSON. Override the configured defaults only with an
exact name:

```powershell
.\Invoke-MO2Control.ps1 validate `
  -Profile "Codex" `
  -Executable "Launch MGO - Do Not Unlock" `
  -RequireClosed
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
- `sessions/` — reserved for a future single-owner session lock; never a capture
  store.

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

## Session lifecycle

`prepare` requires a closed game/MO2 state, validates one exact profile and
registered executable, creates a durable evidence manifest on staging storage,
and atomically acquires the shared lock. `launch` requires the returned session
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
`status` is bounded and non-mutating. `stop-game` requests normal closure of the
owned game/loader while preserving the exact owner MO2 PID, allowing controlled
relaunches. `close` refuses while a game/loader exists and cooperatively resolves
MO2's structured `File` → `Exit` path and visible modal chain, including the VFS
`Unlock` prompt. `stop` first closes
the game and then uses the same MO2 resolver. `release` removes only an
exactly owned lock after proving MO2 and the game are closed, while retaining
the evidence directory. All mutation commands have `-WhatIf`. Evidence
collection, archive verification, profile mutation, cache management, and
recovery remain deferred until separately bounded.

Use `-NoExit` when embedding the entry script in a larger PowerShell host; a
failed command then returns structured JSON without terminating that host.

The retained cycle is:

```powershell
.\Invoke-MO2Control.ps1 stop-game -SessionId $sessionId
.\Invoke-MO2Control.ps1 launch -SessionId $sessionId
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
