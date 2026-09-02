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
`{"action":"prepare_coc"}`, then `mcp__devbench_vr__scenario`. Never call
Scenario first or issue either as a standalone tool.
Store the exact envelopes under run-unique `startup-prepare` and
`startup-positioning` keys, but control from the local responses. Do not call
`load()`, compare object identity, stringify, or create evidence during startup;
finalization materializes both stored responses.

Decode each envelope once from `content[0].type: "text"` with `JSON.parse` of
`content[0].text`. Admit `prepare_coc` only from these exact paths: top-level
`ready: true`, `persisted: false`, 64-character `producer.buildId`;
`after.ready`, `after.vr`, `after.inGame`,
`after.vrFpsStabilizer.activeForSession`, `after.developerMode.active`,
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

Do not end the positioning `functions.exec` after the scenario response. In
that same cell, load `tools/renderscale-tuning-live/runner.js` and
`skills/renderscale-tuning-nvidia/references/matrix.v1.json` from the current
plugin root with one parallel local read. Evaluate the runner source as
`runRenderScaleTuningLive` and await it with the already-admitted
`positioningRoot` unchanged, `variant: "nvidia"`, the bound Build ID, the
parsed matrix, a short run-unique ID, and the cell's `tools`, `store`, and
`notify` functions. Do not extract, normalize, or validate positioning fields
in the client; the runner exclusively owns positioning admission.
Use this loader shape, substituting only the current plugin root and the local
positioning/build variables:

```javascript
const support = await Promise.all([
  tools.exec_command({cmd:"Get-Content -Raw -LiteralPath 'tools\\renderscale-tuning-live\\runner.js'",workdir:"<plugin-root>",shell:"powershell",login:false}),
  tools.exec_command({cmd:"Get-Content -Raw -LiteralPath 'skills\\renderscale-tuning-nvidia\\references\\matrix.v1.json'",workdir:"<plugin-root>",shell:"powershell",login:false})
]);
const runLive = new Function(`${support[0].output}\nreturn runRenderScaleTuningLive;`)();
const liveResult = await runLive({tools,store,notify,variant:"nvidia",runId:`nvidia-${Date.now().toString(36)}`,buildId,positioningRoot,matrix:JSON.parse(support[1].output)});
text(JSON.stringify(liveResult));
```

The runner is the executable live contract. Each strict waiter owns a 20-second
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
evidence is a tooling gap. Direct `mcp__devbench_vr__*` tools are the only
permitted transport. Do not enumerate tools or inspect fallbacks; if a named
tool is not callable, stop and never use the bundled controller.
