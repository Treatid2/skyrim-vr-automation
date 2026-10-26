# MO2 Mod Package Control

`Invoke-MO2ModPackageControl.ps1` inspects ZIP layout and creates deterministic MO2 install
packages from an explicitly selected Skyrim `Data` root. It packages the *contents* of that
directory at archive root; it never relies on MO2 guessing which wrapper directory to remove.

Commands:

- `inspect -ArchivePath <zip>` validates member safety and classifies the layout.
- `package -DataRoot <directory> -OutputPath <zip>` creates a deterministic ZIP plus a
  `<zip>.receipt.json` containing the archive hash and exact source-file hashes.

Pass the directory that directly contains paths such as `SKSE\Plugins`, `meshes`, `textures`,
or root plugin files (`.esp`, `.esm`, `.esl`, `.bsa`). Do not pass its parent merely because it
contains one `Data` or mod-name directory. Optional `-DocumentationFiles` are installed under
`docs/`; they cannot accidentally change the root shaping decision.

`inspect` distinguishes:

- `direct-data-root`: deterministic; no installer flattening is needed.
- `single-wrapper-flatten-dependent`: one wrapper with no siblings; MO2 may descend through it,
  but the package is fragile and should be rebuilt from the reported `recommendedSourceRoot`.
- `data-wrapper-with-supported-docs`: MO2 quick-installer special handling for `Data` plus root
  documentation/image files; supported by current MO2 source but still unnecessary shaping.
- `wrapper-blocked-by-siblings`: a wrapper exists but root siblings prevent deterministic
  descent.
- `unrecognized-layout`: no recognized direct Data-root payload was found.

The packager rejects reparse points, rooted/traversal member paths, case-insensitive collisions,
symlink ZIP members, output inside the source tree, empty payloads, and configured size/count
limits. Non-standard layouts require the explicit `-AllowUnrecognizedPayload` acknowledgement;
that switch does not weaken archive-member safety checks.

Examples:

```powershell
pwsh -NoProfile -File .\tools\mo2-mod-package-control\Invoke-MO2ModPackageControl.ps1 inspect `
  -ArchivePath C:\staging\candidate.zip

pwsh -NoProfile -File .\tools\mo2-mod-package-control\Invoke-MO2ModPackageControl.ps1 package `
  -DataRoot C:\staging\MyMod\Data `
  -OutputPath C:\packages\MyMod.zip
```

Run `tests\Test-MO2ModPackageControl.ps1` after changing the contract.
