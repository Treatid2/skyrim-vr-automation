---
name: capture-interaction-control
description: "Capture, observe, and interact with a running Skyrim VR session through one correlated DevBench state recording plus optional CSX stereo frames. Use for LLM-guided navigation, latest-frame observation, named or direct in-game actions, full activity capture with or without image sequences, or orderly capture finalization."
---

# Capture interaction control

Use `tools/capture-interaction-control/Invoke-CaptureInteraction.ps1` as the
only session orchestrator. Read its `README.md` before the first mutation.

1. Acquire `Kind=capture` managed scratch before `start` when frames or a unique
   activity trace will be written. Pass its `workPath` as `-SessionDirectory`.
2. Use `capabilities` before a new runtime/build. Require successful DevBench
   recording and atomic tracked-set observation. Require screenshot v1 only for
   `on-demand` or `sequence` mode.
3. Choose `none` for state/input capture only, `on-demand` for a frame at each
   `observe`, or `sequence` for continuous stereo evidence. Do not emulate a
   sequence with repeated still requests.
4. Call `observe` and inspect `data.observation`. When a frame is present, use
   the image-viewing tool on `frameSubmission.path`; do not infer the current
   screen from an earlier frame or an uncommitted artifact.
5. Prefer a catalogued `-ActionName`. Named controller actions preserve the
   currently observed HMD/controller poses and mutate only the declared bounded
   input, then wait for the exact sequence generation to finish. Use
   `-DirectTool` only when the exact DevBench contract and mutation
   are already understood. Never approximate an unsupported input silently.
6. Use `-ObserveAfterAction` when closed-loop feedback matters. The action
   receipt and subsequent observation have distinct IDs and timestamps.
7. Use `stop` for normal completion. Use `abort` only for explicit partial
   finalization. Both preserve receipts; neither deletes evidence.
8. Use `wait-save` for a requested save boundary. Keep its bounded UTC receipt,
   then call `stop` separately after the expected save is stable.
9. Promote unique retained evidence to the configured authoritative permanent
   store and verify it before releasing capture scratch as promoted. Do not keep
   using a released allocation.

The tool does not launch or stop MO2/Skyrim. Use `$mo2-control` for the owned
runtime lifecycle, `$steamvr-null-hmd` for null-HMD changes, and
`$shader-cache-control` before launch when shader recompilation can be avoided.
