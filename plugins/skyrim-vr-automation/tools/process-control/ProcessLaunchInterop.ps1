# SPDX-License-Identifier: GPL-3.0-or-later
if (-not ('SkyrimVRAutomation.Native.SuspendedProcessLauncher' -as [type])) {
    $launcherSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
namespace SkyrimVRAutomation.Native {
    public sealed class SuspendedProcessLaunch {
        public int ProcessId;
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public IntPtr StdoutReadHandle;
        public IntPtr StderrReadHandle;
        public InteractiveLaunch Interactive;
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

        public static SuspendedProcessLaunch Launch(string filePath, string[] arguments, string workingDirectory, bool normalInteractive, DateTime deadline) {
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
                InteractiveLaunch interactive = null;
                if (normalInteractive) {
                    interactive = NormalInteractiveProcess.Create(filePath,command.ToString(),workingDirectory,stdinHandle,stdoutWrite,stderrWrite,deadline);
                    process.hProcess=interactive.ProcessHandle; process.hThread=interactive.ThreadHandle; process.dwProcessId=interactive.ProcessId; process.dwThreadId=interactive.ThreadId;
                }
                else if (!CreateProcess(filePath, command, IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_NO_WINDOW,
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
                    ,Interactive = interactive
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
    # Compile the two owner sources together; do not rely on dynamic-assembly
    # reference paths or expose an arbitrary caller-supplied launch callback.
    $normalSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NormalInteractiveProcess.cs'))
    $normalSource = [regex]::Replace($normalSource, '(?m)^using [^\r\n]+;\r?\n', '')
    Add-Type -TypeDefinition ($launcherSource + "`n" + $normalSource)
}

function Get-NormalInteractiveLaunchProof($Launch) {
    if (-not $Launch) { return $null }
    return [pscustomobject][ordered]@{
        method = $Launch.Method
        caller = $Launch.Caller
        desktop = $Launch.Desktop
        child = $Launch.Child
        normalUserAccessVerified = $Launch.NormalUserAccessVerified
        processId = $Launch.ProcessId
        threadId = $Launch.ThreadId
        creationSecurity = 'normal desktop token default DACL and owner; medium mandatory label for new objects only'
    }
}

function Start-NormalInteractiveProcess {
    param([string]$FilePath, [DateTime]$DeadlineUtc)
    $launch = $null
    $resumed = $false
    try {
        $launch = [SkyrimVRAutomation.Native.NormalInteractiveProcess]::Create($FilePath, ('"' + $FilePath + '"'), (Split-Path -Parent $FilePath), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, $DeadlineUtc)
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup deadline expired before normal-user launcher resume.') }
        if ([SkyrimVRAutomation.Native.NormalInteractiveProcess]::ResumeThread($launch.ThreadHandle) -eq [uint32]::MaxValue) { throw 'Normal-user launcher resume failed.' }
        $resumed = $true
        return [pscustomobject]@{ Id = $launch.ProcessId; interactiveLaunch = Get-NormalInteractiveLaunchProof $launch }
    }
    finally {
        if ($launch) {
            if (-not $resumed) {
                if (-not [SkyrimVRAutomation.Native.NormalInteractiveProcess]::Abort($launch)) { throw "Suspended launcher cleanup unverified, exact PID $($launch.ProcessId)." }
            }
            else {
                $threadClosed = [SkyrimVRAutomation.Native.NormalInteractiveProcess]::CloseHandle($launch.ThreadHandle)
                $processClosed = [SkyrimVRAutomation.Native.NormalInteractiveProcess]::CloseHandle($launch.ProcessHandle)
                if (-not $threadClosed -or -not $processClosed) { throw "Launcher handle cleanup failed, exact PID $($launch.ProcessId)." }
            }
        }
    }
}
