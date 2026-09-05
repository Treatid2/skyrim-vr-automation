# Install the Codex plugin

## From GitHub

Add the repository marketplace and install the available plugin:

```text
codex plugin marketplace add Treatid2/skyrim-vr-automation --ref main
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

Restart Codex after a new installation. Run the doctor before a live workflow:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

Initialize the stable MO2 configuration at
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json` and then edit the copied
example, or migrate an existing file with `-SourceConfigPath`:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 init
```

An explicit `-ConfigPath` takes precedence, followed by
`SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user path, and the legacy ignored
checkout-local path. The doctor reports which source won.

## Qualify the maintained MO2 source

Before handing fresh MO2 profiles to tasks, configure
`defaults.testProfileSource` as the maintained prime profile and keep one
known-good world-entry save in its `saves` tree. Live-load that save once with
the intended base mod list, then copy and adapt
`tools/mo2-workspace-control/save-fixtures.example.json` outside the checkout.
Set `defaults.newGameFixtureManifest` to that file and record the exact source
profile fingerprint and save/co-save hashes.

Verify the contract before installation is considered ready:

```powershell
.\tools\mo2-workspace-control\Invoke-MO2WorkspaceControl.ps1 fixture-status -Compact
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

The first command must return `fixture-valid`; the doctor check
`prime-profile-world-entry-integrity` must pass. A missing, stale, or mismatched fixture
blocks fresh workspace creation. Only one save is required because guarded
`coc`/`cow` transitions can reach other locations after world entry.

Every fresh task profile receives the complete prime-profile save tree and a
verified copy of that baseline. This is exact static integrity, not proof of a
successful runtime load. A resumed task profile is intentionally left untouched
and is not reverified after the task changes its own mod or save state.

## Declare optional local work

Keep the prime profile representative of the installed modlist plus mandatory
shared diagnostics. Install local work additively under distinct mod names and
leave it selectable per task. Copy
`tools/mo2-workspace-control/local-work-mods.example.json` to an ignored local
path and set `defaults.localWorkModCatalog` to it.

For CSX, provide separate AIO packages from the same source head: one built
with `DEVBENCH_BRIDGE` off to match public release behavior and one with it on
for automation. Give them the same `exclusionGroup` so a task cannot enable
both. Protect locally maintained packages from Wabbajack with the installation's
supported no-delete naming convention.

After installation or a modlist update, run:

```powershell
.\tools\mo2-workspace-control\Invoke-MO2WorkspaceControl.ps1 list-local-work-mods -Compact
```

Only candidates with an exact existing mod directory and one exact marker in
the maintained profile are available. Fresh workspace requests then state
either `-WorkspaceContent Modlist` or
`-WorkspaceContent ModlistPlusLocalWorkMods` with exact candidate IDs.

## Upgrade

```text
codex plugin marketplace upgrade skyrim-vr-tools
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

Review `CHANGELOG.md`, rerun the doctor, and restart Codex. Pin a marketplace
checkout to a release tag with `--ref vX.Y.Z` when reproducibility matters.

## Remove

```text
codex plugin remove skyrim-vr-automation@skyrim-vr-tools
codex plugin marketplace remove skyrim-vr-tools
```

Removal does not delete per-user configuration, MO2 session evidence, SteamVR
backup receipts, or profiler/cache reports.
