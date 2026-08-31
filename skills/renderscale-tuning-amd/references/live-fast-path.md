# AMD live fast path

`tools/renderscale-tuning-live/runner.js` executes this path in the positioning
cell. This file is its post-run audit contract; it is not read or translated
during live measurement.

Select runnable lanes from the decoded positioning capabilities and use the
decoded positioning snapshot as the first baseline boundary. For each runnable
lane, build the runtime-only FSR Hoshipa target from the effective profile
names, preserving `dlssProfile`, with the lane's configured FSR runtime. Run
one fail-closed scenario in this order: render-scale `reset`, render-scale
`start`, `qualification_begin`, `qualification_dispatch` with
`startPerformanceTelemetry: false`, public-API `apply`, and strict
`qualification_wait`. Use unique nonempty string owner/client/command IDs, a
numeric transition ID, the exact state revision and Build ID, Dragonsreach,
the `0.3/0.3/0.7` fixture, `persistence: runtime_only`, and the full
dispatch-relative `timeoutMs: 30000`.

Before the first runnable AMD lane, run and retain one bounded DLSS trace
status/reset/start/stop/read lifecycle and require its raw read to contain no
DLSS dispatch. This is one capability/isolation receipt, not a per-row trace;
never start a DLSS trace during an AMD matrix transition.

On strict baseline success, immediately run one handoff scenario: stop the
exact baseline stress session, start measured stress, reset/start texture
lifetime, reset/start load presentation, and enable the profiler. Execute the
lane matrix twice in this same orchestration cell. Each row scenario starts
with the sole 5,000 ms wait, then `qualification_begin`, transition-1 profiler
history clear, `qualification_dispatch`, public-API `apply`, and strict
`qualification_wait`. Transition 1 alone sets
`startPerformanceTelemetry: true`. Construct each target from the preceding
terminal waiter's authoritative stable profile and state revision plus the
matrix destination and lane runtime. Store the exact terminal waiter
immediately and emit only a compact projection. Do not pause for model
reasoning, read files, write evidence, hash, or issue a confirmation read
between rows.

Continue after a semantic row failure only when the terminal receipt proves
the owner closed, zero active operation, matching PID/Build ID, and no device
loss, OOM, producer terminal failure, or unresolved mutation. Otherwise stop
future mutations and perform only ownership-guarded cleanup. After pass 1,
finalize its owned sessions, take the memory boundary, run the one server-owned
10,000 ms cooldown, establish the fresh pass-2 baseline and owners, and repeat
the unchanged lane matrix. Finalize a lane before selecting the next one.

Only after a pass completes or is interrupted may the runner read the
[shared detailed contract](../../../docs/protocols/renderscale-tuning-fast-start.md)
and [AMD protocol](protocol.md) for cumulative evidence, reporting, cleanup
verification, and ledger finalization.
