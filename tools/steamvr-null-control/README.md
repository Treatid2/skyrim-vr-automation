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
Lock acquisition is bounded by `-TransactionLockTimeoutMilliseconds`.

SteamVR may rewrite `steamvr.vrsettings` while the null runtime is active. A
restore therefore reconstructs the applied settings contract from the exact
pre-apply backup plus the receipt-bound null profile. Apply copies the exact
profile bytes into its evidence directory and binds that stable path and hash
in the receipt, so plugin-cache replacement cannot strand a later restore. A
legacy receipt may use a caller-supplied profile only when its SHA-256 matches
the receipt. Restore accepts byte-only
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
central bounded-process controller. The probe and its process-tree cleanup are
charged to the outer readiness deadline. Shared-memory protocol versions are
admitted before size selection, and access-denied state is surfaced distinctly
from a provider that is simply not running. A probe cannot outlive its timeout.
If a start or qualification attempt fails, cleanup stops only
SteamVR-root-owned processes whose creation time belongs to that attempt and
reports the verified survivor inventory.

Readiness polling keeps an incremental identity/offset cache and reads at most
`LogTailMaxBytes` of new payload from the shared `vrserver` log. Its retained
proof, including first-line framing, is capped to the same size. A final bounded
read through the currently selected path rejects replacement, truncation, or
in-place mutation before lines are published. Runtime evidence reports payload
and proof byte counts plus cache usability, reuse, and resynchronization state.
Decoding, hashing, and publication are charged to the startup deadline, so a
large historical log cannot turn one poll into an unbounded whole-file read.
The polling loop reserves a final bounded log-read window and records its
deadlines, attempt count, and confirmation outcome in the runtime receipt. A
timed-out confirmation invalidates readiness and performs exact-attempt cleanup
before attempting to persist diagnostic evidence. Accepted receipt bytes are
staged and validated privately, then the absolute deadline is checked after
staging and again immediately before atomic publication. A late admission never
publishes the accepted stage; it blocks measurement and cleans up the exact
attempt. Before launch, schema-v2 receipt authority is atomically replaced with
a nonaccepted record carrying a new `attemptId`; a prior accepted attempt can
therefore never remain current during a retry. If that replacement fails, the
controller refuses to launch. Receipt-write failure remains diagnostic and
cannot bypass mandatory cleanup or convert a failed attempt into success. Any
unexpected post-launch exception returns the same explicit failed-admission
envelope: measurement is blocked, available confirmation state is retained,
receipt persistence is reported with any error, and cleanup is either verified
or identified as incomplete. Private accepted-stage removal is verified. A
surviving stage remains non-authoritative and its exact path and removal error
are returned and written to the public nonaccepted receipt when possible.
Operator diagnostics never describe unverified cleanup as successfully stopped.

```powershell
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -IsolateExternalDisplayRedirectors -Compact
.\Invoke-SteamVRNullControl.ps1 start -EvidenceDirectory <session-evidence> -Compact
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
