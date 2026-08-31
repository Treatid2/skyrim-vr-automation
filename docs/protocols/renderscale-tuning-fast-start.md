# Render-scale tuning detailed contract

The vendor `SKILL.md` and its small `live-fast-path.md` reference own the live
path from runtime fixture through the current pass. Do not read this detailed
contract during startup,
after positioning, or between measured rows. Read it only after a pass has
completed or been interrupted, when cumulative evidence and guarded
finalization begin. Its detailed live rules remain the normative audit
reference, but loading them must never delay a COC, baseline, or next row.
When this file is loaded at finalization, use its live-action sections only to
audit preserved receipts. Never replay an action merely because it is
described below.

## Validate the one positioning response

Require top-level `ok: true`, `aborted: false`, and `stepsRun: 8`. Use the
labeled results already returned by that scenario; do not issue confirmation
reads. Require:

- `position-health`: one live `SkyrimVR.exe` PID with `vr: true`;
- `position-state`: `playerLoaded: true` with the same PID and an advancing
  frame;
- `position-scene`: `playerLoaded: true` and
  `cell.editorId: WhiterunDragonsreach`. This scene receipt alone owns exact
  cell identity; never require it from `position-state`;
- `position-capabilities`: success, the fixture's exact producer/Build ID, and
  every method, quality, and runtime required by the selected matrix;
- `position-snapshot`: the same Build ID, a complete authoritative public
  snapshot, and no active operation;
- `position-renderscale`: the same Build ID, no terminal or unresolved
  physical failure, an available adapter, and vendor ID `0x10DE`/4318 for
  NVIDIA or `0x1002`/4098 for AMD.

The synchronous response is the positioning observation. The live skill
decodes the MCP envelope exactly once from `content[0].text`, validates the
fixed labeled paths, and reports positioning as soon as it returns. It must not
create an evidence directory, decode Base64, hash files, recursively search
the response, or read this contract first. A failed scenario or required field
stops without replaying the COC.

After positioning, the same orchestration cell loads the packaged deterministic
runner and matrix in parallel and starts the baseline without another model
handoff. Pass the initial boundary already decoded during positioning; the
runner reads only each strict waiter's documented qualification snapshot after
that. It does not search, normalize, or revalidate positioning. Do not load
Simple COC/CSM, enumerate tools, inspect schemas, or run another
admission/reset scenario. Vendor live-path, protocol, and this detailed
contract are finalization-only reads.

The vendor `SKILL.md` stores the exact `prepare_coc` and positioning responses
under run-unique startup keys before this contract is read. They are startup
identity/admission evidence, not measurement timing evidence. The live path
keeps the returned envelopes in local variables and must not call `load()` or
compare object identity to verify storage. Load the stored values only during
finalization; do not print them to chat or perform another live startup read.
Materialize both under `raw/startup` and include them in the one
receipt-index/hash batch.

If either stored startup receipt is unexpectedly unavailable, never replay a
startup call or invalidate completed render rows. Record
`startup_evidence_incomplete`, forbid the comparison-ledger append, and make the
missing receipt explicit in the report. The normal protocol must not produce
this state because both keys are stored before positioning is reported.

After the first live startup call returns, a client, orchestration, storage, or
validation error ends that invocation. Never correct the check and restart the
fixture/positioning prefix in place; require a fresh user invocation.

Every later mutation and ownership scenario remains synchronous with
`async: false` and `continueOnError: false`.

## Baseline and measured ownership

Reuse the post-position public snapshot and its exact `stateRevision` when it
is complete, has no active operation, and still matches the bound Build ID.

After that one prescribed live-path/matrix read and until transition 1 has
been dispatched, do not run another local command, create evidence, locate a
ledger, hash/serialize a receipt, search source, inspect a schema, or prepare a
report. Only compile and run the baseline, handoff, and transition 1's 5,000 ms
settle. The ledger path is the repository-relative
`docs/development/vr-render-scale-comparison-ledger.csv`; never search for it.

Use these typed substitutions without discovery. `transitionId` is the only
numeric caller identifier. `ownerId`, `clientId`, and `commandId` are always
nonempty JSON strings; never substitute an ordinal, session ID, or other
number. Use descriptive values such as
`"rst-nvidia-baseline-pass-1-owner"`,
`"rst-nvidia-baseline-pass-1-client"`, and
`"rst-nvidia-baseline-pass-1-apply"` with a run-unique suffix.

- `<build-id>`: exact bound Build ID string;
- `<state-revision>`: numeric post-position `stateRevision`;
- `<transition-id>`: new nonzero integer;
- `<owner-id>`: new unique nonempty string;
- `<client-id>` and `<command-id>`: new unique nonempty strings;
- `<api-target>`: complete string-valued API profile from the vendor protocol;
- `<qualification-target>`: the same profile with numeric quality
  (`native_aa=0`, `hoshipa=1`,
  `ultra_quality=2`, `quality=3`, `balanced=4`, `performance=5`,
  `ultra_performance=6`);
- `<foveation>`: exactly `{ "foveatedVendorDispatch": true,
  "foveatedCenterArea": 0.3, "peripheryTAAEnable": true,
  "peripheryTAACenterArea": 0.3, "peripheryTAAOuterScale": 0.7 }`.

The six baseline scenario steps have these complete tool/argument shapes; add
no field and perform no lookup:

| Label | Tool | Arguments |
| --- | --- | --- |
| `baseline-stress-reset` | `communityshaders.renderscale` | `{"action":"reset","expectedBuildId":"<build-id>"}` |
| `baseline-stress-start` | `communityshaders.renderscale` | `{"action":"start","expectedBuildId":"<build-id>"}` |
| `qualification-begin` | `communityshaders.renderscale` | `{"action":"qualification_begin","transitionId":<transition-id>,"ownerId":"<owner-id>","expectedBuildId":"<build-id>"}` |
| `qualification-dispatch` | `communityshaders.renderscale` | `{"action":"qualification_dispatch","transitionId":<transition-id>,"ownerId":"<owner-id>","startPerformanceTelemetry":false,"expectedBuildId":"<build-id>"}` |
| `profile-apply` | `communityshaders.upscaling_api` | `{"action":"apply","expectedBuildId":"<build-id>","expectedStateRevision":<state-revision>,"target":<api-target>,"purpose":"direct","persistence":"runtime_only","clientId":"<client-id>","commandId":"<command-id>","reason":"render-scale tuning baseline"}` |
| `qualification-wait` | `communityshaders.renderscale` | `{"action":"qualification_wait","transitionId":<transition-id>,"ownerId":"<owner-id>","expectedCellEditorId":"WhiterunDragonsreach","timeoutMs":30000,"milestone":"strict","target":<qualification-target>,"foveation":<foveation>,"expectedBuildId":"<build-id>"}` |

Start the baseline with one synchronous fail-closed scenario containing six
labeled tool steps in this exact order: `baseline-stress-reset`,
`baseline-stress-start`, `qualification-begin`, `qualification-dispatch`,
`profile-apply`, and `qualification-wait`. This is the only pre-baseline reset.
The apply immediately follows dispatch, and the strict target-correlated waiter
immediately follows apply inside the same server-owned scenario. Pass the full
dispatch-relative `timeoutMs: 30000`; DevBench measures it from
`qualification_dispatch`. Never calculate or pass a client-side remaining
timeout. Do not inspect, validate, persist, or comment on the scenario response
until the server has executed the waiter and returned the complete six-step
transcript.

After the scenario returns, read only its fixed wrapper shape. Require
top-level `ok: true`, `aborted: false`, and `stepsRun: 6`. The apply receipt is
`results[]` entry `label: profile-apply`, under `result.apply`; its disposition
is `result.apply.disposition.name`. The waiter receipt is the unique entry
`label: qualification-wait`, under `result`, with
`result.action: qualification_wait`. Never search another wrapper location or
run another waiter because a client-side field lookup failed.

If the containing scenario response is lost or cannot be decoded, do not replay
the scenario, apply, or waiter. Before writing evidence, reporting feedback,
cancelling, cleaning up, or pausing for commentary, read
`qualification_status` once with the exact `expectedBuildId`, then validate its
returned ownership pair. For the exact active owner in `dispatched` or
`waiting`, allow the already-running server scenario to reach the original
deadline and recover matching terminal `lastEvidence`; do not call
`qualification_wait` independently. If the owner is inactive and matching
`lastEvidence` is present, use it as the terminal waiter receipt. Allow at most
five additional seconds only to retrieve already-terminal evidence. Any
different owner, transition, Build ID, or missing terminal evidence after that
bound stops future mutations and asks the user. Never reapply the profile or
create a second measurement window. Record the client error only after the
qualification owner is terminal. This owner-correlated recovery rule applies
to every baseline and measured waiter in both vendor assays.

The terminal baseline waiter receipt is the first authoritative output-contract
proof. Require its independent `milestoneTimings` and `replacementTimeline`
objects. If either object is absent, record `plugin_contract_outdated`, preserve
the receipt, stop the baseline stress session with its ownership guard, and
stop before measured-owner handoff or transition 1. Never infer either object
from a tool description or later status snapshot.

Only after strict waiter success and that receipt check, continue without a
model pause into one synchronous fail-closed handoff scenario to stop the
baseline stress session with its exact ownership guard, start measured stress,
reset then start texture-lifetime, reset then start load-presentation, and
pre-arm the profiler with `set_enabled`. The baseline session guard is the
positive integer at the `baseline-stress-start` result's
`result.status.session.id`. Use exactly these handoff steps, replacing the
typed placeholders with that numeric session ID and unique string profiler
command IDs:

| Label | Tool | Arguments |
| --- | --- | --- |
| `baseline-stress-stop` | `communityshaders.renderscale` | `{"action":"stop","expectedSessionId":<baseline-stress-session-id>,"expectedBuildId":"<build-id>"}` |
| `measured-stress-start` | `communityshaders.renderscale` | `{"action":"start","expectedBuildId":"<build-id>"}` |
| `texture-lifetime-reset` | `communityshaders.renderscale` | `{"action":"texture_lifetime_reset","expectedBuildId":"<build-id>"}` |
| `texture-lifetime-start` | `communityshaders.renderscale` | `{"action":"texture_lifetime_start","expectedBuildId":"<build-id>"}` |
| `load-presentation-reset` | `communityshaders.renderscale` | `{"action":"probe_reset","expectedBuildId":"<build-id>"}` |
| `load-presentation-start` | `communityshaders.renderscale` | `{"action":"probe_start","expectedBuildId":"<build-id>"}` |
| `profiler-enable` | `communityshaders.profiler_api` | `{"contractMajor":1,"clientId":"<client-id>","commandId":"<command-id>","action":"set_enabled","enabled":true,"expectedBuildId":"<build-id>"}` |

Do not clear profiler history here. Transition 1 inserts exactly
`{"contractMajor":1,"clientId":"<client-id>","commandId":"<command-id>","action":"clear_history","expectedBuildId":"<build-id>"}`
as a `communityshaders.profiler_api` step immediately before
`qualification_dispatch`; use new client/command IDs and do not use
`start_capture` or invent `frameCount`. Transition 1's
`qualification_dispatch` is the sole CPU/GPU reset/start and timing origin.
Immediately begin transition 1's measured scenario after the handoff returns;
its first step owns the 5,000 ms wait. Retain every owner receipt. A failed or
unsatisfied baseline waiter, a missing waiter subreceipt, or an incomplete
scenario must never invoke this handoff scenario because it contains measured
owner start actions. The handoff scenario is never a cleanup path. Stop only
the baseline stress session with one
ownership-guarded `stop` call, start no measured owner, and follow the lane's
terminal failure rules.

## Fast measured-loop contract

The terminal `qualification-wait` receipt is the transition boundary. Its
closed owner, zero active operation, exact PID/Build ID, and unresolved-mutation
state are the complete safety decision for starting the next row. Do not add a
post-wait operation read, status read, final snapshot, local evidence write,
hash, report update, source search, or model pause before starting the next
row. Do not invent another previous-transition safety gate.

Invoke the direct scenario inside one orchestration cell. Extract its uniquely
labeled `qualification-wait` result, `store()` that exact terminal receipt
under a run-unique pass/lane/transition key together with any trace lifecycle
subreceipts produced by that scenario, and return only a compact
projection with `text()`. Keep only this projection in context:
pass/lane/ordinal,
transition and owner IDs, target, classification and reason, dispatch and
terminal QPC/frame, presentation/cleanup/strict elapsed values, closed-owner
state, final active-operation ID, unresolved-mutation state, and terminal
failure flags. Project cleanup completion only from the terminal waiter's
top-level boolean `cleanupDrained`; retain `outstandingCleanupDebt` as structured
raw evidence and never compare that object with numeric zero. Do not expand,
quote, Base64-decode, or return the full response
to the model/chat during the measured loop. The stored exact terminal receipt
and same-scenario trace subreceipts are the only immediate per-row evidence
action. A stable response-store handle is raw evidence until pass finalization;
it is not a substitute in the completed evidence bundle.

Store the complete scenario envelope under its own stable receipt key
immediately after the direct call returns and before decoding, validating, or
extracting any step. A failed scenario's compact projection must link to that
key and retain the producer-reported `ok`, `aborted`, `stepsRun`, error, failed
step, and ordered step results. Set `failedStep` only when the response
explicitly marks a step failed. Report `firstUnreportedStep` separately as an
observation boundary; never invent that it failed. Transport and decode
failures likewise retain their phase without fabricating a producer result.
The live result lists every retained receipt key and keeps completed rows in
the pass summary as each row closes. After interruption, materialize those
keys plus the failed scenario before reporting; a later failure never discards
an earlier completed pass or row.

The orchestration cell and packaged runner are only a response-handling
boundary. Every nested live call must still use the installed plugin's selected
direct DevBench MCP tools; this does not authorize an external controller,
HTTP call, alternate local transport, or fallback lane.

Keep the complete measured pass in that one live orchestration cell; do not
end the cell between rows. After storing and classifying a terminal receipt,
emit the compact progress projection with `notify()` and immediately call the
next synchronous scenario. The next scenario owns its initial five-second
wait. Use `yield_control()` when a user update is due while the cell continues;
never return to model reasoning, local commands, or evidence processing between
safe rows. Stop the loop in the cell on an unsafe terminal receipt.

Start the next row's one synchronous scenario immediately. Its first step is
the sole server-owned `wait` of exactly 5,000 ms, followed by that row's
preconstructed begin/dispatch/apply/wait sequence. Use the preceding terminal
waiter's authoritative final public snapshot and `stateRevision` as the next
apply boundary. A stale revision fails closed at the apply; it does not justify
a separate pre-row snapshot. Transition 1 uses the terminal baseline snapshot
in the same way. This makes the five-second server timer, not client evidence
handling, own the inter-transition pace.

If a local safety layer refuses to send a scenario before any direct MCP call
is dispatched, correct that local refusal and issue the never-sent scenario
once. This is not a replay.

If the direct tooling layer rejects a row as possibly still owned but proves
that row was never dispatched and created no owner, read `qualification_status`
once. When it reports `active: false` and terminal `lastEvidence` exactly
matches the preceding row's owner/transition, stable/satisfied result, and zero
active operation, classify the rejection as `tooling_false_positive` and issue
the never-dispatched row once. Preserve the rejection and recovery receipts for
finalization. If any ownership, dispatch, or terminal fact is absent or differs,
stop without retry. Never retry when DevBench may have accepted the scenario,
when a new qualification owner exists, or when the response was lost; use the
owner-correlated recovery rule in those cases.

At pass finalization, use `load()` to materialize every retained terminal
response and trace lifecycle receipt losslessly without first printing it to
chat,
then make one cumulative evidence-read batch for operation/event history,
render-scale status, preparation/provider traces, telemetry, profiler, stress,
texture-lifetime, and load-presentation results. Correlate those cumulative
records by the preserved transition IDs and QPC/frame bounds. Only then write
the raw files, generate the receipt index, and calculate byte lengths and
SHA-256 hashes in one local batch. Missing optional cumulative detail marks
only that evidence facet `INCONCLUSIVE`; a preserved terminal receipt remains
valid transition evidence.

During that same offline finalization, hash the exact deployed DLL and verify
its adjacent build manifest against the bound Build ID, artifact hash, and byte
length. Preserve the resulting receipt under
`raw/startup/deployment-verification.json`. Missing or mismatched deployment
proof makes reporting incomplete but does not rewrite completed render rows.
Pass those already-resolved paths to the offline finalizer as
`--artifact-path` and `--manifest-path`; never discover or hash them in the
live startup/measurement cell.

The post-measurement finalizer must also walk every JSON file below `raw/` and
write `evidence-values.csv` as a lossless long-form analysis table. Give every
row its relative source path, lane/pass/ordinal when present, RFC 6901 JSON
Pointer, JSON value type, and JSON-encoded value. Do not use a field allowlist:
retain false, zero, null, strings, numbers, and explicit empty arrays/objects.
This export makes every retained producer value queryable without flattening
different timeline facets together or treating a terminal delta as a missing
mutation-boundary event.

When the live runner is interrupted at baseline, retain `raw/live-result.json`
and the exact baseline waiter receipt. The offline finalizer validates their
run/build ownership and emits an `INTERRUPTED` zero-of-expected report with
reporting `INCOMPLETE` and memory `repeat_not_completed`; it performs no live
DevBench call and does not require a measured transition receipt.

Keep Task 2 classifications per transition. Report counts for `PASS`, `FAIL`,
and `INCONCLUSIVE`, but never calculate an aggregate Task 2 or overall verdict.
Retain every nonzero producer violation counter as a reported pipeline
observation. Promote it to authoritative `FAIL` only when the cycle audit is
complete, its owner matches the qualification, the required mutation boundary
has matching session/transition/token ownership, and the first-offender timing
places that violation in the claimed phase. If any authority or ordering fact
is missing, mismatched, or impossible, keep the counter visible, record the
producer-invalid reason, and classify Task 2 `INCONCLUSIVE`. Never turn an
unowned counter into either a pipeline failure or a synthetic zero.
Producer `presentationCycleAudit.evidenceComplete` describes bounded-storage
retention only. Transition evidence is complete only after dispatch, a matching
audit owner/token, at least one eye observation, all four decisive violation
counters, and schema revision 14 or newer are present. Older schemas and
cancelled pre-dispatch owners remain `INCONCLUSIVE` even when their storage flag
is true. Keep raw mixed/unproven stereo totals diagnostic; only the four
`violations` counters can decide Task 2.
Emit each reported counter's own authority status and reasons so one exact
violation is not erased merely because a different counter is mismatched.
Omit legacy aggregate verdict fields instead of populating them with sentinel
values that a consumer could misclassify as a failure.
An absent boundary remains `not_exposed` for that row while its dispatch and
terminal generations, epochs, resource revisions, paths, backends, frames, and
QPC values remain available for diagnosis. This finalization-only rule does not
add or reorder startup, positioning, baseline, handoff, pacing, or mutation
steps.

Finalization runs after a complete pass and after every interrupted pass while
the direct control plane remains callable. Stop only task-owned sessions with
their exact returned guards, disable the task-owned profiler state, and verify
all owners inactive. A semantic row failure never skips cleanup. If transport
is genuinely unavailable, preserve the guards, warn the user that sessions may
remain active, and make no speculative cleanup call.
