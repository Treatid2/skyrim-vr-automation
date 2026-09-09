---
name: renderscale-tuning-nvidia
description: Run or explicitly replay the NVIDIA Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning nvidia or orders continuation after its failed recovery, repeating the exact 33-transition None, TAA, DLAA, DLSS, and FSR3 matrix once in the same process with full telemetry. Do not use for AMD, simple csm, or release qualification.
---

# NVIDIA render-scale tuning

Use only for exact command `renderscale-tuning nvidia`,
`renderscale-tuning-nvidia`, or an explicit continuation directive for the
immediately preceding NVIDIA attempt's failed recovery. Never infer this lane
from inventory.

## Immediate positioning

Apart from reading this SKILL, use named direct `mcp__devbench_vr__*`
tools. Before positioning, do not read references, run other local commands,
create evidence, enumerate tools, or inspect fallbacks.

After the required skill announcement, use one `functions.exec` with nested
direct tools: first `mcp__devbench_vr__communityshaders_menu` with exactly
`{"action":"prepare_tuning"}`, then `mcp__devbench_vr__scenario`. Never call
Scenario first or issue either as a standalone tool.
Store the exact envelopes under run-unique `startup-prepare` and
`startup-positioning` keys, but control from the local responses. Do not call
`load()`, compare object identity, stringify, or create evidence during startup;
the post-positioning runner journals both stored responses before measurement.

Decode each envelope once from `content[0].type: "text"` with `JSON.parse` of
`content[0].text`. Admit `prepare_tuning` only from these exact paths: top-level
`ready: true`, `persisted: false`, 64-character `producer.buildId`;
`after.ready`, `after.vr`, `after.inGame`,
`after.developerMode.active`,
`after.foveation.ready`, `after.foveation.foveatedVendorDispatch`, and
`after.foveation.peripheryTAAEnable` all `true`; and
`after.developerMode.logLevel: "debug"`. Require `after.foveation` values
`foveatedCenterArea: 0.3`, `peripheryTAACenterArea: 0.3`, and
`peripheryTAAOuterScale: 0.7` within `0.000001`. No other `before` or `after`
field gates admission; do not infer aliases. Within the current attempt, after
any live-call error, stop; never correct, restart, or replay the live prefix.
The explicit failed-recovery replay below is a separate attempt.

Immediately submit the following synchronous scenario, replacing only
`<bound-build-id>` with that producer Build ID. Do not insert commentary,
another call, or local work between the fixture and this request.

```json
{"action":"run","async":false,"continueOnError":false,"steps":[
  {"label":"position-coc","tool":"console","args":{"action":"exec","command":"coc WhiterunDragonsreach"}},
  {"label":"position-settle","wait":60000},
  {"label":"position-health","tool":"inspect","args":{"kind":"health"}},
  {"label":"position-state","tool":"inspect","args":{"kind":"state"}},
  {"label":"position-scene","tool":"inspect","args":{"kind":"scene"}},
  {"label":"position-capabilities","tool":"communityshaders.upscaling_api","args":{"action":"capabilities","expectedBuildId":"<bound-build-id>"}},
  {"label":"position-snapshot","tool":"communityshaders.upscaling_api","args":{"action":"snapshot","expectedBuildId":"<bound-build-id>"}},
  {"label":"position-renderscale","tool":"communityshaders.renderscale","args":{"action":"status","expectedBuildId":"<bound-build-id>"}}
]}
```

Pass the decoded scenario root unchanged to the packaged runner. Do not
calculate a positioning-admission result, inspect individual payload shapes,
or emit a positioning verdict in the client. The runner validates the
successful outer scenario, required labeled tool entries, exact scene, and
snapshot, then emits the compact positioning `notify()`. In particular,
`position-renderscale.result` is an opaque payload: its outer presence is
required, but no nested `result` or adapter field is required.

## Uninterrupted measurement

The runner verifies NVIDIA vendor ID `0x10DE`/4318 from existing stress-start
receipts and terminal waiters. A safe non-stable waiter without status retains
the verified identity of its exact stress session. Missing or mismatched
identity stops measurement with diagnostics, without a positioning gate or
extra tool call.

Do not end the positioning `functions.exec` before handing the admitted
startup to `tools/renderscale-tuning-live/handoff.js`. Load it from the current
plugin root in that same cell. It starts a hidden detached Node worker, which
loads `tools/renderscale-tuning-live/runner.js` and the unchanged matrix.
Pass `positioningRoot` unchanged, the bound Build ID and run ID, and both exact
startup envelopes. Do not extract, normalize, or validate positioning fields
in the client; the runner exclusively owns positioning admission.
Use this loader shape, substituting only the current plugin root and the local
positioning/build variables. Reuse the run ID assigned to startup receipts;
`prepareEnvelope` and `positioningEnvelope` below are the exact local startup
responses:

```javascript
const support = await tools.exec_command({cmd:"Get-Content -Raw -LiteralPath 'tools\\renderscale-tuning-live\\handoff.js'",workdir:"<plugin-root>",shell:"powershell",login:false});
if (support.exit_code !== 0) throw new Error("worker_handoff_unavailable");
const startWorker = new Function(`${support.output}\nreturn startRenderScaleTuningWorker;`)();
const worker = await startWorker({tools,runId,buildId,positioningRoot,startupReceipts:{prepare:prepareEnvelope,positioning:positioningEnvelope},pluginRoot:"<plugin-root>"});
store(`${runId}:worker`,worker);
text(worker);
```

The runner is the executable live contract. After positioning, it creates
a new run directory under the current workspace's `artifacts/renderscale-tuning`.
Every received scenario and every row revision is queued as an immutable copy
before the next operation. A separate writer appends complete receipts to one
`raw/journal.ndjson` document. The queue may drain during later transitions or
passes; never wait for disk acknowledgements or flushes between them. A save
backlog never aborts or slows measurement. Preserve all fields, raw traces,
per-transition timings, and later revisions; compact status is not evidence.
Flush the entire document after measurement and cleanup before claiming that
evidence is saved. Generate CSVs, hashes, and report files afterward.
Do not pass a custom `receiptJournal` in a live run (that injection exists only
for offline tests). Partial runs remain useful for
comparison: report missing metrics explicitly instead of discarding evidence.

Once the worker launch is acknowledged, the positioning cell may end. Monitor
its exact `worker-status.json` with read-only local calls at intervals of at
most five seconds. Emit a concise update after every five completed transitions,
at pass boundaries, and at completion. Progress questions are status reads;
they never cancel, restart, or replay the worker. A missing exec cell is not
evidence that the detached worker stopped. Check `worker-terminal.json` if a
terminal status replacement failed. Do not launch a competing worker or clear
its endpoint ownership lock. Report timing gaps diagnostically, without stopping
because evidence saving or status delivery is behind. See
`tools/renderscale-tuning-live/README.md` after measurement for recovery details.
 Each strict waiter owns a 20-second
terminal budget. An unsatisfied terminal receipt records a compact non-stable
note, including its presentation disposition and eye paths. A safely closed
failure advances directly. A stuck operation or physical mutation gets one
runner-owned reset to the lane's proven starting profile; preserve the failed
row, do not retry it, and continue only after that reset strictly stabilizes.
Device loss, OOM, lost ownership/scene/transport, or a failed reset stops the
current attempt. Do not translate the matrix or
live-path prose into another cell, normalize receipt shapes, or add client
checks. It decodes the already-admitted positioning receipt and reads each
later boundary only at `qualification-wait.upscalingSnapshot`. DevBench owns
admission, timing, strict qualification, and fail-closed scenario execution. Read the
[live-path audit](references/live-fast-path.md), detailed contract, and NVIDIA
protocol only after the runner returns for evidence finalization.

## Explicit failed-recovery replay

When the immediately preceding NVIDIA attempt ended specifically with
`transition_recovery_failed`, an explicit user order to close a stale in-game
window or menu and continue authorizes one replacement attempt. Never infer
this authorization from a generic retry request, and never replay
automatically.

Require the interrupted attempt's ownership-guarded cleanup to be complete.
Use capture interaction control to inspect the current menu list, close only
the identified stale non-HUD menu, and inspect again. Do not send a broad
close, kill the game, or mutate another menu. If the stale menu remains, an
operation or qualification owner is active, the physical mutation is not
clear, or PID/Build ID ownership cannot be re-established, stop without a new
apply. Establish those safety facts with direct read-only DevBench inspection
before returning to the normal admission path.

Preserve the interrupted attempt under its original run ID. Return to
**Immediate positioning** and run the complete NVIDIA assay with a fresh run
ID; do not splice the interrupted rows into the replacement evidence. This
operator-authorized replacement is the sole exception to the failed-recovery
replay prohibition. Each explicit directive authorizes at most one replacement
attempt.

Scope is one positioning COC, two runtime-only baselines, and exactly 66
measured runtime-only `communityshaders.upscaling_api` applies. Never load/run
Simple COC/CSM or alter Simple CSM's 25-step matrix. It does not authorize a
build, deployment, MO2/Stabilizer/INI edit, persistence, restart, fault
injection, another protocol, or render-scale mutation. VR FPS Stabilizer stays
outside this assay.

The explicit NVIDIA command selects this lane. Vendor execution and backend
correctness are qualified by the baseline and measured waiters, not by another
client-side adapter-shape admission gate. Missing optional native-generation
evidence is a tooling gap. Startup uses direct `mcp__devbench_vr__*` tools.
After positioning, the packaged worker uses the same selected DevBench MCP
HTTP endpoint from this plugin's `.mcp.json`, with one persistent session and
the positioned PID and bound Build ID. This post-position handoff is the sole
transport exception; do not enumerate tools, select an alternate endpoint,
retry failed mutations, or use the bundled controller.
