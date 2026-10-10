# Immutable render-map start planning

Use `New-CSXRenderMapCapturePlan.ps1` with a successful retained registry and
explicit workload estimates. Dispatch only a successful result's entire
`arguments`; never append fields after planning. Headroom, registry ceilings and
default-only catalogue sizing remain enforced. A matched allocation recipe is
required to exceed default catalogue capacities; selecting fewer events does
not reduce catalogue allocation.

Optional `Activation`, `MaxActivationWaitMs`, and
`ExecutionWithinSelectedGeometry` are qualified against the retained registry
and a hash-pinned **tool descriptor** (`name`, `inputSchema`) supplied using
`InputSchemaPath` and `ExpectedInputSchemaSha256`. Obtain that descriptor from
the fresh tool inventory on the same selected DevBench transport/runtime as the
registry, not from this test fixture. The immutable receipt retains both input
hashes and the exact returned request. Offline planning cannot establish live
catalog currency: the calling experiment must verify its answering runtime and
producer binding before dispatch, and replace stale evidence after replacement.

For the native VR late window select `Activation main_post_processing`, explicit
integer `MaxActivationWaitMs 2000`, Boolean
`ExecutionWithinSelectedGeometry:$false`, and `EventKinds eye-submitted`.
The wait must fit both schema and registry limits, independently of active
`maxDurationMs`. No selector is silently defaulted or rewritten. Unknown modes,
missing late support, missing eye-submitted selection, restricted geometry,
non-Boolean execution values and malformed/out-of-range waits fail without
issuing start arguments. Omitting all selector/schema parameters preserves the
existing native default lane.

The fixture `fixtures/native-render-map-start.ad8.json` derives from the tool
descriptor in `src/RenderMap/DevBenchBridge.cpp` at CSX commit
`ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0`, with the registered tool name added.
It is historical source-schema evidence only, never a live discovery result.
`Test-RenderMapStartSelection.ps1 -FixtureRoot <managed-scratch-workPath>`
exercises the production planner, exact returned/receipt equality and bounded
negative cases. It does not open a session or start a capture.
