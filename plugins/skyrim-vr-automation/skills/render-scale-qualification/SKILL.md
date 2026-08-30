---
name: render-scale-qualification
description: Run the fully unattended CSX VR render-scale qualification when the user invokes $render-scale-qualification, asks to start render-scale qualification, or contextually says start after confirming the intended DLL is running in game at the controlled start scene. Attach to that exact session and return its final verdict without building, deploying, or launching.
---

# Render-scale qualification

Run the packaged revision-4 qualification once and return its final result.
The package owns capture, image-model evaluation, telemetry validation,
evidence finalization, and verdict generation.

Before live work, read the sibling `devbench-control` skill and
`../coc-stability/references/protocol.md`. Use the packaged entrypoint for all
test mutations; use direct DevBench tools only for read-only diagnosis when the
package reports an infrastructure problem.

## Invocation boundary

- Require the intended CSX DLL and Skyrim VR session to be running already at
  the controlled start scene.
- When that context is established, treat `start render-scale qualification`
  or a contextual `start` as authorization to run this package once.
- Never build, configure, deploy, redeploy, launch, restart, reload, switch an
  MO2 profile, or edit game or mod configuration in this workflow.
- Never substitute a runtime, fixture, GPU matrix, baseline, capture source,
  model, or model output. Never search arbitrary MO2 directories for inputs.
- Do not edit generated review or evidence files. Preserve partial evidence
  when the package fails, and do not repeat uncertain mutations.

## Input resolution

The entrypoint resolves runtime metadata in this order:

1. an explicit `-RuntimePath` already supplied in the task;
2. `CSX_DEVBENCH_RUNTIME_PATH`;
3. `devBenchRuntimePath` in
   `%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`.

It must bind one reachable listener, authoritative process identity, and exact
64-character Build ID for the DLL that is already loaded. It reads the live D3D
adapter through DevBench and requires its vendor, device, and driver identity
to agree with the selected fixture before choosing the NVIDIA or AMD matrix.

The entrypoint resolves the fixture in this order:

1. an explicit `-FixtureManifestPath` already supplied in the task;
2. `CSX_RENDER_SCALE_FIXTURE_PATH`;
3. `%LOCALAPPDATA%\SkyrimVRAutomation\render-scale-qualification\fixture.json`.

Require one existing, non-example `csx-render-scale-fixture-v1` manifest. Do
not generate, repair, attest, or update it during the run.

Use an explicit evidence directory when supplied. Otherwise let the package
create a unique directory below
`%LOCALAPPDATA%\SkyrimVRAutomation\evidence\render-scale-qualification`.
Never reuse, empty, or delete an existing directory. Use local mode unless the
task already supplies both a baseline evidence path and its exact Build ID. If
only one baseline input is present, stop before mutation.

## Run once

Resolve the entrypoint relative to this skill as
`../../tools/render-scale-qualification/Start-CSXRenderScaleQualification.ps1`.
Run it in a separate PowerShell process so its exit code is preserved. Pass
only explicit inputs already authorized by the task. For an exact paired
baseline add `-PrMode`, `-BaselinePath`, and
`-ExpectedBaselineBuildId`; otherwise run local mode.

The package discovers the running Build ID and verified GPU matrix, executes
the 20-transition COC assay, the 25-transition menu assay, two 30-second
recovery barriers, and the three one-minute HMD-submission capture sequences.
Each telemetry-bearing transition retains render-target resource-publication
generations, expected/published dimensions, completion/deferred setup, and D3D
device/context identity alongside CPU/GPU evidence. Each assay's existing
stress-stop receipt also supplies the bounded preparation trace. The package
retains raw events, transition-epoch stage views, and CSV evidence for
admission/early exits, shader-cache deferral, SSS/SSGI prewarm,
DLSS/FSR/FSR4 preparation, D3D creation, total preparation,
request-to-prepared, and prepared-to-creator without adding transition polls.
It then runs `gpt-5.6-sol` through the Codex CLI in six blinded batches: three
replicates in each of two independently swapped presentation passes. The model
evaluates sharpness, blur, shimmer, stereo alignment, equal eye scale, and
geometry correspondence. Render-scale latch is decided only from owner-bound
telemetry. Low confidence, indeterminate results, or disagreement across the
swapped passes fails closed.

The complete invocation has a hard 600-second pass limit. While it runs, poll
the process without sending input or starting a second instance, and keep the
user informed at least once per minute.

## Return the final result

Trust only the package's structured result and process exit code:

- exit `0`: `PASS` or `LOCAL_PASS`;
- exit `2`: qualification `FAIL`, including a valid negative or inconclusive
  quality assessment;
- exit `4`: `INFRASTRUCTURE_ERROR`, including runtime, fixture, baseline,
  model access, schema, timeout, or evidence-integrity failure.

Report the exact status, evidence directory, discovered Build ID and GPU
vendor, elapsed time, and concise failure reasons. Do not reinterpret a
nonzero exit as a pass and do not leave an external review step.
