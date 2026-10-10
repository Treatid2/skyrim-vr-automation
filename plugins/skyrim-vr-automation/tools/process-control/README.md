# Bounded process control

`-NormalInteractiveUser` is explicit; generic launches retain their default
context. The SteamVR launcher and its original independent probe use this mode.
It requires the exact interactive explorer process in the same user/session,
medium integrity, unelevated and not AppContainer. Child context/path and normal
token access (0x40/0x400/READ_CONTROL) are checked while suspended, before resume.
From a high caller, the documented desktop-parent attribute supplies the normal
token; initial NEW process/thread security uses that token's default DACL/owner
and a medium mandatory label. No existing ACL, token or privilege is edited.
Temporary inheritance is restricted to three owned stream handles; only those
duplicates are removed from the parent. Read-only impersonation is reverted and
verified. Missing context, identity drift, access denial or expired admission
fails closed. Public receipts contain identities, not private handles.
`Test-NormalInteractiveProcess.ps1` uses benign Windows fixture processes only.

`Invoke-BoundedProcess.ps1` runs an exact executable with an argument array,
captures each attempt, enforces a wall-clock timeout, and writes an optional
receipt plus stdout/stderr logs. It retries only when output matches an explicit
`-RetryPatterns` entry; arbitrary build failures are never retried.

The defaults recognize the transient MSVC dependency `.d.json` permission
failure observed during CSX builds and make at most two attempts.

```powershell
.\Invoke-BoundedProcess.ps1 -FilePath cmake `
  -ArgumentList @('--build', 'build\ALL', '--config', 'Release') `
  -WorkingDirectory 'L:\Source\CSX' `
  -EvidenceDirectory 'D:\Evidence\build'
```

Use `-NoExit` when composing several tools in one PowerShell host.

## Live Windows thread contexts

`Invoke-WindowsThreadContext.ps1` captures bounded AMD64 register and stack
samples from one exact live process/thread identity. It requires the expected
executable path and process start time, verifies that the thread belongs to the
process, rejects the sampler's own thread, and rechecks the owning process plus
thread start identity after every `OpenThread`. It suspends the verified handle
only around `GetThreadContext` and always resumes it in a `finally` block.
Every owned process and thread handle also has a structured close outcome under
`cleanup.handles`. A failed or thrown `CloseHandle` leaves captured samples
available as evidence but returns `cleanup-uncertain` rather than claiming a
fully restored capture.

```powershell
.\Invoke-WindowsThreadContext.ps1 `
  -ProcessId 1234 `
  -ThreadId 5678 `
  -ExpectedProcessPath 'C:\Games\SkyrimVR.exe' `
  -ExpectedStartTimeUtc '2026-08-26T04:09:23.6606299Z' `
  -Samples 10 `
  -IntervalMs 100 `
  -StackBytes 1024
```

Pointer alignment stays in signed pointer-width arithmetic, and register bit
patterns use `BitConverter` instead of direct signed-to-unsigned casts. The
same regression runs under 64-bit Windows PowerShell and PowerShell 7 so host
selection cannot reintroduce the pointer-conversion failure.
