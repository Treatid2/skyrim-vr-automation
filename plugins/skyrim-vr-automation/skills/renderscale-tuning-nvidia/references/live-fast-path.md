# NVIDIA live fast path

`tools/renderscale-tuning-live/runner.js` executes this path in the positioning
cell. This file is its post-run audit contract; it is not read or translated
during live measurement.

Use the decoded positioning snapshot as the baseline boundary. Build the
runtime-only DLSS Hoshipa target from its effective profile names, preserving
`dlssProfile`, and set dormant `fsrRuntime: fsr3`. Run one fail-closed scenario
in this order: render-scale `reset`, render-scale `start`,
`qualification_begin`, `qualification_dispatch` with
`startPerformanceTelemetry: false`, public-API `apply`, and strict
`qualification_wait`. Use unique nonempty string owner/client/command IDs, a
numeric transition ID, the exact state revision and Build ID, Dragonsreach,
the `0.3/0.3/0.7` fixture, `persistence: runtime_only`, and the full
dispatch-relative `timeoutMs: 30000`.

On strict baseline success, immediately run one handoff scenario: stop the
exact baseline stress session, start measured stress, reset/start texture
lifetime, reset/start load presentation, and enable the profiler. Then execute
the matrix twice in this same orchestration cell. Each row scenario starts
with the sole 5,000 ms wait, then optional owned DLSS trace reset/start,
`qualification_begin`, transition-1 profiler history clear,
`qualification_dispatch`, public-API `apply`, strict `qualification_wait`, and
optional owned DLSS trace stop/read. Transition 1 alone sets
`startPerformanceTelemetry: true`. Construct each target from the preceding
terminal waiter's authoritative stable profile and state revision plus the
matrix destination. Store the exact terminal waiter immediately; for a traced
row, retain its reset, start, stop, and bounded raw-read subreceipts in the same
stored row record. Emit only a compact projection. Do not pause for model
reasoning, read files, write evidence, hash, or issue a confirmation read
between rows.

Continue after a semantic row failure only when the terminal receipt proves
the owner closed, zero active operation, matching PID/Build ID, and no device
loss, OOM, producer terminal failure, or unresolved mutation. Otherwise stop
future mutations and perform only ownership-guarded cleanup. After pass 1,
finalize its owned sessions, take the memory boundary, run the one server-owned
10,000 ms cooldown, establish the fresh pass-2 baseline and owners, and repeat
the unchanged matrix.

Only after a pass completes or is interrupted may the runner read the
[shared detailed contract](../../../docs/protocols/renderscale-tuning-fast-start.md)
and [NVIDIA protocol](protocol.md) for cumulative evidence, reporting, cleanup
verification, and ledger finalization.
