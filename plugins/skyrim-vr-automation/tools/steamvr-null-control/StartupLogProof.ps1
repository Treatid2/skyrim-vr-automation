# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest

# Never inherit proof from an earlier controller invocation or startup attempt.
$script:NullStartupLogProofState = @{}
$script:NullStartupLogAnchor = $null

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

function New-NullStartupLogAnchor {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AttemptId,
          [DateTime]$DeadlineUtc = [DateTime]::MaxValue, [scriptblock]$InternalMutationHook)
    $script:NullStartupLogProofState.Clear()
    $script:NullStartupLogAnchor = $null
    $anchor = [ordered]@{ schemaVersion = 1; attemptId = $AttemptId; path = [IO.Path]::GetFullPath($Path)
        capturedUtc = [DateTime]::UtcNow.ToString('o'); existed = $false; fileIdentity = $null
        offset = 0L; skipPartialFirstLine = $false; guardOffset = 0L; guardLength = 0; guardSha256 = $null
        policy = 'existing-append-only; absent-single-create; no-in-attempt-reanchor' }
    $stream = $selected = $null
    try {
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log anchor deadline expired.') }
        try { $stream = [IO.File]::Open($anchor.path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
        catch [IO.FileNotFoundException] { }
        if ($stream) {
            $anchor.existed = $true
            $anchor.fileIdentity = Get-NullLogFileIdentity $stream
            $anchor.offset = $stream.Length
            $anchor.guardLength = [int][Math]::Min(4096, $anchor.offset)
            $anchor.guardOffset = $anchor.offset - $anchor.guardLength
            $checked = 0
            $anchor.guardSha256 = Get-StreamRangeSha256 -Stream $stream -Offset $anchor.guardOffset -Length $anchor.guardLength -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checked)
            if ($anchor.offset -gt 0) { $stream.Position = $anchor.offset - 1; $anchor.skipPartialFirstLine = $stream.ReadByte() -ne 10 }
            if ($InternalMutationHook) { $null = & $InternalMutationHook $Path }
            $selected = [IO.File]::Open($anchor.path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $confirmed = Get-StreamRangeSha256 -Stream $selected -Offset $anchor.guardOffset -Length $anchor.guardLength -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checked)
            # No writer may advance the boundary while it is being anchored.
            if ((Get-NullLogFileIdentity $selected) -cne $anchor.fileIdentity -or $selected.Length -ne $anchor.offset -or $confirmed -cne $anchor.guardSha256) {
                throw [IO.InvalidDataException]::new('Startup log changed while capturing its prelaunch anchor.')
            }
        }
        elseif ([IO.File]::Exists($anchor.path)) { throw [IO.InvalidDataException]::new('Startup log appeared during absent-path anchor capture.') }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log anchor deadline expired before publication.') }
        $script:NullStartupLogAnchor = [pscustomobject]$anchor
        return $script:NullStartupLogAnchor
    }
    finally { if ($selected) { $selected.Dispose() }; if ($stream) { $stream.Dispose() } }
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
    $anchor = $script:NullStartupLogAnchor
    $anchorId = if ($anchor) { $anchor.attemptId } else { '' }
    $binding = "$([IO.Path]::GetFullPath($Path).ToLowerInvariant())|$($Server.id)|$($serverStart.ToString('o'))|$([IO.Path]::GetFullPath($Server.path).ToLowerInvariant())|$SerialNumber|$MaxBytes|$anchorId"
    $prior = if ($script:NullStartupLogProofState.ContainsKey($binding)) { $script:NullStartupLogProofState[$binding] } else { $null }
    $result = [ordered]@{
        stable = $false; complete = $false; retained = $false; error = $null; terminalFailure = $false
        attemptId = if ($anchor) { $anchor.attemptId } else { $null }; anchor = $anchor; serverStartup = $null
        serverId = $Server.id; serverStartUtc = $serverStart.ToString('o'); serverPath = $Server.path; serialNumber = $SerialNumber
        fileIdentity = $null; offset = if ($anchor) { [long]$anchor.offset } else { 0L }; length = 0; sha256 = $null
        maxBytes = $MaxBytes; maxLines = 10000; bytesRead = 0; hashBytesRead = 0
        driverLoaded = $null; activeHmd = $null; headPoseDriverLoaded = $null; headPoseDeviceRegistered = $null
    }
    $stream = $selected = $null
    try {
        if ($prior -and $prior.error) { throw [IO.InvalidDataException]::new([string]$prior.error) }
        if (-not $anchor -or -not [string]::Equals([IO.Path]::GetFullPath($Path), $anchor.path, [StringComparison]::OrdinalIgnoreCase)) {
            throw [IO.InvalidDataException]::new('No exact prelaunch startup log anchor is available; restore/start through the supported owner.')
        }
        if ($serverStart -lt ([DateTimeOffset]$anchor.capturedUtc).UtcDateTime) { throw [IO.InvalidDataException]::new('Server identity predates the startup log attempt anchor.') }
        if ($script:NullStartupLogProofState.Count -gt 0 -and -not $prior) { throw [IO.InvalidDataException]::new('Server/serial/path/budget binding changed during the startup log attempt.') }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired before opening the log.') }
        try { $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
        catch [IO.FileNotFoundException] {
            if (-not $anchor.existed -and -not $prior) { return [pscustomobject]$result }
            throw
        }
        $identity = Get-NullLogFileIdentity $stream
        $capturedLength = $stream.Length
        $result.fileIdentity = $identity
        if ($anchor.existed) {
            if ($identity -cne $anchor.fileIdentity -or $capturedLength -lt $anchor.offset) { throw [IO.InvalidDataException]::new('Startup log was replaced, rotated or truncated after prelaunch anchor.') }
            $checkedBytes = 0
            $guardHash = Get-StreamRangeSha256 -Stream $stream -Offset $anchor.guardOffset -Length $anchor.guardLength -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
            $result.hashBytesRead += $checkedBytes
            if ($guardHash -cne $anchor.guardSha256) { throw [IO.InvalidDataException]::new('Startup log prelaunch framing guard changed in place.') }
        }
        if ($prior) {
            if ($identity -cne $prior.fileIdentity -or $capturedLength -lt $prior.observedLength) {
                throw [IO.InvalidDataException]::new('Startup log was rotated, replaced or truncated for the same server identity.')
            }
            $checkedBytes = 0
            $priorHash = Get-StreamRangeSha256 -Stream $stream -Offset $result.offset -Length $prior.length -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
            $result.hashBytesRead += $checkedBytes
            if ($priorHash -cne $prior.sha256) { throw [IO.InvalidDataException]::new('Startup log prefix changed in place for the same server identity.') }
        }
        if ($prior -and $prior.complete) {
            foreach ($name in @('serverStartup', 'driverLoaded', 'activeHmd', 'headPoseDriverLoaded', 'headPoseDeviceRegistered', 'length', 'sha256')) { $result[$name] = $prior.$name }
            $result.retained = $true
        }
        else {
            # The immutable attempt-relative window never slides with noisy tails.
            $length = [int][Math]::Min($capturedLength - $result.offset, $MaxBytes)
            $bytes = [byte[]]::new($length)
            $read = 0
            $stream.Position = $result.offset
            while ($read -lt $length) {
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired during prefix reading.') }
                $count = $stream.Read($bytes, $read, $length - $read)
                if ($count -eq 0) { throw [IO.InvalidDataException]::new('Startup log shortened during prefix reading.') }
                $read += $count
                $result.bytesRead = $read
            }
            $offset = 0; $lines = 0
            if ($anchor.skipPartialFirstLine) {
                $firstEnd = [Array]::IndexOf($bytes, [byte]10)
                $offset = if ($firstEnd -lt 0) { $length } else { $firstEnd + 1 }
            }
            while ($offset -lt $length) {
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired during prefix parsing.') }
                if (++$lines -gt 10000) { throw [IO.InvalidDataException]::new('Startup log-proof line budget exhausted before all four proofs were found.') }
                $end = [Array]::IndexOf($bytes, [byte]10, $offset)
                if ($end -lt 0) { break } # Incomplete lines never establish proof.
                if (($end - $offset) -le 4096) {
                    $line = [Text.Encoding]::UTF8.GetString($bytes, $offset, $end - $offset).TrimEnd([char]13)
                    $timestamp = Get-LogTimestampUtc -Line $line
                    if ($timestamp -and $timestamp -ge $serverStart.AddSeconds(-3)) {
                        if ($line -match 'vrserver .*startup with PID=(\d+), .*runtime=(.+), arch=win64$') {
                            $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Server.path))))
                            if ([long]$Matches[1] -ne [long]$Server.id -or $timestamp -gt $serverStart.AddSeconds(3) -or
                                -not [string]::Equals([IO.Path]::GetFullPath($Matches[2]).TrimEnd('\', '/'), $root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
                                throw [IO.InvalidDataException]::new('Startup log server PID/runtime/timestamp does not match the exact current server.')
                            }
                            if ($result.serverStartup) { throw [IO.InvalidDataException]::new('Multiple server startup records in one attempt proof window.') }
                            $result.serverStartup = [pscustomobject]@{ timestampUtc = $timestamp.ToString('o'); line = $line; byteStartInclusive = $result.offset + $offset; byteEndExclusive = $result.offset + $end + 1 }
                        }
                        $kind = if (-not $result.serverStartup -or $timestamp -lt [DateTimeOffset]::Parse($result.serverStartup.timestampUtc).UtcDateTime) { $null }
                        elseif ($line -match 'Loaded server driver null .*driver_null\.dll') { 'driverLoaded' }
                        elseif ($line -cmatch "Active HMD set to null\.$([regex]::Escape($SerialNumber))$") { 'activeHmd' }
                        elseif ($line -match 'Loaded server driver codex_head_pose .*driver_codex_head_pose\.dll') { 'headPoseDriverLoaded' }
                        elseif ($line -match 'codex_head_pose: registered synthetic head-pose device at configured standing pose') { 'headPoseDeviceRegistered' }
                        else { $null }
                        if ($kind) { $result[$kind] = [pscustomobject]@{ timestampUtc = $timestamp.ToString('o'); line = $line; byteStartInclusive = $result.offset + $offset; byteEndExclusive = $result.offset + $end + 1 } }
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
        $confirmedHash = Get-StreamRangeSha256 -Stream $selected -Offset $result.offset -Length $result.length -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
        $result.hashBytesRead += $checkedBytes
        if ($anchor.existed) {
            $guardHash = Get-StreamRangeSha256 -Stream $selected -Offset $anchor.guardOffset -Length $anchor.guardLength -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$checkedBytes)
            $result.hashBytesRead += $checkedBytes
            if ($guardHash -cne $anchor.guardSha256) { throw [IO.InvalidDataException]::new('Startup log framing guard changed before selected-path confirmation.') }
        }
        if ((Get-NullLogFileIdentity $selected) -cne $identity -or $selected.Length -lt $capturedLength -or $confirmedHash -cne $result.sha256) {
            throw [IO.InvalidDataException]::new('Startup log identity, length or proof prefix changed before path confirmation.')
        }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Startup log-proof deadline expired before publication.') }
        $result.stable = $true
        $result.complete = [bool]($result.driverLoaded -and $result.activeHmd -and $result.headPoseDriverLoaded -and $result.headPoseDeviceRegistered)
        if (-not $result.complete -and $capturedLength - $result.offset -ge $MaxBytes) { throw [IO.InvalidDataException]::new('Startup log-proof byte budget exhausted before all four proofs were found.') }
        $saved = [pscustomobject]$result
        $saved | Add-Member -NotePropertyName observedLength -NotePropertyValue $capturedLength
        $script:NullStartupLogProofState.Clear()
        $script:NullStartupLogProofState[$binding] = $saved
        return $saved
    }
    catch {
        $result.stable = $false; $result.complete = $false; $result.error = $_.Exception.Message; $result.terminalFailure = $true
        foreach ($name in @('driverLoaded', 'activeHmd', 'headPoseDriverLoaded', 'headPoseDeviceRegistered')) { $result[$name] = $null }
        $script:NullStartupLogProofState.Clear()
        $script:NullStartupLogProofState[$binding] = [pscustomobject]$result
        if ($_.Exception -is [TimeoutException]) { throw }
        return [pscustomobject]$result
    }
    finally { if ($selected) { $selected.Dispose() }; if ($stream) { $stream.Dispose() } }
}

function Import-NullStartupLogAnchor {
    # Called only with the accepted runtime receipt inside the authoritative
    # apply journal's evidence directory. Never reconstruct a prelaunch offset
    # from a running log or a caller-selected historical receipt.
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)]$Server, [Parameter(Mandatory)][string]$SerialNumber,
          [Parameter(Mandatory)][int]$MaxBytes)
    $anchor = $Receipt.startupLogAnchor
    $proof = $Receipt.runtime.startupLogProof
    if ($Receipt.schemaVersion -ne 2 -or -not $Receipt.runtimeAccepted -or $Receipt.admissionState -cne 'accepted' -or
        -not $anchor -or $anchor.schemaVersion -ne 1 -or $anchor.attemptId -cne $Receipt.attemptId -or
        -not [string]::Equals($anchor.path, [IO.Path]::GetFullPath($Path), [StringComparison]::OrdinalIgnoreCase) -or
        $anchor.offset -lt 0 -or $anchor.guardLength -ne [Math]::Min(4096, $anchor.offset) -or
        $anchor.guardOffset -ne $anchor.offset - $anchor.guardLength -or
        ($anchor.existed -and ([string]::IsNullOrWhiteSpace($anchor.fileIdentity) -or
            ($anchor.guardLength -gt 0 -and $anchor.guardSha256 -notmatch '^[a-fA-F0-9]{64}$') -or
            ($anchor.guardLength -eq 0 -and $anchor.guardSha256 -cne ''))) -or
        (-not $anchor.existed -and ($anchor.offset -ne 0 -or $anchor.guardLength -ne 0 -or $anchor.skipPartialFirstLine)) -or
        -not $proof.stable -or -not $proof.complete -or $proof.terminalFailure -or $proof.error -or
        $proof.attemptId -cne $anchor.attemptId -or $proof.offset -ne $anchor.offset -or
        $proof.maxBytes -ne $MaxBytes -or $proof.length -le 0 -or $proof.length -gt $MaxBytes -or
        $proof.observedLength -lt $proof.offset + $proof.length -or $proof.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        $proof.serialNumber -cne $SerialNumber -or $proof.serverId -ne $Server.id -or ([DateTimeOffset]$proof.serverStartUtc).UtcTicks -ne ([DateTimeOffset]$Server.startTimeUtc).UtcTicks -or
        -not [string]::Equals($proof.serverPath, $Server.path, [StringComparison]::OrdinalIgnoreCase)) {
        throw [IO.InvalidDataException]::new('Accepted runtime receipt cannot supply an exact immutable startup log anchor/proof binding.')
    }
    $script:NullStartupLogAnchor = $anchor
    $startText = ([DateTimeOffset]$Server.startTimeUtc).UtcDateTime.ToString('o')
    $binding = "$([IO.Path]::GetFullPath($Path).ToLowerInvariant())|$($Server.id)|$startText|$([IO.Path]::GetFullPath($Server.path).ToLowerInvariant())|$SerialNumber|$MaxBytes|$($anchor.attemptId)"
    $script:NullStartupLogProofState.Clear()
    $script:NullStartupLogProofState[$binding] = $proof
}
