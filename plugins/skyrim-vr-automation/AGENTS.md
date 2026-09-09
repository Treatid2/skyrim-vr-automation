# Automation repository rules

- Treat `dev` as the sole integration line for ongoing automation work. A
  temporary worktree branch is not complete until its commits are integrated
  into `dev`; update `main` only through a `dev`-to-`main` pull request, and
  keep local `main` aligned with the latest merged `origin/main`. Open or merge
  that pull request only when the user explicitly instructs it. Develop in
  scoped feature branches and never push directly to `main`.
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
- A task may delete or replace only uniquely named mods that its workspace
  proves did not predate the task and explicitly records as task-owned.
- Do not inherit unknown-provenance saves, and do not treat COC as New Game.
- Require MO2 and Skyrim to be closed before profile or package mutation.
- Do not treat Virtual Desktop or `VirtualDesktop.Streamer` as a blocker for
  profile mutation or SteamVR null-HMD. For the null-HMD route, an enabled
  profile-local OCU/OpenComposite provider is the conflicting route.
- Require SteamVR to be closed before applying or restoring null-HMD settings.
- Retain exact backups and receipts until the associated test evidence has been
  classified. Never delete unclassified MO2 overwrite or shader-cache content.
- Render-scale tuning saves each received measurement and later revision to
  an append-only run journal before the next operation. Compare available
  measurements even from partial runs, explicitly labeling missing values and
  incomplete coverage instead of requiring a complete run for ledger entry.
- Keep automated waits bounded and report the observed postcondition. A CTD is
  useful evidence, not permission for unbounded retries.
- Treat the render-scale tuning fixture, immediate positioning, and startup
  admission sequence as frozen. Change that prefix only on explicit user
  instruction or preserved evidence proving the prefix itself is defective;
  post-position runner, telemetry, and reporting fixes must not alter it.
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
  When an in-scope safe fix is available, implement and validate it before
  resolving or amending feedback; record feedback first only when evidence
  would otherwise be lost or the implementation is blocked.
  Tasks report desires; they do not publish issues or edit automation source
  unless that work is explicitly in scope.
