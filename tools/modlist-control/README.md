# Modlist Control

Modlist Control registers and selects exact machine-local MO2 configurations.
It makes frequent switching between portable MO2 installations explicit while
preserving the controllers' no-fallback contract.

Named configurations live outside the repository under:

```text
%LOCALAPPDATA%\SkyrimVRAutomation\modlists\<name>.machine.local.json
```

The selected name is stored atomically in
`%LOCALAPPDATA%\SkyrimVRAutomation\active-modlist.json`. The selection stores
only a name, timestamp, and configuration hash; the resolver derives the exact
config path and never accepts an arbitrary path from the selection file.

## Commands

```powershell
.\Invoke-SkyrimVRModlist.ps1 list
.\Invoke-SkyrimVRModlist.ps1 register -Name main -ConfigPath C:\staging\main.json
.\Invoke-SkyrimVRModlist.ps1 select -Name main
.\Invoke-SkyrimVRModlist.ps1 resolve
.\Invoke-SkyrimVRModlist.ps1 resolve -Name synergy
```

`register` refuses to overwrite an existing name. `select` refuses a missing or
incomplete config. Both support `-WhatIf`. Commands return structured JSON.

Configuration resolution precedence is:

1. explicit `-ConfigPath`;
2. `SKYRIM_VR_AUTOMATION_CONFIG`;
3. exact `SKYRIM_VR_AUTOMATION_MODLIST` name;
4. the persisted active modlist;
5. the historical stable per-user and package-local paths, but only when no
   named configurations exist.

If named configurations exist without a valid active selection, controllers
fail closed with `named-selection-required`; they never choose the first file,
the label `main`, the UI-selected MO2 profile, or an older stable config.
