# Exact native input inventory admission

Current native DevBench ca3e1456940cc07ed06f84810dd4aa0af9a5c15c advertises
`devbench.input`2.0 and keyboard version1 with exactly105 canonical bindings.
The original102 keyboard bindings are unchanged. The only extension is
mouseLeft256, mouseRight257, mouseMiddle258, accompanied by
`keyboard.mouseButtons:{codeBase:256,keys:[mouseLeft,mouseRight,mouseMiddle]}`.
The native catalog Git blob is a2a0c10625ffa4db3ed677adff2037a1ade7b4d5.
Mouse codes dispatch to native mouse IDs0/1/2; they are not keyboard aliases.

Admit only the exact105 inventory with coherent typed descriptor, or the
separately retained source-qualified legacy102 inventory with no descriptor.
Never admit an arbitrary count >=102, partial mouse extension, duplicate,
foreign name, wrong case, misbound scan code or coercible JSON value. Contract,
readiness, bounds, tracked-set, negative-envelope and runtime identity guards
remain in force. Schema admission does not prove input injection or recording.

`Test-InputMouseCapabilities.ps1` exercises the production schema helper;
`-UseSemanticAdapter` additionally exercises the integrated production
`Get-DevBenchCallSemanticStatus` and its lossless qualified projection.
The curated-main branch introduces the native read helper as prerequisite
context; its old module does not yet dispatch this helper. Curated promotion
must reconcile the native-read/PR80 context rather than merge an aggregate
development baseline. Immediate integrated source does dispatch the helper.

Current105 fixture is the exact `data.content[0]` projection of the retained
read-only diagnostic stdout at
L:/Codex/analysis/completion-driven-process/runs/mapping-ad8-input-capabilities-diagnostic-20261005/stdout.log,
26012bytes, SHA256364895369b38d585e2c8703ed0884257d4e1fe7191e9b86cf89bc3d12b51ad93,
captured2026-10-04T23:43:11.542556Z through23:43:14.631643Z.
Its enclosing client refused the old102-count schema; native transport returned
isErrorfalse. No runtime wrapper/producer fields were invented in the payload.
DevBench owner advice and verification:
L:/Codex/artifacts/devbench/management/20261005-input-inventory-advice/ADVICE.md
and source-contract-verification.json. Independently read deployed DLL SHA256
0c501fc5ff52d44bb371fb377c3959401ea605e9a23f931b5daf2b76c6462973 matches
the source-qualified ca3e145 delivery. Those captures are separate, not atomic.

Legacy102 fixture is unchanged from the original native observation:
mapping-rsoff-input-capability-diagnostic-20261004-0252-001/stdout.log,
25204bytes, SHA256b911c2fe6997ee65331c3fef1e0318ab86ecd7de3817b94bbf2871a5b0175d46,
same exact data.content[0] projection. Both JSON fixtures are derived serializations
of immutable original evidence; originals remain authoritative. No runtime call,
plugin rotation, MO2/null/cache change, live pass or independent review is claimed.
