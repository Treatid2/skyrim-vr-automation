# SteamVR controller control

`Invoke-SteamVRControllerControl.ps1` exposes the native controller v1 channel.
It does not install, start, stop, qualify, or change SteamVR settings. Use the
existing null/head-pose controllers for those operations and MO2 route admission.
The original head-pose v2 API is unchanged. The production null profile retains
`enableControllers=true` and `power.turnOffControllersTimeout=0`.

This requires the full-input native provider, not the earlier passive-only DLL.
The mapping is **opened**, never created, at `Local\CSXVRControllers-v1`.
`inspect` validates the header and a coherent telemetry snapshot, exact live
`vrserver` PID/creation FILETIME, and driver nonce. Each mutation supplies the
binding returned by inspect and its own stable random owner nonce. Reusing a
binding after SteamVR restarts fails before publication. Another active owner
returns `controller-owner-busy`; reset has no force bypass.

Invoke with PowerShell 7 x64. `new-owner` generates a local identity without
acquiring a native lease or touching the runtime. Retain it for the task; do not
regenerate it between commands. UInt64 fields (nonce, masks, sequences, FILETIME,
ticks) are canonical decimal **strings**, never lossy JSON floating-point numbers.

```powershell
.\Invoke-SteamVRControllerControl.ps1 new-owner -Compact
.\Invoke-SteamVRControllerControl.ps1 inspect -Compact
.\Invoke-SteamVRControllerControl.ps1 set -RequestPath <set.json> -Compact
.\Invoke-SteamVRControllerControl.ps1 tap -RequestPath <tap.json> -Compact
.\Invoke-SteamVRControllerControl.ps1 sequence -RequestPath <sequence.json> -Compact
.\Invoke-SteamVRControllerControl.ps1 reset -RequestPath <reset.json> -Compact
```

Requests are UTF-8 JSON files up to 256 KiB. `request.schema.json` describes their
shape. `set` requires both full hand snapshots and an integer lease of
100..60000 milliseconds. No implicit other-hand defaults or partial updates:
inspect a coherent pair under your ownership if you intend to preserve it.
Both hands are validated before any command bytes are written.

Standing positions are metres (+X right, +Y up, -Z forward). Quaternions are
WXYZ; finite squared norm must be strictly between .25 and 4, and native code
normalizes them. Trackpad/stick axes are [-1,1], trigger/grip [0,1]. Mask IDs are
system=0, application_menu=1, grip=2, trackpad=32, trigger=33, thumbstick=34.
Press and touch masks are independent. Original Vive legacy controls have
bindings; extra grip scalar/thumbstick modern components need explicit action
binding qualification. No Index/skeletal support is implied.

`tap` requires a neutral pair, `hand` left/right, one button name above, and an
integer `holdMilliseconds` 1..10000. It preserves both current poses and sets
only that pressed bit (touch/scalar inputs are not inferred). `sequence` takes
1..128 frames, each containing a full `pair` and integer `holdMilliseconds`
0..10000. All frames are prevalidated. The sum of waits, every configured ack
budget, and a 1000ms margin must fit 60000ms. These are synchronous, bounded
conveniences, not clock-accurate replay or an atomic HMD/controller tracked set.
Do not run competing DevBench VR tracked-set replay over the native controller
channel. Keyboard ownership is separate.

A set/tap/sequence lease gets one absolute GetTickCount64 deadline. Stale commands
are never rebased or replayed. The owner-only writer mutex spans writes, ack
waits and convenience completion. Publication uses odd/even interlocked sequence
and a fresh random writer nonce. Only exact coherent sequence/nonce acknowledgement
with accepted sequence and input health succeeds. A rejected ack is a failure.
An ack timeout is **indeterminate**; stop and inspect, never retry it automatically.

Successful tap/sequence clears all inputs while retaining the final poses, via
one new neutral full-pair command with a 100ms lease. It returns success only
after that command is acknowledged **and** coherent telemetry reports its exact
accepted sequence, no active owner/deadline, healthy neutral inputs. A changed
accepted sequence or unobserved expiry fails. Explicit reset instead restores
default neutral poses (left [-.25,1.25,-.35], right [.25,1.25,-.35]) and releases
the lease. On interruption/failure, an accepted command retains its original
deadline: native expiry releases buttons/touches/axes on the next RunFrame,
retaining poses and connected roles. This is not a guarantee that a halted
runtime has executed expiry; report the observed receipt, not assumed cleanup.

`inspect` optionally accepts `{"cursor":{"driverNonce":"...","sequence":"..."}}`.
Haptic events are runtime requests, not physical vibration. The latest 16 are
retained; the response cursor is scoped to driver nonce and reports the exact
`overwritten` count. New-instance, future or inconsistent cursors fail rather
than silently claiming lossless history. Without a cursor, inspect reports
history since sequence zero, including any overwritten events.

Every result has schema `steamvr.controllers.result.1`, typed Boolean `ok`,
`state`, errors and data. Set/reset/tap/sequence retain command receipts with
observed state. `gameConsumed=false` deliberately means game consumption is
**not established**, not that consumption was disproven. Shared-memory state
is driver-reported; independent OpenVR readback and separately authorized
Skyrim action acceptance are distinct validation phases. Passive neutral probe
qualification does not qualify active input, extra bindings, haptics or replay.

## Skyrim keyboard (reuse DevBench, no second wrapper)

Select the supported DevBench transport and bind its runtime identity as usual.
Discover `input` and call `{"action":"capabilities"}`, then keyboard status
`{"action":"status","device":"keyboard"}` before injecting. Require actual
keyboard capability/readiness, not this document or an old fallback descriptor.
Use a stable task `owner` for `device:"keyboard"` down/up/tap or balanced sequence.
For example the existing controller accepts:

```powershell
..\devbench-control\Invoke-DevBenchControl.ps1 call -Tool input `
  -ArgumentsJson '{"action":"tap","device":"keyboard","owner":"my-task","key":"k","durationMs":50}' `
  -RequireSuccess
..\devbench-control\Invoke-DevBenchControl.ps1 call -Tool input `
  -ArgumentsJson '{"action":"releaseAll","device":"keyboard","owner":"my-task"}' `
  -RequireSuccess
```

These are illustrative mutating calls, not executed examples. Keyboard uses
Skyrim's BSInputEventQueue, not OS/SteamVR dashboard injection. A sequence is
balanced, not a simultaneous/atomic chord; use the live negotiated key catalog
and limits. Pending release is not completion. Preserve the owner-scoped
keyboard releaseAll receipt separately from the native controller release/reset
receipt. There is no atomic cross-provider reset or physical-input override.

Run `tests/Test-SteamVRControllerControl.ps1` for offline fixture checks. It uses
its own uniquely named fixture mapping and mocked native acknowledgements;
it never opens the production controller mapping or launches a runtime/game.
