---
name: simple-coc-5
description: Run the measured Skyrim VR Windhelm-to-Dragonsreach COC comparison with five-second measured-transition pacing when the user says simple coc 5. Do not use for simple coc, static coc, or release qualification.
---

# Simple COC 5

Use this skill only for the complete live protocol triggered by the exact user
command `simple coc 5`.

Before the first live call, read these files completely in order:

1. [Simple COC skill](../simple-coc/SKILL.md)
2. [Simple COC protocol](../simple-coc/references/protocol.md)
3. [Five-second override](references/protocol.md)

The base protocol's authorization, fidelity requirements, telemetry, failure
rules, 20-transition count, and CSV contract all apply. The override changes
only the deliberate pacing wait before each measured COC. Never interpret
`simple coc` as authorization for this variant or `simple coc 5` as
authorization for the base variant.
