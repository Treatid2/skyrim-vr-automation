# Bounded process control

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
process, suspends it only around `GetThreadContext`, and always resumes it in a
`finally` block.

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
