# Durable MO2 task workspaces

MO2 access and an MO2 task workspace have deliberately different lifetimes.
The access lease is scarce and short-lived. The task workspace is a retained
copy of the maintained primary profile and survives any number of lease yields.

## Acquisition

Identify the task with the stable Codex task/thread ID. `list-task -TaskId`
reports every retained workspace owned by that task.

The access request must also declare exactly one runtime route: `OCU`, physical
`SteamVR`, or `SteamVRNull`. OCU cannot coexist with either SteamVR route, and
the null-HMD route is a SteamVR mode rather than an OCU mode. The selected route
belongs to the short-lived access lease and prepared session, not to the
retained profile; switching routes therefore requires ending the session and
requesting a new lease, but does not require rebuilding the task workspace.
Virtual Desktop and `VirtualDesktop.Streamer` are unrelated to this admission
decision and never block profile mutation or null-HMD. An enabled profile-local
OCU/OpenComposite provider is the blocker for the `SteamVRNull` route.

- On the task's first MO2 request, acquire MO2 access, run `prepare-source`, and
  run `fixture-status`. Proceed to `create -TaskId` only from
  `fixture-valid`. Creation otherwise fails closed. It clones the configured
  primary profile, including its complete saves tree and mandatory default
  world-entry save, verifies the copy, and selects the new profile in MO2.
- On a later request, the task must explicitly choose either `resume -TaskId
  -WorkspaceId` or a fresh `create -TaskId`. The tool never silently replaces a
  retained profile or guesses among multiple workspaces.
- For `SteamVRNull`, select the task workspace and run closed-state validation
  with the owned access lease before applying or starting null-HMD. The
  `runtime-route-provider` check must prove that the exact selected profile has
  no enabled OCU or other root OpenVR replacement. Only then transition the
  runtime and continue with MO2 prepare and launch. This ordering prevents a
  null-HMD run from inheriting an OCU-enabled profile.
- A fresh `SteamVR` or `SteamVRNull` clone route-shapes only the new task
  profile: every inherited root OpenVR provider is disabled, the result is
  validated, and the maintained source profile remains byte-for-byte
  untouched. `resume` does not rewrite an existing task profile; it fails
  closed when that retained profile no longer satisfies its newly leased
  runtime route.
- Before a fresh clone, run `list-local-work-mods` and make the workspace
  content explicit. `Modlist` selects no optional local builds.
  `ModlistPlusLocalWorkMods` requires one or more exact catalog IDs. The tool
  disables every unselected catalog candidate in the cloned profile and
  rejects mutually exclusive variants, while leaving the maintained source
  profile unchanged. A retained workspace keeps its original choice across
  lease release and resume, and `list-task` reports that choice.
- `resume` verifies stable task ownership, requires the newly owned access
  lease, rebinds the workspace to that lease, and selects the retained profile.
  It does not refresh the profile from the primary profile or requalify a save
  after task-local edits. A task that needs the current known-good baseline must
  explicitly request a fresh clone.

Success results identify the exact workspace, profile directory, selected
profile transaction, save policy, and current lease. Missing profiles, wrong
task identities, and ambiguous requests fail with recovery guidance and, where
applicable, the valid retained workspace IDs.

## Yield versus retirement

After ending the live evidence session and completing the output transactions
below, call MO2 `release-access` as soon as the task can compile, edit, or
analyse offline. This yields MO2 but preserves the task profile, its saves,
its option state, and its task-owned mods. A later lease can resume it directly.

After the game and MO2 close, run shader-cache catalog `complete` and workspace
`complete-output`. These preserve generated `ShaderCache` and `backup` trees,
restore the exact pre-task MO2 Overwrite state, and release the output owner
marker. They preserve the retained task profile and its local changes.

This retained environment is the default end state. Do not restore it to the
source profile, remove its task-local changes, or retire it merely because a
run, turn, or task has completed. Reacquire access and resume the exact
workspace when work continues.

Use workspace `retire` only after explicit direction to discard or replace that
exact environment, or when a separately stated retention policy proves it
obsolete. Retirement requires exact cache and backup completion receipts. It
selects the maintained primary profile and recursively removes only the exact
task-owned profile. `-CleanupOwnedMods` additionally removes only
mods that the workspace created and registered. The old workspace `release`
command now fails closed without mutation. It points callers to MO2
`release-access` for lease yield and to the explicit `retire` command for
destructive cleanup.

## Ownership and shared-state rules

A task may change files only in its cloned profile and in a uniquely named mod
that it created and registered. It may enable or disable existing mods using
profile-local markers in its own profile, but it must not edit, replace, claim,
or delete an existing shared mod directory.

Primary-profile package updates are additive. Install an update under a new mod
name, then disable the old mod and enable the new mod in the maintained primary
profile. Existing task profiles retain their prior mod selections and shared
mod references until the owning task explicitly requests a fresh clone.

CSX runtime output is bound to MO2 Overwrite, not an existing mod. Workspace
creation removes the cloned profile's game and `Synthesis` custom-overwrite
mappings, snapshots `backup`, and materializes its enabled-provider union.
Shader-cache preparation does the same for `ShaderCache`. New paths and updates
therefore resolve to Overwrite; shared mod directories remain immutable.

Restoration of shared or global transient state is a separate lifecycle. For
example, a requested SteamVR settings restoration may run after a test without
changing, reverting, or retiring the task-owned MO2 workspace.
