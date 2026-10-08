# Automation repository rules

- Treat `main` as the sole integration line and keep local `main` aligned with
  the latest merged `origin/main`. Develop in scoped feature branches; a
  temporary worktree is not complete until its commits are pushed to its named
  branch and represented by a pull request targeting `main`. Never push
  directly to `main`. Open or merge that pull request only when the user
  explicitly instructs it.
- Treat every game, MO2, SteamVR, profile, and cache mutation as an attributable
  transaction. Inspect first and preserve its result with the test record.
- Never silently fall back to a different MO2 profile, executable, runtime,
  configuration file, or null-HMD profile.
- Give every independent test task a unique profile cloned from the configured
  stable source. Never share a mutable task profile or infer an experimental
  alternate profile as a safe template.
- Retain each task-owned workspace and its profile-local changes by default.
  End the live session and release scarce MO2 access, then reacquire access and
  resume that exact workspace later. Run, turn, or task completion does not
  authorize retirement, reset, or deletion. Retire only on explicit direction
  to discard or replace that exact environment, or under a separately stated
  policy that proves it obsolete.
- Keep task-local environment retention separate from restoration of shared or
  global transient state. Restoring SteamVR or another shared runtime must not
  rewrite, revert, or retire the task-owned MO2 profile.
- Auto-Tools owns shared-state cleanup, recovery, and verified environment
  handoff; calling tasks own their experiment setup and calibration, not a
  bespoke reset procedure. Preserve their configured workspaces on yield and
  resume the exact requested environment later. A request for a clean
  environment selects an explicit known-good baseline without resetting or
  retiring another retained setup. Require observed postconditions before
  handing off access; unresolved cleanup is not a clean-state claim. Use the
  existing ownership-guarded controls, not duplicate wrappers or speculative
  process kills. This responsibility does not expand mutation authority or
  change the coordination-only meaning of human `Release`.
- A task may delete or replace only uniquely named mods that its workspace
  proves did not predate the task and explicitly records as task-owned.
- Do not inherit unknown-provenance saves, and do not treat COC as New Game.
- Require Skyrim and its loader to be closed before profile or package
  mutation. The normal autonomous task flow also closes MO2 to establish a
  known ground state. While the human holds an exact-profile human lease, a
  task may instead validate the private human mutation capability, mutate only the selected leased
  profile or explicitly authorized mod content with MO2 open, and invoke the
  supported exact-instance `refresh` after mod-directory or `modlist.txt`
  changes. Any profile drift, active RootBuilder deployment, extra MO2 process,
  modal/Unlock state, or other ambiguity returns to close/recover-close.
- The human code word `Lease` means acquire human access bound to MO2's exact
  selected profile and restore the receipt-bound normal physical-headset route
  before reporting the environment ready for human use. Null-HMD is shared
  SteamVR state, not a profile mod to disable. Use existing bounded stop/restore
  controls; require game/loader and SteamVR closed for the transition, preserve
  the profile/workspaces and matching human lease, and refuse unknown baseline,
  drift or foreign ownership. Do not force-close the game, stop Virtual Desktop,
  hand-edit settings or infer headset readiness from lease acquisition alone.
  Follow the human headset handoff section in `tools/mo2-control/MO2-RUNBOOK.md`.
  Return the public lease identity. `Release` means remove
  only that human coordination lease; do not close MO2, Skyrim, or another
  application as part of Release.
- Dump Management has standing content authority to install, update, configure,
  and enable the Tullius dump-management mod. That authority does not waive the
  closed-Skyrim rule or lease/known-state checks. Under a human lease it uses
  the leased selected profile; otherwise it follows the normal automation
  access flow.
- Do not treat Virtual Desktop or `VirtualDesktop.Streamer` as a blocker for
  profile mutation or SteamVR null-HMD. For the null-HMD route, an enabled
  profile-local OCU/OpenComposite provider is the conflicting route.
- Require SteamVR to be closed before applying or restoring null-HMD settings.
- Retain exact backups and receipts until the associated test evidence has been
  classified. Never delete unclassified MO2 overwrite or shader-cache content.
- Keep automated waits bounded and report the observed postcondition. A CTD is
  useful evidence, not permission for unbounded retries.
- Tests must use temporary fixtures by default. Live checks must be explicitly
  selected and read-only unless the user has placed a state change in scope.
- Machine-specific paths belong only in ignored `machine.local.json` files,
  explicit parameters, or documented environment variables.
- Never rotate an installed Codex plugin cache while any automation protocol
  is active in any chat. Feature branches validate source/package parity but do
  not rotate the installed cache. After an authorized merge to `main` that
  affects installed plugin behavior, skills, tools, MCP configuration,
  manifests, or packaged AI guidance, rotate both plugin manifest cache
  identities once from the final integrated tree, rebuild the managed
  marketplace package, and reinstall it with the guarded repository installer
  instead of direct `codex plugin add`. Verify the registered version plus
  source, marketplace, and installed-cache hashes, then fully reload the Codex
  host; a new chat alone is not a safe pickup boundary. If a protocol is
  active, defer installation until every run is terminal.
- When an automation command behaves unexpectedly, its contract is ambiguous,
  or a concrete safety issue or enhancement is discovered, submit it through
  `tools/feedback-control/Invoke-AutomationFeedback.ps1`. Claim that feedback
  was recorded only when the controller returns a durable `AUTO-...` receipt.
  Tasks report desires; they do not publish issues or edit automation source
  unless that work is explicitly in scope.
