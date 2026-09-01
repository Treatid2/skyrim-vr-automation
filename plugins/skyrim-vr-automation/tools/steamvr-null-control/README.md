# SteamVR null-HMD control

`Invoke-SteamVRNullControl.ps1` transactionally inspects, applies, starts, and
restores the Valve null-HMD route. Apply always takes an exact settings backup,
and restore requires its hash receipt.

Applying settings is not runtime proof. `start` launches SteamVR and succeeds
only after the current `vrserver` session logs both the Valve null driver load
and `Active HMD set to null.<configured serial>`. `inspect` therefore reports
`null-configured-runtime-stopped` separately from
`null-runtime-active-unqualified`. A qualified start also requires the
`codex_head_pose` provider to load, register its tracked device, acknowledge its
versioned shared-memory state, and appear as a valid standing HMD to the bundled
independent OpenVR probe.

The profile sets `dashboard.enableDashboard=false` so the generic-HMD
laser-mouse/dashboard route cannot be summoned. A resident `vrdashboard.exe`
is retained as process telemetry; its presence alone is not an input-conflict
signal. The controller never edits Valve's bindings and does not invent
controller devices.

Valve's null display driver does not provide the controlled standing pose this
automation requires. The separately installed `codex_head_pose` server driver
supplies one HMD pose and is mapped to `/user/head` with SteamVR
`TrackingOverrides`. Its default eye height is 1.68 metres; the controller can
update the pose through `Local\CSXVRHeadPose-v2`. The returned `inputContract`
marks the HMD pose provider ready only after both driver acknowledgement and an
application-observed OpenVR qualification. Controller input remains
unavailable, replay readiness remains false, and the broader measurement policy
remains fail-closed until its other runtime conflicts are separately qualified.

Before `start`, the controller reads the OpenVR registration file (normally
`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`) and inventories every external
driver manifest with exact paths and hashes. An external driver declaring
`redirectsDisplay=true` conflicts with the forced null display path: `inspect`
returns `external-driver-conflict`, and `start` refuses with the exact driver
inventory. Use `-OpenVRPathsPath` for a nonstandard registration file. This
preflight also refuses startup when a registered driver cannot be classified;
it does not silently mutate or unregister third-party drivers.

For an MO2-launched application, pass both `-MO2ProfilePath` and
`-MO2ModsPath`. The controller reads the exact profile's `modlist.txt` and
refuses `start` when any enabled mod provides `Root\openvr_api.dll` or
`openvr_api.dll`; this catches renamed OpenComposite/OCU selectors by effective
root-file provenance rather than a legacy display name. The check is read-only
and never disables a mod. Omitting both parameters remains valid for
non-MO2 applications, but does not establish the application's SteamVR route.

For a measurement-qualified transaction with one classified redirector, pass
`-IsolateExternalDisplayRedirectors` to `apply`. The controller backs up and
hashes the exact OpenVR registration file, binds the selected driver root and
manifest hash into the apply receipt, removes only that registration, and
verifies that the remaining inventory is complete and conflict-free. If more
than one redirector is present, name every exact root in the
`-ExternalDisplayRedirectorRoot <root1>,<root2>` array. `start` refuses registration drift;
`restore` refuses to overwrite semantic drift and restores the exact pre-apply
bytes only when the isolated state and suppressed manifests remain qualified.
Formatting-only changes are accepted using a canonical semantic hash. The
expected isolated document is always rebuilt from the exact registration
backup by removing each unique recorded target exactly once; a receipt semantic
hash is corroboration, not authority. Duplicate or missing targets and any
receipt/backup disagreement fail closed.
The normal fail-closed path remains unchanged when this option is omitted.

Apply and restore are recoverable multi-file transactions. Every command first
acquires one bounded exclusive lock keyed by the canonical SteamVR-settings and
OpenVR-registration paths. The authoritative write-ahead journal lives beneath
the stable per-user `TransactionControlRoot`, not beneath a caller-selected
evidence directory. Evidence journals are secondary mirrors. Consequently, a
second caller cannot evade an active operation or its recovery merely by
choosing a different evidence directory. Before changing either live file, the
controller records every exact target, preimage, and expected hash. A failed
operation restores and verifies every target before reporting rollback; an
incomplete rollback is reported as `recovery-required`, never as success. Any
next command reconciles a nonterminal authoritative journal before proceeding
(after first stopping SteamVR when required), and a repeated restore recognizes
a committed exact baseline as `already-restored`. An active committed apply
retains ownership of its original evidence directory; another apply returns
`already-applied`, while start/restore reject a conflicting explicit directory.

The control root is fixed beneath the Windows LocalApplicationData folder at
`CSX-VR-Automation\SteamVR\transactions`; callers cannot select different lock
domains. The fixture-only `CSX_STEAMVR_TRANSACTION_ROOT` override is rejected
unless both settings and control paths are inside the OS temporary directory.
Lock acquisition is bounded by `-TransactionLockTimeoutMilliseconds`. The
retained lock file is owner evidence, not the lock itself: the operating-system
file handle provides exclusion and is released when its process exits. Timeout
errors include the readable PID and process-start identity of the current owner
when available, which distinguishes a live holder from a stale filename.

SteamVR may rewrite `steamvr.vrsettings` while the null runtime is active. A
restore therefore reconstructs the applied settings contract from the exact
pre-apply backup plus the receipt-bound null profile. It accepts byte-only
formatting changes and runtime-managed changes confined to the top-level
`GpuSpeed` and `LastKnown` sections only when every controller-owned null-HMD
setting still matches. Changes to a controller-owned key or any other section
remain unclassified drift and fail closed. The validation route and exact
difference paths are returned as `settingsRestoreValidation`; rollback retains
the exact accepted live bytes rather than assuming they equal the originally
written serialization.

For a specifically authorized coexistence diagnostic, `start
-AllowExternalDisplayRedirector` leaves every vendor registration untouched,
records the exact conflict inventory and override in the runtime receipt, and
keeps the resulting null-HMD route unqualified. It is not a compatibility or
measurement-readiness claim.

The default null-HMD profile is resolved from
`../../profiles/steamvr-null.profile.json`. Pass `-SettingsPath` and
`-SteamVRRoot` for nonstandard Steam installations.
The controller requires PowerShell 7 or newer. Windows PowerShell 5.1 returns
the structured state `unsupported-powershell-version` with an exact `pwsh.exe`
migration instruction before reaching unsupported JSON parameters.

`stop` first requests SteamVR's normal shutdown and waits for a closed-state
postcondition. If the null-driver runtime does not accept that request, inspect
the returned exact process inventory and retry with `stop -Force`. The forced
path validates every target executable is inside `SteamVRRoot` before stopping
it; it does not target Steam, Virtual Desktop, or unrelated same-name binaries.
Same-name processes outside the configured root are reported as unproven but
are never used as stop, start, apply, or restore blockers.

Runtime qualification invokes the independent OpenVR pose probe through the
central bounded-process controller. A probe cannot outlive its timeout. If a
start or qualification attempt fails, cleanup stops only SteamVR-root-owned
processes whose creation time belongs to that attempt and reports the verified
survivor inventory.

Readiness polling keeps an incremental identity/offset cache and reads at most
`LogTailMaxBytes` from the shared `vrserver` log. The byte cap, rather than the
startup deadline, bounds one file read, so a large historical log cannot turn
one poll into an unbounded whole-file read. A final bounded read is still
attempted when process
startup consumes the polling budget. Current Valve evidence using either
`Active HMD` or `Using existing HMD` is accepted for the exact configured null
serial, and recent matching log lines are returned when qualification fails.

```powershell
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -IsolateExternalDisplayRedirectors -Compact
.\Invoke-SteamVRNullControl.ps1 start -EvidenceDirectory <session-evidence> `
  -MO2ProfilePath <exact-task-profile> -MO2ModsPath <mods-directory> -Compact
.\Invoke-SteamVRNullControl.ps1 inspect -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Force -Compact
.\Invoke-SteamVRNullControl.ps1 restore -EvidenceDirectory <session-evidence> -Compact
```

Install and independently qualify the provider through
`../steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1`. Installation
requires SteamVR to be closed and uses the bundled native package by default.

Launch Skyrim only after `start` or `inspect` returns current-session runtime
proof, and do not interpret the `-unqualified` state as replay or measurement
readiness. Also use an MO2 profile that disables OpenComposite; a running null
SteamVR instance does not prove an application bypassing SteamVR is attached to
it.

Run `Test-SteamVRNullControl.ps1` after changing the control contract.
