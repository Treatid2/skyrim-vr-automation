---
name: steamvr-null-hmd
description: "Inspect, apply, restore, or stop SteamVR's Valve null-HMD configuration through a transactional controller. Use for null HMD, HMD null, SteamVR null driver, headless VR testing, SteamVR test-runtime switching, restoration of normal headset settings, or investigation of the exact SteamVR processes and overrides involved."
---

# SteamVR Null HMD

Use the bundled controller rather than editing `steamvr.vrsettings` directly.

## Load the contract

Before acting, read `../../tools/steamvr-null-control/README.md` completely and
`../../tools/steamvr-head-pose-control/README.md` completely, then
inspect the parameter block in
`../../tools/steamvr-null-control/Invoke-SteamVRNullControl.ps1` and
`../../tools/steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1`.
Treat the
repository-root `AGENTS.md` as binding operational policy. The bundled default
profile is `../../profiles/steamvr-null.profile.json`.

Resolve these paths from this skill's installed location; do not assume a
particular drive letter for the plugin itself.

## Operating sequence

1. State in commentary that this skill is governing the null-HMD operation.
2. Run `inspect -Compact` first and retain the JSON result as the before-state.
   If it reports `external-driver-conflict`, do not start SteamVR; report the
   exact redirecting driver inventory. For an authorized measurement run,
   preview and apply `-IsolateExternalDisplayRedirectors`; when more than one
   redirector exists, specify every exact root in the
   `-ExternalDisplayRedirectorRoot` array. A Virtual Desktop driver registration
   is retained as inventory evidence but is never classified as a null-HMD
   conflict and must not be isolated for null-HMD admission.
3. When the test also uses MO2, complete MO2 route admission before any
   null-HMD mutation. Apply `$mo2-control`, request access with
   `-RuntimeRoute SteamVRNull`, select or create the exact task workspace, and
   run `validate -AccessId <literal-access-id> -RequireClosed`. Require the
   `runtime-route-provider` check to pass, proving that the selected profile
   exposes no enabled OCU or other root OpenVR replacement. Do not prepare or
   launch MO2 yet. If admission fails, leave SteamVR unchanged and release the
   access lease when no immediate profile-local correction is authorized.
4. Before `apply` or `restore`, prove SteamVR is closed. Use `stop -Compact`
   first; if it does not close, review the returned exact process inventory
   before using `stop -Force -Compact`.
5. Create or select one attributable evidence directory for the test. The
   target-owned transaction journal, rather than this caller-selected folder,
   is authoritative. Preview
   `apply` or `restore` with `-WhatIf`, then perform the authorized operation
   using the same `-EvidenceDirectory`. For an MO2-backed `apply` or `start`,
   pass the exact admitted `-MO2AccessId <literal-access-id>` and
   `-MO2Profile <literal-profile-name>` on every call. The controller repeats
   the closed-state `SteamVRNull` provider admission and binds its public proof
   into the transaction receipt; it refuses a changed profile or provider
   inventory at `start`. Never use `-Standalone` for Skyrim through MO2.
6. Parse the JSON postcondition. After `apply`, require `state` to be
   `null-applied` and the effective profile checks to match. If isolation was
   requested, also require a conflict-free inventory and a receipt containing
   the exact registration and manifest hashes. After `restore`, require both
   the settings and OpenVR registration hashes to match their exact backups.
7. Require `headPoseProvider.state` to be `ready` and independently run the
   head-pose controller's `qualify` command. Qualification requires both the
   driver's shared-memory acknowledgement and a valid standing HMD pose seen
   by a separate OpenVR application. Treat any unqualified runtime as rendering
   availability only; do not replay input or collect measurements. Controllers
   remain explicitly unavailable. Treat a resident `vrdashboard.exe` as
   telemetry; `dashboard.enableDashboard=false` is the dashboard contract.
8. For an MO2 test, return to the already admitted `$mo2-control` lifecycle and
   use the same access lease, task workspace, and `SteamVRNull` route for
   `prepare` and launch. Revalidate the route if the profile changed. Never
   substitute an OCU-qualified workspace after the null-HMD transition.
9. Run `inspect -Compact` again and preserve the before/after results, exact
   backup, receipt, hashes, and evidence-directory identity.

## Safety and recovery

- Inspection does not initiate a new runtime mutation, but every command takes
  the target lock and must finish recovery of an already-pending authoritative
  transaction before reporting state. Preserve the reported recovery evidence.
- Never apply or restore while any SteamVR process remains. Do not stop Steam,
  Virtual Desktop, OpenComposite, or unrelated same-name processes.
- `apply` must create a new exact backup and receipt. Never replace an existing
  backup; use a new evidence directory only after the prior transaction has
  been restored. An active committed apply owns its original evidence folder.
- `restore` must use the evidence directory from its corresponding apply and
  must verify the receipt, retained profile, and backup hashes. New apply
  receipts retain the exact profile bytes in their evidence directory; a
  legacy receipt may use another profile path only after an exact hash match.
  Isolation restore must fail closed on registration or suppressed-manifest
  drift. Retain all backups afterward.
- Use `-SettingsPath` and `-SteamVRRoot` for nonstandard installations. Never
  silently fall back to the default installation paths.
- Invoke the controller with PowerShell 7 `pwsh.exe`. Do not work around its
  explicit Windows PowerShell compatibility rejection.
- A launch failure or CTD is evidence. Record the runtime state and analyze the
  result before another attempt.

When a test also uses MO2, split its lifecycle at the runtime boundary: admit
and validate the exact `SteamVRNull` profile first, perform the null-HMD
transition second, and only then prepare or launch MO2. Do not infer which
runtime Skyrim actually used from the presence of SteamVR processes alone;
record the route separately.
