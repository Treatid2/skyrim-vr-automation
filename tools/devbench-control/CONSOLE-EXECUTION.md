# Captured console execution receipt

Explicit `console {action:exec,command:<exact>,capture:true}` qualifies only the
documented ConsoleHandler four-field receipt: the exact string command,
Boolean `completed:true`, `queued:false`, `capturing:true`. No additional
arguments or payload fields, redirects, error objects, multiple replies or
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

Run `Test-ConsoleExecutionEvidence.ps1` for typed/negative receipt tests.
