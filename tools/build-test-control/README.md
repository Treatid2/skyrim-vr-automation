# CSX build test control

`Invoke-CSXBuildTests.ps1` prevents an empty CTest registration from being
reported as a meaningful test pass. It first asks CTest for its JSON test
inventory. When CTest has tests, it runs them normally with failure output. When
CTest has zero registered tests (for example, a build configured with
`BUILD_TESTS=OFF` while branch-local test executables were still built), it
discovers and directly invokes executables whose names end in `Test` or `Tests`.

Every process is bounded. The JSON result records the selected route, discovery
inventory, stdout, stderr, exit code, timeout state, and optional evidence path.

```powershell
.\Invoke-CSXBuildTests.ps1 -BuildDirectory C:\Path\To\build `
  -EvidenceDirectory C:\Evidence\branch-tests
```

Use explicit `-TestExecutablePath` values when a build uses nonstandard names.
`-DiscoveryOnly` validates discovery without executing binaries.

