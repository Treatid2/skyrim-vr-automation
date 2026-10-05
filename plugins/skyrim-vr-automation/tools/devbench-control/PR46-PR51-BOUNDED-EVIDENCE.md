# PR46 / PR51 finite source-bound evidence

Native destination correction (confirmed exact f4): the manifest's effective
capture retains the requested parent directory (and optional resolved parent).
Native DirectoryLease generates exactly `CS_sequence_<requestId>` beneath it;
child effective captures, image files and manifest publication belong to that
exact leaf. The qualifier derives this owned leaf without filesystem access and
never substitutes it into the raw manifest's effective recipe. A parent or a
different request's leaf cannot qualify a child. Preparation failure may retain
`partialPath:""` only in the exact failed/destination_preparation_failed/
preparation, zero-scheduled/zero-artifact/unwritten-final shape. Empty strings
are preserved, not converted to null or accepted as ordinary artifact paths.

This is a small evidence service, not another runtime orchestrator. Use native
DevBench controls on the already-selected transport. The two modules below only
inspect retained payloads; they do not connect, dispatch, wait, retry, launch,
allocate, delete, restore or reset anything. They leave raw evidence unchanged.
Auto-Tools owns shared cleanup; experiment owners retain their calibrated setup.

Pinned source inspected: CSX `217992d1e29e55a707d6e41c3ca111b2154904fa`,
`src/Features/ScreenshotApi.cpp` (sequence admission/cancel, MakeReceipt,
MakeSequenceReceipt, generated children and manifest publication) and full
`src/Features/Upscaling/FSRColorContractDevBenchBridge.cpp` / policy header.
This historical contract is not admission of Builder's next candidate. Require
the new exact source/build/artifact receipt, fresh typed catalog and answering
process/session identity before using these expectations. Schema2 minor1 is
explicitly supported; other pairs and source-incompatible shapes refuse.

## PR51 exact small request

Native outer fields: `contractMajor:1`, action, clientId, commandId. Retain one
client ID for the finite case; every command gets its own fresh command ID.
`sequence_start` takes a **sequence.capture**, not a top-level capture:

```json
{
  "contractMajor": 1,
  "action": "sequence_start",
  "clientId": "<this-case-client>",
  "commandId": "<one-start-command>",
  "expectedBuildId": "<actual-admitted-build>",
  "sequence": {
    "frameCount": 3,
    "useSettings": false,
    "schedule": { "basis": "wall_clock", "intervalMs": 500, "startDelayMs": 0, "pausePolicy": "hold" },
    "backpressure": { "policy": "abort", "maximumConsecutiveSkips": 1 },
    "failurePolicy": "abort",
    "capture": {
      "source": { "kind": "hmd_submission", "fallback": "reject" },
      "outputs": [
        { "view": "left_eye", "encoding": { "format": "png", "colourContract": "sdr_srgb" } },
        { "view": "right_eye", "encoding": { "format": "png", "colourContract": "sdr_srgb" } }
      ],
      "destination": { "policy": "absolute", "directory": "<active-managed-capture-workPath/new-case-directory>", "baseName": "frame", "overwrite": "never" },
      "clipboard": "none"
    },
    "packaging": { "frameManifest": true, "previewVideo": { "requested": false, "required": false } }
  }
}
```

Require current capabilities to advertise absolute destination, HMD submission,
stereo PNG and compatible frame/duration limits. Do not use global defaults or
adopt an existing directory. Native preparation creates an exclusive child
directory. `preparing` is successful admission, not image or terminal success.
`publication:unresolved` never qualifies. Parent artifact progress describes
**one manifest**, not six images. The actual image artifacts live in child
requests; their native kind is `sequence_frame`, clientId `sequence:<parentId>`,
commandId `frame:<ordinal>`. Their `requested` has four command fields and **no
capture subobject**. Do not manufacture requested.capture or use a still adapter.

Import `ScreenshotSequenceEvidence.psm1`. Feed the exact single native payload
and exact submitted arguments to `Get-DevBenchScreenshotSequenceEvidence`, with
explicit expected build, screenshot serviceSessionId and destination directory.
Retain the successful start result as `AcceptedOwner`; all later parent reads,
cancel/stop responses must pass it. Read-only `request_get` needs the same client,
a fresh commandId and the exact accepted requestId. No request adoption.

The normalizers are output-schema qualification, not transport/runtime admission:
retain the native MCP envelope and require its `isError:false`; controller users
retain `transportOk:true`, answering process/artifact identity and invocation
journal. A controller call that lacks this new shape adapter can return
`ok:false` with decoded native data: retain that failed envelope and use only
this exact typed evidence normalizer, not a generic unknown-success override.
Never treat a lost/undecoded response as this case or replay its mutation. These
modules do not alter generic `call.ok`, existing still semantics or host catalog.

Bound the **whole case** to60 seconds including reads/transport, with a128MiB
output budget. A native call may consume up to5 seconds in main-thread admission;
the transport allowance must exceed that budget but not extend the case deadline.
Do not stack independent60-second waits. Read the same owner until its native
state/UTC/progress and settled publication qualify; no transient event is needed.
Record request/events before and after; retain event cursor expiry/moreAvailable.
Cursor expiry is missing stream coverage, not permission to start again.

For a manifest checkpoint, read at most1MiB of its published bytes, then obtain
a fresh parent read. Parse child IDs for lookup only. Read each named child on
the same transport/client using `request_get`; feed raw payload/arguments and
the accepted parent evidence to `Get-DevBenchScreenshotSequenceFrameEvidence`.
Parent/frame/original command, producer/session, actual acquisition/schedule,
stereo planes and artifact hashes/dimensions are checked and retained.

Pass the exact bytes/path, fresh parent evidence and those child read results to
`Get-DevBenchScreenshotSequenceManifestEvidence`. A partial checkpoint remains
partial, never terminal proof. A final manifest must match the committed native
manifest byte count/hash/path/outcome/counts, and every child must independently
match its owned terminal read. Latest-frame selection uses the returned `frames`
through the existing `Get-CaptureInteractionLatestFrame`; never submit the
parent's JSON manifest as an image. Before promotion, separately verify each
actual file's size/hash against its qualified artifact receipt. Declared native
hashes do not prove local files exist. The service checks total declared output
bytes; the caller must also stop for observed output-budget/deadline violations.

### One cancellation

Use one separate three-frame case with `startDelayMs:2000`, otherwise the same
bounded recipe. Declare `preparing` or `running` as the checkpoint; observe it,
then send exactly one `request_cancel` with the same client and accepted parent
requestId and a fresh commandId. `commandAccepted:true` alone is not completed
cancellation. Follow with fresh reads of that same parent and retained partial
children. Require native `cancelled`/`cancelled_partial`, drained owned work and
a responsive status read. `alreadyTerminal:true` or `commandAccepted:false`
after finalization is a valid late-command observation but cancellation coverage
**not achieved**. Do not loop until a race is won. No accepted mutation replay.

### One safe failure

Builder must deliver the exact confined, non-destructive fixture and native
phase/error expectation. Preparation rejection, encoding failure, manifest
publication failure and worker cancellation are different coverage claims.
The normalizers preserve typed historical `preparation`, `packaging` and
`sequence_policy` errors on unsuccessful requests. Synthetic tests exercise
these shapes only; they are not a delivered worker fixture or live proof.
No disk exhaustion, global ACL changes, arbitrary injection or sabotage.

## PR46 negative cases

At most3 named negative calls, once each; no replay. Use fresh admitted colour
status before each and fresh typed status afterward. Keep RS/HDR/provider and
calibrated experiment setup unchanged. Malformed input is optional: omit it if
no currently supported native path exists. A client/schema refusal is not native
handler coverage; do not tunnel through scenario or bypass argument admission.

For build mismatch, keep the controller's expected answering build/artifact
**correct**. Deliberately change only native tool argument expectedBuildId to
a different well-typed64-hex string. The existing exclusive coded-error path
may qualify exact `producer_mismatch`; retain actual producer and unchanged
requested revision/flags/context readback. This is a producer guard, not CAS or
context-recreation coverage.

For stale CAS, supply actual native expectedBuildId, a definitely mismatching
nonnegative integer expectedRevision and the unchanged requested Boolean flags.
Zero is stale only when the fresh current revision is positive. The native217
rejection is **uncoded**: `accepted:false`, resultingRevision=current revision,
full current snapshot, error exactly
`expectedRevision did not match the current request`.

Do not pass `ExpectedErrorCode revision_mismatch`; that code does not exist.
Retain the failed controller/native call and its raw error. Import
`ColourCasRejectionEvidence.psm1` and call
`Test-DevBenchColourCasRejectionEvidence` with the exact before/rejected/after
native payloads, submitted arguments and admitted expected build. It checks
staleness, exact rejection, stable producer lineage and unchanged requested and
host/runtime context flags/generations. Normal dispatch frame/serial advance is
not mutation. Its successful **negative observation** never changes native set
acceptance or the original failed envelope. It is not a transport/handler proof:
the caller retains the single dispatch receipt, same process/service binding,
fresh ordered status reads and current-schema admission. No generic failed
outer receipt, text-only exception or malformed snapshot can substitute.

The existing colour-window runner is not duplicated. Its original-false flags
restoration limitation must be resolved before claiming arbitrary initial-state
restoration. Mapping's completed excursion02 cleanup must not be requested again.
