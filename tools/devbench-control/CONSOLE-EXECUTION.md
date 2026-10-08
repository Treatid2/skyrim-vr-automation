# Captured console execution receipt

Explicit `console {action:exec,command:<exact>,capture:true}` qualifies only the
documented ConsoleHandler receipt: the exact string command,
Boolean `completed:true`, `queued:false`, `capturing:true`, and optionally
a positive native integer `windowId`. Legacy four-field replies remain valid,
but cannot establish a capture generation. No additional arguments or unknown
payload fields, redirects, error objects, multiple replies or
Boolean coercion are admitted. Existing identity, transport, unsafe-command and
workspace-save guards remain in force. This is not a new dispatch interface.

`completionBasis:execution-only` means the fenced invocation completed.
It does not prove that Skyrim accepted the desired operation, that an INI
setting changed, that a scene is calibrated, or that captured output is lossless.
Retain one separate qualified fenced read and actual desired-state observation.
Never replay an accepted/lost mutation because its original outer controller
receipt lacked a semantic adapter.

The exported pure `Get-DevBenchConsoleExecutionStatus` accepts exact Arguments
and decoded Content for offline or existing direct-lane evidence. It performs no
connection, call, retry or mutation. Current runtime/tool schema, ordered request
identity and native MCP non-error evidence remain caller prerequisites. A later
offline qualification does not rewrite the original failed controller envelope.
Save/load redirects must use their managed game contracts; uncaptured queued
commands are not qualified by this adapter.

## Uncaptured queue receipt

Explicit `console {action:exec,command:<exact>,capture:false}` uses the separate
three-field native queue receipt: exact string command, Boolean `queued:true`
and `capturing:false`. Extra fields/arguments, redirects, malformed or multiple
payloads refuse. Existing mutation identity, save and unsafe-command guards stay
required. `console-uncaptured-dispatch-queued` and `completionBasis:dispatch-only`
prove queue admission only; `executionCompleted`, `desiredEffectVerified` and
`outputQualified` stay false. The pure exported `Get-DevBenchConsoleDispatchStatus`
performs no calls. Native non-error MCP evidence and exact answering runtime
remain prerequisites. A later qualification never rewrites old controller output.
Observe arrival/current state separately on the selected lane. Never replay a
queued or uncertain mutation because an arrival or compiler probe fails.

Run `Test-ConsoleExecutionEvidence.ps1` for typed/negative receipt tests.
See [CONSOLE-WINDOWS.md](CONSOLE-WINDOWS.md) for guarded immutable read admission
and `Test-ConsoleWindowEvidence.ps1` for window-ID/loss/truncation tests.
