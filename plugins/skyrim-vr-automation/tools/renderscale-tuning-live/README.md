# Persistent NVIDIA tuning worker

The NVIDIA skill transfers the unchanged admitted startup and fixed matrix to
a hidden detached Node process. One persistent connection uses the selected
plugin's loopback DevBench MCP endpoint. The worker pins the positioned PID and
Build ID, owns both passes, and keeps running after its launcher or chat tool
cell exits. Progress messages do not control it. AMD retains its existing path.

The worker drains a persistent notification stream on that same MCP session.
This keeps session activity current during long POST requests and server waits.
It never adds a heartbeat tool call or another measurement session. HTTP errors
retain their status and bounded response detail.

After transport loss, measurement remains interrupted. Cleanup may reconnect
once to the exact selected endpoint, verify the positioned PID and Build ID,
and compare the current captures with their retained start/dispatch ownership.
CPU and GPU stops include their session/start-frame guards. Cleanup checks the
qualification owner, trace, profiler and every telemetry capture; a lost stop
response leads to a status check, never a replay. A blocked cleanup preserves
the exact known owners and failure in worker status and retains the endpoint
lock. Journal completion never substitutes for verified inactive captures.

The launcher requires Node 22 or newer. It uses `CSX_TUNING_NODE_PATH`, `node`
on PATH, or the Node bundled with Visual Studio found through `vswhere`.
An explicit `-NodePath` is also supported. Start only through the skill's
post-position handoff; do not fabricate startup receipts for a live run.

## Measurement and evidence

Keep the prescribed five-second server wait and strict terminal qualification.
Dispatch the next safe scenario immediately after local qualification. No model
turn, disk acknowledgement, hashing, CSV generation, or report rendering gates
a transition or the next pass. Copy every received envelope and row revision
into the writer queue before reusing it. A dedicated thread serializes and
appends complete JSON records to `raw/journal.ndjson` through one open handle.
There is no save-backlog cutoff, dropped receipt, telemetry filter, or per-row
file. Queue growth never stops measurement. Status writes run asynchronously.

Raw records retain every Task 2 facet, ownership identity, phase counter,
first-offender audit, both-eye publication/backend/generation fields, full
replacement timeline, trace page, CPU/GPU/profiler capture, memory boundary,
and transition timing supplied by the protocol. Later revisions append under
the same receipt key. Sequence numbers prove ordering. Progress projections
are separate and cannot replace this evidence. The queue preserves full data
needed by downstream analyses, including Task 3; no fields are selected out.

After both passes and ownership cleanup, acknowledge every queued record and
flush the file before publishing terminal success. A genuine storage error
prevents a saved-evidence claim and leaves guarded cleanup callable. An abrupt
machine or worker termination can lose unflushed data; a game crash or a chat
status question does not terminate the writer. Offline finalization reads the
document incrementally, projects the latest revision, and preserves the original
document. Every journal revision is exported to `evidence-values.csv` with
`raw/journal.ndjson#sequence=N` as its source and a JSON Pointer within that
record, including revisions superseded by later rows. It also supports
historical numbered journals. Reports and their
additional files are generated only after measurement ends.

The worker records extra dispatch gaps separately from producer timings.
Exceeding the diagnostic 250 ms budget changes the pacing observation, never
the run's control flow. Do not claim a runtime speedup from mocked tests.

## Status and interruption

Read the acknowledged `statusPath` at intervals of at most five seconds and
report after every five completed transitions, at pass boundaries, and at
completion. Read the current count and pass even when a requested update arrives
between scheduled updates. Never wait on the launcher's exec cell to determine
whether the worker is alive. If terminal status publication fails, the worker
writes `worker-terminal.json` and includes the error.

An exclusive endpoint lock under local application data prevents competing
workers. Release it only after verified telemetry cleanup or proof that no
mutation was dispatched. Missing status, process loss, or an unresolved owner
requires inspection of the exact run, PID, Build ID and qualification owner;
never automatically replay, clear the lock, or start a replacement. Preserve
the request, journal, status, and worker log for manual guarded recovery.

Validation: `node tests/Test-RenderScaleTuningWorker.js` uses a local mock MCP
server, complete matrices, delayed writes, storage failures, and launcher exit.
`node tests/Test-RenderScaleTuningFinalizer.js` validates journal reconstruction.
