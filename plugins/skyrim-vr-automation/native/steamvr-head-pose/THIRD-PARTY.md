# Virtual Motion Tracker reuse

Controller component publication, independent click/touch/trigger/joystick
mapping, neutral reset and component-handle haptic event dispatch are adapted
from gpsnmeajp's MIT-licensed Virtual Motion Tracker (VMT).

Retained source: `https://github.com/gpsnmeajp/VirtualMotionTracker`, exact local
candidate `6a41faa91f82ee0e3d496817c20f68335224f226`, upstream parent
`336155b93e2049195b2bc707d959c8207b3da1ef`. The local candidate changes only the OSC
receive address to loopback; that transport is not copied into this provider.
Source sections: `vmt_driver/TrackedDeviceServerDriver.cpp` UpdateButtonInput,
UpdateButtonTouchInput, UpdateTriggerInput, UpdateJoystickInput, Reset,
ProcessEvent and Activate. Attribution/license accompany source and package.

The integration retains its established head pose v2 channel, stable controller
serials and Vive legacy bindings. The new acknowledged shared-memory channel,
whole-pair validation and bounded native owner lease replace VMT's OSC command
transport. Inputs expire to neutral without VMT Reset's device disconnect,
because disconnected roles recreate the known Skyrim/VR Tools failure.
No VMT skeletal controller or OSC API compatibility is claimed.
