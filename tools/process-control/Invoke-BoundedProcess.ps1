# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$EvidenceDirectory,
    [ValidateRange(1, 10)][int]$MaxAttempts = 2,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600,
    [ValidateRange(100, 30000)][int]$TerminationGraceMilliseconds = 3000,
    [ValidateRange(100, 30000)][int]$StreamDrainGraceMilliseconds = 3000,
    [ValidateRange(0, 10000)][int]$RetryDelayMilliseconds = 250,
    [string[]]$RetryPatterns = @('(?is)\.d\.json.*permission denied', '(?is)permission denied.*\.d\.json'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Invoke-BoundedProcess currently requires Windows job objects.' }
$controllerStartedUtc = [DateTime]::UtcNow

if (-not ('SkyrimVRAutomation.Native.JobObjects' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SkyrimVRAutomation.Native {
    public static class JobObjects {
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const int JobObjectExtendedLimitInformation = 9;
        [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS {
            public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public UInt32 LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public UInt32 ActiveProcessLimit;
            public Int64 Affinity;
            public UInt32 PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
            public Int64 TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public UInt32 TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, UInt32 length);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, UInt32 length, IntPtr returnLength);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

if (-not ('SkyrimVRAutomation.Native.SuspendedProcessLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace SkyrimVRAutomation.Native {
    public sealed class SuspendedProcessLaunch {
        public int ProcessId;
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public IntPtr StdoutReadHandle;
        public IntPtr StderrReadHandle;
    }
    public static class SuspendedProcessLauncher {
        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint STARTF_USESTDHANDLES = 0x00000100;
        const uint HANDLE_FLAG_INHERIT = 0x00000001;
        const uint GENERIC_READ = 0x80000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct STARTUPINFO {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, ref SECURITY_ATTRIBUTES attributes, int size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES attributes, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(
            string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory,
            ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", EntryPoint="CloseHandle", SetLastError=true)] public static extern bool CloseNativeHandle(IntPtr handle);

        static string Quote(string value) {
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') {
                    result.Append('\\', slashes * 2 + 1).Append(c);
                    slashes = 0;
                    continue;
                }
                result.Append('\\', slashes).Append(c);
                slashes = 0;
            }
            result.Append('\\', slashes * 2).Append('"');
            return result.ToString();
        }

        public static SuspendedProcessLaunch Launch(string filePath, string[] arguments, string workingDirectory) {
            var security = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = 1 };
            IntPtr stdoutRead = IntPtr.Zero, stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero, stderrWrite = IntPtr.Zero;
            IntPtr stdinHandle = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            try {
                if (!CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe(stdout) failed");
                if (!SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetHandleInformation(stdout) failed");
                if (!CreatePipe(out stderrRead, out stderrWrite, ref security, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe(stderr) failed");
                if (!SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetHandleInformation(stderr) failed");
                stdinHandle = CreateFile("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, ref security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                if (stdinHandle == INVALID_HANDLE_VALUE) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile(NUL) failed");

                var startup = new STARTUPINFO {
                    cb = Marshal.SizeOf(typeof(STARTUPINFO)),
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = stdinHandle,
                    hStdOutput = stdoutWrite,
                    hStdError = stderrWrite
                };
                var command = new StringBuilder(Quote(filePath));
                foreach (string argument in arguments ?? Array.Empty<string>()) command.Append(' ').Append(Quote(argument ?? String.Empty));
                if (!CreateProcess(filePath, command, IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_NO_WINDOW,
                    IntPtr.Zero, workingDirectory, ref startup, out process)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess(CREATE_SUSPENDED) failed");
                }
                CloseNativeHandle(stdoutWrite); stdoutWrite = IntPtr.Zero;
                CloseNativeHandle(stderrWrite); stderrWrite = IntPtr.Zero;
                CloseNativeHandle(stdinHandle); stdinHandle = IntPtr.Zero;
                return new SuspendedProcessLaunch {
                    ProcessId = process.dwProcessId,
                    ProcessHandle = process.hProcess,
                    ThreadHandle = process.hThread,
                    StdoutReadHandle = stdoutRead,
                    StderrReadHandle = stderrRead
                };
            }
            catch {
                if (process.hProcess != IntPtr.Zero) { TerminateProcess(process.hProcess, 0xE0000002); CloseNativeHandle(process.hProcess); }
                if (process.hThread != IntPtr.Zero) CloseNativeHandle(process.hThread);
                if (stdoutRead != IntPtr.Zero) CloseNativeHandle(stdoutRead);
                if (stdoutWrite != IntPtr.Zero) CloseNativeHandle(stdoutWrite);
                if (stderrRead != IntPtr.Zero) CloseNativeHandle(stderrRead);
                if (stderrWrite != IntPtr.Zero) CloseNativeHandle(stderrWrite);
                if (stdinHandle != IntPtr.Zero && stdinHandle != INVALID_HANDLE_VALUE) CloseNativeHandle(stdinHandle);
                throw;
            }
        }
    }
}
'@
}

function New-KillOnCloseJob {
    $native = [SkyrimVRAutomation.Native.JobObjects]
    $job = $native::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw "CreateJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
    $information = [SkyrimVRAutomation.Native.JobObjects+JOBOBJECT_EXTENDED_LIMIT_INFORMATION]::new()
    $information.BasicLimitInformation.LimitFlags = $native::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    $size = [Runtime.InteropServices.Marshal]::SizeOf($information)
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($information, $buffer, $false)
        if (-not $native::SetInformationJobObject($job, $native::JobObjectExtendedLimitInformation, $buffer, [uint32]$size)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $null = $native::CloseHandle($job)
            throw "SetInformationJobObject failed with Win32 error $errorCode."
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    return $job
}

function Get-JobActiveProcessCount([IntPtr]$Job) {
    $information = [SkyrimVRAutomation.Native.JobObjects+JOBOBJECT_BASIC_ACCOUNTING_INFORMATION]::new()
    $size = [Runtime.InteropServices.Marshal]::SizeOf($information)
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        if (-not [SkyrimVRAutomation.Native.JobObjects]::QueryInformationJobObject(
                $Job, 1, $buffer, [uint32]$size, [IntPtr]::Zero)) {
            throw "QueryInformationJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        $information = [Runtime.InteropServices.Marshal]::PtrToStructure(
            $buffer, [type][SkyrimVRAutomation.Native.JobObjects+JOBOBJECT_BASIC_ACCOUNTING_INFORMATION])
        return [uint32]$information.ActiveProcesses
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
}

function Wait-JobQuiescent([IntPtr]$Job, [DateTime]$DeadlineUtc) {
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        if ((Get-JobActiveProcessCount -Job $Job) -eq 0) { return $true }
        Start-Sleep -Milliseconds 10
    }
    return (Get-JobActiveProcessCount -Job $Job) -eq 0
}

function Write-TextAtomic([string]$Path, [string]$Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Value, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $false)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-OneAttempt([int]$Attempt, [int]$AttemptTimeoutMilliseconds, [string]$TransactionId) {
    $startedUtc = [DateTime]::UtcNow
    $attemptDeadlineUtc = $startedUtc.AddMilliseconds([Math]::Max(1, $AttemptTimeoutMilliseconds))
    $job = [IntPtr]::Zero
    $launch = $null
    $process = $null
    $processId = $null
    $terminationErrors = [Collections.Generic.List[string]]::new()
    $attemptErrors = [Collections.Generic.List[string]]::new()
    $launched = $false
    $jobAssigned = $false
    $jobTerminated = $false
    $jobClosed = $false
    $jobQuiescent = $false
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutReader = $null
    $stderrReader = $null
    $rootExited = $false
    $exitCode = $null
    $exitVerified = $false
    $deadlineExceeded = $false
    $terminationRequested = $false
    $terminationConfirmed = $false
    try {
        $job = New-KillOnCloseJob
        $launch = [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::Launch(
            $resolvedExecutable, [string[]]$ArgumentList, $resolvedWorkingDirectory)
        $launched = $true
        $processId = [int]$launch.ProcessId
        $process = [Diagnostics.Process]::GetProcessById($processId)
        $stdoutReader = [IO.StreamReader]::new([IO.FileStream]::new(
                [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($launch.StdoutReadHandle, $true),
                [IO.FileAccess]::Read, 4096, $false))
        $stderrReader = [IO.StreamReader]::new([IO.FileStream]::new(
                [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($launch.StderrReadHandle, $true),
                [IO.FileAccess]::Read, 4096, $false))
        $stdoutTask = $stdoutReader.ReadToEndAsync()
        $stderrTask = $stderrReader.ReadToEndAsync()
        $jobAssigned = [SkyrimVRAutomation.Native.JobObjects]::AssignProcessToJobObject($job, $launch.ProcessHandle)
        if (-not $jobAssigned) {
            throw "AssignProcessToJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()); the suspended process was never admitted to execution."
        }
        $resumeResult = [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::ResumeThread($launch.ThreadHandle)
        if ($resumeResult -eq [uint32]::MaxValue) {
            throw "ResumeThread failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
        $null = [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::CloseNativeHandle($launch.ThreadHandle)
        $launch.ThreadHandle = [IntPtr]::Zero

        $remainingMs = [long]($attemptDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainingMs -gt 0) {
            $rootExited = $process.WaitForExit([int][Math]::Min([int]::MaxValue, $remainingMs))
        }
        if ($rootExited) {
            [uint32]$nativeExitCode = 0
            if (-not [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::GetExitCodeProcess($launch.ProcessHandle, [ref]$nativeExitCode)) {
                throw "GetExitCodeProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
            }
            $exitCode = [long]$nativeExitCode
            $exitVerified = $true
            $jobQuiescent = Wait-JobQuiescent -Job $job -DeadlineUtc $attemptDeadlineUtc
        }
        if (-not $rootExited -or -not $jobQuiescent) {
            $deadlineExceeded = $true
            $terminationRequested = $true
            $jobTerminated = [SkyrimVRAutomation.Native.JobObjects]::TerminateJobObject($job, [uint32]3758096385)
            if (-not $jobTerminated) { $terminationErrors.Add("TerminateJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
            $terminationDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($TerminationGraceMilliseconds)
            if (-not $rootExited) {
                $remainingTerminationMs = [long]($terminationDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
                if ($remainingTerminationMs -gt 0) {
                    $rootExited = $process.WaitForExit([int][Math]::Min([int]::MaxValue, $remainingTerminationMs))
                }
            }
            if ($rootExited) {
                $exitVerified = $true
                [uint32]$nativeExitCode = 0
                if ([SkyrimVRAutomation.Native.SuspendedProcessLauncher]::GetExitCodeProcess($launch.ProcessHandle, [ref]$nativeExitCode)) {
                    $exitCode = [long]$nativeExitCode
                }
                else { $terminationErrors.Add("GetExitCodeProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
            }
            $jobQuiescent = Wait-JobQuiescent -Job $job -DeadlineUtc $terminationDeadlineUtc
            $terminationConfirmed = $rootExited -and $jobQuiescent
        }
    }
    catch {
        $attemptErrors.Add($_.Exception.Message)
        if ($launched) {
            $terminationRequested = $true
            $terminationDeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($TerminationGraceMilliseconds)
            if ($jobAssigned -and $job -ne [IntPtr]::Zero) {
                $jobTerminated = [SkyrimVRAutomation.Native.JobObjects]::TerminateJobObject($job, [uint32]3758096386)
                if (-not $jobTerminated) { $terminationErrors.Add("TerminateJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
            }
            elseif ($null -ne $launch -and $launch.ProcessHandle -ne [IntPtr]::Zero) {
                if (-not [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::TerminateProcess($launch.ProcessHandle, [uint32]3758096386)) {
                    $terminationErrors.Add("TerminateProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).")
                }
            }
            if ($null -ne $process) {
                try {
                    $remainingTerminationMs = [long]($terminationDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
                    if ($remainingTerminationMs -gt 0) {
                        $rootExited = $process.WaitForExit([int][Math]::Min([int]::MaxValue, $remainingTerminationMs))
                    }
                    if ($rootExited) {
                        $exitVerified = $true
                        [uint32]$nativeExitCode = 0
                        if ([SkyrimVRAutomation.Native.SuspendedProcessLauncher]::GetExitCodeProcess($launch.ProcessHandle, [ref]$nativeExitCode)) {
                            $exitCode = [long]$nativeExitCode
                        }
                        else { $terminationErrors.Add("GetExitCodeProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
                    }
                }
                catch { $terminationErrors.Add("Root-process termination verification failed: $($_.Exception.Message)") }
            }
            if ($jobAssigned -and $job -ne [IntPtr]::Zero) {
                try { $jobQuiescent = Wait-JobQuiescent -Job $job -DeadlineUtc $terminationDeadlineUtc }
                catch { $terminationErrors.Add("Job quiescence verification failed: $($_.Exception.Message)") }
            }
            else { $jobQuiescent = $rootExited }
            $terminationConfirmed = $rootExited -and $jobQuiescent
        }
    }
    finally {
        if ($null -ne $launch -and $launch.ThreadHandle -ne [IntPtr]::Zero) {
            if (-not [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::CloseNativeHandle($launch.ThreadHandle)) {
                $terminationErrors.Add("CloseHandle(thread) failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).")
            }
            $launch.ThreadHandle = [IntPtr]::Zero
        }
        if ($job -ne [IntPtr]::Zero) {
            $jobClosed = [SkyrimVRAutomation.Native.JobObjects]::CloseHandle($job)
            if (-not $jobClosed) { $terminationErrors.Add("CloseHandle(job) failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
        }
        if ($null -ne $launch -and $launch.ProcessHandle -ne [IntPtr]::Zero) {
            if (-not [SkyrimVRAutomation.Native.SuspendedProcessLauncher]::CloseNativeHandle($launch.ProcessHandle)) {
                $terminationErrors.Add("CloseHandle(process) failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).")
            }
            $launch.ProcessHandle = [IntPtr]::Zero
        }
    }
    $streamDrainComplete = $false
    if ($null -ne $stdoutTask -and $null -ne $stderrTask) {
        $drainBudgetMs = if ($deadlineExceeded) {
            $StreamDrainGraceMilliseconds
        }
        else {
            [int][Math]::Max(0, [Math]::Min($StreamDrainGraceMilliseconds, [long]($attemptDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
        }
        try {
            if ($drainBudgetMs -gt 0) {
                $streamDrainComplete = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $drainBudgetMs)
            }
        }
        catch { $terminationErrors.Add("Stream drain faulted: $($_.Exception.Message)") }
    }
    $stdout = if ($streamDrainComplete -and $stdoutTask.IsCompletedSuccessfully) { $stdoutTask.GetAwaiter().GetResult() } else { $null }
    $stderr = if ($streamDrainComplete -and $stderrTask.IsCompletedSuccessfully) { $stderrTask.GetAwaiter().GetResult() } else { $null }
    if ($null -ne $stdoutReader) { $stdoutReader.Dispose() }
    if ($null -ne $stderrReader) { $stderrReader.Dispose() }
    $combined = [string]$stdout + "`n" + [string]$stderr
    $matchedPatterns = @(if ($streamDrainComplete) { $RetryPatterns | Where-Object { $combined -match $_ } })
    if (-not $deadlineExceeded -and [DateTime]::UtcNow -gt $attemptDeadlineUtc) { $deadlineExceeded = $true }
    $unresolved = $launched -and (-not $exitVerified -or -not $jobQuiescent)
    if ($terminationRequested -and -not $terminationConfirmed) { $unresolved = $true }
    $attemptOk = $launched -and $exitVerified -and $exitCode -eq 0 -and $jobAssigned -and $jobQuiescent -and
        $jobClosed -and $streamDrainComplete -and -not $deadlineExceeded -and
        $attemptErrors.Count -eq 0 -and $terminationErrors.Count -eq 0

    if ($null -ne $resolvedEvidenceDirectory) {
        $stem = "bounded-process.$TransactionId.attempt-{0:D2}" -f $Attempt
        try {
            Write-TextAtomic -Path (Join-Path $resolvedEvidenceDirectory ($stem + '.stdout.log')) -Value $(if ($null -ne $stdout) { $stdout } else { '[stream drain did not complete within its bounded grace period]' })
            Write-TextAtomic -Path (Join-Path $resolvedEvidenceDirectory ($stem + '.stderr.log')) -Value $(if ($null -ne $stderr) { $stderr } else { '[stream drain did not complete within its bounded grace period]' })
        }
        catch {
            $attemptErrors.Add("Attempt evidence persistence failed after launch: $($_.Exception.Message)")
            $attemptOk = $false
        }
    }
    $record = [pscustomobject][ordered]@{
        attempt = $Attempt; ok = $attemptOk; pid = $processId; launched = $launched; startedUtc = $startedUtc.ToString('o')
        elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds; allottedTimeoutMs = $AttemptTimeoutMilliseconds
        exitCode = $exitCode; exitVerified = $exitVerified; timedOut = $deadlineExceeded; deadlineSatisfied = -not $deadlineExceeded
        processTreeOwned = $jobAssigned; jobQuiescent = $jobQuiescent
        terminationRequested = $terminationRequested; terminationConfirmed = $terminationConfirmed; unresolvedProcess = $unresolved
        jobTerminated = $jobTerminated; jobClosed = $jobClosed; streamDrainComplete = $streamDrainComplete
        retryPatternMatched = $matchedPatterns.Count -gt 0; matchedPatterns = $matchedPatterns
        stdout = $stdout; stderr = $stderr; terminationErrors = @($terminationErrors); errors = @($attemptErrors)
    }
    if ($null -ne $process) { $process.Dispose() }
    return $record
}

try {
    $startedUtc = $controllerStartedUtc
    $deadlineUtc = $startedUtc.AddSeconds($TimeoutSeconds)
    $attempts = [Collections.Generic.List[object]]::new()
    $resolvedExecutable = (Get-Command $FilePath -ErrorAction Stop).Source
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) { throw "WorkingDirectory does not exist: $resolvedWorkingDirectory" }
    $resolvedEvidenceDirectory = if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $null } else { [IO.Path]::GetFullPath($EvidenceDirectory) }
    if ($null -ne $resolvedEvidenceDirectory -and -not (Test-Path -LiteralPath $resolvedEvidenceDirectory -PathType Container)) { New-Item -ItemType Directory -Path $resolvedEvidenceDirectory -Force | Out-Null }
    $transactionId = [guid]::NewGuid().ToString('N')
    for ($number = 1; $number -le $MaxAttempts; $number++) {
        $remainingMs = [long]($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        $attempt = Invoke-OneAttempt -Attempt $number -AttemptTimeoutMilliseconds ([int][Math]::Min([int]::MaxValue, $remainingMs)) -TransactionId $transactionId
        $attempts.Add($attempt)
        if ([bool]$attempt.ok) { break }
        if ($attempt.timedOut -or $attempt.unresolvedProcess -or -not $attempt.retryPatternMatched -or $number -eq $MaxAttempts) { break }
        $remainingAfterAttemptMs = [long]($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($RetryDelayMilliseconds -gt 0 -and $remainingAfterAttemptMs -gt $RetryDelayMilliseconds) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
        elseif ($RetryDelayMilliseconds -gt 0) { break }
    }
    $last = if ($attempts.Count -gt 0) { $attempts[$attempts.Count - 1] } else { $null }
    $ok = $null -ne $last -and [bool]$last.ok -and [DateTime]::UtcNow -le $deadlineUtc
    $resultErrors = [Collections.Generic.List[string]]::new()
    if (-not $ok) {
        if ($null -eq $last) { $resultErrors.Add("The total process budget of $TimeoutSeconds seconds expired before an attempt could start.") }
        elseif ($last.unresolvedProcess) { $resultErrors.Add("Process PID $($last.pid) did not reach verified root-and-job quiescence within the bounded cleanup window.") }
        elseif ($last.timedOut) { $resultErrors.Add("Process exceeded the total bounded timeout of $TimeoutSeconds seconds; owned-tree cleanup was requested.") }
        elseif ($last.exitVerified -and $last.exitCode -ne 0) { $resultErrors.Add("Process exited with code $($last.exitCode).") }
        else { $resultErrors.Add('Process completion did not satisfy the complete ownership, quiescence, stream, and deadline contract.') }
        foreach ($message in @($last.errors) + @($last.terminationErrors)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$message)) { $resultErrors.Add([string]$message) }
        }
    }
    $result = [pscustomobject][ordered]@{
        contractVersion = '2.1.0'; ok = $ok; command = 'bounded-process'; transactionId = $transactionId
        filePath = $resolvedExecutable; argumentList = @($ArgumentList); workingDirectory = $resolvedWorkingDirectory
        timeoutSeconds = $TimeoutSeconds; elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds
        deadlineSatisfied = [DateTime]::UtcNow -le $deadlineUtc
        maxAttempts = $MaxAttempts; attemptsRun = $attempts.Count; retried = $attempts.Count -gt 1; attempts = @($attempts)
        errors = @($resultErrors | Select-Object -Unique)
    }
    if ($null -ne $resolvedEvidenceDirectory) {
        $receiptPath = Join-Path $resolvedEvidenceDirectory "bounded-process.$transactionId.receipt.json"
        try {
            Write-TextAtomic -Path $receiptPath -Value (($result | ConvertTo-Json -Depth 20) + "`n")
            $result | Add-Member -NotePropertyName receiptPath -NotePropertyValue $receiptPath
        }
        catch {
            $result.ok = $false
            $result.errors = @($result.errors) + @("Final receipt persistence failed: $($_.Exception.Message)")
        }
    }
    if ([DateTime]::UtcNow -gt $deadlineUtc) {
        $result.ok = $false
        $result.deadlineSatisfied = $false
        $result.errors = @($result.errors) + @('The bounded result or final receipt crossed the absolute process deadline.')
        if ($result.PSObject.Properties['receiptPath'] -and (Test-Path -LiteralPath $result.receiptPath -PathType Leaf)) {
            try { Write-TextAtomic -Path $result.receiptPath -Value (($result | ConvertTo-Json -Depth 20) + "`n") }
            catch { $result.errors = @($result.errors) + @("Failed to replace a late receipt with its terminal failure projection: $($_.Exception.Message)") }
        }
    }
    $result.elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds
}
catch {
    $retainedAttempts = @(if (Get-Variable attempts -ErrorAction SilentlyContinue) { @($attempts) } else { @() })
    $result = [pscustomobject][ordered]@{
        contractVersion = '2.1.0'; ok = $false; command = 'bounded-process'; filePath = $FilePath; argumentList = @($ArgumentList)
        elapsedMs = [long]([DateTime]::UtcNow - $controllerStartedUtc).TotalMilliseconds
        deadlineSatisfied = [DateTime]::UtcNow -le $controllerStartedUtc.AddSeconds($TimeoutSeconds)
        attemptsRun = $retainedAttempts.Count; retried = $retainedAttempts.Count -gt 1; attempts = $retainedAttempts; errors = @($_.Exception.Message)
    }
}

$result | ConvertTo-Json -Depth 20 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
