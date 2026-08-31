# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ProcessId,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ThreadId,

    [Parameter(Mandatory)]
    [string]$ExpectedProcessPath,

    [Parameter(Mandatory)]
    [DateTime]$ExpectedStartTimeUtc,

    [ValidateRange(1, 50)]
    [int]$Samples = 10,

    [ValidateRange(10, 5000)]
    [int]$IntervalMs = 100,

    [ValidateRange(64, 4096)]
    [int]$StackBytes = 1024,

    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-Int64BitsToUInt64 {
    param([Parameter(Mandatory)][Int64]$Value)
    return [BitConverter]::ToUInt64([BitConverter]::GetBytes($Value), 0)
}

function Format-Address {
    param([Parameter(Mandatory)][UInt64]$Value)
    return '0x{0:X}' -f $Value
}

if (-not ('SkyrimVRAutomation.LiveThreadContext.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SkyrimVRAutomation.LiveThreadContext
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern uint SuspendThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetThreadContext(IntPtr thread, IntPtr context);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool ReadProcessMemory(
            IntPtr process,
            ulong address,
            byte[] buffer,
            UIntPtr size,
            out UIntPtr read);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

$records = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$state = 'capture-failed'
$identity = $null
$processHandle = [IntPtr]::Zero

try {
    if (-not [Environment]::Is64BitProcess) {
        throw 'A 64-bit PowerShell host is required for AMD64 thread contexts.'
    }

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $actualPath = [IO.Path]::GetFullPath($process.Path)
    $expectedPath = [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($ExpectedProcessPath))
    $actualStartTimeUtc = $process.StartTime.ToUniversalTime()
    $expectedStartUtc = $ExpectedStartTimeUtc.ToUniversalTime()
    $identity = [pscustomobject][ordered]@{
        processId = $process.Id
        processName = $process.ProcessName
        processPath = $actualPath
        processStartTimeUtc = $actualStartTimeUtc.ToString('o')
        threadId = $ThreadId
    }

    if (-not [string]::Equals(
            $actualPath,
            $expectedPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        $actualStartTimeUtc.Ticks -ne $expectedStartUtc.Ticks) {
        $state = 'identity-mismatch'
        throw 'The live process does not match the expected path and start-time identity.'
    }

    $threadMatches = @($process.Threads | Where-Object Id -eq $ThreadId)
    if ($threadMatches.Count -ne 1) {
        $state = 'thread-mismatch'
        throw "Thread '$ThreadId' is not owned exactly once by process '$ProcessId'."
    }

    $modules = @($process.Modules | ForEach-Object {
        $moduleSize = [Int64]$_.ModuleMemorySize
        if ($moduleSize -lt 0) { $moduleSize += 0x100000000L }
        [pscustomobject][ordered]@{
            name = $_.ModuleName
            path = $_.FileName
            base = Convert-Int64BitsToUInt64 $_.BaseAddress.ToInt64()
            size = [UInt64]$moduleSize
        }
    })

    $processHandle = [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::OpenProcess(
        0x410,
        $false,
        [UInt32]$ProcessId)
    if ($processHandle -eq [IntPtr]::Zero) {
        throw "OpenProcess failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    $contextBytes = 0x4D0
    $threadAccess = 0x0002 -bor 0x0008 -bor 0x0040
    $offsets = [ordered]@{
        rax = 0x78; rcx = 0x80; rdx = 0x88; rbx = 0x90; rsp = 0x98
        rbp = 0xA0; rsi = 0xA8; rdi = 0xB0; r8 = 0xB8; r9 = 0xC0
        r10 = 0xC8; r11 = 0xD0; r12 = 0xD8; r13 = 0xE0; r14 = 0xE8
        r15 = 0xF0; rip = 0xF8
    }

    for ($sample = 1; $sample -le $Samples; $sample++) {
        $threadHandle = [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::OpenThread(
            $threadAccess,
            $false,
            [UInt32]$ThreadId)
        if ($threadHandle -eq [IntPtr]::Zero) {
            throw "OpenThread failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        $allocation = [Runtime.InteropServices.Marshal]::AllocHGlobal($contextBytes + 16)
        # Stay in signed pointer-width arithmetic; Windows PowerShell cannot
        # reliably bind a masked UInt64 back to IntPtr.
        $alignedAddress = ($allocation.ToInt64() + [Int64]15) -band [Int64]-16
        $aligned = [IntPtr]::new([Int64]$alignedAddress)
        $suspended = $false
        try {
            [Runtime.InteropServices.Marshal]::Copy(
                (New-Object byte[] $contextBytes),
                0,
                $aligned,
                $contextBytes)
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $aligned,
                0x30,
                0x00100003)
            if ([SkyrimVRAutomation.LiveThreadContext.NativeMethods]::SuspendThread(
                    $threadHandle) -eq [UInt32]::MaxValue) {
                throw "SuspendThread failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            $suspended = $true
            if (-not [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::GetThreadContext(
                    $threadHandle,
                    $aligned)) {
                throw "GetThreadContext failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }

            $registers = [ordered]@{}
            foreach ($entry in $offsets.GetEnumerator()) {
                $signedValue = [Runtime.InteropServices.Marshal]::ReadInt64(
                    $aligned,
                    $entry.Value)
                $registers[$entry.Key] = Convert-Int64BitsToUInt64 $signedValue
            }

            $stack = New-Object byte[] $StackBytes
            [UIntPtr]$read = [UIntPtr]::Zero
            $stackOk = [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::ReadProcessMemory(
                $processHandle,
                $registers.rsp,
                $stack,
                [UIntPtr]::new([UInt64]$StackBytes),
                [ref]$read)
            $resumeResult = [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::ResumeThread(
                $threadHandle)
            if ($resumeResult -eq [UInt32]::MaxValue) {
                throw "ResumeThread failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            $suspended = $false

            $candidates = [System.Collections.Generic.List[object]]::new()
            if ($stackOk) {
                for ($offset = 0; $offset -le ([int]$read.ToUInt64() - 8); $offset += 8) {
                    $address = [BitConverter]::ToUInt64($stack, $offset)
                    $module = $modules |
                        Where-Object {
                            $address -ge $_.base -and
                            $address -lt ($_.base + $_.size)
                        } |
                        Select-Object -First 1
                    if ($null -ne $module) {
                        $candidates.Add([pscustomobject][ordered]@{
                            offset = Format-Address ([UInt64]$offset)
                            address = Format-Address $address
                            module = $module.name
                            rva = Format-Address ($address - $module.base)
                        })
                    }
                }
            }

            $records.Add([pscustomobject][ordered]@{
                sample = $sample
                rip = Format-Address $registers.rip
                rsp = Format-Address $registers.rsp
                registers = [pscustomobject]$registers
                stackRead = $stackOk
                stackBytesRead = [UInt64]$read.ToUInt64()
                stackCandidates = @($candidates)
            })
        }
        finally {
            if ($suspended) {
                $resumeResult = [SkyrimVRAutomation.LiveThreadContext.NativeMethods]::ResumeThread(
                    $threadHandle)
                if ($resumeResult -eq [UInt32]::MaxValue) {
                    $errors.Add("ResumeThread retry failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())")
                }
            }
            [Runtime.InteropServices.Marshal]::FreeHGlobal($allocation)
            [void][SkyrimVRAutomation.LiveThreadContext.NativeMethods]::CloseHandle(
                $threadHandle)
        }

        if ($sample -lt $Samples) {
            Start-Sleep -Milliseconds $IntervalMs
        }
    }

    $state = 'captured'
}
catch {
    $errors.Add($_.Exception.Message)
}
finally {
    if ($processHandle -ne [IntPtr]::Zero) {
        [void][SkyrimVRAutomation.LiveThreadContext.NativeMethods]::CloseHandle(
            $processHandle)
    }
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    ok = $state -eq 'captured'
    state = $state
    capturedUtc = [DateTime]::UtcNow.ToString('o')
    host = [pscustomobject][ordered]@{
        edition = $PSVersionTable.PSEdition
        version = $PSVersionTable.PSVersion.ToString()
        is64Bit = [Environment]::Is64BitProcess
    }
    identity = $identity
    requestedSamples = $Samples
    capturedSamples = $records.Count
    intervalMs = $IntervalMs
    stackBytes = $StackBytes
    records = @($records)
    errors = @($errors)
}
$result | ConvertTo-Json -Depth 10
if (-not $result.ok -and -not $NoExit) { exit 2 }
