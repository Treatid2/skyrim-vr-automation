# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest

# Never inherit proof from an earlier controller invocation or startup attempt.
$script:NullStartupLogProofState = @{}

function Get-NullLogFileIdentity([IO.FileStream]$Stream) {
    if (-not ('SkyrimVRAutomation.Native.NullLogIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace SkyrimVRAutomation.Native {
    public static class NullLogIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
                WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
        public static string Read(SafeFileHandle handle) {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return String.Format("{0:X8}:{1:X8}{2:X8}:{3:X8}{4:X8}",
                info.Volume, info.IndexHigh, info.IndexLow, info.CreationHigh, info.CreationLow);
        }
    }
}
'@
    }
    return [SkyrimVRAutomation.Native.NullLogIdentity]::Read($Stream.SafeFileHandle)
}

function Get-NullStartupLogProof {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$SerialNumber,
        [Parameter(Mandatory)][ValidateRange(4096, 4194304)][int]$MaxBytes,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue,
        [scriptblock]$InternalMutationHook
    )
    $serverStart = [DateTimeOffset]::Parse([string]$Server.startTimeUtc).UtcDateTime
    $binding = "$([IO.Path]::GetFullPath($Path).ToLowerInvariant())|$($Server.id)|$($serverStart.ToString('o'))|$([IO.Path]::GetFullPath($Server.path).ToLowerInvariant())|$SerialNumber|$MaxBytes"
    $prior = if ($script:NullStartupLogProofState.ContainsKey($binding)) { $script:NullStartupLogProofState[$binding] } else { $null }
    $result = [ordered]@{
        stable = $false; complete = $false; retained = $false; error = $null
        serverId = $Server.id; serverStartUtc = $serverStart.ToString('o'); serverPath = $Server.path
        fileIdentity = $null; offset = 0L; length = 0; sha256 = $null
        maxBytes = $MaxBytes; maxLines = 10000; bytesRead = 0; hashBytesRead = 0
        driverLoaded = $null; activeHmd = $null; headPoseDriverLoaded = $null; headPoseDeviceRegistered = $null
    }
    $stream = $selected = $null
    try {
        if ($prior -and $prior.error) { throw [IO.InvalidDataException]::new([string]$prior.error) }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired before opening the log.') }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $identity = Get-NullLogFileIdentity $stream
        $capturedLength = $stream.Length
        $result.fileIdentity = $identity
        if ($prior) {
            if ($identity -cne $prior.fileIdentity -or $capturedLength -lt $prior.observedLength) {
                throw [IO.InvalidDataException]::new('Startup log was rotated, replaced or truncated for the same server identity.')
            }
            $checkedBytes = 0
            $priorHash = Get-StreamRangeSha256 -Stream $stream -Offset 0 -Length $prior.length -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
            $result.hashBytesRead += $checkedBytes
            if ($priorHash -cne $prior.sha256) { throw [IO.InvalidDataException]::new('Startup log prefix changed in place for the same server identity.') }
        }
        if ($prior -and $prior.complete) {
            foreach ($name in @('driverLoaded', 'activeHmd', 'headPoseDriverLoaded', 'headPoseDeviceRegistered', 'length', 'sha256')) { $result[$name] = $prior.$name }
            $result.retained = $true
        }
        else {
            # Read from the startup prefix, not the moving tail. A delayed first
            # poll must still see startup lines after a burst of diagnostic noise.
            $length = [int][Math]::Min($capturedLength, $MaxBytes)
            $bytes = [byte[]]::new($length)
            $read = 0
            $stream.Position = 0
            while ($read -lt $length) {
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired during prefix reading.') }
                $count = $stream.Read($bytes, $read, $length - $read)
                if ($count -eq 0) { throw [IO.InvalidDataException]::new('Startup log shortened during prefix reading.') }
                $read += $count
                $result.bytesRead = $read
            }
            $offset = 0; $lines = 0
            while ($offset -lt $length) {
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired during prefix parsing.') }
                if (++$lines -gt 10000) { throw [IO.InvalidDataException]::new('Startup log-proof line budget exhausted before all four proofs were found.') }
                $end = [Array]::IndexOf($bytes, [byte]10, $offset)
                if ($end -lt 0) { break } # Incomplete lines never establish proof.
                if (($end - $offset) -le 4096) {
                    $line = [Text.Encoding]::UTF8.GetString($bytes, $offset, $end - $offset).TrimEnd([char]13)
                    $timestamp = Get-LogTimestampUtc -Line $line
                    if ($timestamp -and $timestamp -ge $serverStart.AddSeconds(-3)) {
                        $kind = if ($line -match 'Loaded server driver null .*driver_null\.dll') { 'driverLoaded' }
                        elseif ($line -cmatch "Active HMD set to null\.$([regex]::Escape($SerialNumber))$") { 'activeHmd' }
                        elseif ($line -match 'Loaded server driver codex_head_pose .*driver_codex_head_pose\.dll') { 'headPoseDriverLoaded' }
                        elseif ($line -match 'codex_head_pose: registered synthetic head-pose device at configured standing pose') { 'headPoseDeviceRegistered' }
                        else { $null }
                        if ($kind) { $result[$kind] = [pscustomobject]@{ timestampUtc = $timestamp.ToString('o'); line = $line; byteStartInclusive = $offset; byteEndExclusive = $end + 1 } }
                    }
                }
                $offset = $end + 1
                if ($result.driverLoaded -and $result.activeHmd -and $result.headPoseDriverLoaded -and $result.headPoseDeviceRegistered) { break }
            }
            # Pin only the fully framed prefix needed for complete proof.
            $result.length = if ($result.driverLoaded -and $result.activeHmd -and $result.headPoseDriverLoaded -and $result.headPoseDeviceRegistered) { $offset } else { $length }
            $proofBytes = [byte[]]::new($result.length)
            [Array]::Copy($bytes, $proofBytes, $result.length)
            $result.sha256 = Get-ByteArraySha256 -Bytes $proofBytes -DeadlineUtc $DeadlineUtc
            if ($InternalMutationHook) { $null = & $InternalMutationHook $Path }
        }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired before path confirmation.') }
        $selected = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $checkedBytes = 0
        $confirmedHash = Get-StreamRangeSha256 -Stream $selected -Offset 0 -Length $result.length -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
        $result.hashBytesRead += $checkedBytes
        if ((Get-NullLogFileIdentity $selected) -cne $identity -or $selected.Length -lt $capturedLength -or $confirmedHash -cne $result.sha256) {
            throw [IO.InvalidDataException]::new('Startup log identity, length or proof prefix changed before path confirmation.')
        }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired before publication.') }
        $result.stable = $true
        $result.complete = [bool]($result.driverLoaded -and $result.activeHmd -and $result.headPoseDriverLoaded -and $result.headPoseDeviceRegistered)
        if (-not $result.complete -and $capturedLength -ge $MaxBytes) { throw [IO.InvalidDataException]::new('Startup log-proof byte budget exhausted before all four proofs were found.') }
        $saved = [pscustomobject]$result
        $saved | Add-Member -NotePropertyName observedLength -NotePropertyValue $capturedLength
        $script:NullStartupLogProofState.Clear()
        $script:NullStartupLogProofState[$binding] = $saved
        return $saved
    }
    catch {
        $result.stable = $false; $result.complete = $false; $result.error = $_.Exception.Message
        foreach ($name in @('driverLoaded', 'activeHmd', 'headPoseDriverLoaded', 'headPoseDeviceRegistered')) { $result[$name] = $null }
        $script:NullStartupLogProofState.Clear()
        $script:NullStartupLogProofState[$binding] = [pscustomobject]$result
        if ($_.Exception -is [TimeoutException]) { throw }
        return [pscustomobject]$result
    }
    finally { if ($selected) { $selected.Dispose() }; if ($stream) { $stream.Dispose() } }
}
