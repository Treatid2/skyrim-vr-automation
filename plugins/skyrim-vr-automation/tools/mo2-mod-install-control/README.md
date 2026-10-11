# Native-only installer admission foundation

This source-only module validates a proposed additive native mod. It does not
install, enable, refresh, obtain/transfer a lease or confer content authority.
There is deliberately no public deployment entry point yet. Historical RaceMenu
plans are not this schema and must not be silently reinterpreted or replayed.

`Get-VerifiedNativeInstallPlan` requires caller-pinned plan SHA256, candidate
commit, exact profile and public lease identity. The public lease is correlation
only; a matching value does not authenticate an owner. The existing private
holder gate remains required for every future mutation. Never put a private
capability into the plan, result, log or requester message.

The closed-field `mo2.native-install-plan.1` object contains `schema`, `installId`
(32 lowercase hex characters), `sourceCommit` (the caller's full commit),
`profile`, `leaseId`, `modName`, `buildReceipt` (`path`, `sha256`) and `files`.
Each file contains exactly `sourcePath`, `relativePath`, `bytes`, `sha256`.
Metadata is strict UTF-8 JSON with no duplicates/case aliases, comments or trailing
commas. Plan limit64KiB; receipt1MiB; depth12;20000 JSON nodes;1..32 files,
256MiB/file and512MiB total. Integer sizes are typed; numeric strings, Booleans
and nonintegral JSON numbers do not qualify. Hashes are lowercase hex.

Only `SKSE/Plugins/<name>.dll` and matching optional `<name>.pdb` are admitted.
The DLL is required. No INI, movie, shader, script, executable, archive or arbitrary
Data payload is admitted. Case-colliding targets and duplicated sources refuse.
The source filename must match the target. Source and metadata paths must be
explicit local Windows drive paths, not UNC/device/ADS/environment expansions
or reparse paths. No installation layout flattening is involved.
Drive spelling alone is not proof: admission checks GetDriveType and the current
QueryDosDevice mapping, conservatively accepting only fixed local HarddiskVolume
devices. Remote, SUBST/path-backed and unknown namespaces refuse for both metadata
and payloads. The same opened read handle supplies its normalized NT path and
volume/file ID before and after reading. Its exact path must match the current
mapping; duplicate physical payload identities (including hard links) refuse.
Each verified file includes `sourceIdentity`, not a reusable custody capability.
Profile/mod names also refuse reserved COM/LPT superscript 1/2/3 forms and suffixes.

The caller-pinned build receipt must contain the exact `commit` and a bounded
`artifacts` array. Every selected file must have exactly one matching issued
`path`, integer `bytes` and `sha256`; source size/hash must then match. Other
Broker receipt metadata or unselected artifacts confer no extra authority.
A pinned receipt is evidence supplied by the caller, not independent Broker
authentication, a successful-compilation verdict, executable/DLL loadability,
content permission or runtime qualification. The calling owner must separately
evaluate the original build transaction before authorising installation.

Reads use non-write/delete-sharing handles while hashing in bounded chunks.
The30s default/60s maximum deadline is checked between reads. A single blocked OS
filesystem read is not hard-preempted by this module; run substantial validation
under the owning bounded process wrapper. The returned result is a point-in-time
read-only validation snapshot. Handles close before return; it is NOT durable
file custody and must not authorise later staging or deployment without fresh
validation/pinning. No physical ancestor identity/atomic cross-file snapshot is
claimed. Unknown current lease/process/RootBuilder/UI state stays unknown.
Mapping checks are sequential observations, not an atomic DOS-namespace generation
or protection against an undetectable change-and-revert between checks. Handles
pin the actual files read; a later installer must freshly pin its deployment set.

`Open-VerifiedNativeInstallPayloadCustody` uses the same complete admission core
but retains every verified payload's non-write/delete-sharing read handle until
the returned in-process `IDisposable` object is disposed. It rechecks all retained
paths/namespace/file IDs/lengths after the last payload read. Failure at any point
closes every acquired handle; successful callers must use `try/finally` and call
`Dispose()` promptly (idempotent). The acquisition deadline does not automatically
expire custody; the future staging owner must enforce its complete process budget.
The immutable `ValidationJson` is evidence only, not serializable handle custody,
private holder authority, a restart/replay capability or installation permission.
No source payload stream, filesystem staging/publication method or generic callback is exposed.
These file handles block cooperating writes/deletes to their files, not DOS mapping
changes or all ancestor mutation; no atomic cross-file/ancestor identity claim.
Disposed custody is ended, even though its captured validation remains readable.

The V2 custody object provides one `CopyToValidatedStreams(Stream[], DateTime)`
attempt. Supply exactly one empty, readable/writable/seekable exact FileStream or
MemoryStream per validation-file ordinal, and an absolute UTC deadline no more
than60s ahead. Custom subclasses and duplicate stream references refuse. All
targets are checked before the first write; their reference array is cloned.
Bytes come from the SAME pinned source handles, not reopened paths. Each copied
source must still match its admitted size/hash, and the complete destination set
is independently reread after the final write before a content receipt returns.
Expected sizes/hashes are cloned separately from mutable caller projections.
The deadline is checked between bounded64KiB I/O operations; blocked OS I/O is
not hard-preempted. Use the owning bounded process wrapper for the whole workflow.
Dispose and copy serialize on the custody object. Any failure closes all source
handles and returns no qualified copy receipt. A second attempt refuses; there
is no automatic retry. Caller-owned destination streams remain open and any
partial bytes remain untouched for accountable owner recovery; do not confuse a
partial write with verified content or silently delete it.

This is stream-content qualification, NOT a protected Data-root stage, unique
destination/ancestor identity proof, durable disk flush, atomic publication,
holder validation or installation authority. The caller must own destinations
and keep other writers out. A readback is a sequential observation, not protection
against later destination mutation. Successful custody remains held until explicit
Dispose. V2 is initialized independently of the earlier V1/FileProofV1 types so
an already-loaded admission helper does not prevent the new implementation.

The future installer must stage this exact set, persist its uniquely owned
publication journal, and publish a new directory under the supported holder
transaction. It must release that nonreentrant lock before the existing
independently guarded `add-enable` service. Revocation/drift between stages must
retain truthful deployed-not-enabled custody; committed refresh failure is not
rolled back or called ready. Existing add-enable owns DLL priority and conservative
retirement. This module implements admission, in-process payload read custody and
single-attempt verified stream copying, none of the protected filesystem
staging/publication/journal/holder/add-enable stages.

Fixtures use synthetic native bytes and receipts in an explicit fixture root;
they do not launch or manipulate MO2, Skyrim, SteamVR or a real lease.
