# Fixed grip/neutral diagnostic lifecycle

`tools/steamvr-null-control/Invoke-NullHmdGripDiagnostic.ps1` is a task-specific
composition of existing owner controls, not a second controller API. It owns
startup, one fixed A/B diagnostic, shutdown, recovery and result publication.
Tasks retain their MO2 setup; this standalone diagnostic does not acquire MO2,
launch Skyrim, build/install a provider, calibrate poses or change bindings.

The experimental live adapter is source-only until exact native fixture hashes,
ABI and injected entry-point evidence are reconciled. Offline PASS is not live
qualification or authority to execute. A live run requires a separately selected
diagnostic and the mandatory `-Live -PlanPath` interface. It rejects running
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
The live evidence root must be new and beneath that fixed fixture's `evidence`
directory, with ordinary non-reparse ancestors. Invalid output placement is
rejected before the coordinator creates the root or starts a worker.

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

`externalUnregistrationVerified:false` remains explicit. Shutdown return and
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
