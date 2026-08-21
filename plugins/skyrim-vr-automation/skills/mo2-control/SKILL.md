---
name: mo2-control
description: "Inspect and operate Mod Organizer 2 through the bundled exact-profile, single-owner controls. Use for MO2 or Mod Organizer inspection, validation, launch, game cycling, shutdown, session recovery, exact mod enable/disable transactions, package deployment planning, or Skyrim VR test-session orchestration. Also use when a user asks whether MO2 or Skyrim is closed, which profile or executable is configured, or how to preserve evidence from an MO2 run."
---

# MO2 Control

Use the plugin's PowerShell controls; do not reconstruct MO2 command lines or
edit `modlist.txt` ad hoc.

## Load the applicable contract

- For inspection, validation, prepare, open, launch, status, stop-game, close,
  recover-close, stop, terminate, release, or recovery, read
  `../../tools/mo2-control/MO2-RUNBOOK.md` completely before acting. Read
  `../../tools/mo2-control/README.md` when command or schema details matter.
- For enabling, disabling, or restoring one exact mod marker, read
  `../../tools/mo2-profile-control/README.md` and inspect the entry point's
  parameter block before acting.
- Treat the repository-root `AGENTS.md` as binding operational policy.

Resolve all paths from this skill's installed location. The main entry points
are:

```text
../../tools/mo2-control/Invoke-MO2Control.ps1
../../tools/mo2-profile-control/Invoke-MO2ProfileControl.ps1
```

## Operating sequence

1. State in commentary that this skill is governing the MO2 operation.
2. Start with `inspect`. Before any closed-state mutation, run `validate
   -RequireClosed` and account for every warning or block.
3. Use `-WhatIf` when the command supports it and the requested change has not
   already been proven in an isolated fixture.
4. For a live run, call `prepare`, retain its `sessionId`, and pass that exact
   identity to every lifecycle command. Parse the JSON result; do not infer
   success from process appearance alone.
5. For repeated measurements, retain the owning MO2 process and cycle Skyrim
   with `stop-game` followed by `launch`.
6. Use `-StartOnly` when the outer host cannot safely wait for UI/game
   readiness; retain the immediate receipt and poll the exact session with
   `status`.
7. If `status` reports `rootbuilder-recovery-required`, preview and use
   `recover-rootbuilder` with the same exact session, then finish through normal
   `stop`/Unlock. Never delete `BuildData.json` directly.
8. End with the bounded graceful path. Use `terminate` and `release` only under
   the runbook's ownership and closed-game proofs.
9. Preserve session identifiers, receipts, hashes, logs, screenshots, dumps,
   and the pre/post inspection results with the test record.

## Safety and authority

- Inspection is read-only. A user's request to diagnose or report does not
  authorize profile, package, process, or filesystem mutation.
- Never accept a fallback profile or executable. Use the exact configured
  names and report a mismatch as a failed precondition.
- Require MO2 and Skyrim closed before changing a profile, mod package, or
  other MO2-owned state.
- Do not launch a second owner while the first session is unresolved. Do not
  retry a crash or failed launch before classifying the evidence.
- Never delete, bulk-move, or silently clean MO2 overwrite, RootBuilder data,
  shader caches, captures, or session evidence.
- Do not kill processes by name. Use the bounded controller commands, which
  prove ownership and game/loader absence.
- Run visible MO2/game window operations through the approved elevated route so
  they execute as the logged-on interactive user. A sandbox
  `interactive-desktop-required` result is a precondition failure, not
  permission to fall back to SendKeys or a process kill.
- `recover-close` is the only route for adopting one stranded, exact-path MO2
  without a prior session. It may invoke only exact `Unlock`; Notepad++,
  Tullius, and other editors remain outside the process target set.
- Keep machine paths only in the stable per-user or ignored legacy
  `machine.local.json`, explicit parameters, or documented environment
  variables. If configuration is absent, use the bundled doctor to initialize
  the stable path and ask only for values that cannot be discovered read-only.

When SteamVR null-HMD state is also involved, apply the
`$steamvr-null-hmd` skill before launching MO2. Restore the prior runtime state
only when the user's requested workflow includes restoration.
