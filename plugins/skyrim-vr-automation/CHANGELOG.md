# Changelog

All notable changes are documented here. Versions follow Semantic Versioning.

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
