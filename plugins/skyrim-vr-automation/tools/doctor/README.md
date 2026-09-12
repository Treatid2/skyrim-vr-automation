# Skyrim VR Automation doctor

`Invoke-SkyrimVRAutomationDoctor.ps1 inspect` performs read-only checks for the
supported PowerShell runtime, resolved MO2 configuration, MO2 validation,
SteamVR paths, the bundled null-HMD profile, and optional DevBench discovery.
It also verifies static integrity for the maintained MO2 source profile's
mandatory default world-entry save. The check passes only when `fixture-status` validates the
profile fingerprint, one declared `.ess`, its co-save files, and all recorded
hashes. This does not assert a successful live load. Missing or stale fixture metadata is a setup failure because fresh task
profiles may not be cloned without a known route into the loaded game world.

MO2 configuration is resolved in strict precedence order: explicit
`-ConfigPath`, `SKYRIM_VR_AUTOMATION_CONFIG`, an exact
`SKYRIM_VR_AUTOMATION_MODLIST` name, the persisted selection managed by
`../modlist-control`, the stable per-user file, then the legacy ignored
checkout-local file. The historical files are considered only when no named
configs exist. The selected source and modlist are always reported.

Initialize the stable path without overwriting an existing file:

```powershell
.\Invoke-SkyrimVRAutomationDoctor.ps1 init -WhatIf
.\Invoke-SkyrimVRAutomationDoctor.ps1 init
```

By default this copies the public example for editing. To migrate an existing
configuration exactly, pass `-SourceConfigPath`.
