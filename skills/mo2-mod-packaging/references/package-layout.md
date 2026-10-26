# MO2 package layout

The reliable package rule is simple: place the contents of the intended Skyrim `Data` directory at
archive root. A package for `Example.dll` should contain:

```text
SKSE/
  Plugins/
    Example.dll
docs/
  LICENSE.txt
```

Do not depend on an installer removing `My Mod/` or `Data/`. This avoids both observed failures:

1. A structurally correct wrapper is removed because it is the only root directory.
2. A wrapper expected to be removed remains because a readme, licence, or another entry is beside it.

MO2's quick installer repeatedly descends while the current tree is not recognized as valid and
contains exactly one directory. Current source also has a narrow special case for a `Data`
directory accompanied only by one or more root documentation/image files. That behavior explains
existing archives; it is not a reason for newly produced packages to depend on it.

Primary implementation reference:
https://github.com/ModOrganizer2/modorganizer-installer_quick/blob/2eda288190bac72d247209b7d1d81e5eef8c4172/src/installerquick.cpp

The package controller deliberately recognizes only a conservative subset of Skyrim Data-root
markers. Use `-AllowUnrecognizedPayload` only when a non-standard MO2/RootBuilder layout has been
independently verified. This acknowledgement does not permit traversal, rooted paths, symlinks,
case-insensitive collisions, reparse-point sources, or unbounded archives.
