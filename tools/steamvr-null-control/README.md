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
signal. The controller never edits Valve's bindings. The separately packaged
native provider supplies the opt-in passive controller devices.

Valve's null display driver does not provide the controlled standing pose this
automation requires. The separately installed `codex_head_pose` server driver
supplies one HMD pose and is mapped to `/user/head` with SteamVR
`TrackingOverrides`. Its default eye height is 1.68 metres; the controller can
update the pose through `Local\CSXVRHeadPose-v2`. The returned `inputContract`
marks the HMD pose provider ready only after both driver acknowledgement and an
application-observed OpenVR qualification. The default null profile enables
the native passive left/right pair. Every null-route application probe passes
`--require-controllers`: exact passive serial/provider identity, distinct hand
roles, valid connected finite standing and compositor poses, 100 neutral legacy
input samples and zero button/touch events must pass before runtime admission.
Head-only or legacy probe output fails this gate. The returned input contract
distinguishes `controllerPresenceReady` from `controllerInput=passive-neutral`;
replay readiness remains false, and the broader measurement policy
remains fail-closed until its other runtime conflicts are separately qualified.

Passive devices must not rely on synthetic activity to avoid standby. The
controller-required production profile declares
`power.turnOffControllersTimeout=0` (Never in the installed SteamVR schema).
Apply stages and hash-binds that exact profile, changes only this power leaf,
and preserves other existing power settings. Effective-state inspection checks
the typed integer value; measurement readiness additionally requires
`controllerInactivitySuppressed=true`. This is not proof that controller roles
remain valid: the independent required-controller probe is still mandatory.

An explicitly selected `-Standalone` diagnostic profile may declare a positive
integer timeout for a bounded idle-standby comparison. Pass the same explicit
profile and `-Standalone` to apply/start; this never authorizes Skyrim through
MO2. Its effective timeout can match and startup can qualify initial presence,
but `controller-inactivity-timeout-not-suppressed` blocks measurement readiness.
Non-standalone apply/start require Never when power is declared. Profile power
must contain only this one nonnegative Int32-range JSON integer; malformed
values or an existing non-object power section fail before mutation.

Restore reconstructs this controlled leaf from the receipt-bound profile and
rejects timeout drift as well as unclassified changes to other power leaves.
The exact original bytes are restored, including absence of a power section.
Historical receipt-bound profiles without power remain restorable and acquire
no new power ownership; they cannot establish inactivity-suppressed readiness.

Before `start`, the controller reads the OpenVR registration file (normally
`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`) and inventories every external
driver manifest with exact paths and hashes. A non-Virtual-Desktop external
driver declaring `redirectsDisplay=true` conflicts with the forced null display
path: `inspect` returns `external-driver-conflict`, and `start` refuses with the
exact driver inventory. A Virtual Desktop registration remains visible in the
inventory with disposition `ignored-virtual-desktop`; it is not a null-HMD
blocker and is never selected for isolation. Use `-OpenVRPathsPath` for a
nonstandard registration file. This preflight also refuses startup when a
registered driver cannot be classified; it does not silently mutate or
unregister third-party drivers.

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
failed admission, including an unexpected post-launch exception, returns the
same explicit envelope: measurement is blocked, available confirmation state is
retained, receipt persistence is reported with any error, and cleanup is either
verified or identified as incomplete. The primary admission state, failure
observation, active startup deadline, and cleanup completion are recorded as one
timeline in both the returned admission object and the public nonaccepted
receipt. These primary facts are frozen before cleanup, so cleanup delay or a
cleanup exception cannot reclassify the failure. Private accepted-stage removal
is verified. A surviving stage remains non-authoritative and its exact path and
removal error are returned and written to the public nonaccepted receipt when
possible.
Operator diagnostics never describe unverified cleanup as successfully stopped.

```powershell
.\Invoke-SteamVRNullControl.ps1 apply -MO2AccessId <access-id> -MO2Profile <task-profile> -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 apply -MO2AccessId <access-id> -MO2Profile <task-profile> -EvidenceDirectory <session-evidence> -IsolateExternalDisplayRedirectors -Compact
.\Invoke-SteamVRNullControl.ps1 start -MO2AccessId <access-id> -MO2Profile <task-profile> -EvidenceDirectory <session-evidence> -Compact
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
readiness. For an MO2-backed run, acquire a `SteamVRNull` MO2 access lease,
select the exact task workspace, and pass closed-state runtime-route validation
before applying or starting null-HMD. Pass that exact lease's bearer
`-MO2AccessId` and selected `-MO2Profile` to both `apply` and `start`. The
controller independently repeats the `runtime-route-provider` check, requires
the `SteamVRNull` route, and binds the public admission proof into the apply
receipt. `start` rejects lease, profile, or provider-inventory drift. The
explicit `-Standalone` escape is for non-MO2 SteamVR diagnostics only and must
not be used for Skyrim through MO2. A running null SteamVR instance does not
prove an application bypassing SteamVR is attached to it.

Run `Test-SteamVRNullControl.ps1` after changing the control contract.

## Resuming a retained environment under a new access lease

Releasing MO2 access preserves the task workspace; it does not transfer the
shared null-HMD transaction. A committed apply is bound to its recorded lease,
profile, provider inventory, exact receipt/profile backups and target journal.
Reacquiring access for the same task/profile produces a new lease. That does
not make the old apply eligible for `start`: lease drift is deliberately
rejected, and `apply` reporting `already-applied` is not a rebind operation.
There is no supported journal edit or blind restart shortcut.

Auto-Tools owns the shared cleanup/restoration handoff. Calling tasks retain
their intended environment and evidence; they are not required to undo their
profile changes or reconstruct shared baseline state. For an authorised resume:

1. Identify the exact retained task workspace and old transaction/evidence
   directory. Acquire the new `SteamVRNull` lease and validate the exact task
   profile with the closed-state `runtime-route-provider` gate. Keep Skyrim,
   its loader and MO2 closed during the runtime transition; verify SteamVR-root
   processes stopped through the supported controller. Do not stop another
   owner's live experiment or steal its lease.
2. Inspect the authoritative transaction and retained receipts. If the prior
   restore is already committed, retain its verified result and do not replay
   that restore. Otherwise preview `restore -EvidenceDirectory <old-evidence>
   -WhatIf`, then restore that exact prior apply through its receipt-bound
   backup/profile and verify the returned baseline/restoration proof.
3. Apply into a fresh evidence directory with the new exact `-MO2AccessId`
   and `-MO2Profile`, selecting the independently qualified provider package.
   Retain the fresh transaction and public route proof. Start with those same
   identities only after apply succeeds; require current independent
   application-facing head/controller qualification before preparing MO2.

Unclassified settings/registration drift requires investigation after refusal;
it is not permission to replace journals, broaden restore ownership, select
`-Standalone` for Skyrim, or retry with a newly accepted hash.

Some integrated controller versions expose the separately implemented
`-PreserveDesktopUIWindowState` restore option. Use it only when that exact
controller advertises it and the human has explicitly selected preservation
of the two string leaves `DesktopUI.pairing` and
`DesktopUI.settings_desktop`. Take a fresh exact preview and preimage;
commit with its `-ExpectedCurrentSettingsSha256` and retain the selected-result
receipt. It is not general DesktopUI/drift tolerance. A controller without the
option must fail closed on such drift; do not pass undocumented flags or edit
settings by hand. A changed preimage or refused preview requires classification,
not a silent new-hash retry.

This lifecycle guidance authorises no runtime action by itself. Preserve
completed restoration receipts, task-local profile/mod/cache state and the
current runtime owner's authority when the workflow is held.

## Explicit preservation of two DesktopUI strings

Ordinary restore still restores the exact original backup and refuses unrelated
drift. Only when the human has selected narrow preservation, use
`restore -PreserveDesktopUIWindowState`. This preserves exactly the present,
actual, exact-case, string-valued `DesktopUI.pairing` and
`DesktopUI.settings_desktop` leaves; it does not interpret their contents or
whitelist the whole DesktopUI section. Both leaves must also be present strings
in the receipt-bound baseline. Missing/malformed sections/leaves, dotted-key
aliases, case changes, controlled-key changes and any other unclassified drift
are refused. Existing runtime-managed GpuSpeed/LastKnown and typed dashboard
history differences are admitted but restored from the baseline, not preserved.

Preview first with the original apply evidence directory, while SteamVR is
closed. Require `ok=true`, `state=dry-run`, and the expected preservation policy.
Commit requires the exact SHA-256 returned by this preview; do not automatically
accept a changed hash by recomputing it after refusal.

```powershell
# All existing exact path, closed-runtime and evidence-ownership gates remain.
.\Invoke-SteamVRNullControl.ps1 restore -EvidenceDirectory <original-apply-evidence> -PreserveDesktopUIWindowState -WhatIf -Compact
.\Invoke-SteamVRNullControl.ps1 restore -EvidenceDirectory <same-original-apply-evidence> -PreserveDesktopUIWindowState -ExpectedCurrentSettingsSha256 <preview-data.settingsRestoreSelection.preimageSha256> -Compact
```

`settingsRestoreSelection` schema 1 has policy
`baseline-plus-exact-desktopui-strings`, apply transaction identity, exact
baseline/preimage/result hashes and the two `preservedStrings`. A committed
selection additionally retains its distinct `resultPath` and immutable apply
receipt digest. `expectedSha256` in preview and `restoredSha256` on success
identify this selected result, **not** the original whole-file backup.
The new restore receipt and target-owned journal retain this selection; the old
apply receipt/profile/backup are never rewritten. All settings input parsing
for this option is bounded to 1 MiB with duplicate keys refused.
Untouched baseline values are copied as raw JSON, including full-precision
numbers. Drift comparison uses exact decimal coefficient/exponent identities
from the current raw JSON, so changes hidden by floating-point parsing refuse.
For receipt-profile-owned floating-point leaves only, the exact declared decimal
or the finite binary64 value's canonical invariant `G17` runtime spelling is
accepted, with identical binary64 bits required. JSON numbers with exactly equal
normalized decimal identities admit integer/decimal formatting such as `90.0`
to `90` and `0.0` to `0`; their PowerShell CLR types need not match. The explicitly
integer-schema power timeout still refuses floating-point representations. For
example, profile `1.68` and runtime `1.6799999999999999` are the same controlled
eye height. This is not a tolerance: changed bits (including signed zero), type
changes to a non-number kind and arbitrary extra precision still refuse. The whole-document check
uses that same admitted owned-leaf result; unowned values and additional keys
retain strict raw-decimal, type, case and structure comparison. Numeric settings
are restored from the baseline, not preserved as additional selected UI leaves.

Staging verifies the accepted preimage and selected result hashes again before
dispatch. Failure after mutation rolls back to the exact accepted live bytes,
including those UI strings. Interrupted operations use the existing target-owned
journal recovery. A repeat after a committed preservation restore recognizes
only the exact recorded result after reconstructing the selection from the
retained baseline and validated preimage; it never adopts new live UI drift.
Omitting the option on that repeat does not silently revert a completed selection.
A changed result/preimage/receipt/profile or selection refuses. This is a bounded
cooperative-controller transaction, not protection against a hostile same-user
writer racing the final filesystem replacement.

Run `Test-DesktopUIRestore.ps1` as well as `Test-SteamVRNullControl.ps1` after
changing this contract. Both use temporary fixtures; passing them is source
qualification, not live SteamVR or in-game qualification. Auto-Tools owns shared
recovery/known-state handoff; caller experiment environments remain retained.

Runtime startup and every application-facing probe also require the exact
owned `HeadPoseDriverRoot` and committed schema-3 installation custody described
in the head-pose README. Exactly one canonical registration and one same-name
provider are required. Manifest/driver/probe/OpenVR DLL/settings/input-profile
hashes are enforced against independent bundled provenance, not merely reported.
An explicitly authorized custom build uses
`-HeadPoseExpectedProvenanceSha256 <sha256>`; it retains distinct digest authority.
The selected profile cannot substitute another executable as its probe.

The creator must match the configured `vrserver.exe`, loaded driver module, and
current runtime server PID/start identity. `runtime.packageAuthority` retains
the root, committed transaction, provenance and verified artifact hashes.
`head-pose-package-not-qualified` is a measurement blocker and refuses startup
before launch; behavioral head/controller readiness cannot override it. Old
install markers require an explicit closed-state upgrade, not an automatic
rewrite. Source fixtures, installation custody and standalone presence still do
not prove in-game controller roles or game fixture qualification.
