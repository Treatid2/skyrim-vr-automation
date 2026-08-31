# Changelog

All notable changes are documented here. Versions follow Semantic Versioning.

## Unreleased

- Materialize and hash-verify every lower-provider `ShaderCache` and generated
  `backup` path into each task-owned MO2 runtime output, reject stale or missing
  shadows before launch, permit only isolated task-output growth on retained
  game cycles, and preserve the complete trees when the workspace retires.
- Add a correlated capture/interaction framework with latest committed frame
  selection, continuous or on-demand stereo capture, full-state recording,
  pose-preserving named actions, direct DevBench passthrough, orderly
  finalization, and UTC-safe stable-save waits.
- Add read-only physical HMD/controller observation and correlation IDs to the
  DevBench input/recording contracts used by the framework.
- Add `mainMenuReady`, a real `validate-closed` alias, approval-compatible
  multi-path files, exact configuration-resolution provenance, and guarded
  workspace reuse through the current task-resume contract.
- Treat SteamVR physical, SteamVR null-HMD, and OpenComposite execution routes
  as provenance within one explicit Skyrim VR D3D11 bytecode compatibility
  class while retaining the exact feature-set compatibility gate.
- Add bounded whole-runtime Skyrim quiet-window capture and informational
  comparison reports alongside the existing CSX timer profiler.
- Let MO2 access requests retain an explicit stable task identity, complete
  asynchronous `-StartOnly` opens from proven main-window state, retry transient
  UI Automation enumeration once, and clean late failure dialogs after the
  retained-process stability window.
- Preserve the invoking command context through shader-cache completion so
  promoted working caches retain functional `ShouldProcess` authorization.
- Serialize every SteamVR/OpenVR command with a bounded lock derived from the
  canonical live targets, move recovery authority to a deterministic per-user
  journal independent of caller evidence directories, and replace repeated
  whole-log reads with deadline-charged incremental bounded-byte tails.
- Serialize head-pose driver installs/upgrades by canonical install and OpenVR
  targets, persist authoritative registration preimages, and recover interrupted
  replacement/registration phases before admitting another installer.
- Serialize shader-cache swaps by canonical live target, recover interrupted
  operations from a target-owned journal, and use one deadline-, depth-, byte-,
  file-, and reparse-bounded inventory primitive across transactions and catalogs.
- Give MO2 profile mutations a deterministic target-owned lock and recovery
  journal, and recover interrupted workspace create, resume, and retire
  transactions from durable manifest and selected-profile preimages before any
  later command reads or changes workspace state.
- Serialize profiler captures per runtime, enforce one total deadline with a
  reserved restoration budget, and bind every accepted DevBench response and
  sample to the same complete, verified process/build/artifact identity. Recover
  nonterminal captures from a deterministic runtime-owned journal without ever
  mutating a replacement process.

- Require every fresh MO2 task clone to inherit a hash- and
  profile-fingerprint-verified default world-entry save, make the doctor fail
  invalid setup, keep static integrity distinct from runtime qualification, and
  preserve resumed task profiles without making a post-edit save warranty.
  Bound all related traversal, hashing, copy, and verification work with one
  total deadline plus file, byte, depth, directory, and reparse-point limits.
- Make deprecated workspace `release` fail closed, add collision-resistant
  registration evidence names, let blocking DevBench calls consume their
  declared bounded timeout, and require recognized positive contract evidence
  for `serviceReady`.
- Separate MO2's public lease identity from its bearer credential in status
  results, bind live session ownership to PID plus process start time, and make
  feedback amendments and maintainer transitions carry explicit actor roles.
- Redact local paths recursively from feedback operation, resolution, and
  resolution-link fields in default exports.
- Add a native, fixed-standing SteamVR head-pose provider for Valve null-HMD,
  a versioned shared-memory control/acknowledgement contract, independent
  application-facing OpenVR qualification, transactional installation, and
  null-runtime readiness enforcement. Controllers remain unavailable.
- Synthesize schema-valid, non-mutating registry envelopes for versioned
  DevBench `serviceReady` waits, reject arbitrary explicit probe arguments, and
  keep unknown non-empty responses unready.
- Disable SteamVR dashboard input in the null-HMD transaction, report the
  deliberately unavailable controller/controlled-pose contract, retain a
  surviving dashboard process as telemetry, and reject Windows PowerShell with
  an explicit PowerShell 7 migration result.
- Persist DevBench invocation journals before dispatch, preserve failed-call
  evidence across target exit, guard the known-crashing Skyrim VR `tfc 1`
  command, and enforce workspace save policy for direct and scenario game
  mutations.
- Inventory external OpenVR driver manifests before null-HMD startup and refuse
  display redirectors such as Virtual Desktop with exact path and hash evidence.
- Add opt-in, receipt-bound isolation of exact OpenVR display redirectors;
  refuse registration or manifest drift and restore the byte-identical
  pre-test registration file before returning to normal VR operation.
- Accept formatting-only OpenVR registration drift through ordinal canonical
  JSON comparison while deriving the isolated expectation from the exact
  backup; reject duplicate targets and receipt/backup disagreement.
- Restore SteamVR settings safely after runtime serialization by rebuilding the
  receipt-bound null contract, accepting only formatting plus allowlisted
  `GpuSpeed`/`LastKnown` runtime fields, and retaining exact live bytes for
  rollback while rejecting controlled or unclassified drift.
- Revalidate the exact MO2 owner through a bounded post-game stability window,
  returning an explicit release-required state if MO2 exits, and add compact
  JSON output to profile control.
- Decouple scarce MO2 access leases from durable task workspaces: tasks can
  list and resume an exact retained profile under a new lease, while explicit
  destructive `retire` replaces the ambiguous workspace-release lifecycle.
- Select fresh and resumed task profiles transactionally, bind them to a stable
  task identity, preserve saves and profile-local state across lease yields,
  and enforce additive shared-mod update guidance.
- Copy and hash-verify the maintained source profile's complete save tree into
  every task profile while retaining `SavePolicy` as an authorization marker
  and verified fixtures as the only deterministic baseline contract.
- Exclude local `.fixture-refresh-*` evidence from generated marketplace
  packages.
- Treat physical-headset and Valve null-HMD SteamVR shader caches as one
  render-compatible family while optionally hard-gating reuse on an exact
  effective feature-set fingerprint.
- Add a durable `-RequireSKSE` MO2 session precondition so DevBench workflows
  reject direct `SkyrimVR.exe` entries and revalidate the loader before every
  launch.
- Classify replay scheduler receipts without postconditions as unverified, and
  make `-RequireSuccess` reject them instead of reporting interaction success.
- Make verified-fixture discovery non-throwing when its manifest is absent,
  return exact configuration/example guidance, and expose the same state in the
  automation doctor.
- Require task profiles to clone the configured primary/stable profile only
  after recursively evacuating every legacy `ShaderCache*` directory from MO2
  overwrite into a newly enabled, receipt-backed VFS mod.
- Classify active, rollback, swap, and other legacy ShaderCache trees during
  MO2 inspection, flag persistent swap state, and block launch until overwrite
  is cache-free.
- Register DevBench directly from the Codex plugin and make NVIDIA and AMD
  render-scale tuning fail closed when that plugin lane is unavailable. The
  protocols now search deferred tools before declaring the direct lane absent
  and never fall back to the bundled controller.
- Split render-scale tuning into explicit NVIDIA and AMD protocols. The
  NVIDIA lane runs the exact 33-transition None/TAA/DLAA/DLSS/FSR3 matrix;
  the AMD lane runs separate 31-transition explicit-FSR4, explicit-FSR3, and
  documented-fallback matrices. Both use only the public upscaling API,
  preserve dormant profile fields, bind each apply to the immediately prior
  state revision, and retain the full Simple CSM telemetry contract.
- Keep configured FSR4 preference separate from physical backend identity in
  Simple CSM and render-scale tuning: omit the runtime preference from strict
  FSR waiter targets and require coherent desired, authoritative, resource,
  lifecycle, and both-eye dispatch backends so NVIDIA and unsupported AMD
  capability fallback to FSR3/host is not misclassified as a latch failure.
- Add the original render-scale tuning correctness protocol and its complete
  admission, ownership, publication, preparation, and per-eye evidence set.
- Add the `$simple-csm` protocol: reuse Simple COC 5 binding, runtime fixture,
  telemetry, failure handling, and evidence extraction; position once at
  Dragonsreach; then measure the canonical hardware-specific 25-step CS menu
  matrix without issuing measured COCs.
- Detect persisted pre-isolation task profiles during MO2 inspection and add a
  closed-state recovery that selects the stable profile while preserving the
  legacy workspace, cache, manifest, and exact INI evidence.
- Keep VR FPS Stabilizer as the sole profile owner by omitting static profile
  targets from every measured COC waiter and recording the coherent
  post-dispatch profile selected externally.
- Treat Stabilizer ownership as a discovery boundary: never select profiles
  from GPU inventory, INI precedence, or MO2 winning-file resolution.
- Require COC readiness to prove PyGhidra execution and the exact active
  artifact path/hash, so an MCP listener attached to an older RC program cannot
  be accepted for another build.
- Keep COC evidence coverage through normal long loads by using automatic
  unhandled-exception dumps plus an explicit classified hang capture, and add a
  post-Windhelm controller whose independent monotonic watchdog submits the
  measured 20-transition scenario exactly once even when baseline calls stall.
- Make COC readiness use durable project-scoped DevBench/Ghidra registrations
  and a saved Ghidra listener PID/start binding that sandboxed status checks can
  verify without privileged process ancestry.
- Add a bounded Codex marketplace installer that detects a stale structured
  plugin registration, performs one scoped marketplace refresh, and verifies
  the final version and every installed file hash.
- Publish the `coc-stability` skill for deadline-driven, exact-destination
  COC transition testing. It queues the 10-second Windhelm start before
  concurrent identity reads, applies the startup-active Stabilizer and
  debug/FOV/TAA fixture once after Windhelm loads, collects baseline evidence
  in parallel, and runs all 20 command-timed transitions in one
  anomaly-accumulating server batch while preserving the full stereo-fidelity
  predicate.
- Add the bounded `csx-render-scale-pr-v1` qualification package and
  `$render-scale-qualification` skill for one-command attachment to the DLL
  that is already running in game. Protocol revision 4 discovers the exact
  Build ID and verifies the live D3D adapter, runs the 20-COC and 25-menu
  assays with two 30-second recoveries, captures all three one-minute stereo
  sequences, and returns a final verdict within a hard ten-minute limit. It
  evaluates quality through six `gpt-5.6-sol` Codex CLI batches using two
  blinded, swapped presentation passes, while render-scale latch remains an
  owner-bound telemetry decision. The closed evidence inventory includes all
  144 PNGs, diagnostic records, model request/response receipts, and bounded
  baseline provenance. The complete `dlss_trace_status`,
  `dlss_trace_reset`, `dlss_trace_start`, `dlss_trace_stop`, and
  `dlss_trace_read` lifecycle introduced by
  `b46edeaed14c41ad41225641c3a4943f1db25db6` remains mandatory.
- Add exact-identity AMD64 live-thread context capture with bit-preserving
  pointer/register conversions validated under Windows PowerShell and
  PowerShell 7.
- Give every task profile a unique executable-bound runtime-output mod, require
  its current winning loose cache provider and materialization plan at MO2
  prepare/launch, independently recheck the prepared tree and lower-provider
  path coverage, and preserve its complete output on release. Retained cycles
  may grow only the winning task output. Cache completion and workspace cleanup
  now fail closed when output is missing, unclassified, stale, or still
  transactionally open.
- Add the repository-local Git launcher required by agent policy, with
  command-scoped `safe.directory` handling and exact exit-code propagation.
- Prefer direct plugin MCP tools for live DevBench work, retaining the bundled
  client for offline validation and controller-only receipt behavior.
- Add exact named MO2 config registration, listing, resolution, and persistent
  selection for machines that switch between multiple portable modlists.
- Resolve explicit config paths and environment overrides before a named
  selection, and fail closed when named configs exist without one exact valid
  choice.
- Route the MO2 skill and doctor through the shared multi-modlist contract.
- Expand environment variables in verified-save fixture manifest paths before
  normalization so `%LOCALAPPDATA%` configuration remains portable.
- Allow feedback identity collection to run from hydrated plugin caches whose
  generated metadata omits the optional source plugin version.
- Publish exact direct-invocation approval metadata from the MO2 lifecycle,
  workspace, and profile controllers, document stable conversation-scoped
  prefix rules, and keep forced termination and overwrite/removal operations
  explicitly one-shot.
- Preserve approval and configuration metadata in dictionary-backed lifecycle
  results such as access acquisition and renewal.
- Snapshot a self-contained lifecycle controller into every MO2 session so an
  installed plugin cache replacement cannot invalidate an active run.
- Normalize MO2 profile directory/modlist identity, add compact workspace
  output, fixture drift inspection and guarded refresh, and select the stable
  profile transactionally before deleting a task profile.
- Classify and acknowledge only retained failed-to-run MO2 dialogs after a
  game stop, returning needs-attention for unknown windows.
- Keep MCP initialization within the full DevBench wait deadline and require a
  fresh unloaded-to-loaded transition for `playerLoaded` by default.

## 0.8.0 - 2026-08-24

- Add immutable content-addressed compiled shader-cache catalogs with
  receipt-proven provenance and explicit ABI, runtime, render-path, shader
  source, build, preset, status, and tag metadata.
- Add explainable compatibility selection plus transactional task preparation,
  exact prior-cache restoration, displaced-result preservation, and opt-in
  known-working promotion.
- Route CSX test tasks through cache preparation before launch and completion
  before MO2 workspace release to reduce avoidable recompilation without
  weakening closed-state or ownership guarantees.

## 0.7.0 - 2026-08-23

- Add a durable local automation-feedback mailbox with atomic receipts,
  immutable lifecycle events, duplicate hints, evidence hashes, bounded
  concurrent writers, maintainer triage, and explicit sanitized export.
- Add a feedback skill that prevents tasks from claiming a report was recorded
  without a durable receipt and keeps public issue creation under explicit
  maintainer control.

## 0.6.0 - 2026-08-23

- Copy only hash-verified, explicitly selected save/co-save fixtures into task
  profiles and return their deterministic load identity.
- Add guarded registration and reordering that proves a task-owned DLL mod wins
  every requested path among enabled loose-file providers.
- Allow cooperative stranded-MO2 recovery to bind an already-owned access
  lease without weakening exact-process or closed-game checks.
- Add isolated per-task profiles cloned from an explicit stable source without
  inherited saves, plus guarded task-owned mod registration and cleanup.
- Add launch-pending grace, detached MO2 runtime-owner adoption, structural
  Unlock classification, and exact-session game deadlock recovery.
- Require RootBuilder restoration after deadlock recovery and reject COC as a
  substitute for a genuine New Game baseline.

## 0.5.0 - 2026-08-22

- Add atomic cross-task MO2 access requests with exact lease identities,
  bounded contention waits, ownership status, and explicit release.
- Allow an access lease to span multiple attributable MO2 evidence sessions
  while preserving the legacy implicit `prepare`/`release` lifecycle.
- Record optional release-time estimates as advisory coordination metadata;
  leases never expire or transfer automatically.
- Add closed-state-gated recovery for positively confirmed abandoned leases and
  document the requirement to release MO2 during compilation and offline work.

## 0.4.0 - 2026-08-21

- Add contract-aware DevBench service/tool waits with exponential backoff,
  transient 429/502/503/504 retries, recursive service-state inspection, and
  expected guard-error classification.
- Generalize runtime identity binding across CSX service registries and report
  process, build, artifact, completeness, and missing identity fields.
- Add compile-gate observations that distinguish an absent service from a
  responsive process still doing initialization work, with optional bounded
  log-tail evidence.
- Add structured MO2 session preconditions, exact settings-write-dialog
  classification, immediate `open`/`launch` receipts with `-StartOnly`, and an
  attributable `recover-rootbuilder` route.
- Add a bounded CSX branch-test runner that directly executes branch-local test
  binaries when CTest reports zero registered tests.

## 0.3.0 - 2026-08-21

- Add exact shader-cache provider inventory and transactional physical-tree
  snapshot, verification, and recoverable restore.
- Bind DevBench calls to listener PID, runtime identity, CSX build ID, and an
  optional deployed artifact hash; normalize semantic success independently
  from MCP transport success.
- Add bounded client-side `noBlockingMenu`/`playerLoaded` waits and compact tool
  discovery filters.
- Persist MO2 open-start evidence before UI readiness, support detached exact
  owner adoption, and harden cooperative close against startup/modal windows.
- Add exact profile enable/disable/restore transactions and nonterminating
  orchestration switches.
- Add bounded process execution that retries only classified transient MSVC
  dependency-file permission failures.

## 0.2.0 - 2026-08-20

- Add stable MO2 configuration discovery and a read-only/config-initialization
  doctor.
- Add Codex skills for DevBench, profiler capture/comparison, and preserved
  shader-cache comparison.
- Add a repository marketplace and reproducible public plugin package.
- Add clean-distribution, policy, upgrade, and release documentation.

## 0.1.0 - 2026-08-20

- Initial public preservation of MO2, SteamVR null-HMD, DevBench, profiler, and
  shader-cache automation controls.
