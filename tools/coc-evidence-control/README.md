# COC evidence control

Invoke-CocEvidenceControl.ps1 prepares the local crash/hang evidence lane
before a live Skyrim VR COC assay.

It verifies:

- ProcDump and CDB/WinDbg are available;
- the dump drive has at least 100 GiB free by default.
- the exact dump root can create, write, and remove a controller-owned probe.

`inspect` performs the write probe before any monitor launch. A failed
`dump-write` check is a configuration block: preserve that receipt, do not arm
or retry ProcDump, and ask the operator to repair the configured output path.

The arm command requires the exact Skyrim PID and starts one hidden ProcDump
monitor for that lifetime. It records
full dumps for unhandled exceptions, caps the run at two dumps, and does not
create a normal-process-exit dump. It deliberately does not use ProcDump's
five-second window-hang trigger because a healthy Skyrim COC load can satisfy
that heuristic twice and exhaust evidence coverage before the assay.

For a visually confirmed freeze, `capture-hang` officially cancels the owned
crash monitor and immediately takes one classified full dump of the exact PID.
The returned receipt records `operator-confirmed-hang`, exact child-process
identity, dump length, and SHA-256. Until hashing completes, status remains
`hash-pending`; it never presents unfinalized bytes as complete evidence.
The returned state path owns status, hang-capture, and stop operations.
Exact targets are bound by PID and process start time. A replacement process is
never accepted merely because Windows reused its numeric PID. Monitor, capture,
and cancellation-helper children remain attributable across every return; a
timed-out helper is reported as `cleanup-incomplete`, not as successful stop.

`capture-complete` requires the exact nonempty dump plus its matching completion
receipt and successful ProcDump exit record. Empty, unrelated, or unfinalized
files remain preserved as `capture-evidence-partial` and never imply that it is
safe to disturb the game.

Hang capture runs through an exact, journal-admitted completion worker. The
actual ProcDump child is started suspended inside a kill-on-close Windows job,
assigned before it can run, and journaled by exact PID/start time. Wrapper loss
therefore terminates the child; after journaling, `status` and `stop` can also
recover it directly. Both the child wait and foreground wait are bounded. A
later `status` recomputes the dump digest before proving completion.

The controller discovers the sibling `codex-ghidra-live` GitHub folder.
Portable overrides are `CSX_COC_EVIDENCE_ROOT`, `CSX_PROCDUMP_PATH`,
`CSX_CDB_PATH`, and `CSX_COC_DUMP_ROOT`.

The controller owns only local dump collection and WinDbg analyzer readiness.
Before a live assay, Codex must use Community Shaders'
`tools/ghidra-mcp-control.ps1` to prove the managed Ghidra server is ready,
make a harmless Ghidra MCP call, and confirm that the DevBench MCP tools are
present in the current Codex window.
