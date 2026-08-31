---
name: coc-stability
description: Run a fast, deadline-driven Skyrim VR COC stability assay that preserves semantic anomalies but stops dispatching after a real control failure.
---

# COC stability

Use this entrypoint for live operation. Read
[references/protocol.md](references/protocol.md) while maintaining or
diagnosing the protocol, never after the user has entered the live start
window.

Use a strict two-command handshake. At Skyrim's main menu/load window the user
says `start COC protocol`; perform readiness only, report `ready to load`, and
stop. Do not issue a COC or another in-game command. After the user loads into
the game, visually confirms it is loaded, and says `start`, begin the timed live
path.

The live command grammar is closed: `start COC protocol` authorizes only the
readiness phase and `start` authorizes only the post-load phase defined in the
protocol. Quoted, contextual, partial, or historical mentions do not authorize
an action. If a required action cannot complete under that command's explicit
scope, preserve its receipt, freeze the phase, and ask the user what to do.
Never retry, substitute an action, alter settings, or issue an extra game
command without a new explicit user command.

When Skyrim reaches its main menu/load window, and before loading into the test
world, establish the analysis environment. In parallel, use Community Shaders'
`tools/ghidra-mcp-control.ps1` to start or verify the managed Ghidra server
against the candidate DLL path and SHA-256 from the explicit DevBench runtime
metadata, and run `coc-evidence-control inspect` against the exact Skyrim PID.
Arm only after its `dump-write` check proves the configured output can create,
write, and remove a controller-owned probe. A failed check blocks readiness:
preserve it, do not retry arm, and ask the user to repair the output path.
Require CDB/WinDbg, ProcDump, dump storage, and an owned crash collector. It is
exception-triggered; use `capture-hang` only after a visually confirmed freeze
so normal COC loads cannot consume its dump quota. Require the
trusted project `.codex/config.toml` to declare the exact DevBench and Ghidra
loopback endpoints; do not rely on volatile global registration state. Confirm
the current Codex window exposes both DevBench and Ghidra MCP tools and make
one harmless call through each. Require the native-headless Ghidra receipt and live
`list_binaries` MCP call to prove `binaryListReady: true`,
`programMatchesExpectation: true`, and the exact active executable path. The
controller records the imported artifact SHA-256; a listening server or project
name alone is not proof. The controller reimports a stale managed program when
the supplied candidate path or SHA-256 differs; do not select a snapshot or
reuse a prior candidate. Do not require PyGhidra or `eval_python` activation. If
either tool family is absent, leave Skyrim at the main menu, preserve the receipts, and ask
the user to restart Codex. After the user returns and explicitly repeats
`start COC protocol`, repeat only the tool-call checks. Retain the Ghidra and
ProcDump receipts. Report readiness only after every required receipt and real
MCP call passes, then wait for the user's second command.

Before reporting readiness, run the protocol's harmless one-step scenario
probe and require DevBench to convert the extension's embedded
`missing_expected_cell` receipt into `ok:false`, `aborted:true`, and exactly one
executed step. This proves `continueOnError:false` will stop later COCs on a
real embedded tool failure.

When the user confirms Skyrim VR is visibly loaded and says `start`, make the
first live operation an async DevBench server scenario that waits exactly 10
seconds and dispatches one isolated `coc WindhelmExterior01`. During that
server wait, read runtime identity and the exact CSX Build ID concurrently. Do
not put discovery or sequential status calls ahead of this COC.

After Windhelm loads, invoke `coc-stability-control run` once with the exact
Skyrim PID, Build ID, owned collector state, and evidence root. Do not call
`prepare_coc`, baseline tools, or the measured scenario separately. The
controller calls `communityshaders.menu` exactly once with
`{"action":"prepare_coc","expectedBuildId":"<exact build ID>"}` and records
`ready: true`, `persisted: false`, startup-active VR FPS Stabilizer, developer
mode, and the FOV/TAA 0.3/0.3/0.7 fixture. It raises an `info` or less-verbose
CSX log level to `debug`, then may correct only the FOV/TAA runtime settings;
it must not save. A returned fixture defect prevents only the early-start
shortcut; the 10-second watchdog still runs the measured assay.

VR FPS Stabilizer exclusively owns every DLSS/upscaling change. Observe its
per-cell profiles; never apply an upscaling method, quality, preset, render
scale, or dynamic policy through CSX. Every measured `qualification_wait`
omits `target`; it requires a post-dispatch profile change and returns the
coherent observed profile as evidence.

That ownership includes profile discovery and policy selection. Do not inspect
graphics adapters, infer a target from AMD/NVIDIA hardware, read or compare
Stabilizer INIs, resolve a winning MO2 file, or invoke `mo2-control` for an
upscaling decision. Multiple adapters or Stabilizer INIs are irrelevant to the
assay; record only the coherent profile exposed by the running CSX APIs.

The controller starts one monotonic 10-second watchdog immediately after the
fixture receipt and collects exact-cell, profile, lifecycle, stereo,
diagnostic-status, and already-available image evidence in one parallel bundle.
Its independent watchdog and atomic dispatch claim start the assay once only:
immediately for a complete acceptable bundle, or at 10 seconds while preserving
an incomplete or faulty baseline. Do not probe providers or retry checks.

The controller runs the stress reset/start and all 20 alternating transitions
in one async server scenario. On transition 1, `qualification_dispatch` uses
`startPerformanceTelemetry: true` immediately adjacent to the COC, so CPU and
GPU counters share the first COC command boundary and exclude setup. Use
`continueOnError: false`: semantic timeout/profile/fidelity/lifecycle faults are
normal successful waiter receipts and continue, while an actual failed tool
step, including a top-level embedded tool `error`/`ok:false`, or lost main
thread aborts later COCs immediately. Preserve the embedded receipt. Do not
split ordinary transitions into client round trips.

Every canonical transition uses one `qualification_wait` with
`milestone: "strict"` and `timeoutMs: 30000`. This is a post-dispatch maximum,
not a fixed wait: the atomic COC executes first and the waiter returns as soon
as strict is satisfied. The strict receipt captures the first
presentation-stable, cleanup-drained, and strict-satisfied observations without
changing the independent 10-second start-cell settle. Do not use a
presentation-only or cleanup-only wait in the same owned transition, add a
fixed inter-transition wait, or poll the client. Those shorter milestones are
separate diagnostic runs only.

After the scenario completes, use `coc-stability-control status` for the
per-transition milestone table and its presentation, cleanup, strict, and
cleanup-tail aggregates. Strict frames remain the canonical RC166 comparison;
presentation and cleanup-tail timings are diagnostic evidence only.
The same analysis must retain each post-wait `status.preparation` trace,
including admission/early-exit, shader-cache, prewarm, DLSS/FSR/FSR4, D3D,
total, request-to-prepared, and prepared-to-creator timings. Do not add a
second waiter or client poll to collect them.

After transition 20, attempt guarded GPU, CPU, stress, and ProcDump cleanup only
while their control planes are responsive. On CTD or hang, make no further
main-thread calls; wait for the already-armed dump to settle, preserve it, and
analyze it with WinDbg and the managed Ghidra MCP server before telling the user
it is safe to quit.

Retain the controller state path and use `coc-stability-control status` to read
the final scenario transcript. Do not reconstruct or redispatch the batch from
client-side tool calls.

Classify a fully stable run as `clean` and a complete imperfect run as
`completed_with_anomalies`. Use an interrupted verdict only when a hard control
failure prevented all 20 COCs from being dispatched.
