# Fixed grip/neutral diagnostic lifecycle

`tools/steamvr-null-control/Invoke-NullHmdGripDiagnostic.ps1` is a task-specific
composition of existing owner controls, not a second controller API. It owns
startup, one fixed A/B diagnostic, shutdown, recovery and result publication.
Tasks retain their MO2 setup; this standalone diagnostic does not acquire MO2,
launch Skyrim, build/install a provider, calibrate poses or change bindings.

The experimental live adapter is source-only until exact native fixture hashes,
ABI and injected entry-point evidence are reconciled. Offline PASS is not live
qualification or authority to execute. A live run requires a separately selected
diagnostic and the `-Live -PlanPath -ExpectedPlanSha256` interface. Direct Live
without an independently selected hash fails before admission. It rejects running
Skyrim/loader, an existing runtime, non-null baseline ownership and changed pins.

The plan schema is `null-grip-session.1`, diagnostic `fixed-grip-neutral-A-B`,
`standalone:true`. Exact absolute `{path,sha256}` pins are required for
`nullControl`, `headControl`, `controllerControl`, `boundedProcess`, `fixture`,
`python` (the stable configured entry point), `atomics`, installed `provider`,
`openvr`, `poseProbe`, `nullProfile`, and a finite complete `fixtureDependencies` array.
`toolkitRoot` identifies the supported entry-point layout; the pin set must use
those exact paths, not an arbitrary controller-loader interface. `python` must
address `CODEX_PYTHON`; batch delegation runs within the owned native A/B worker.
Explicit runtime paths: `settingsPath`, `openVRPathsPath`, `steamVRRoot`,
`serverLogPath`, `driverRoot`. The coordinator additionally requires the exact
bounded-process path/hash. Do not manufacture a plan before the native handoff.
Use the current supported bounded-process owner with `launched`, `exitVerified`,
`jobQuiescent` and `deadlineSatisfied` attempt proofs. The older contract-v2
callee on an isolated historical branch cannot establish these facts and is
not a supported diagnostic owner. Pin the all-integrated owner until its
reviewed dependency is present in curated main; do not weaken the receipt gate.
The live evidence root must be new and beneath that fixed fixture's `evidence`
directory, with ordinary non-reparse ancestors. Invalid output placement is
rejected before the coordinator creates the root or starts a worker.

The coordinator exclusively claims the whole lifecycle with `CreateNew` on
`<EvidenceDirectory>.outer-session.json` before creating the evidence directory.
The claim records a random session nonce, canonical root, coordinator PID and
creation FILETIME. Its handle prevents competing writes for the entire run;
its immutable bytes remain retained afterwards. An existing claim or root is a
refusal, not permission to adopt or recover its files. A losing contender never
launches a worker or enters stop, restore or publication.

Every worker launch carries that exact identity. Workers verify the claim and
live creator before reading lifecycle ownership, invoking controls, publishing,
or cleanup. Lifecycle records carry the same `outerSession` and are checked on
read; separately pinned native payloads retain their existing producer schema
and are consumed only inside the admitted owned worker. A foreign or stale
creator is rejected outside the worker's cleanup `try/finally`.

Abrupt worker death still uses the original live coordinator's separate bounded
recovery worker. Coordinator death retains the claim and receipts and refuses
automatic takeover. Auto-Tools must explicitly recover using the existing exact
receipt-bound owner controls after verifying the stale creator and owned
survivors; restarting this diagnostic is not a recovery interface and must not
delete its claim or reuse its root. A new run requires a distinct evidence root.

When the completion service does not inherit shell-only `CODEX_PYTHON`, use the
task-shaped `Invoke-NullHmdGripSelectedRun.ps1` envelope. Supply the exact selected
plan/hash and independently verified configured Python path/hash. It refuses a
different plan binding or conflicting existing process configuration, sets only
the invocation's process environment, and calls the fixed pinned coordinator
with the unchanged240-second common/90-second recovery reserve. Descendants
inherit the binding; no global/service environment rewrite or Python fallback
occurs. `-ValidateOnly` verifies this same binding and all plan pins without
creating evidence or invoking runtime controls. A new live attempt still needs
its own explicit selection, unique completion job and new evidence root.

Selection is retained across every stage, not merely checked at initial launch.
The wrapper locks and hashes the proposal and coordinator before executing it.
The coordinator authenticates Common before loading it, and holds read-only
handles denying write/delete to the plan, all primary pins and finite dependency
pins until its stages terminate. Coordinator, Worker and Common each require
exactly one lifecycle pin. It stages the original plan bytes with CreateNew in
the unique run root and retains its exact hash in `selected-inputs.json`.
Every session, recovery, publication and native worker receives that expected
plan hash plus Worker/Common hashes and verifies them before loading Common or
entering lifecycle cleanup. Concurrent in-place deployment is refused by the OS;
it cannot silently replace the originally selected recovery authority. Handles
are released after terminal completion. Coordinator death still requires the
explicit stale-owner recovery procedure above, not adoption of its old plan.
This is cooperative same-user selection custody, not a hostile-user security
boundary or permission to modify any pinned input while the run is active.

`Test-GripSelectedCustody.ps1` uses a disposable pinned toolkit to exercise
missing/changed plan admission, changed Common/Worker before execution, exact
staged bytes, and attempted write/replace at session/recovery/publication launch
boundaries. It invokes real worker admission with a different self-consistent
plan, requiring refusal before controls or cleanup. Its process-owner responses
are deliberately injected failures: it must not publish or claim clean handoff.
These selection tests complement, rather than replace, actual bounded-job and
offline lifecycle tests. No installed runtime or native provider is invoked.

## Selected observational boundary

Mapping selected `after-shutdown-return-and-worker-exit`, not independent
SteamVR client unregistration. A complete, non-injected A result must match the
exact admitted instance and inherited worker ceiling, report valid control and
neutral baseline, and retain successful shutdown `completed-return`, known
close-clock bounds, no partial evidence or post/close errors. The existing
bounded owner must separately prove one zero-exit, uncancelled A worker and
its entire job quiescent. Unknown/hung/cancelled close or worker exit stops
dispatch and enters Main-owned recovery. A fresh controller inspection must
then prove the same instance, owner/deadline zero, healthy input, and both hands'
native masks/scalars/axes neutral before the compiled probe can run.

`applicationClose.externalUnregistrationVerified:false` is mandatory Boolean
false; omission, null, a number/string, or true is rejected. Shutdown return and
OS/job exit do not prove that SteamVR completed its internal client removal.
No extra Background observer, guessed server-log disconnect marker or arbitrary
delay is introduced. This diagnostic cannot attribute later behavior to runtime
unregistration. The existing compiled probe's 100 neutral samples and zero
input-event qualification criteria are unchanged.

Evidence retains native shutdown-end ticks, a bounded worker-exit observation
interval, the subsequent qualify invocation interval and measured delays in
the same Windows GetTickCount64 domain. Existing controls do not expose internal
compiled-probe launch/init tick stamps: those events are only enclosed by the
recorded invocation interval, explicitly `exactTicksKnown:false`. This is an
observability limitation, not fabricated precise launch/init measurement.

One absolute Windows GetTickCount64 end applies to admission, assay, recovery
and publication. A positive-work cutoff reserves recovery time. Startup,
assay and normal stop live inside one owned job; a child surviving the startup
parent remains owned until shutdown. A stall cancels that whole job before the
positive cutoff. A separate bounded worker then uses receipt-bound restoration
and verifies exact settings/registration hashes inside the same common end.
Unknown cleanup is reported as unknown, never a clean handoff. Original failure
and subsequent cleanup errors remain distinct. No phase implicitly retries.
Recovery previews the exact receipt-bound restore with supported `-WhatIf`,
requires its success, then performs restore within the same inherited budget.
A rejected preview blocks actual restore and a verified-clean claim; it never
authorizes a fallback. As documented by the controller, command entry may first
reconcile a pending authoritative transaction even for inspection/preview;
`-WhatIf` prevents a new requested restore, not mandatory prior recovery.
The coordinator returns exit2 for unknown cleanup or incomplete publication;
exit0 describes a completed diagnostic with verified cleanup, not product PASS.

Final result IO runs in a separately supervised worker. It stages at most eight
MiB, checks the inherited deadline immediately before an atomic unique-path
publication, and never writes a product-acceptance or canonical-ready pointer.
An incomplete publication leaves only nonauthoritative staged evidence. The
coordinator returns its compact envelope without a final filesystem write.
Its own preflight/OS calls are not realtime-guaranteed; an existing completion
owner provides the outer cancellation boundary. Do not claim a hard realtime
filesystem guarantee or live SteamVR job inheritance from disposable fixtures.

Offline tests invoke the same entry point with a fixed enumerated `-OfflineCase`.
There is no arbitrary adapter-loader flag. They spawn uniquely owned disposable
children, exercise startup-parent exit and real job cancellation, and manipulate
only new fixture files beneath the declared evidence directory. They never load
OpenVR DLLs or production maps. The native owner separately tests actual A/B
entry-point semantics, independent all-axis neutral gates and event/sample caps.
The suite's original 12 cases plus 13 boundary-refusal cases and one rejected
restore-preview case exercise the real
nested A worker's exit/job receipt. Runtime responses and clock/result failure
injections remain simulated; these tests do not qualify live SteamVR inheritance,
client unregistration, input consumption, or the experimental adapter itself.
`Test-GripOuterCustody.ps1` concurrently releases two real coordinators against
one absent root, checks exclusive winner-bound lifecycle evidence and clean
winner completion, and rejects a foreign recovery worker before cleanup.
`Test-GripNativeContract.ps1` additionally rejects six missing/malformed
unregistration-field variants of an otherwise accepted native result.
