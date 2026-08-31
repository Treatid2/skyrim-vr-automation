---
name: mo2-control
description: "Inspect and operate Mod Organizer 2 through the bundled exact-profile, single-owner controls. Use for MO2 or Mod Organizer inspection, validation, launch, game cycling, shutdown, session recovery, exact mod enable/disable transactions, package deployment planning, or Skyrim VR test-session orchestration. Also use when a user asks whether MO2 or Skyrim is closed, which profile or executable is configured, or how to preserve evidence from an MO2 run."
---

# MO2 Control

Use the plugin's PowerShell controls; do not reconstruct MO2 command lines or
edit `modlist.txt` ad hoc.

## Load the applicable contract

- For access requests, inspection, validation, prepare, open, launch, status,
  stop-game, close, recover-close, stop, terminate, release, or recovery, read
  `../../tools/mo2-control/MO2-RUNBOOK.md` completely before acting. Read
  `../../tools/mo2-control/README.md` when command or schema details matter.
- Before constructing any elevated MO2, workspace, or profile command, read
  `../../tools/mo2-control/APPROVALS.md` completely and use the command's
  returned `approval.reusablePrefix` when it is eligible. Never hide the
  executable, entry point, or subcommand behind a variable or `-Command`.
- For enabling, disabling, or restoring one exact mod marker, read
  `../../tools/mo2-profile-control/README.md` and inspect the entry point's
  parameter block before acting. For a DLL deployment, prefer the workspace
  controller's `-WinningPaths` transaction; do not guess MO2 priority order.
- For every independent test task, read
  `../../tools/mo2-workspace-control/README.md` and use the stable task ID to
  discover, resume, or create its task profile before preparing a session.
  Creation binds snapshotted `ShaderCache` and `backup` output to MO2 Overwrite,
  removes both game and `Synthesis` custom-overwrite mappings from the clone,
  and physically shadows every enabled provider path. Never use an
  experimental alternate profile as an implicit template.
- Treat the repository-root `AGENTS.md` as binding operational policy.

Resolve all paths from this skill's installed location. The main entry points
are:

```text
../../tools/mo2-control/Invoke-MO2Control.ps1
../../tools/mo2-profile-control/Invoke-MO2ProfileControl.ps1
```

## Operating sequence

1. State in commentary that this skill is governing the MO2 operation.
2. Start with `inspect`. Before any planned MO2 operation, call
   `request-access`, retain its exact `accessId`, and respect `access-busy`.
   An estimated duration is advisory only and never permits lease stealing.
   Use workspace `list-task -TaskId` to discover retained state. On the first
   request, require `fixture-status` to report
   `fixture-valid`, and then run `create -TaskId`; the primary profile, its
   complete save tree, and the mandatory default world-entry save are cloned,
   verified, and selected. On later requests, require an explicit
   `resume -TaskId -WorkspaceId` or fresh `create -TaskId`. Never silently
   replace, refresh, or requalify a retained profile after task-local edits.
   Before any closed-state mutation, run `validate -AccessId <literal-access-id>
   -RequireClosed` and account for every warning or block.
3. Use `-WhatIf` when the command supports it and the requested change has not
   already been proven in an isolated fixture.
4. For a live run, call `prepare -AccessId` with the owned lease, retain its
   `sessionId` and returned `controllerPath`, then invoke every lifecycle
   command through that literal session-scoped controller path with the exact session
   identity. The copied controller survives plugin cache replacement; do not
   keep using the versioned plugin-cache entry point after prepare. A shell
   variable may retain data for local reasoning, but an approval request must
   contain the literal path and subcommand reported by the tool. Parse the JSON result; do not infer
   success from process appearance alone.
   For DevBench, SKSE plugins, or any extension-dependent test, pass
   `-RequireSKSE` to both validation and preparation. Do not accept direct
   `SkyrimVR.exe` launch as equivalent; the requirement is retained and
   revalidated for subsequent launches in the same session.
   Pass the exact profile returned by the task workspace rather than accepting
   the ordinary configured session default.
   Every fresh task profile receives a verified copy of the stable source
   profile's complete saves tree and mandatory default world-entry fixture.
   This makes saves available but does not authorize their use: respect
   `SavePolicy`, and use only a declared `VerifiedFixture` as a deterministic
   automation baseline. A resumed task profile is preserved as-is; never claim
   its save remains working after the task has changed its profile.
   When the test requires a deterministic new-game baseline, create the
   workspace with `-SavePolicy VerifiedFixture`. Use the returned fixture ID
   and `loadName`; do not copy saves manually or substitute `coc`.
   If fixture discovery reports `fixture-not-configured` or
   `fixture-manifest-missing`, follow its returned example path and guidance;
   do not guess a save or manifest path.
   If the task may compile CSX shaders, apply `$shader-cache-control` while MO2
   and Skyrim are still closed: catalog `prepare` the exact task cache before
   launch with the exact task profile, mods root, Overwrite cache path,
   `-BindToOverwrite`, and `-RequireMaterializedOutput`. Require its provider
   shadow receipt and prepared tree hash; an empty directory cannot prevent
   later-area shader paths from resolving back into a lower mod. MO2
   preparation and the first launch recompute the exact tree and current provider
   coverage. They also verify the complete generated `backup` tree against its
   creation receipt. Retained game cycles may grow the bound Overwrite cache
   and backup trees, but every relaunch still requires complete provider path
   coverage. Then catalog `complete` and workspace `complete-output` after
   shutdown and before yielding access or retiring the workspace.
5. For repeated measurements, retain the owning MO2 process and cycle Skyrim
   with `stop-game` followed by `launch`.
   If `stop-game` returns `mo2-exited-after-game-stop` or `releaseRequired`, do
   not relaunch from that session; release it and request access normally.
6. Use `-StartOnly` when the outer host cannot safely wait for UI/game
   readiness; retain the immediate receipt and poll the exact session with
   `status`.
7. If `status` reports `rootbuilder-recovery-required`, preview and use
   `recover-rootbuilder` with the same exact session, then finish through normal
   `stop`/Unlock. Never delete `BuildData.json` directly.
8. End with the bounded graceful path. Use `terminate` and `release` only under
   the runbook's ownership and closed-game proofs. After releasing the session,
   call `release-access` as soon as MO2 is no longer needed.
   If the game main thread is deadlocked, `terminate-game` is the only forced
   game recovery: it targets launch-recorded identities, retains MO2, invokes
   exact Unlock, and requires RootBuilder cleanup. `release-access` is the
   normal yield path and preserves the task workspace. Use workspace `retire`
   only when that exact profile is no longer wanted. Retirement requires the
   exact cache and backup completion receipts and never deletes MO2 Overwrite;
   workspace `release` is a deprecated destructive alias.
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
- Do not retain an access lease during compilation, source editing, offline
  analysis, or reporting. Each task explicitly releases MO2 whenever it can
  make progress without it, even if the overall task is unfinished.
- Never treat an overdue estimated release time as expiry. `recover-access`
  requires positive abandonment classification, exact ownership identity, and
  closed-state proof.
- Never delete, bulk-move, or silently clean MO2 overwrite, RootBuilder data,
  shader caches, captures, or session evidence.
- Do not kill processes by name. Use the bounded controller commands, which
  prove ownership and game/loader absence.
- Never delete or replace a mod that existed when a test workspace was created.
  A task may clean only uniquely named mods explicitly registered as its own.
- A task may enable or disable existing mods only in its own cloned profile.
  It must not edit an existing shared mod directory. Update the maintained
  primary list additively: install a new version under a new mod name, disable
  the old marker, and enable the new marker. Retained task profiles remain
  unchanged until their owner explicitly requests a fresh clone.
- Register a task DLL with its exact relative path in `-WinningPaths`. Treat
  the returned loose-file provider proof as scoped: overwrite, unmanaged game
  files, and archives still require separate VFS evidence.
- Never treat `coc APStartCell` as a genuine New Game. Copied ordinary saves
  are conveniences, not deterministic baselines; use only an exact
  hash-verified fixture when baseline provenance matters.
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
