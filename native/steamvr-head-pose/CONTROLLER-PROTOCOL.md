# Controller command protocol v1

The Windows local-session mapping `Local\CSXVRControllers-v1` is created by the
provider with owner-only ACL. It has 1304 bytes, little endian, 8-byte alignment.
`src/controller_protocol.h` owns the layout. Existing head mapping v2 is unchanged.
Clients must bind creator PID, process creation FILETIME and random driver nonce
to a live `vrserver.exe` and verify magic `0x43585343`, version 1 and size 1304.
Refuse a wrong header, expired process, new instance or pre-existing mapping.

## Byte layout

| Offset | Field | Type |
|---:|---|---|
| 0 | magic, version, size | u32, u16, u16 |
| 8 | requestedSequence | interlocked u64 |
| 16 | appliedSequence | interlocked u64 |
| 24 | acknowledgedWriterNonce | u64 |
| 32 | driverNonce | u64 |
| 40 | driverStartedFileTimeUtc | u64 |
| 48 | driverCreatorPid, status | u32, u32 |
| 56 | telemetrySequence | interlocked u64 |
| 64 | command.ownerNonce | u64 |
| 72 | command.writerNonce | u64 |
| 80 | command.deadlineTickMs | u64 |
| 88 | command.driverNonce | u64 |
| 96 | command.flags, reserved | u32, u32 |
| 104, 232 | command left, right Hand | 128 bytes each |
| 360 | activeOwner | u64 |
| 368 | deadlineTickMs | u64 |
| 376 | acceptedSequence | u64 |
| 384 | expirationCount | u64 |
| 392 | inputHealthy, reserved | u32, u32 |
| 400, 528 | applied left, right Hand | 128 bytes each |
| 656 | hapticSequence | u64 |
| 664 | haptics | 16 entries of 40 bytes |

Hand offsets: position XYZ doubles 0/8/16; quaternion WXYZ doubles 24/32/40/48;
pressed/touched masks u64 56/64; trackpad XY float32 72/76; trigger/grip float32
80/84; stick XY float32 88/92; zero reserved u64[4] at 96.
Positions are OpenVR standing metres, +X right, +Y up, -Z forward. Quaternion
components are finite with squared norm strictly between 0.25 and 4; provider
normalizes them. Positions are finite within +/-1000m. Trackpad/stick axes are
finite [-1,1], trigger/grip [0,1]. Unsupported bits or nonzero reserved reject.
Button IDs: system 0, application_menu 1, grip 2, trackpad 32, trigger 33,
thumbstick 34; masks are `1 << ID`. Press and touch are independent.
Legacy Vive bindings map the original Vive controls. Extra grip scalar and
thumbstick are available as modern input components; their game bindings need
explicit qualification, and they must not be claimed as Index/skeletal support.

## Command and ownership

Use owner-only mutex `Local\CSXVRControllersWriter-v1` with a bounded wait.
It serializes command writes/ack waits. A stable random nonzero ownerNonce is a
lease identity spanning commands; a fresh nonzero writerNonce identifies each
command. Do not derive either from sequence alone. Both hands are full snapshots.
To preserve a hand, copy a coherent applied snapshot under the same ownership.
Reject requests for another active owner; return a structured busy error.

Publish odd requestedSequence with InterlockedExchange64, then the full command,
then a memory barrier and the next even requestedSequence. Never touch telemetry
or immutable header fields. Do not reuse a sequence; refuse wraparound. The driver
copies only a stable even snapshot and echoes exact writerNonce and sequence.
Wait at most a bounded configured ack timeout. Read ack fields coherently using
the telemetry seqlock as well as appliedSequence; status is not safe to read alone.

Flags 0 sets poses/inputs with absolute Windows GetTickCount64 deadline, >now and
at most 60000ms ahead. Do not rebase a stale command in transit. Scripts use a
bounded 100..60000ms lease. Any active different owner rejects the whole command.
Flags 1 resets both hands to their default neutral standing poses and releases
the native lease. Only the active owner may reset; when no lease exists any
properly bound owner may reset. Reserved command field must be zero.
There is no externally callable force-reset bypass.

On expiry, the provider releases buttons/touches and zeros all scalar inputs on
its next RunFrame while retaining the last poses and connected roles. A crashed
writer cannot extend the lease. Reset restores default poses as well. The driver
never disconnects a hand during neutralization. Publication failure yields
InputFailed and invalid poses; it does not produce a successful ack. Successful
ack means both devices' input components were published to SteamVR, not that a
game consumed them or performed an action.

Statuses: 0 Waiting, 1 Applied, 2 Invalid, 3 Busy, 4 Expired, 5 InputFailed.
Rejected commands leave the previously accepted lease/state unchanged except
normal deadline expiration. They still receive an exact sequence/nonce ack.
No sequence ack for torn/odd commands; clients time out and must inspect.

## Telemetry and haptics

Driver writes odd telemetrySequence, then all ack/state/haptic fields, barrier,
then even. Readers copy fields and require matching nonzero even values before
and after. Independent controller state is verified through OpenVR; shared-memory
applied state is a driver report. inputHealthy is 1 only when both hands publish.
`acceptedSequence` denotes last accepted command, not every acknowledged rejection.

Haptic event offsets: sequence u64 0, hand u32 8 (0 left/1 right), reserved u32 12,
duration seconds/frequency Hz/amplitude float32 16/20/24, padding u32 28,
GetTickCount64 tick u64 32. Events match the runtime component handle (VMT pattern).
The ring retains the latest 16 valid events; entry index `(sequence-1)%16`.
Driver-instance nonce scopes sequences. A client cursor <latest-16 reports the
exact number of overwritten events; never silently claim lossless history.
No physical vibration is produced. Haptic readback reports runtime requests.

## Integration boundary

Native provider/controller source is owned by Manage null-HMD inputs. Auto owns
scripts/profile/schema/tools and offline tests. DevBench owns Skyrim keyboard API.
Keep existing inspect/install/qualify/head-set compatible and preserve package
provenance, controller timeout0, runtime closed gates and exact restoration.
Expose controller inspect/set/reset plus bounded sequence/tap convenience using
this same lease/ack path. Reset keyboard separately with DevBench owner releaseAll;
return both receipts rather than claiming an atomic cross-provider reset.
