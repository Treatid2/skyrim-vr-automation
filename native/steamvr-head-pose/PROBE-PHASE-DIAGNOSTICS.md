# Optional native application-probe phase diagnostics

`csx_openvr_pose_probe --require-controllers --diagnostic-phases` emits flushed,
fixed-domain `CSX_OPENVR_PROBE_PHASE_V1` records on stderr. The normal stdout
JSON observation and qualification checks are unchanged. Unknown/duplicate CLI
flags still fail before OpenVR initialization. Normal invocation emits no phase
records. The public null controller exposes default-off `-ProbeDiagnosticPhases`
and forwards it only to the existing admitted probe invocation; all package,
creator, continuity, one-attempt and ten-second-share guards remain in force.
Older probes reject the new flag and cannot qualify: install a new exact
Broker-verified package under supported custody controls before diagnostic use.

Each call has a monotonically assigned call ID, entered and completed/aborted
records, sequence and optional sample/hand index. The phase identifies the
specific initialization, pose/property/compositor/controller call. Event polling
is one bounded drain phase (at most256 polls); no per-event logging. A timeout
with an entered call and no matching completed record identifies the last
observed unfinished boundary, not a root-cause proof. Nested compositor-interface
records distinguish interface resolution from GetLastPoses. Exceptions record
aborted, never completed. Shutdown is observed too; final stdout alone cannot
prove process exit. Preserve the original bounded result and raw stderr.

At most4096 fixed-domain records plus one explicit truncation marker are emitted,
below0.76MiB with the192-byte per-line bound. Current100-sample successful path
uses2430 records; shorter refusal paths use fewer. After truncation, last entered
and completed coverage is incomplete and must not identify a later blocking
phase. Pipe write/drain failure also limits diagnostic coverage. No logging
thread, runtime retries, wait enlargement, provider registration, controller
inputs, calibration or scientific acceptance is added.

The first next live condition is a matching new native package and this opt-in
flag on ONE authorised startup under the original ten-second probe bound. Mapping
owns that live qualification. Retain last entered/completed records, package and
creator proofs plus exact cleanup; do not infer the historical blocked call from
empty streams or rerun without the diagnostic change.
