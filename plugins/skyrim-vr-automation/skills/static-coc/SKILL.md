---
name: static-coc
description: Run the preserved Skyrim VR static COC assay with strict render-scale milestones when the user says start static coc.
---

# Static COC

Use this entrypoint only for the preserved 20-transition static COC assay.
Before taking any action, read [references/protocol.md](references/protocol.md)
completely.

The dispatch phrase is `start static coc`. If a fresh arm receipt already binds
DevBench, Ghidra, ProcDump, and the intended Skyrim process, run the protocol.
Otherwise perform only the arm phase, report that no COC was sent, and require
the user to repeat the exact phrase before dispatching.

Require the next-build `qualification_wait` milestone contract before the first
COC: `strict`, `presentation`, and `cleanup` must be accepted values. Do not
fall back to the old waiter if the candidate does not expose those milestones.

Run one initial server-scheduled, unmeasured Windhelm positioning COC, then one
async 20-transition scenario. Every measured transition uses server-side
`qualification_status`, `qualification_begin`, one atomic
`qualification_dispatch` COC, one strict waiter with `timeoutMs: 30000`, and
one post-wait `status` that retains the completed preparation trace.
Dispatch executes the COC before the waiter starts. The 30 seconds is only a
post-dispatch maximum; the waiter returns as soon as strict is satisfied. The
initial Windhelm COC remains the only COC preceded by a 10-second server wait.

VR FPS Stabilizer exclusively owns DLSS, FSR, render scale, and profile choice.
Every static waiter omits `target`; record the coherent observed profile without
changing it. The protocol may pass the exact FOV/TAA foveation fixture only
after its one runtime-only `prepare_coc` receipt establishes that fixture.

Keep strict frames as the canonical RC166 comparison. Presentation latency and
the strict-minus-presentation cleanup tail are diagnostic measurements. Never
replace pinned ledger rows; append a new candidate only after a completed run.
