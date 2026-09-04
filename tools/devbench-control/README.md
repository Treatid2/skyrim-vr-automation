# DevBench Control

`Invoke-DevBenchControl.ps1` lists and calls the MCP tools exposed by a running
CSX DevBench server. Supply runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`; no machine-specific path is compiled into the
client.

```powershell
.\Invoke-DevBenchControl.ps1 list -RuntimePath 'C:\Path\To\runtime.json'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}' -RequireSuccess
.\Invoke-DevBenchControl.ps1 wait -Condition noBlockingMenu -TimeoutSeconds 30
.\Invoke-DevBenchControl.ps1 wait -Condition mainMenuReady -TimeoutSeconds 30
.\Invoke-DevBenchControl.ps1 wait -Condition toolAvailable `
  -Tool communityshaders.profiler_api -TimeoutSeconds 600 `
  -ProgressLogPath C:\Evidence\CommunityShaders.log
.\Invoke-DevBenchControl.ps1 wait -Condition serviceReady `
  -Tool communityshaders.upscaling_api
```

The client communicates only with the loopback endpoint and reports structured
JSON. By default it binds the endpoint to the owning listener PID and DevBench's
off-thread `inspect health` identity before returning. Runtime metadata may add
`pid`/`processId` and `exe`/`executable`; supplied values become strict
expectations. Pass `-EvidenceDirectory` to preserve this binding with the run.
Each invocation writes a uniquely named binding receipt, so parallel calls do
not overwrite one another. Use `-EvidenceLabel` to give that receipt a stable
human-readable label within the unique filename.
The controller also persists an invocation journal before dispatch. It records
the requested tool and arguments, dispatch boundary, last verified runtime
identity, transport retries, and terminal result. If the target exits during a
synchronous call, the failed result returns `invocationEvidencePath` instead of
discarding the last known request boundary. Without an explicit evidence
directory these journals use the local Skyrim VR automation evidence root.
When available, add `buildId`, `artifactPath`/`dllPath`, and
`artifactSha256` to runtime metadata (or pass their explicit parameter
equivalents). The controller queries the CSX registry bridge and hashes the
deployed DLL, binding source build, physical artifact, endpoint, and process in
one evidence record.

`ok` reflects transport success unless `-RequireSuccess` is supplied. Every
call also reports `transportOk` and a normalized `semantic` result, so an API
payload such as `idempotency_conflict` cannot be mistaken for successful work.
The `communityshaders.profiler` bridge has a contract-specific adapter because
its legacy response does not carry a generic top-level `ok`: `status` must
contain a frame-bearing status object, while `enable` and `disable` must report
the requested observed state. This keeps profiler collection fail-closed
without misclassifying a valid bridge response as unknown.
Replay completion receipts containing only scheduler facts such as `done`,
`runId`, and `stepsRun` are classified as
`scheduler-complete-unverified`, not semantic success. A replay response must
include explicit `semantic`, `postconditions`, `outcomeChecks`, or `assertions`
evidence before `-RequireSuccess` will accept it. This proves that the requested
interaction outcome occurred instead of merely proving that the scheduler ran.
Nested `error.code`, `status`, and `result.state` values are classified. Use
`-ExpectedErrorCode producer_mismatch` when a guarded rejection is the intended
test outcome. Transient HTTP 429/502/503/504 responses and timeouts use bounded
exponential retry and are preserved under `transportRetries`.

The exact Skyrim VR console command `tfc 1` is denied wherever it appears in a
tool argument tree because it has a confirmed player-camera null-write crash
path under null-HMD automation. Prefer a naturally stationary scene for
benchmarks. `-AllowUnsafeTfc1` exists only for an explicitly accepted crash-risk
experiment and is never implied by a normal scenario call.

State-changing `game` calls are also default-deny. Direct calls and nested
scenario steps for `load`, `loadLast`, or `save` require
`-WorkspaceManifestPath`. `MainMenuOnly` and `FreshGame` deny all three;
`VerifiedFixture` permits only `load` with the manifest's exact
`saveFixture.loadName`; `dir` is required and must be the workspace profile's
exact `saves` directory. The same rule covers console `load`/`save` commands,
which DevBench reroutes internally to the game tool. `-AllowUnprovenGameMutation` is an explicit policy
bypass for work outside a managed workspace; it is never inferred from copied
save availability.

`wait -Condition noBlockingMenu` polls the menu tool client-side, ignores only
the explicitly listed `-IgnoredMenus` (HUD by default), and always reports the
actual timeout and final observation. This avoids the server-side `noMenu`
condition being held open forever by Skyrim's permanent HUD menu.

`mainMenuReady` instead requires `Main Menu` to be open, permits Skyrim VR's
normal `Mist Menu` and `Fader Menu` overlays, and rejects every other menu
outside `-AllowedMainMenuMenus` (HUD, Main Menu, Mist Menu, and Fader Menu by
default). It represents a
usable front-end state without pretending that Skyrim's persistent menus have
closed.

`toolAvailable` repeatedly refreshes the authoritative tool inventory rather
than freezing the initial list. `serviceReady` additionally calls a controller-
qualified read-only probe and understands accepted and retryable service states,
including structured errors that explicitly declare `retryable: true`. The
controller inspects the authoritative
`inputSchema`: an empty object is used only when the schema permits it, while a
versioned service requiring `contractMajor`, `clientId`, `commandId`, and
`action` receives a generated `registry` (or `capabilities`) envelope. Unknown
required fields fail closed instead of dispatching a malformed or potentially
mutating probe. Explicit `-ArgumentsJson` is forbidden for `serviceReady`;
use `toolAvailable` when registration alone is sufficient, or add a reviewed
tool-specific probe adapter. Arbitrary non-empty responses remain unknown and
cannot establish readiness. Both
waits back off to `-MaxPollMilliseconds` and collect bounded PID/CPU/memory and
optional explicit-log samples. A missing target with increasing CPU is reported
as `api-waiting-behind-initialization`; a quiet missing target is
`api-absent-or-not-registered`.

The same `-TimeoutSeconds` value is the total transport budget for `list`,
`call`, and `wait`. Blocking calls such as a scenario with declared server-side
waits may therefore use the caller's full bounded budget instead of failing at
an unrelated fixed 15-second HTTP timeout. Mutation transport failures remain
indeterminate and are never replayed automatically.

All bounded waits keep explicitly transient 404/429/502/503/504, timeout, and
main-thread-busy probe failures as unsatisfied observations after the short
transport retry budget is exhausted. The outer deadline therefore survives a
normal load or compile transition, while non-transient probe failures still
terminate immediately and the last transient error remains in the result.
The initial MCP initialize/initialized/tools-list exchange is part of that same
outer wait state machine, so a temporarily unavailable listener cannot exhaust
the short transport budget before the requested timeout begins.

`playerLoaded` is transition-fresh by default: the wait must observe an
unloaded state before accepting loaded. This prevents the prior world's cached
`true` from satisfying an asynchronous load. Use `-AcceptAlreadyLoaded` only
when the caller intentionally wants a current-state check rather than proof of
a new load transition.

Runtime identity is refreshed after a waited-for service registers. The binding
reports listener process identity, every available CSX producer registry,
deployed artifact hash, completeness, and the exact missing fields.

Use `-ToolFilter` or `-NamesOnly` to reduce a large authoritative `list`
response. `-NoExit` keeps failures as structured JSON without terminating a
larger PowerShell orchestration host. A missing runtime file, identity mismatch,
or unreachable endpoint is a blocked result.
