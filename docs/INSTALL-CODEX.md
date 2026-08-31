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

The plugin registers the loopback `devbench_vr` MCP server from its own
`.mcp.json`. Render-scale tuning requires those plugin-provided direct tools
and never uses the bundled HTTP controller. A separate global
`mcp_servers.devbench_vr` entry is not required. Remove a legacy global entry
after installing the plugin, then restart Codex:

```text
codex mcp remove devbench_vr
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

## Upgrade

From a repository checkout, use the bounded installer:

```powershell
.\scripts\Install-CodexMarketplacePlugin.ps1 -ConfirmSafeCacheRotation
```

It verifies the marketplace manifest version, the structured installed
registration, and every installed file hash. If `plugin add` succeeds while
`plugin list` still reports an older snapshot, it performs one scoped
`skyrim-vr-tools` remove/add cycle and verifies the result again.

Installation replaces the versioned plugin cache directory. Finish every
automation run in every chat before invoking it, then fully reload the Codex
host or VS Code before starting another protocol. A new chat in the existing
host can retain the old catalog path and is not a sufficient reload boundary.
Source/package generation and commits may continue while a run is active;
defer only the installed-cache rotation.

For a Git marketplace installation without a checkout, refresh the marketplace
registration before reinstalling the plugin:

```text
codex plugin remove skyrim-vr-automation@skyrim-vr-tools
codex plugin marketplace remove skyrim-vr-tools
codex plugin marketplace add Treatid2/skyrim-vr-automation --ref main
codex plugin add skyrim-vr-automation@skyrim-vr-tools
codex plugin list --marketplace skyrim-vr-tools --json
```

The listed version must match `.codex-plugin/plugin.json`. Review
`CHANGELOG.md`, rerun the doctor, and restart Codex. Pin a marketplace checkout
to a release tag with `--ref vX.Y.Z` when reproducibility matters.

## Remove

```text
codex plugin remove skyrim-vr-automation@skyrim-vr-tools
codex plugin marketplace remove skyrim-vr-tools
```

Removal does not delete per-user configuration, MO2 session evidence, SteamVR
backup receipts, or profiler/cache reports.
