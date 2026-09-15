# MO2 Profile Control

`Invoke-MO2ProfileControl.ps1` inspects, registers, enables, disables, or restores one exact
mod marker in an MO2 profile's `modlist.txt`. Every mutation retains a backup and
emits a receipt; it does not launch MO2 or select a fallback profile. `-WhatIf`
previews enable and disable operations without creating evidence or changing the
profile.

For elevated use, follow `../mo2-control/APPROVALS.md`. Every result exposes an
exact command-specific `approval.reusablePrefix`. `inspect` is read-only; every
profile mutation remains a one-shot approval because it overwrites
`modlist.txt` under an exact backup transaction. Do not invoke it through a
path variable, `-Command`, pipeline, or constructed command string.
Use `-Compact` for a single-line JSON result in orchestration logs.

Every target profile has one deterministic per-user control directory keyed by
its canonical `modlist.txt` path. Mutations serialize on that target-owned lock
and persist an authoritative preimage and journal there before replacement;
caller evidence directories are mirrors, not recovery authority. The next
command recovers or finalizes a nonterminal transaction before planning against
the live profile. Unclassified live drift fails closed for manual review.

`-ProfilePath` accepts either the profile directory or its exact `modlist.txt`
leaf (`-ModListPath` is an alias). Results and receipts preserve the legacy
`profilePath` leaf while also reporting unambiguous `profileName`,
`profileDirectory`, and `modListPath` fields.

`register` requires an exact deployed mod directory and proves that no marker
already exists. It inserts one disabled marker by default at `End`, `Before`,
or `After`; relative placement requires one exact `RelativeToMod`. Prefer the
workspace controller, which also proves that the mod did not predate the task.

`register-winning` registers and enables a new mod immediately before the
earliest enabled loose-file provider of every exact `WinningPaths` entry.
`ensure-winner` enables and repositions an existing marker using the same
calculation. Both require `ModsDirectory`, prove the target supplies every
path, retain an exact modlist backup, and record all displaced providers plus a
postcondition. MO2 overwrite, unmanaged files, and archives are outside this
proof; use VFS evidence when those sources matter.

For more than one winning path in a direct `pwsh -File` invocation, use
`-WinningPathsFile`. It accepts either a JSON string array or one relative path
per line (blank lines and `#` comments are ignored), then combines and
deduplicates those entries with any inline `-WinningPaths` values.

For noninteractive orchestration, pass `-Confirm:$false` only after the caller
has authorized the exact transaction. A bare `-Confirm` requests an interactive
PowerShell prompt and is converted into a clear blocked error when no prompt
host exists. `-NoExit` prevents the script from terminating a larger host.

The default blocking process set is `ModOrganizer`, `SkyrimVR`, and
`sksevr_loader`. `-BlockingProcessNames` exists for alternate installations and
isolated fixtures; an operational override must still name every process that
can own the target profile.

The normal task flow keeps all of those processes closed. When the human has
said `Lease`, pass the public `-HumanLeaseId`, the exact configured
`-ConfigPath`, and the leased profile. The controller first runs the
exact-profile human mutation gate: Skyrim/loader must be closed, RootBuilder
must be inactive, the selected profile must match, and MO2 must be either closed
or one exact unblocked main window. A committed marker change made while MO2 is
open automatically invokes the supported `ModOrganizer.exe refresh` command
and returns `committed-and-refreshed`. If the file transaction commits but the
refresh cannot be proven, it returns `ok=false`, state
`committed-refresh-required`, and retains the exact transaction receipt; it
does not pretend the committed bytes were rolled back.

Run `tests/Test-MO2ProfileControl.ps1` after changing the contract.
