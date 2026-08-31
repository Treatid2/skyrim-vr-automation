# Automation repository rules

- Treat every game, MO2, SteamVR, profile, and cache mutation as an attributable
  transaction. Inspect first and preserve its result with the test record.
- Never silently fall back to a different MO2 profile, executable, runtime,
  configuration file, or null-HMD profile.
- Give every independent test task a unique profile cloned from the configured
  stable source. Never share a mutable task profile or infer an experimental
  alternate profile as a safe template.
- A task may delete or replace only uniquely named mods that its workspace
  proves did not predate the task and explicitly records as task-owned.
- Do not inherit unknown-provenance saves, and do not treat COC as New Game.
- Require MO2 and Skyrim to be closed before profile or package mutation.
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
  is active in any chat. Build and commit the marketplace package, then defer
  installation until every run is terminal. Use the guarded repository
  installer instead of direct `codex plugin add`, and fully reload the Codex
  host after installation; a new chat alone is not a safe pickup boundary.
- When an automation command behaves unexpectedly, its contract is ambiguous,
  or a concrete safety issue or enhancement is discovered, submit it through
  `tools/feedback-control/Invoke-AutomationFeedback.ps1`. Claim that feedback
  was recorded only when the controller returns a durable `AUTO-...` receipt.
  Tasks report desires; they do not publish issues or edit automation source
  unless that work is explicitly in scope.
