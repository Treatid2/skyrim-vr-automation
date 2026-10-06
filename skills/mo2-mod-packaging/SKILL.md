---
name: mo2-mod-packaging
description: Package or inspect Skyrim VR Mod Organizer 2 install ZIPs without relying on archive flattening. Use when a task prepares a mod archive, diagnoses an archive that installs too deeply, or selects the exact Data root to package.
---

# MO2 Mod Packaging

Use the deterministic controllers instead of manually shaping archives or editing `modlist.txt`.

## Package or inspect an archive

Run `tools/mo2-mod-package-control/Invoke-MO2ModPackageControl.ps1`.

- For `package`, pass the directory whose *contents* are the Skyrim Data root. A normal SKSE
  plugin therefore packages as `SKSE/Plugins/Name.dll`, not `ModName/Data/SKSE/...` and not
  `Data/SKSE/...`.
- Put optional licence/readme files through `-DocumentationFiles`; the packager installs them
  under `docs/` so they cannot affect root shaping.
- Treat only `direct-data-root` as independent of MO2's flattening heuristics. Rebuild other
  layouts from the reported explicit `recommendedSourceRoot`; do not guess or recursively strip
  wrappers.
- Never normalize an untrusted third-party archive without an explicit source-root selection.
  Inspect it first, extract with a safe archive tool into isolated staging, then package the
  selected Data root.

Read [references/package-layout.md](references/package-layout.md) when interpreting a third-party
archive or explaining why an existing ZIP installs too deeply.

Archive creation does not authorize installation or profile mutation. Use the separate MO2 profile
controller for those operations; Skyrim must be closed for every modlist change.
