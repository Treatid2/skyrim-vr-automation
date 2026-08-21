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
.\Invoke-DevBenchControl.ps1 wait -Condition toolAvailable `
  -Tool communityshaders.profiler_api -TimeoutSeconds 600 `
  -ProgressLogPath C:\Evidence\CommunityShaders.log
.\Invoke-DevBenchControl.ps1 wait -Condition serviceReady `
  -Tool communityshaders.upscaling_api `
  -ArgumentsJson '{"contractMajor":1,"clientId":"test","commandId":"registry-1","action":"registry"}'
```

The client communicates only with the loopback endpoint and reports structured
JSON. By default it binds the endpoint to the owning listener PID and DevBench's
off-thread `inspect health` identity before returning. Runtime metadata may add
`pid`/`processId` and `exe`/`executable`; supplied values become strict
expectations. Pass `-EvidenceDirectory` to preserve this binding with the run.
When available, add `buildId`, `artifactPath`/`dllPath`, and
`artifactSha256` to runtime metadata (or pass their explicit parameter
equivalents). The controller queries the CSX registry bridge and hashes the
deployed DLL, binding source build, physical artifact, endpoint, and process in
one evidence record.

`ok` reflects transport success unless `-RequireSuccess` is supplied. Every
call also reports `transportOk` and a normalized `semantic` result, so an API
payload such as `idempotency_conflict` cannot be mistaken for successful work.
Nested `error.code`, `status`, and `result.state` values are classified. Use
`-ExpectedErrorCode producer_mismatch` when a guarded rejection is the intended
test outcome. Transient HTTP 429/502/503/504 responses and timeouts use bounded
exponential retry and are preserved under `transportRetries`.

`wait -Condition noBlockingMenu` polls the menu tool client-side, ignores only
the explicitly listed `-IgnoredMenus` (HUD by default), and always reports the
actual timeout and final observation. This avoids the server-side `noMenu`
condition being held open forever by Skyrim's permanent HUD menu.

`toolAvailable` repeatedly refreshes the authoritative tool inventory rather
than freezing the initial list. `serviceReady` additionally calls the supplied
read-only action and understands accepted and retryable service states, including
structured errors that explicitly declare `retryable: true`. Both
waits back off to `-MaxPollMilliseconds` and collect bounded PID/CPU/memory and
optional explicit-log samples. A missing target with increasing CPU is reported
as `api-waiting-behind-initialization`; a quiet missing target is
`api-absent-or-not-registered`.

Runtime identity is refreshed after a waited-for service registers. The binding
reports listener process identity, every available CSX producer registry,
deployed artifact hash, completeness, and the exact missing fields.

Use `-ToolFilter` or `-NamesOnly` to reduce a large authoritative `list`
response. `-NoExit` keeps failures as structured JSON without terminating a
larger PowerShell orchestration host. A missing runtime file, identity mismatch,
or unreachable endpoint is a blocked result.
