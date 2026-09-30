# Bounded RaceMenu diagnostic sweep

`racemenu_sweep.py` implements the three bounded menu phases from the retained
race-change/shadow protocol: paced playable-race qualification, rapid legal
two-race alternation, and enabled race/slider coverage. It does not launch,
deploy, edit game mods, open a transport, start capture, or stop capture. No
plugin-cache rotation is needed to use this exact durable source controller.

## Admission and ownership

The runtime owner must first qualify the final hash-paired RaceMenu candidate,
CSX pose guard, DevBench identity, null-HMD route, genuine fresh game and dump
window. This controller does **not** establish those prerequisites itself.
Create an owner qualification receipt using `qualification.example.json`:
copy the existing capture session's exact `sessionId` and `runtimeIdentity`,
retain the protocol SHA-256 and hash-verified evidence, and set a check true only
when the owner actually established it. The example deliberately refuses to run.
This is an explicit owner attestation backed by evidence, not an independent
native-module/pose-guard qualification or proof that a flag's payload supports
its claim. The full crash investigation remains owned by the caller.

Use only an **already-selected capture-controller lane**. Supply the exact
active `capture-interaction.session.json` and its unchanged capture controller.
`--confirm-existing-capture-lane` is mandatory. Every UI read/mutation and
observation goes through `Invoke-CaptureInteraction.ps1`; its existing runtime
identity guard remains enabled. `Invoke-SweepDevBench.ps1` only passes the call
to that controller's existing sibling DevBench wrapper with retries disabled
and a remaining deadline. It contains no HTTP/MCP implementation. The installed
generic semantic gate does not recognize Papyrus' `called`/`returned` receipt;
the adapter supplies a narrow qualifier for this sweep's exact UI methods only
when transport succeeded, the receipt is determinate and no known semantic
rejection exists. It retains the entire original controller envelope and labels
this as Papyrus-return-only, never actor-change completion. The engine still
requires the separate movie result and fresh resulting menu state.

If the run has already selected a healthy direct-MCP-only lane, **do not run
this controller or switch lanes for convenience**. This version does not provide
a direct-MCP adapter. A capture session created through the documented bundled
lane before its first live call is required. No lane-switch exception is added.

Do not operate other controls in this capture session concurrently. An exclusive
`.racemenu-sweep.lock` prevents two sweeps from running together. A stale lock
is a recovery decision for the runtime owner, never an automatic force-unlock.
The sweep rechecks the exact active session and runtime binding before and after
each wrapper call. It never acquires or steals an MO2 lease.

## Invocation

Use the stable `CODEX_PYTHON` entry point. Example PowerShell shape (replace every
placeholder with the runtime owner's exact qualified paths):

```powershell
& 'L:\Codex\shared\tools\python\python.cmd' -B `
  '<durable-controller-root>\racemenu_sweep.py' `
  --capture-session '<owned-capture>\capture-interaction.session.json' `
  --capture-controller '<exact-installed-plugin>\tools\capture-interaction-control\Invoke-CaptureInteraction.ps1' `
  --confirm-existing-capture-lane `
  --pwsh 'C:\Program Files\PowerShell\7\pwsh.exe' `
  --protocol '<retained-evidence>\protocol.json' `
  --qualification '<retained-evidence>\sweep-qualification.json' `
  --output '<active-managed-capture-workPath>\qualification-unique-run' `
  --phase qualification --maximum-changes 20
```

For `human-beast-alternation`, pass `--race-ids <live-Nord-ID> <live-Argonian-ID>`.
They must be different, offered and enabled in each current snapshot. IDs are
never guessed from localized names or retained across a missing live offering.
The phase defaults to 100 changes and zero additional pacing; it sends the next
input only after the last menu state is verified ready. This is *rapid legal*
serial control, not simultaneous inputs or a promise of a specific dispatch rate.
PowerShell/wrapper identity checks and evidence I/O add real overhead.

`race-slider-cross-product` defaults to a maximum of 200 changes. It visits
offered enabled races, then enabled `set-slider` controls at their live legal
minimum/interval-aligned upper endpoints. Every slot is read afresh. Use
`--include-sex` only when sex mutations are intended; it dispatches through
`SelectVRDiagnosticSex`, never the ordinary slider setter. It does not exercise
sculpt, paint/color dialogs, saved presets or hidden/disabled controls. It may
finish earlier as `coverage-exhausted`; the receipt reports the actual count,
not a fictitious 200-action success.

Phase/settle maxima are 900/30 seconds, bounded further by the retained protocol.
Defaults: qualifier pacing 2 seconds, other pacing 0, menu poll spacing 0.1,
per-wrapper worker deadline 10. These may be reduced, never expanded beyond
the protocol's ceilings. One worker/request is in flight; mutation retries are
zero. A ready old state may be read again under the same settle deadline, but
the mutation is never resubmitted. Late positive responses do not satisfy an
expired deadline. All new trace directories are exclusive; rerunning with the
same `--output` refuses before any input.

An optional `--stop-file <owner-signal-path>` stops inputs when that file exists.
The runtime owner can use it for a native guard rejection or other external
abort. This script does not invent a native guard API or claim to monitor crash
dump writers. Stop signals are checked between bounded worker calls, not via a
background collector. A synchronous call can take up to its declared worker
budget to return/cancel. The owner still preserves the ongoing capture and dump
window and diagnoses the cause.

For deterministic first-new-guard-event stopping, pass `--guard-log` with the
owner-resolved exact current `CommunityShaders.log`. The sweep retains file
identity and current EOF at admission and inspects only appended bytes before
and after its existing worker calls. It conservatively stops on **any new**
`[VR pose binding guard]` marker (including rejection/scene/allocation messages),
journals the exact byte offset and bounded excerpt, and preserves capture/game.
It does not match historical startup messages, start a collector/agent, mutate
the log, or read more than 64 KiB of new data in one check. Split markers are
recognized across bounded reads; replacement, truncation and excess growth
fail closed. Without this flag, only owner stop-file signalling is provided;
do not claim automatic first-native-event stopping. Detection is between
bounded worker calls, not an instantaneous native interrupt.

## Trace and failure contract

`trace.ndjson` is a flushed/fsynced ordered UTC journal containing qualification
identity/evidence, capture call intents **before dispatch**, complete returned
envelopes/stdout/stderr, live snapshots, exact mutation intent, callback result,
verified resulting menu state and frame observations, and a terminal result.
Existing capture `actions.ndjson`, recordings, screenshots and DevBench
invocation journals remain owned by that capture session and are not replaced.
`receipt.json` reports count, phase, timestamps and trace location. Successful
completion proves menu-state verification and advancing game frames only; it
sets `nativeFaultEliminated: false`. A callback's `dispatched` means neither
native rebuild completion nor intermittent-crash elimination.

Malformed/negative transport or menu responses, stale generations, wrong active
race/slider, inactive tab, missing player/recording, stalled or regressing frames,
identity drift, stop signal and deadlines stop the sweep. A worker timeout
cancels only the owned wrapper worker and preserves its partial output; an
uncertain callback is never replayed. Capture and Skyrim are deliberately left
running (`captureFinalized: false`) so the runtime owner can retain crash/dump
evidence. Session cleanup may be indeterminate after cancellation; reconcile
the same capture owner before any further input. The only removed file is the
exclusive sweep lock created by this run after its worker is terminal.

Use an active managed `Kind=capture` allocation for unique trace output; promote
and verify retained evidence on L: before releasing it. The controller neither
allocates scratch nor releases the owner's allocation.

## Offline validation

```powershell
& 'L:\Codex\shared\tools\python\python.cmd' -B .\tests\test_sweep.py
```

Fixtures use temporary isolated state, never Skyrim or network calls. Tests
cover dynamic generations, legal slider intervals, refusal/no-replay, pending
deadlines, inactive/disabled controls, frame failure, exclusive output, and
the real production entry point plus PowerShell policy adapter. Its sleeping
worker cancellation test verifies bounded return, lock release, no added
mutation and preservation of the previous valid receipt. Live qualification
must still be performed by the runtime owner against the exact deployed movie.
