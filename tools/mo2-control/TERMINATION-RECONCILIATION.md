# Accepted game termination: terminal evidence authority

An accepted exact termination has a session-local random request ID, retained
target set and primitive result. It is never automatically repeated. Older,
unknown, missing or contradictory reconciliation evidence remains pending.

Reporting retains a pending lifecycle state, then publishes a bounded (1 MiB)
content-addressed proof candidate. The candidate explicitly says `resolved=false`
and `recoveryRequired=true`; its existence is not terminal success. Its original
accepted request, cleanup observations and all reporting flags are immutable.
`receiptPublished` in the authoritative record means this proof candidate exists
and matches its byte length/digest, not that a later public projection succeeded.
`receiptPath` names that actual proof candidate. The local completed-call result
separately exposes `publicReceiptPath`/`publicReceiptPublished` for the projection.

One serialized owned-session mutation validates the closed schema, exact current
session/request/targets/result, typed successful cleanup facts, empty errors and
proof binding, and commits both `resolved=true` and terminal lifecycle status.
Only then may `mo2-terminate-game.json` project that committed record. Failure of
the final commit leaves the session pending and no success-shaped public receipt.
Failure of the subsequent projection is a reporting failure with `projectionFailed`
and retained resolved authority, not another termination opportunity. Status derives
the terminal state from validated authority; stale reporting cannot reopen it.

Targeted and untargeted status expose recovery required for pending/malformed
accepted evidence. Release, including preview and its serialized final transition,
refuses it even when process/deployment sets are empty. A verified next launch
archives the resolved record before clearing the prior request; pending launch
reset is refused. Physical process/handle/Unlock/RootBuilder predicates are unchanged.

The private owner reporting helper can finish the same accepted request using its
retained independently verified cleanup facts; it never dispatches termination or
Unlock. This is not a new generic public recovery command, permission to invent
missing cleanup evidence, or an upgrade of legacy requests. Existing unresolved
live sessions still require their separately authorised exact-owner recovery route.

Proof reads use a reparse-free path chain and a read-only stream denying cooperating
writes/deletes while reading. The record is content-bound, not an atomic multi-file
transaction against arbitrary external maintenance or an in-memory process proof.
Later unavailable/changed proof bytes keep lifecycle operations held. Original
proof candidates and failures remain retained; no overwrite or garbage collection
of old session evidence is implied.

The copied public-entry fixture exercises final-write-only refusal, status/release
holds, exact owner reporting reconciliation, projection failure, malformed terminal
schemas, proof mismatches and no replay. OS/process/UI and lease adapters are
test-owned; this is offline qualification, not live termination evidence.
