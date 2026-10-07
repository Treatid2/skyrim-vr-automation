# Native console window evidence

Captured exec admits exactly command/completed/queued/capturing plus optional
positive integer windowId. The command must match exactly, completed/capturing
must be Boolean true, and queued Boolean false. A four-field legacy receipt
remains execution-only and cannot supply a generation guard.

On the already selected controller lane, a retained modern capture can be read
with call -Tool console -ArgumentsJson '{"action":"read","windowId":1,"maxLines":200}'
and -RequireSuccess -MaxTransientRetries 0, keeping the existing runtime/build
expectations. Supply the ID from the admitted exec receipt, not an invented ID.
Only the runtime owner executes this read. Do not issue a new capture to recover
an uncertain exec or merely because a read refuses.

The read is the latest closed, drained immutable snapshot only. Active/draining
or a replaced generation returns 409; there is no historical lookup. windowId is
a process-local generation, not authentication, an MCP session handle, or
cross-process identity. Bind exec and read to the same process PID/start and
runtime/build; a successful numeric match alone never proves that binding.

Read admission requires exact known top-level fields, count/string-array
agreement, both markers, supported print/buffer source, no timeout or loss,
and typed known diagnostics. Modern receipts require the complete native diag
shape and zero printLoss counters. Print also needs an active hook, zero drops
and printPayloadLines matching the returned count, refusing silent tail clipping.
The native maxLines range is 1..20000, default 200. Because modern buffer output
has no retained total-line count and maxLines clips silently, its full-output
qualification requires maxLines 20000. A refused smaller buffer read is retained
evidence, not permission to replay the command.

Legacy windowless reads remain retained raw evidence, but report
outputQualified false: their total-line completeness is unproved. Clean fences,
count/array agreement, zero drops and lossPossible false do not exclude native
tail trimming. Even a full-capacity request cannot invent missing producer
telemetry. No legacy read refusal permits command replay.
Unguarded modern reads also report windowMatched false. Successful
read admission proves captured-output structure only: it does not parse an
INISetting value, verify the command's desired effect, prove visible illumination,
or establish asynchronous engine-wide quiescence.

Unknown fields, errors, redirects, malformed IDs/counters, timeout, loss,
missing markers, replaced generations and multiple payloads fail closed.
