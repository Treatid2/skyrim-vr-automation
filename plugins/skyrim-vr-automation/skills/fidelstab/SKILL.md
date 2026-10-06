---
name: fidelstab
description: Run the fixed Skyrim VR Breezehome fidelity, stability, CPU, and GPU DevBench protocol when the user says fidelstab or asks to repeat the preserved PR41 paced door test.
---

# Fidelstab

Run the preserved protocol exactly. Do not reuse results from abandoned,
unpaced, partially visible, or differently configured runs.

Read [references/protocol.md](references/protocol.md) before operating the game.

Use the Skyrim VR automation skills for DevBench, profiling, MO2, and shader
cache transactions. Use plugin-provided direct MCP tools for every live-game
discovery, call, wait, screenshot, and profiler operation. PowerShell is only
for MO2 lifecycle transactions, shader-cache transactions, offline evidence,
Git, or functionality unavailable through MCP.

Do not restart or reload Skyrim when the exact Save 14 fixture is already loaded
in Breezehome. Treat any failed or altered run as excluded evidence and restart
that run from Breezehome only after the cause is corrected.

CPU performance is primary and GPU performance is secondary. Preserve raw
evidence and report stretch duration in consecutive frames; convert it to time
only when the capture exposes a defensible measured frame interval.
Also preserve the render-scale stress-stop preparation trace and all stage
timings; do not add polling or infer missing producer measurements.
