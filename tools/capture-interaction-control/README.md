# Capture interaction control

`Invoke-CaptureInteraction.ps1` is the host-side observation/action layer over
DevBench recording, atomic OpenVR tracked-set input, and the CSX screenshot v1
service. It does not encode video and does not invent missing game state.

Every session has one UUID and one durable session document. Sequence mode first
reads the screenshot API capabilities and verifies the requested frame count and
wall-clock duration against the runtime's exact positive integral limits. An
incompatible request fails with the largest compatible frame count before a
session directory is created or state recording starts. State recording then
starts first; optional stereo capture starts second and rolls recording back if
it cannot be accepted. Stop reverses that order so the state trace encloses all
captured frames. `none`, `on-demand`, and `sequence` visual modes all retain the
same interaction and state contract.

Partial-start recovery distinguishes a pre-dispatch refusal, a retained
accepted receipt, and a dispatched request whose result was lost. Accepted
screenshot receipts remain available for exact cancel-and-wait cleanup even if
the controller's final evidence write fails. A dispatched screenshot or
recording without a retained identity remains `cleanup-uncertain`; stopping the
other lane does not manufacture terminal proof for it.

```powershell
pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 start `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -RuntimePath D:\CSX-MO2-Sessions\...\devbench-runtime.json `
  -VisualMode sequence -FrameIntervalMs 500

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 observe `
  -SessionDirectory D:\CodexScratch\...\interaction

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 act `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -ActionName accept -ObserveAfterAction

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 wait-save `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -SaveDirectory D:\MO2\profiles\Task\saves -SaveNamePattern 'Save3*'

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 stop `
  -SessionDirectory D:\CodexScratch\...\interaction
```

`observe` writes `latest-observation.json` and returns a composite snapshot of
the latest committed CSX frame, screenshot request state, recording status,
game state, open menus, tracked-set injection state, and the current physical
HMD/controller set. `data.observation.frameSubmission.path` is the image to
submit to an image-capable model. It is deliberately the newest completed
artifact, not the oldest unprocessed member of a backlog. Stereo artifacts and
the CSX frame manifest remain intact for evidence.

Named actions are declared in `actions.v1.json`. Controller actions first use
the read-only DevBench tracked-set observation, preserve all three current
poses, neutralize stale input state, and then compile a bounded atomic sequence.
The call waits for that exact sequence generation to become terminal before it
returns, preventing a following action from colliding with an active owner.
`key-tap` uses DevBench keyboard input. `-DirectTool` with
`-DirectArgumentsJson` is an explicit passthrough for operations not represented
by the catalog; every action is appended to `actions.ndjson`.

A direct `game load` is dispatched once. Require its receipt to report
`queued: true`, then verify current `playerLoaded` and the exact target cell
through read-only observations or the DevBench `playerLoaded` state barrier.
Do not wait for a transient load lifecycle event or replay the load when that
event was not observed.

`wait-save` uses the session start timestamp by default, parses explicit
`-SinceUtc` values as `DateTimeOffset`, compares only UTC values, and requires a
matching `.ess` file to retain identical size and last-write time for the
requested stability interval. Its bounded receipt includes the resolved UTC
boundary and every observed candidate; it never stops the capture implicitly.

The tool never launches Skyrim or MO2 and never allocates scratch implicitly.
The caller supplies a managed capture allocation or another explicit evidence
directory and remains responsible for promotion/release. Runtime identity
verification is on by default; the bypass exists only for isolated tests.
