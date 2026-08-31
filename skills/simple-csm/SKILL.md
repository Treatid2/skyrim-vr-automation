---
name: simple-csm
description: Run the measured Skyrim VR Dragonsreach 25-step Community Shaders menu transition assay with five-second pacing and full telemetry when the user says simple csm. Do not use for simple coc, simple coc 5, static coc, or release qualification.
---

# Simple CSM

Use this skill only for the complete live protocol triggered by the exact user
command `simple csm`.

Before the first live call, read these files completely in order:

1. [Simple COC skill](../simple-coc/SKILL.md)
2. [Simple COC protocol](../simple-coc/references/protocol.md)
3. [Canonical menu matrix](../../tools/render-scale-qualification/protocol.v1.json)
4. [Simple CSM override](references/protocol.md)

The Simple COC authorization, fixture, fidelity, telemetry, failure, cleanup,
and CSV contracts apply except where the Simple CSM override explicitly
replaces the initial cell, measured mutation, transition count, trace
lifecycle, or result grouping.

The trigger authorizes one positioning COC to `WhiterunDragonsreach` and only
the 25 exact render-scale `apply` mutations in the selected canonical menu
matrix. Setup must not change upscaling. Do not build, deploy, change MO2 or VR
FPS Stabilizer configuration, issue another COC, restart Skyrim, or run another
protocol. Never interpret `simple coc` or `simple coc 5` as authorization for
this assay, or `simple csm` as authorization for either COC assay.
