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

- On the task's first MO2 request, acquire MO2 access, run `prepare-source`, and
  run `fixture-status`. Proceed to `create -TaskId` only from
  `fixture-valid`. Creation otherwise fails closed. It clones the configured
  primary profile, including its complete saves tree and mandatory default
  world-entry save, verifies the copy, and selects the new profile in MO2.
- On a later request, the task must explicitly choose either `resume -TaskId
  -WorkspaceId` or a fresh `create -TaskId`. The tool never silently replaces a
  retained profile or guesses among multiple workspaces.
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

After ending the live evidence session, call MO2 `release-access` as soon as the
task can compile, edit, or analyse offline. This yields MO2 but preserves the
task profile, its saves, its option state, and its task-owned mods. A later
lease can resume it directly.

Use workspace `retire` only when the task has finished with that profile.
Retirement selects the maintained primary profile and recursively removes only
the exact task-owned profile. `-CleanupOwnedMods` additionally removes only
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

Some applications write runtime data into an existing mod, notably CSX writing
compiled shaders into the managed shader-cache mod. That known exception is
accepted. Automatic cache reset on lease yield is intentionally not part of
this contract; it can be added later as a separately evidenced policy.
