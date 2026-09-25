// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CocOwnedProcess : IDisposable
{
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint ExtendedLimitInformationClass = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;

    private IntPtr jobHandle;
    public Process Process { get; private set; }

    private CocOwnedProcess(IntPtr job, Process process)
    {
        jobHandle = job;
        Process = process;
    }

    public static CocOwnedProcess Start(string executable, string[] arguments)
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");

        try
        {
            var limits = new JobObjectExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int size = Marshal.SizeOf(limits);
            IntPtr limitsPointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, limitsPointer, false);
                if (!SetInformationJobObject(job, ExtendedLimitInformationClass,
                        limitsPointer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetInformationJobObject failed.");
            }
            finally { Marshal.FreeHGlobal(limitsPointer); }

            string commandLine = Quote(executable);
            foreach (string argument in arguments)
                commandLine += " " + Quote(argument);

            var startup = new StartupInfo();
            startup.cb = Marshal.SizeOf(startup);
            ProcessInformation processInfo;
            if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero,
                    IntPtr.Zero, false, CreateSuspended | CreateNoWindow,
                    IntPtr.Zero, null, ref startup, out processInfo))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed.");

            try
            {
                if (!AssignProcessToJobObject(job, processInfo.hProcess))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "AssignProcessToJobObject failed.");
                var process = Process.GetProcessById((int)processInfo.dwProcessId);
                if (ResumeThread(processInfo.hThread) == uint.MaxValue)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread failed.");
                return new CocOwnedProcess(job, process);
            }
            catch
            {
                TerminateProcess(processInfo.hProcess, 1);
                throw;
            }
            finally
            {
                CloseHandle(processInfo.hThread);
                CloseHandle(processInfo.hProcess);
            }
        }
        catch
        {
            CloseHandle(job);
            throw;
        }
    }

    private static string Quote(string value)
    {
        if (value == null) return "\"\"";
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return value;
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"')
            {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    public void Dispose()
    {
        if (jobHandle != IntPtr.Zero)
        {
            CloseHandle(jobHandle);
            jobHandle = IntPtr.Zero;
        }
        if (Process != null) Process.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed,
            PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars,
            dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, uint infoClass,
        IntPtr information, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInfo startupInfo, out ProcessInformation processInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
