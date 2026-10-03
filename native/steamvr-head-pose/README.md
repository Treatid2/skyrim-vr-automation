# CSX SteamVR head-pose provider

This Windows OpenVR server driver supplies the tracked head pose missing from
Valve's display-only null HMD. It exposes one generic tracked device and is
mapped to `/user/head` through SteamVR's `TrackingOverrides` setting. It also
exposes an optional controllable left/right controller pair when
`driver_codex_head_pose.enableControllers=true`. The default is false.

The pair uses stable serials `CSX-NULL-CONTROLLER-LEFT-1` and
`CSX-NULL-CONTROLLER-RIGHT-1`, Controller device class and explicit hand-role
hints. Fixed standing positions are `(-0.25, 1.25, -0.35)` and
`(0.25, 1.25, -0.35)` metres, identity orientation and zero velocities.
The bundled input profile declares Vive legacy controls plus grip value and
thumbstick components. Inputs start neutral. The versioned controller channel
controls both hands' standing poses, button presses/touches, trigger/grip values
and trackpad/stick axes. Exact command acknowledgement follows publication of
both hands. A bounded native lease releases input on sender loss, while keeping
the devices connected and preserving their last poses. Owner reset restores
default neutral poses. Haptic requests are retained in a bounded sequenced ring;
no physical vibration is produced. See [the protocol](CONTROLLER-PROTOCOL.md).
VMT's controller input/reset/haptic patterns are adapted with retained MIT
attribution; see [reuse provenance](THIRD-PARTY.md).

Run `csx_openvr_pose_probe.exe --require-controllers` before admitting Skyrim.
It requires distinct non-HMD left/right indices within OpenVR's tracked-device
array, matching runtime class/roles and the pair's serial/provider identity,
finite connected valid standing and
compositor render/game poses, and successful neutral legacy
`GetControllerState` samples. It observes 100 samples over approximately two
seconds and rejects any controller button/touch event during that interval.
An absent, invalid, non-neutral or changing pair produces exit code 3 and
`controllers.valid=false`; unknown arguments produce exit code 4.
Without the option, the probe retains head/stereo qualification only.

This supplies the missing-controller precondition for the observed VR Tools
invalid-index crash. It does not repair VR Tools' unchecked device-index
handling on a later disconnect. Application admission must require this probe;
role hints or successful driver registration alone are insufficient.

The default standing pose is `(0, 1.68, 0)` metres with identity orientation.
The driver also publishes the version-2 shared-memory control block
`Local\CSXVRHeadPose-v2`. It is created with an owner-only ACL and a fresh
driver-instance nonce; a pre-existing mapping is rejected. Writers serialize
through a named mutex, publish with aligned interlocked sequence fields, and
receive acknowledgement of the exact command nonce and sequence. DevBench can
implement the same contract later without becoming a SteamVR bootstrap
dependency.

The independent probe qualifies both the standing HMD pose and distinct,
finite per-eye transforms with a plausible eye separation and render target.

Compile exact committed candidates through Build Broker. The broker owns the
managed build scratch, pinned OpenVR SDK closure and retained package receipt;
source worktrees must not create repository-local build intermediates.
`CSX_OPENVR_SDK_ROOT` allows the broker to select its retained SDK checkout.
The CMake package is produced at `<broker-build>/package/codex_head_pose`.

`csx_controller_tests` is a separate EXCLUDE_FROM_ALL host test target. Broker
compiles it without execution; the requester runs its deterministic lease and
validation assertions. A host pass is not SteamVR/game input acceptance. The
neutral probe remains a startup gate; stop active commands before qualification.
Legacy thumbstick/grip-value mappings and game actions require their own evidence.
