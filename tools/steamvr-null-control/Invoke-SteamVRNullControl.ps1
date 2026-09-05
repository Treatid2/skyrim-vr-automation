# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'apply', 'start', 'restore', 'stop')]
    [string]$Command = 'inspect',

    [string]$SettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',

    [string]$NullProfilePath,

    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',

    [string]$ServerLogPath = 'C:\Program Files (x86)\Steam\logs\vrserver.txt',

    [string]$OpenVRPathsPath = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath' } else { $null }),

    [string]$HeadPoseDriverRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'CSX-VR-Automation\SteamVR\drivers\codex_head_pose' } else { $null }),

    [string]$EvidenceDirectory,

    [ValidateRange(100, 60000)]
    [int]$TransactionLockTimeoutMilliseconds = 5000,

    [ValidateRange(4096, 4194304)]
    [int]$LogTailMaxBytes = 262144,

    [switch]$WhatIf,

    [switch]$Force,

    [switch]$AllowExternalDisplayRedirector,

    [ValidateSet('', 'apply-after-openvr', 'apply-source-drift-after-stage', 'restore-after-settings', 'head-pose-access-denied', 'head-pose-access-denied-after-start', 'runtime-ready', 'runtime-confirmation-timeout', 'runtime-confirmation-timeout-receipt-failure', 'runtime-final-admission-timeout', 'runtime-final-admission-timeout-no-confirmation', 'runtime-post-receipt-timeout')]
    [string]$InternalTestFailurePoint = '',

    [switch]$IsolateExternalDisplayRedirectors,

    [string[]]$ExternalDisplayRedirectorRoot = @(),

    [ValidateRange(5, 120)]
    [int]$StartupTimeoutSeconds = 45,

    [switch]$NoExit,

    [switch]$Compact
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $versionFailure = [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $false
        state = 'unsupported-powershell-version'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @("steamvr-null-control requires PowerShell 7.0 or newer; current host is $($PSVersionTable.PSVersion). Invoke the script with pwsh.exe, not Windows PowerShell powershell.exe.")
        data = @{ requiredPowerShellVersion = '7.0'; actualPowerShellVersion = [string]$PSVersionTable.PSVersion; requiredExecutable = 'pwsh.exe' }
    }
    $versionJsonParameters = @{ InputObject = $versionFailure; Depth = 8 }
    if ($Compact) { $versionJsonParameters['Compress'] = $true }
    ConvertTo-Json @versionJsonParameters
    if (-not $NoExit) { exit 2 }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('SkyrimVRAutomation.Native.SharedPoseAtomics' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SkyrimVRAutomation.Native {
    public static unsafe class SharedPoseAtomics {
        public static long ReadInt64(SafeMemoryMappedViewHandle handle, long pointerOffset, long fieldOffset) {
            bool referenced = false;
            handle.DangerousAddRef(ref referenced);
            try {
                byte* pointer = (byte*)handle.DangerousGetHandle() + pointerOffset + fieldOffset;
                return Interlocked.Read(ref *(long*)pointer);
            }
            finally { if (referenced) handle.DangerousRelease(); }
        }

        public static long ExchangeInt64(SafeMemoryMappedViewHandle handle, long pointerOffset, long fieldOffset, long value) {
            bool referenced = false;
            handle.DangerousAddRef(ref referenced);
            try {
                byte* pointer = (byte*)handle.DangerousGetHandle() + pointerOffset + fieldOffset;
                return Interlocked.Exchange(ref *(long*)pointer, value);
            }
            finally { if (referenced) handle.DangerousRelease(); }
        }
    }
}
'@ -CompilerOptions '/unsafe'
}

if ([string]::IsNullOrWhiteSpace($NullProfilePath)) {
    $NullProfilePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\profiles\steamvr-null.profile.json'))
}

function Get-SteamVRProcesses {
    $records = @()
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup', 'vrdashboard', 'vrwebhelper')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                startTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                path = $(try { $process.Path } catch { $null })
            }
        }
    }
    return @($records | Sort-Object name, id)
}

function Get-HashOrNull {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $stream = $null
        $algorithm = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $algorithm = [Security.Cryptography.SHA256]::Create()
            return [Convert]::ToHexString($algorithm.ComputeHash($stream))
        }
        finally {
            if ($algorithm) { $algorithm.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

if (-not (Get-Variable -Scope Script -Name SharedTextTailState -ErrorAction SilentlyContinue)) {
    $script:SharedTextTailState = @{}
}

function Get-StreamRangeSha256 {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Length,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue,
        [ref]$BytesRead
    )
    if ($null -ne $BytesRead) { $BytesRead.Value = 0 }
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before hashing the retained window.') }
    if ($Length -eq 0) { return '' }
    $savedPosition = $Stream.Position
    $bytes = [byte[]]::new($Length)
    try {
        $Stream.Position = $Offset
        $read = 0
        while ($read -lt $Length) {
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while hashing the retained window.') }
            $current = $Stream.Read($bytes, $read, $Length - $read)
            if ($current -le 0) { break }
            $read += $current
            if ($null -ne $BytesRead) { $BytesRead.Value = $read }
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while hashing the retained window.') }
        }
        if ($read -ne $Length) { return $null }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before hashing the retained bytes.') }
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = [Convert]::ToHexString($algorithm.ComputeHash($bytes))
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while hashing the retained bytes.') }
            return $hash
        }
        finally { $algorithm.Dispose() }
    }
    finally { $Stream.Position = $savedPosition }
}

function Get-ByteArraySha256 {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue
    )
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before hashing the candidate bytes.') }
    if ($Bytes.Length -eq 0) { return '' }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [Convert]::ToHexString($algorithm.ComputeHash($Bytes))
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while hashing the candidate bytes.') }
        return $hash
    }
    finally { $algorithm.Dispose() }
}

function Get-Utf8TrailingIncompleteByteCount {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { return 0 }
    $continuations = 0
    for ($index = $Bytes.Length - 1; $index -ge 0 -and $continuations -lt 4; $index--) {
        $value = $Bytes[$index]
        if (($value -band 0xC0) -eq 0x80) {
            $continuations++
            continue
        }
        $expected = if (($value -band 0x80) -eq 0) { 0 } elseif (($value -band 0xE0) -eq 0xC0) { 1 } elseif (($value -band 0xF0) -eq 0xE0) { 2 } elseif (($value -band 0xF8) -eq 0xF0) { 3 } else { 0 }
        return $(if ($expected -gt $continuations) { $continuations + 1 } else { 0 })
    }
    return $(if ($continuations -gt 0) { $continuations } else { 0 })
}

function Get-SharedTextTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 10000)][int]$Count,
        [Parameter(Mandatory)][ValidateRange(4096, 4194304)][int]$MaxBytes,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue,
        [scriptblock]$InternalMutationHook,
        [ValidateRange(0, 10000)][int]$InternalDelayAfterValidationMilliseconds = 0
    )
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before opening the log.') }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $capturedLength = $stream.Length
        $info = [IO.FileInfo]::new([IO.Path]::GetFullPath($Path))
        $identity = "$($info.FullName.ToLowerInvariant())|$($info.CreationTimeUtc.Ticks)"
        $prior = if ($script:SharedTextTailState.ContainsKey($identity)) { $script:SharedTextTailState[$identity] } else { $null }
        $hasRetainedWindow = $null -ne $prior -and $prior.PSObject.Properties['usable'] -and [bool]$prior.usable -and $prior.PSObject.Properties['retainedBytes'] -and $prior.PSObject.Properties['retainedOffset'] -and $prior.PSObject.Properties['startsPartial']
        $continuityMatched = $false
        $initialHashBytesRead = 0
        if ($hasRetainedWindow -and [int64]$prior.offset -le $capturedLength) {
            $continuityMatched = [string]$prior.continuitySha256 -ceq [string](Get-StreamRangeSha256 -Stream $stream -Offset ([int64]$prior.continuityOffset) -Length ([int]$prior.continuityLength) -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$initialHashBytesRead))
        }
        $incremental = $hasRetainedWindow -and [int64]$prior.offset -le $capturedLength -and $continuityMatched
        if ($InternalMutationHook) { $null = & $InternalMutationHook 'after-continuity' $stream $capturedLength }
        $start = if ($incremental) { [int64]$prior.offset } else { [Math]::Max([int64]0, $capturedLength - $MaxBytes) }
        if (($capturedLength - $start) -gt $MaxBytes) {
            $start = $capturedLength - $MaxBytes
            $incremental = $false
        }
        $readLength = [int]($capturedLength - $start)
        $bytes = [byte[]]::new($readLength)
        $stream.Position = $start
        $read = 0
        while ($read -lt $readLength) {
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while reading the log.') }
            $current = $stream.Read($bytes, $read, $readLength - $read)
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired while reading the log.') }
            if ($current -le 0) { break }
            $read += $current
        }
        if ($read -ne $readLength) {
            $script:SharedTextTailState.Clear()
            $script:SharedTextTailState[$identity] = [pscustomobject]@{
                usable = $false; stable = $false; offset = 0L; retainedBytes = [byte[]]@(); retainedOffset = 0L
                startsPartial = $false; continuityOffset = 0L; continuityLength = 0; continuitySha256 = $null
                incremental = $false; resynchronized = $true; bytesRead = $read; hashBytesRead = $initialHashBytesRead
                cumulativeBytesRead = [long]$(if ($null -ne $prior -and $prior.PSObject.Properties['cumulativeBytesRead']) { [long]$prior.cumulativeBytesRead + $read } else { $read })
                error = "The shared log became shorter while reading its captured $readLength-byte span."
            }
            return @()
        }
        if ($incremental) { $priorBytes = [byte[]]$prior.retainedBytes }
        else { $priorBytes = [byte[]]::new(0) }
        $retainedBytes = [byte[]]::new($priorBytes.Length + $read)
        if ($priorBytes.Length -gt 0) { [Array]::Copy($priorBytes, 0, $retainedBytes, 0, $priorBytes.Length) }
        if ($read -gt 0) { [Array]::Copy($bytes, 0, $retainedBytes, $priorBytes.Length, $read) }
        $retainedOffset = if ($incremental) { [int64]$prior.retainedOffset } else { $start }
        $startsPartial = if ($incremental) { [bool]$prior.startsPartial } else { $start -gt 0 }
        $leadingProofByte = if ($incremental -and $prior.PSObject.Properties['leadingProofByte']) { $prior.leadingProofByte } else { $null }
        if ($retainedBytes.Length -gt $MaxBytes) {
            $discardCount = $retainedBytes.Length - $MaxBytes
            $retainedBytes = [byte[]]$retainedBytes[$discardCount..($retainedBytes.Length - 1)]
            $retainedOffset += $discardCount
            $startsPartial = $true
            $leadingProofByte = $null
        }
        if ($startsPartial -and $retainedBytes.Length -gt 0) {
            $firstBreak = [Array]::IndexOf($retainedBytes, [byte]0x0A)
            if ($firstBreak -ge 0) {
                $discardCount = $firstBreak + 1
                if ($discardCount -lt $retainedBytes.Length) { $retainedBytes = [byte[]]$retainedBytes[$discardCount..($retainedBytes.Length - 1)] }
                else { $retainedBytes = [byte[]]::new(0) }
                $retainedOffset += $discardCount
                $startsPartial = $false
                $leadingProofByte = [byte]0x0A
            }
        }
        if ($null -ne $leadingProofByte -and $retainedBytes.Length -ge $MaxBytes) {
            $nextBreak = [Array]::IndexOf($retainedBytes, [byte]0x0A)
            if ($nextBreak -ge 0) {
                $discardCount = $nextBreak + 1
                if ($discardCount -lt $retainedBytes.Length) { $retainedBytes = [byte[]]$retainedBytes[$discardCount..($retainedBytes.Length - 1)] }
                else { $retainedBytes = [byte[]]::new(0) }
                $retainedOffset += $discardCount
            }
            else {
                if ($retainedBytes.Length -gt 1) { $retainedBytes = [byte[]]$retainedBytes[1..($retainedBytes.Length - 1)] }
                else { $retainedBytes = [byte[]]::new(0) }
                $retainedOffset++
                $startsPartial = $true
                $leadingProofByte = $null
            }
        }
        $incompleteByteCount = if ($startsPartial) { 0 } else { Get-Utf8TrailingIncompleteByteCount -Bytes $retainedBytes }
        $completeByteCount = $retainedBytes.Length - $incompleteByteCount
        $combined = if (-not $startsPartial -and $completeByteCount -gt 0) { [Text.Encoding]::UTF8.GetString($retainedBytes, 0, $completeByteCount) } else { '' }
        if ($incompleteByteCount -gt 0) { $nextPendingBytes = [byte[]]$retainedBytes[$completeByteCount..($retainedBytes.Length - 1)] }
        else { $nextPendingBytes = [byte[]]::new(0) }
        $parts = @($combined -split '\r?\n')
        $residual = if ($combined.EndsWith("`n", [StringComparison]::Ordinal)) { '' } else { [string]$parts[-1] }
        $completed = if ($residual.Length -gt 0 -and $parts.Count -gt 1) { @($parts[0..($parts.Count - 2)]) } elseif ($residual.Length -gt 0) { @() } else { @($parts | Select-Object -SkipLast 1) }
        $lines = @($completed)
        if ($lines.Count -gt $Count) { $lines = @($lines[($lines.Count - $Count)..($lines.Count - 1)]) }
        # Include the left delimiter whenever decoded text starts after byte 0;
        # payload equality alone cannot prove that the first line stays framed.
        $hasLeadingProof = $null -ne $leadingProofByte -and $retainedOffset -gt 0 -and -not $startsPartial
        $continuityBytes = [byte[]]::new($retainedBytes.Length + $(if ($hasLeadingProof) { 1 } else { 0 }))
        if ($hasLeadingProof) { $continuityBytes[0] = [byte]$leadingProofByte }
        if ($retainedBytes.Length -gt 0) { [Array]::Copy($retainedBytes, 0, $continuityBytes, $(if ($hasLeadingProof) { 1 } else { 0 }), $retainedBytes.Length) }
        $continuityLength = $continuityBytes.Length
        $continuityOffset = $retainedOffset - $(if ($hasLeadingProof) { 1 } else { 0 })
        $continuitySha256 = Get-ByteArraySha256 -Bytes $continuityBytes -DeadlineUtc $DeadlineUtc
        $selectedPathStream = $null
        $selectedPathHashBytesRead = 0
        $selectedPathError = $null
        try {
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before validating the selected log path.') }
            $selectedPathStream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $selectedPathSha256 = Get-StreamRangeSha256 -Stream $selectedPathStream -Offset $continuityOffset -Length $continuityLength -DeadlineUtc $DeadlineUtc -BytesRead ([ref]$selectedPathHashBytesRead)
            $stable = $selectedPathStream.Length -ge $capturedLength -and $selectedPathSha256 -ceq $continuitySha256
        }
        catch [TimeoutException] { throw }
        catch {
            $stable = $false
            $selectedPathError = $_.Exception.Message
        }
        finally { if ($selectedPathStream) { $selectedPathStream.Dispose() } }
        if ($InternalDelayAfterValidationMilliseconds -gt 0) { Start-Sleep -Milliseconds $InternalDelayAfterValidationMilliseconds }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('SteamVR log-tail deadline expired before publishing the validated snapshot.') }
        if (-not $stable) {
            $script:SharedTextTailState.Clear()
            $script:SharedTextTailState[$identity] = [pscustomobject]@{
                usable = $false; stable = $false; offset = 0L; retainedBytes = [byte[]]@(); retainedOffset = 0L
                startsPartial = $false; continuityOffset = 0L; continuityLength = 0; continuitySha256 = $null
                incremental = $false; resynchronized = $true; bytesRead = $read
                hashBytesRead = $initialHashBytesRead + $selectedPathHashBytesRead
                cumulativeBytesRead = [long]$(if ($null -ne $prior -and $prior.PSObject.Properties['cumulativeBytesRead']) { [long]$prior.cumulativeBytesRead + $read } else { $read })
                error = $(if ($selectedPathError) { "The selected shared log could not be validated: $selectedPathError" } else { 'The shared log changed or was replaced while its bounded tail snapshot was being validated.' })
            }
            return @()
        }
        $usable = $retainedBytes.Length -gt 0 -or $retainedOffset -eq 0
        $script:SharedTextTailState.Clear()
        $script:SharedTextTailState[$identity] = [pscustomobject]@{
            usable = $usable
            stable = $true
            offset = $capturedLength
            residual = $residual
            lines = $lines
            pendingBytes = $nextPendingBytes
            retainedBytes = $retainedBytes
            retainedOffset = $retainedOffset
            startsPartial = $startsPartial
            leadingProofByte = $leadingProofByte
            continuityOffset = $continuityOffset
            continuityLength = $continuityLength
            continuitySha256 = $continuitySha256
            incremental = $incremental
            resynchronized = $null -ne $prior -and -not $incremental
            bytesRead = $read
            hashBytesRead = $initialHashBytesRead + $selectedPathHashBytesRead
            cumulativeBytesRead = [long]$(if ($null -ne $prior -and $prior.PSObject.Properties['cumulativeBytesRead']) { [long]$prior.cumulativeBytesRead + $read } else { $read })
        }
        $visible = @($lines)
        if ($residual.Length -gt 0) { $visible += $residual }
        if ($visible.Count -gt $Count) { return @($visible[($visible.Count - $Count)..($visible.Count - 1)]) }
        return $visible
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-SteamVRTargetControl {
    param(
        [Parameter(Mandatory)][string]$Settings,
        [Parameter(Mandatory)][string]$OpenVRPaths,
        [Parameter(Mandatory)][string]$ControlRoot
    )
    $settingsFull = [IO.Path]::GetFullPath($Settings).TrimEnd('\').ToLowerInvariant()
    $openVRFull = [IO.Path]::GetFullPath($OpenVRPaths).TrimEnd('\').ToLowerInvariant()
    $identity = "$settingsFull`n$openVRFull"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $key = [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($identity))).ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    $directory = Join-Path ([IO.Path]::GetFullPath($ControlRoot)) $key
    return [pscustomobject][ordered]@{
        key = $key
        identity = $identity
        directory = $directory
        lockPath = Join-Path $directory 'target.lock'
        journalPath = Join-Path $directory 'transaction.journal.json'
    }
}

function Enter-SteamVRTargetLock {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )
    [IO.Directory]::CreateDirectory([string]$Control.directory) | Out-Null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            $stream = [IO.File]::Open([string]$Control.lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $owner = [ordered]@{ pid = $PID; acquiredUtc = [DateTime]::UtcNow.ToString('o'); command = $Command; targetKey = [string]$Control.key } | ConvertTo-Json -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($owner)
            $stream.SetLength(0); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
            return $stream
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out acquiring the SteamVR target transaction lock after $TimeoutMilliseconds ms: $($Control.lockPath)" }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function ConvertTo-CanonicalJsonValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $canonical = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $canonical[$key] = ConvertTo-CanonicalJsonValue -Value $Value[$key] }
        return $canonical
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-CanonicalJsonValue -Value $_ })
    }
    return $Value
}

function Get-JsonSemanticSha256 {
    param([string]$Path, [AllowNull()]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $Value = Read-JsonHashtable -Path $Path
    }
    $json = (ConvertTo-CanonicalJsonValue -Value $Value) | ConvertTo-Json -Depth 64 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($json))) }
    finally { $algorithm.Dispose() }
}

function Test-JsonDictionaryContains($Dictionary, [string]$Key) {
    return $Dictionary -is [Collections.IDictionary] -and $Dictionary.Contains($Key)
}

function Test-JsonValueEquivalent([AllowNull()]$Expected, [AllowNull()]$Actual) {
    if ($null -eq $Expected -or $null -eq $Actual) { return $null -eq $Expected -and $null -eq $Actual }
    if ($Expected -is [Collections.IDictionary] -or $Actual -is [Collections.IDictionary]) {
        if ($Expected -isnot [Collections.IDictionary] -or $Actual -isnot [Collections.IDictionary]) { return $false }
        $expectedKeys = @($Expected.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        $actualKeys = @($Actual.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
        if (($expectedKeys -join "`n") -cne ($actualKeys -join "`n")) { return $false }
        foreach ($key in $expectedKeys) { if (-not (Test-JsonValueEquivalent $Expected[$key] $Actual[$key])) { return $false } }
        return $true
    }
    $expectedEnumerable = $Expected -is [Collections.IEnumerable] -and $Expected -isnot [string]
    $actualEnumerable = $Actual -is [Collections.IEnumerable] -and $Actual -isnot [string]
    if ($expectedEnumerable -or $actualEnumerable) {
        if (-not $expectedEnumerable -or -not $actualEnumerable) { return $false }
        $expectedItems = @($Expected); $actualItems = @($Actual)
        if ($expectedItems.Count -ne $actualItems.Count) { return $false }
        for ($index = 0; $index -lt $expectedItems.Count; $index++) { if (-not (Test-JsonValueEquivalent $expectedItems[$index] $actualItems[$index])) { return $false } }
        return $true
    }
    if ($Expected -is [string] -or $Actual -is [string]) { return $Expected -is [string] -and $Actual -is [string] -and [string]$Expected -ceq [string]$Actual }
    return $Expected -eq $Actual
}

function Get-JsonDifferencePaths([AllowNull()]$Expected, [AllowNull()]$Actual, [string]$Path = '') {
    $differences = [Collections.Generic.List[string]]::new()
    if ($Expected -is [Collections.IDictionary] -and $Actual -is [Collections.IDictionary]) {
        $keys = @(@($Expected.Keys) + @($Actual.Keys) | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)
        foreach ($key in $keys) {
            $child = if ([string]::IsNullOrWhiteSpace($Path)) { $key } else { "$Path.$key" }
            if (-not (Test-JsonDictionaryContains $Expected $key) -or -not (Test-JsonDictionaryContains $Actual $key)) { $differences.Add($child); continue }
            foreach ($difference in @(Get-JsonDifferencePaths $Expected[$key] $Actual[$key] $child)) { $differences.Add($difference) }
        }
        return @($differences)
    }
    $expectedEnumerable = $Expected -is [Collections.IEnumerable] -and $Expected -isnot [string]
    $actualEnumerable = $Actual -is [Collections.IEnumerable] -and $Actual -isnot [string]
    if ($expectedEnumerable -and $actualEnumerable) {
        $expectedItems = @($Expected); $actualItems = @($Actual)
        if ($expectedItems.Count -ne $actualItems.Count) { return @($Path) }
        for ($index = 0; $index -lt $expectedItems.Count; $index++) {
            foreach ($difference in @(Get-JsonDifferencePaths $expectedItems[$index] $actualItems[$index] "$Path[$index]")) { $differences.Add($difference) }
        }
        return @($differences)
    }
    if (-not (Test-JsonValueEquivalent $Expected $Actual)) { return @($Path) }
    return @()
}

function Get-NullSettingsExpectation([Collections.IDictionary]$Receipt, [string]$BackupPath) {
    if (-not $Receipt.Contains('profileSha256') -or [string]::IsNullOrWhiteSpace([string]$Receipt['profileSha256'])) { throw 'The apply receipt does not identify its null-HMD profile hash.' }
    $profileCandidates = [Collections.Generic.List[string]]::new()
    foreach ($field in @('profileEvidencePath', 'profilePath')) {
        if ($Receipt.Contains($field) -and -not [string]::IsNullOrWhiteSpace([string]$Receipt[$field])) {
            $profileCandidates.Add([IO.Path]::GetFullPath([string]$Receipt[$field]))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($NullProfilePath)) { $profileCandidates.Add([IO.Path]::GetFullPath($NullProfilePath)) }
    $profilePath = @($profileCandidates | Select-Object -Unique | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and (Get-HashOrNull $_) -eq [string]$Receipt['profileSha256']
    } | Select-Object -First 1)
    if ($profilePath.Count -ne 1) { throw 'No receipt-bound or caller-supplied null-HMD profile matches the apply receipt hash.' }
    $profilePath = [string]$profilePath[0]
    $expected = Read-JsonHashtable -Path $BackupPath
    $profile = Read-JsonHashtable -Path $profilePath
    $controlled = [Collections.Generic.List[string]]::new()
    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides')) {
        if (-not $expected.Contains($section)) { $expected[$section] = [ordered]@{} }
        foreach ($key in $profile[$section].Keys) {
            $expected[$section][$key] = $profile[$section][$key]
            $controlled.Add("$section.$key")
        }
    }
    return [pscustomobject][ordered]@{ value = $expected; profile = $profile; controlledPaths = @($controlled); semanticSha256 = Get-JsonSemanticSha256 -Value $expected }
}

function Get-SettingsRestoreValidation([Collections.IDictionary]$Receipt, [string]$BackupPath, [string]$CurrentPath) {
    $expectation = Get-NullSettingsExpectation -Receipt $Receipt -BackupPath $BackupPath
    $current = Read-JsonHashtable -Path $CurrentPath
    $currentHash = Get-HashOrNull $CurrentPath
    $exactMatch = $currentHash -eq [string]$Receipt['settingsSha256Null']
    $controlledDifferences = @()
    foreach ($path in @($expectation.controlledPaths)) {
        $section, $key = $path -split '[.]', 2
        if (-not $current.Contains($section) -or $current[$section] -isnot [Collections.IDictionary] -or -not $current[$section].Contains($key) -or -not (Test-JsonValueEquivalent $expectation.profile[$section][$key] $current[$section][$key])) { $controlledDifferences += $path }
    }
    $allDifferences = @(Get-JsonDifferencePaths $expectation.value $current)
    $runtimeManagedPrefixes = @('GpuSpeed', 'LastKnown')
    $unclassified = @($allDifferences | Where-Object {
        $candidate = [string]$_
        @($runtimeManagedPrefixes | Where-Object { $candidate -eq $_ -or $candidate.StartsWith("$_`.", [StringComparison]::Ordinal) }).Count -eq 0
    })
    $controlledMatch = $controlledDifferences.Count -eq 0
    $formattingOnly = -not $exactMatch -and $allDifferences.Count -eq 0
    $runtimeManagedOnly = -not $exactMatch -and $controlledMatch -and $allDifferences.Count -gt 0 -and $unclassified.Count -eq 0
    return [pscustomobject][ordered]@{
        exactMatch = $exactMatch; controlledContractMatch = $controlledMatch; formattingOnlyDriftAccepted = $formattingOnly; runtimeManagedOnlyDriftAccepted = $runtimeManagedOnly
        authorized = $exactMatch -or $formattingOnly -or $runtimeManagedOnly; authorizationRoute = if ($exactMatch) { 'exact-applied-bytes' } elseif ($formattingOnly) { 'semantic-formatting-only' } elseif ($runtimeManagedOnly) { 'controlled-contract-plus-runtime-managed-fields' } else { 'none' }
        currentSha256 = $currentHash; expectedSha256 = [string]$Receipt['settingsSha256Null']; expectedSemanticSha256 = $expectation.semanticSha256
        currentSemanticSha256 = Get-JsonSemanticSha256 -Value $current; controlledDifferences = @($controlledDifferences)
        runtimeManagedDifferencePaths = @($allDifferences | Where-Object { $_ -notin $unclassified }); unclassifiedDifferencePaths = @($unclassified)
    }
}

function Get-IsolatedRegistrationExpectation {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets
    )
    $document = Read-JsonHashtable -Path $BackupPath
    $registered = @($document['external_drivers'])
    $targetRoots = @($Targets | ForEach-Object { Get-NormalizedPath ([string]$_['root']) })
    $uniqueTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($targetRoot in $targetRoots) {
        if ([string]::IsNullOrWhiteSpace($targetRoot) -or -not $uniqueTargets.Add($targetRoot)) {
            throw 'The isolation receipt contains an empty or duplicate normalized target root.'
        }
    }

    $occurrences = @{}
    foreach ($targetRoot in $targetRoots) { $occurrences[$targetRoot] = 0 }
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($rootValue in $registered) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
        $normalized = Get-NormalizedPath ([string]$rootValue)
        if ($uniqueTargets.Contains($normalized)) { $occurrences[$normalized] = [int]$occurrences[$normalized] + 1 }
        else { $retained.Add([string]$rootValue) }
    }
    foreach ($targetRoot in $targetRoots) {
        if ([int]$occurrences[$targetRoot] -ne 1) {
            throw "The exact registration backup contains isolation target '$targetRoot' $($occurrences[$targetRoot]) times; exactly one occurrence is required."
        }
    }
    $document['external_drivers'] = @($retained)
    return [pscustomobject][ordered]@{
        semanticSha256 = Get-JsonSemanticSha256 -Value $document
        targetRoots = @($targetRoots)
        retainedRoots = @($retained)
    }
}

function Get-IsolationValidation {
    param(
        [Parameter(Mandatory)]$Isolation,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$CurrentPath
    )
    $expectation = Get-IsolatedRegistrationExpectation -BackupPath $BackupPath -Targets @($Isolation['targets'])
    $recordedSemanticSha256 = if ($Isolation.ContainsKey('semanticSha256Isolated')) { [string]$Isolation['semanticSha256Isolated'] } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($recordedSemanticSha256) -and $recordedSemanticSha256 -ne $expectation.semanticSha256) {
        throw 'The receipt semantic hash does not match the isolated state reconstructed from the exact registration backup.'
    }
    $currentSha256 = Get-HashOrNull $CurrentPath
    $expectedSha256 = [string]$Isolation['sha256Isolated']
    $currentSemanticSha256 = Get-JsonSemanticSha256 -Path $CurrentPath
    return [pscustomobject][ordered]@{
        exactMatch = $currentSha256 -eq $expectedSha256
        semanticMatch = $currentSemanticSha256 -eq $expectation.semanticSha256
        formattingOnlyDriftAccepted = $currentSha256 -ne $expectedSha256 -and $currentSemanticSha256 -eq $expectation.semanticSha256
        currentSha256 = $currentSha256
        expectedSha256 = $expectedSha256
        currentSemanticSha256 = $currentSemanticSha256
        expectedSemanticSha256 = $expectation.semanticSha256
        recordedSemanticSha256 = $recordedSemanticSha256
        expectationSource = 'exact-backup-minus-unique-targets'
        targetRoots = $expectation.targetRoots
    }
}

function Get-ExternalDriverInventory {
    param([string]$Path)
    $drivers = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject][ordered]@{ path = $null; exists = $false; sha256 = $null; semanticSha256 = $null; drivers = @(); conflicts = @(); errors = @('The OpenVR paths file could not be resolved because LOCALAPPDATA is unavailable.') }
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ path = $resolvedPath; exists = $false; sha256 = $null; semanticSha256 = $null; drivers = @(); conflicts = @(); errors = @() }
    }
    try {
        $paths = Read-JsonHashtable -Path $resolvedPath
        foreach ($rootValue in @($paths['external_drivers'])) {
            if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
            $root = [IO.Path]::GetFullPath([string]$rootValue)
            $manifestPath = Join-Path $root 'driver.vrdrivermanifest'
            $record = [ordered]@{
                root = $root
                manifestPath = $manifestPath
                manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
                manifestSha256 = $null
                name = $null
                alwaysActivate = $false
                redirectsDisplay = $false
                conflictsWithNullDisplay = $false
                error = $null
            }
            if ($record.manifestExists) {
                try {
                    $manifest = Read-JsonHashtable -Path $manifestPath
                    $record.manifestSha256 = Get-HashOrNull $manifestPath
                    $record.name = if ($manifest.ContainsKey('name')) { [string]$manifest['name'] } else { [IO.Path]::GetFileName($root) }
                    $record.alwaysActivate = $manifest.ContainsKey('alwaysActivate') -and [bool]$manifest['alwaysActivate']
                    $record.redirectsDisplay = $manifest.ContainsKey('redirectsDisplay') -and [bool]$manifest['redirectsDisplay']
                    $record.conflictsWithNullDisplay = [bool]$record.redirectsDisplay
                }
                catch { $record.error = $_.Exception.Message }
            }
            else { $record.error = 'External driver registration has no driver.vrdrivermanifest.' }
            $drivers.Add([pscustomobject]$record)
            if (-not [string]::IsNullOrWhiteSpace([string]$record.error)) { $errors.Add("External driver '$root' could not be classified: $($record.error)") }
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    $conflicts = @($drivers | Where-Object conflictsWithNullDisplay)
    return [pscustomobject][ordered]@{
        path = $resolvedPath
        exists = $true
        sha256 = Get-HashOrNull $resolvedPath
        semanticSha256 = Get-JsonSemanticSha256 -Path $resolvedPath
        drivers = @($drivers)
        conflicts = $conflicts
        errors = @($errors)
    }
}

function Get-NormalizedPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ExternalDisplayIsolationTargets {
    param(
        [Parameter(Mandatory)]$Inventory,
        [string[]]$RequestedRoots = @()
    )
    if ($Inventory.errors.Count -gt 0) {
        throw 'External display-driver isolation requires a complete, error-free OpenVR driver inventory.'
    }
    $conflicts = @($Inventory.conflicts)
    if ($conflicts.Count -eq 0) {
        throw 'External display-driver isolation was requested, but no registered display redirector is present.'
    }

    $requested = @($RequestedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-NormalizedPath $_ } | Select-Object -Unique)
    if ($requested.Count -eq 0) {
        if ($conflicts.Count -ne 1) {
            throw "External display-driver isolation found $($conflicts.Count) redirectors. Specify every exact root with -ExternalDisplayRedirectorRoot."
        }
        return @($conflicts)
    }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($root in $requested) {
        $matches = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq $root })
        if ($matches.Count -ne 1) {
            throw "Requested external display redirector '$root' is not one exact classified conflict."
        }
        $selected.Add($matches[0])
    }
    $unselected = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -notin $requested })
    if ($unselected.Count -gt 0) {
        throw "External display-driver isolation must account for every redirector. Unselected: $(@($unselected.root) -join ', ')"
    }
    return @($selected)
}

function Disable-ExternalDriverRegistrations {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets
    )
    $document = Read-JsonHashtable -Path $Path
    $registered = @($document['external_drivers'])
    $targetRoots = @($Targets | ForEach-Object { Get-NormalizedPath ([string]$_.root) })
    $uniqueTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($targetRoot in $targetRoots) {
        if ([string]::IsNullOrWhiteSpace($targetRoot) -or -not $uniqueTargets.Add($targetRoot)) {
            throw 'External display-driver isolation contains an empty or duplicate normalized target root.'
        }
    }
    $removed = [Collections.Generic.List[string]]::new()
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($rootValue in $registered) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
        $normalized = Get-NormalizedPath ([string]$rootValue)
        if ($uniqueTargets.Contains($normalized)) { $removed.Add($normalized) } else { $retained.Add([string]$rootValue) }
    }
    foreach ($targetRoot in $targetRoots) {
        if (@($removed | Where-Object { $_ -eq $targetRoot }).Count -ne 1) {
            throw "OpenVR registration changed before isolation. Target '$targetRoot' must occur exactly once."
        }
    }
    $document['external_drivers'] = @($retained)
    Write-JsonAtomic -Path $Path -Value $document
    return [pscustomobject][ordered]@{ removedRoots = @($removed); retainedRoots = @($retained) }
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 32
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        $null = Read-JsonHashtable -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Copy-FileAtomicVerified {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, [IO.File]::ReadAllBytes($Source))
        if ((Get-HashOrNull $temporary) -ne $ExpectedSha256) { throw 'The staged null-HMD profile copy failed hash verification.' }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
        if ((Get-HashOrNull $Destination) -ne $ExpectedSha256) { throw 'The committed null-HMD profile evidence failed hash verification.' }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-SteamVRTransactionJournal {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$AuthoritativePath
    )
    Write-JsonAtomic -Path $AuthoritativePath -Value $Journal
    if ((Test-JsonDictionaryContains $Journal 'evidenceJournalPath') -and -not [string]::IsNullOrWhiteSpace([string]$Journal['evidenceJournalPath'])) {
        Write-JsonAtomic -Path ([string]$Journal['evidenceJournalPath']) -Value $Journal
    }
}

function Restore-SteamVRTransactionTargets {
    param(
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$FailureContext
    )
    $errors = @()
    foreach ($target in @($Targets)) {
        try {
            if (-not (Test-Path -LiteralPath ([string]$target['backupPath']) -PathType Leaf)) { throw 'exact rollback preimage is missing' }
            if ((Get-HashOrNull ([string]$target['backupPath'])) -ne [string]$target['expectedHash']) { throw 'rollback preimage hash differs from the journal' }
            Copy-FileAtomic -Source ([string]$target['backupPath']) -Destination ([string]$target['path'])
        }
        catch { $errors += "$($target['name']): $($_.Exception.Message)" }
    }
    foreach ($target in @($Targets)) {
        try { if ((Get-HashOrNull ([string]$target['path'])) -ne [string]$target['expectedHash']) { throw 'live hash does not match the rollback preimage' } }
        catch { $errors += "$($target['name']) verification: $($_.Exception.Message)" }
    }
    $Journal['phase'] = if ($errors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
    $Journal['rollback'] = [ordered]@{ verified = $errors.Count -eq 0; errors = $errors; completedUtc = [DateTime]::UtcNow.ToString('o') }
    try { Write-SteamVRTransactionJournal -AuthoritativePath $JournalPath -Journal $Journal } catch { $errors += "journal: $($_.Exception.Message)" }
    if ($errors.Count -gt 0) { throw "$FailureContext Rollback requires recovery: $($errors -join '; ')" }
}

function Resolve-PendingSteamVRJournal([string]$JournalPath) {
    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
    $journal = Read-JsonHashtable -Path $JournalPath
    if ([string]$journal['phase'] -in @('committed', 'rolled-back', 'recovered')) { return $journal }
    if (-not $journal.ContainsKey('rollbackTargets')) { throw "SteamVR transaction journal requires manual recovery: $JournalPath" }
    Restore-SteamVRTransactionTargets -Targets @($journal['rollbackTargets']) -Journal $journal -JournalPath $JournalPath -FailureContext 'Interrupted SteamVR transaction recovery failed.'
    $journal['phase'] = 'recovered'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
    Write-SteamVRTransactionJournal -AuthoritativePath $JournalPath -Journal $journal
    return $journal
}

function Test-SteamVRJournalTerminal([AllowNull()]$Journal) {
    return $null -eq $Journal -or [string]$Journal['phase'] -in @('committed', 'rolled-back', 'recovered')
}

function Assert-SteamVRJournalTargets {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$ExpectedSettingsPath,
        [Parameter(Mandatory)][string]$ExpectedOpenVRPathsPath
    )
    $settingsFull = [IO.Path]::GetFullPath($ExpectedSettingsPath)
    $openVRFull = [IO.Path]::GetFullPath($ExpectedOpenVRPathsPath)
    $operation = if (Test-JsonDictionaryContains $Journal 'operation') { [string]$Journal['operation'] } else { '' }
    $isLegacyApplyReconcile = [string]::Equals($operation, 'apply-reconcile', [StringComparison]::Ordinal)
    if (-not (Test-JsonDictionaryContains $Journal 'settingsPath') -or -not [string]::Equals([IO.Path]::GetFullPath([string]$Journal['settingsPath']), $settingsFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The authoritative SteamVR journal settings target does not match its target-owned control directory.'
    }
    if ((Test-JsonDictionaryContains $Journal 'openVRPathsPath') -and -not [string]::IsNullOrWhiteSpace([string]$Journal['openVRPathsPath']) -and -not [string]::Equals([IO.Path]::GetFullPath([string]$Journal['openVRPathsPath']), $openVRFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The authoritative SteamVR journal OpenVR target does not match its target-owned control directory.'
    }
    if (-not (Test-JsonDictionaryContains $Journal 'rollbackTargets')) { throw 'The authoritative SteamVR journal has no rollback target inventory.' }
    $allowed = @($settingsFull.ToLowerInvariant(), $openVRFull.ToLowerInvariant())
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in @($Journal['rollbackTargets'])) {
        if (-not (Test-JsonDictionaryContains $target 'path')) { throw 'The authoritative SteamVR journal contains a rollback target without a path.' }
        $path = [IO.Path]::GetFullPath([string]$target['path'])
        if ($path.ToLowerInvariant() -notin $allowed) { throw "The authoritative SteamVR journal contains an out-of-contract rollback target: $path" }
        if (-not $seen.Add($path)) { throw "The authoritative SteamVR journal repeats a rollback target: $path" }
    }
    if ($isLegacyApplyReconcile) {
        if (-not $seen.Contains($openVRFull)) { throw 'The authoritative legacy apply-reconcile journal does not contain the OpenVR registrations rollback target.' }
    }
    elseif (-not $seen.Contains($settingsFull)) {
        throw 'The authoritative SteamVR journal does not contain the SteamVR settings rollback target.'
    }
}

function Stop-ExactStartedSteamVRProcesses([DateTime]$StartedUtc) {
    $targets = @(Get-SteamVRProcesses | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.startTimeUtc) -and [DateTime]::Parse([string]$_.startTimeUtc).ToUniversalTime() -ge $StartedUtc.AddSeconds(-1)
    })
    $errors = @()
    foreach ($target in $targets) { try { Stop-Process -Id ([int]$target.id) -Force -ErrorAction Stop } catch { $errors += "$($target.name)[$($target.id)]: $($_.Exception.Message)" } }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @($targets | Where-Object { Get-Process -Id ([int]$_.id) -ErrorAction SilentlyContinue })
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 100 }
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    return [pscustomobject][ordered]@{ requested = $targets; remaining = $remaining; errors = $errors; verified = $remaining.Count -eq 0 -and $errors.Count -eq 0 }
}

function Get-EffectiveState {
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Profile
    )
    $steamvr = if ($Settings.ContainsKey('steamvr')) { $Settings['steamvr'] } else { @{} }
    $dashboard = if ($Settings.ContainsKey('dashboard')) { $Settings['dashboard'] } else { @{} }
    $driver = if ($Settings.ContainsKey('driver_null')) { $Settings['driver_null'] } else { @{} }
    $headPoseDriver = if ($Settings.ContainsKey('driver_codex_head_pose')) { $Settings['driver_codex_head_pose'] } else { @{} }
    $trackingOverrides = if ($Settings.ContainsKey('TrackingOverrides')) { $Settings['TrackingOverrides'] } else { @{} }
    $expectedSteamVR = $Profile['steamvr']
    $expectedDashboard = $Profile['dashboard']
    $expectedDriver = $Profile['driver_null']
    $expectedHeadPoseDriver = $Profile['driver_codex_head_pose']
    $expectedTrackingOverrides = $Profile['TrackingOverrides']

    $checks = [ordered]@{}
    foreach ($key in @('forcedDriver', 'requireHmd', 'activateMultipleDrivers', 'enableHomeApp')) {
        $checks["steamvr.$key"] = [ordered]@{
            actual = if ($steamvr.ContainsKey($key)) { $steamvr[$key] } else { $null }
            expected = $expectedSteamVR[$key]
            matches = $steamvr.ContainsKey($key) -and $steamvr[$key] -eq $expectedSteamVR[$key]
        }
    }
    foreach ($key in $expectedDashboard.Keys) {
        $checks["dashboard.$key"] = [ordered]@{
            actual = if ($dashboard.ContainsKey($key)) { $dashboard[$key] } else { $null }
            expected = $expectedDashboard[$key]
            matches = $dashboard.ContainsKey($key) -and $dashboard[$key] -eq $expectedDashboard[$key]
        }
    }
    foreach ($key in @('enable', 'serialNumber', 'modelNumber', 'windowWidth', 'windowHeight', 'renderWidth', 'renderHeight', 'displayFrequency')) {
        $checks["driver_null.$key"] = [ordered]@{
            actual = if ($driver.ContainsKey($key)) { $driver[$key] } else { $null }
            expected = $expectedDriver[$key]
            matches = $driver.ContainsKey($key) -and $driver[$key] -eq $expectedDriver[$key]
        }
    }
    foreach ($key in $expectedHeadPoseDriver.Keys) {
        $checks["driver_codex_head_pose.$key"] = [ordered]@{
            actual = if ($headPoseDriver.ContainsKey($key)) { $headPoseDriver[$key] } else { $null }
            expected = $expectedHeadPoseDriver[$key]
            matches = $headPoseDriver.ContainsKey($key) -and $headPoseDriver[$key] -eq $expectedHeadPoseDriver[$key]
        }
    }
    foreach ($key in $expectedTrackingOverrides.Keys) {
        $checks["TrackingOverrides.$key"] = [ordered]@{
            actual = if ($trackingOverrides.ContainsKey($key)) { $trackingOverrides[$key] } else { $null }
            expected = $expectedTrackingOverrides[$key]
            matches = $trackingOverrides.ContainsKey($key) -and $trackingOverrides[$key] -eq $expectedTrackingOverrides[$key]
        }
    }
    return [pscustomobject][ordered]@{
        active = @($checks.Values | Where-Object { -not $_.matches }).Count -eq 0
        checks = $checks
    }
}

function Read-HeadPoseAtomicUInt64([IO.MemoryMappedFiles.MemoryMappedViewAccessor]$View, [long]$Offset) {
    return [uint64][SkyrimVRAutomation.Native.SharedPoseAtomics]::ReadInt64(
        $View.SafeMemoryMappedViewHandle,
        $View.PointerOffset,
        $Offset)
}

function Test-HeadPoseDriverIdentity([uint32]$CreatorPid, [uint64]$DriverStartedFileTimeUtc) {
    if ($CreatorPid -eq 0 -or $DriverStartedFileTimeUtc -eq 0) { return $false }
    try {
        $process = Get-Process -Id $CreatorPid -ErrorAction Stop
        $processStart = [uint64]$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        $now = [uint64][DateTime]::UtcNow.AddSeconds(5).ToFileTimeUtc()
        return $processStart -le $DriverStartedFileTimeUtc -and $DriverStartedFileTimeUtc -le $now
    }
    catch { return $false }
}

function Get-HeadPoseSharedState {
    param([Parameter(Mandatory)]$Contract)
    $mapping = $null
    $view = $null
    try {
        $expectedVersion = [int]$Contract['sharedMemoryVersion']
        $requiredSize = switch ($expectedVersion) {
            1 { 88 }
            2 { 128 }
            default { throw "Unsupported head-pose shared-memory version: $expectedVersion" }
        }
        $expectedSize = if ($Contract.ContainsKey('sharedMemorySize')) {
            [int]$Contract['sharedMemorySize']
        }
        else { $requiredSize }
        if ($expectedSize -ne $requiredSize) {
            throw "Head-pose shared-memory version $expectedVersion requires a $requiredSize-byte contract, not $expectedSize bytes."
        }
        $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            [string]$Contract['sharedMemoryName'],
            [IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
        # Interlocked.Read requires a writable view but does not mutate the contract.
        $view = $mapping.CreateViewAccessor(0, $expectedSize, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $firstSequence = Read-HeadPoseAtomicUInt64 -View $view -Offset 8
            if (($firstSequence % 2) -ne 0) {
                [Threading.Thread]::Sleep(1)
                continue
            }
            $state = [ordered]@{
                magic = $view.ReadUInt32(0)
                version = $view.ReadUInt16(4)
                size = $view.ReadUInt16(6)
                requestedSequence = $firstSequence
                appliedSequence = Read-HeadPoseAtomicUInt64 -View $view -Offset 16
                status = $view.ReadUInt32(24)
                flags = $view.ReadUInt32(28)
                position = @($view.ReadDouble(32), $view.ReadDouble(40), $view.ReadDouble(48))
                quaternion = @($view.ReadDouble(56), $view.ReadDouble(64), $view.ReadDouble(72), $view.ReadDouble(80))
            }
            if ($expectedVersion -eq 2) {
                $state['writerNonce'] = $view.ReadUInt64(88)
                $state['acknowledgedWriterNonce'] = $view.ReadUInt64(96)
                $state['driverInstanceNonce'] = $view.ReadUInt64(104)
                $state['driverCreatorPid'] = $view.ReadUInt32(112)
                $state['driverStartedFileTimeUtc'] = $view.ReadUInt64(120)
            }
            $secondSequence = Read-HeadPoseAtomicUInt64 -View $view -Offset 8
            if ($firstSequence -ne $secondSequence -or ($secondSequence % 2) -ne 0) { continue }

            $state['stable'] = $true
            $state['available'] = $true
            $state['protocolValid'] = $state.magic -eq 0x48505343 -and $state.version -eq $expectedVersion -and $state.size -eq $expectedSize
            $state['eyeHeightQualified'] = $state.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and $state.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
            if ($expectedVersion -eq 2) {
                $state['driverIdentityVerified'] = Test-HeadPoseDriverIdentity -CreatorPid $state.driverCreatorPid -DriverStartedFileTimeUtc $state.driverStartedFileTimeUtc
                $state['acknowledged'] = $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.writerNonce -ne 0 -and $state.acknowledgedWriterNonce -eq $state.writerNonce -and $state.status -eq 1
                $state['qualified'] = $state.protocolValid -and $state.driverIdentityVerified -and $state.driverInstanceNonce -ne 0 -and $state.acknowledged -and $state.eyeHeightQualified -and (($state.flags -band 1) -eq 1)
            }
            else {
                $state['acknowledged'] = $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.status -eq 1
                $state['qualified'] = $state.protocolValid -and $state.acknowledged -and $state.eyeHeightQualified -and (($state.flags -band 1) -eq 1)
            }
            return [pscustomobject]$state
        }
        throw 'The shared pose changed continuously and could not be read atomically.'
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The head-pose shared-memory provider is not running.' }
    }
    catch [UnauthorizedAccessException] {
        throw [UnauthorizedAccessException]::new('The automation identity is not authorized to read and acknowledge the head-pose shared-memory provider.', $_.Exception)
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = $_.Exception.Message }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }
}

function Get-ApplicationHeadPose {
    param(
        [Parameter(Mandatory)]$Contract,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue
    )
    if ([string]::IsNullOrWhiteSpace($HeadPoseDriverRoot)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The stable head-pose driver root could not be resolved.' }
    }
    $probePath = Join-Path $HeadPoseDriverRoot ([string]$Contract['poseProbeRelativePath'])
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = 'The independent OpenVR pose probe is not installed.' }
    }
    try {
        $boundedTool = Join-Path (Split-Path -Parent $PSScriptRoot) 'process-control\Invoke-BoundedProcess.ps1'
        if (-not (Test-Path -LiteralPath $boundedTool -PathType Leaf)) { throw "Bounded process controller is missing: $boundedTool" }
        $probeTimeoutSeconds = 10
        if ($DeadlineUtc -ne [DateTime]::MaxValue) {
            $remainingMilliseconds = [long]($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
            if ($remainingMilliseconds -lt 1450) {
                throw [TimeoutException]::new('SteamVR readiness deadline leaves insufficient time for the application-facing pose probe and bounded cleanup.')
            }
            $probeTimeoutSeconds = [Math]::Max(1, [Math]::Min(10, [Math]::Floor(($remainingMilliseconds - 450) / 1000)))
        }
        $bounded = & $boundedTool -FilePath $probePath -WorkingDirectory (Split-Path -Parent $probePath) -MaxAttempts 1 -TimeoutSeconds $probeTimeoutSeconds -TerminationGraceMilliseconds 100 -StreamDrainGraceMilliseconds 100 -NoExit -Compact | ConvertFrom-Json -Depth 30
        $attempt = if (@($bounded.attempts).Count -gt 0) { $bounded.attempts[-1] } else { $null }
        if ($attempt -and [bool]$attempt.timedOut) {
            throw [TimeoutException]::new("Independent OpenVR pose probe exceeded its $probeTimeoutSeconds-second share of the SteamVR readiness deadline.")
        }
        if ($null -eq $attempt -or [string]::IsNullOrWhiteSpace([string]$attempt.stdout)) { throw "Independent OpenVR pose probe produced no bounded output. $($bounded.errors -join '; ')" }
        $payload = [string]$attempt.stdout | ConvertFrom-Json -ErrorAction Stop
        $qualified = $bounded.ok -and $payload.ok -and $payload.standing.connected -and $payload.standing.valid -and
            [double]$payload.standing.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and
            [double]$payload.standing.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
        return [pscustomobject][ordered]@{
            available = $true
            qualified = $qualified
            probePath = $probePath
            exitCode = $attempt.exitCode
            boundedProcess = $bounded
            observation = $payload
        }
    }
    catch [TimeoutException] {
        throw
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = $_.Exception.Message }
    }
}

function Get-LogTimestampUtc([string]$Line) {
    if ($Line -notmatch '^(?<timestamp>[A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+\[') {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $Matches.timestamp,
        'ddd MMM d yyyy HH:mm:ss.fff',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal,
        [ref]$parsed)) {
        return $null
    }
    return $parsed.UtcDateTime
}

function Get-NullRuntimeEvidence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [Parameter(Mandatory)]$Profile,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue
    )
    $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $owned = @($Processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $server = @($owned | Where-Object name -eq 'vrserver' | Sort-Object startTimeUtc | Select-Object -First 1)
    $serverStartUtc = if ($server.Count -eq 1 -and $server[0].startTimeUtc) { [DateTime]::Parse([string]$server[0].startTimeUtc).ToUniversalTime() } else { $null }
    $loaded = $null
    $active = $null
    $headPoseLoaded = $null
    $headPoseRegistered = $null
    $tail = @()
    $tailState = $null
    if ($serverStartUtc -and (Test-Path -LiteralPath $ServerLogPath -PathType Leaf)) {
        $tail = @(Get-SharedTextTail -Path $ServerLogPath -Count 2000 -MaxBytes $LogTailMaxBytes -DeadlineUtc $DeadlineUtc)
        $tailState = @($script:SharedTextTailState.Values | Select-Object -First 1)[0]
        $minimumUtc = $serverStartUtc.AddSeconds(-3)
        foreach ($line in $tail) {
            $timestampUtc = Get-LogTimestampUtc -Line $line
            if (-not $timestampUtc -or $timestampUtc -lt $minimumUtc) { continue }
            if ($line -match 'Loaded server driver null .*driver_null\.dll') {
                $loaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match "Active HMD set to null\.$([regex]::Escape([string]$Profile['driver_null']['serialNumber']))") {
                $active = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match 'Loaded server driver codex_head_pose .*driver_codex_head_pose\.dll') {
                $headPoseLoaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match 'codex_head_pose: registered synthetic head-pose device at configured standing pose') {
                $headPoseRegistered = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
        }
    }
    $headPoseAuthorizationError = $null
    try {
        $denyAfterStart = $InternalTestFailurePoint -eq 'head-pose-access-denied-after-start' -and
            (Get-Variable -Scope Script -Name SteamVRStartupAttemptActive -ValueOnly -ErrorAction SilentlyContinue)
        if ($InternalTestFailurePoint -eq 'head-pose-access-denied' -or $denyAfterStart) {
            throw [UnauthorizedAccessException]::new('Injected head-pose shared-memory authorization failure.')
        }
        $headPoseState = Get-HeadPoseSharedState -Contract $Profile['headPoseProviderContract']
    }
    catch [UnauthorizedAccessException] {
        $headPoseAuthorizationError = $_.Exception.Message
        $headPoseState = [pscustomobject][ordered]@{
            available = $false
            qualified = $false
            authorizationDenied = $true
            error = $headPoseAuthorizationError
        }
    }
    $providerLogReady = $server.Count -eq 1 -and $null -ne $loaded -and $null -ne $active -and $null -ne $headPoseLoaded -and $null -ne $headPoseRegistered
    $applicationHeadPose = if ($providerLogReady -and [bool]$headPoseState.qualified) { Get-ApplicationHeadPose -Contract $Profile['headPoseProviderContract'] -DeadlineUtc $DeadlineUtc } else { [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The provider is not ready for an application-facing pose probe.' } }
    $runtimeEvidence = [pscustomobject][ordered]@{
        active = $server.Count -eq 1 -and $null -ne $loaded -and $null -ne $active
        serverProcess = if ($server.Count -eq 1) { $server[0] } else { $null }
        steamVrProcesses = $owned
        unprovenProcesses = @($Processes | Where-Object { $_ -notin $owned })
        serverLogPath = $ServerLogPath
        serverLogSha256 = if ($tailState -and [bool]$tailState.stable -and [bool]$tailState.usable) { [string]$tailState.continuitySha256 } else { $null }
        serverLogHashScope = 'bounded-tail-window'
        serverLogHashOffset = if ($tailState) { [long]$tailState.continuityOffset } else { $null }
        serverLogHashLength = if ($tailState) { [int]$tailState.continuityLength } else { 0 }
        serverLogIo = [pscustomobject][ordered]@{
            maxBytes = $LogTailMaxBytes
            bytesRead = if ($tailState) { [int]$tailState.bytesRead } else { 0 }
            hashBytesRead = if ($tailState) { [int]$tailState.hashBytesRead } else { 0 }
            totalBytesExamined = if ($tailState) { [int]$tailState.bytesRead + [int]$tailState.hashBytesRead } else { 0 }
            stable = $null -ne $tailState -and [bool]$tailState.stable
            usable = $null -ne $tailState -and [bool]$tailState.usable
            incremental = $null -ne $tailState -and [bool]$tailState.incremental
            resynchronized = $null -ne $tailState -and [bool]$tailState.resynchronized
            error = if ($tailState -and $tailState.PSObject.Properties['error']) { [string]$tailState.error } else { $null }
        }
        driverLoaded = $loaded
        activeHmd = $active
        headPoseDriverLoaded = $headPoseLoaded
        headPoseDeviceRegistered = $headPoseRegistered
        headPoseState = $headPoseState
        headPoseAuthorizationError = $headPoseAuthorizationError
        applicationHeadPose = $applicationHeadPose
        headPoseReady = $providerLogReady -and [bool]$headPoseState.qualified -and [bool]$applicationHeadPose.qualified
        dashboardProcesses = @($owned | Where-Object name -eq 'vrdashboard')
        dashboardSuppressed = $Profile['dashboard'].ContainsKey('enableDashboard') -and -not [bool]$Profile['dashboard']['enableDashboard']
    }
    $fixtureReadyPoints = @(
        'runtime-ready',
        'runtime-confirmation-timeout',
        'runtime-confirmation-timeout-receipt-failure',
        'runtime-final-admission-timeout',
        'runtime-final-admission-timeout-no-confirmation',
        'runtime-post-receipt-timeout'
    )
    $fixtureMode = -not [string]::IsNullOrWhiteSpace($env:CSX_STEAMVR_TRANSACTION_ROOT) -and
        (Get-Variable -Scope Script -Name SteamVRStartupAttemptActive -ValueOnly -ErrorAction SilentlyContinue)
    if ($fixtureMode -and $InternalTestFailurePoint -in $fixtureReadyPoints) {
        $runtimeEvidence.active = $true
        $runtimeEvidence.headPoseReady = $true
        $runtimeEvidence.headPoseAuthorizationError = $null
    }
    return $runtimeEvidence
}

function New-Result {
    param([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @())
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @($Errors)
        data = $Data
    }
}

function Get-RuntimeInputContract {
    param(
        [Parameter(Mandatory)]$BaseContract,
        [Parameter(Mandatory)]$Effective,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$ExternalDrivers,
        [bool]$DiagnosticDisplayOverride = $false
    )
    $contract = ($BaseContract | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable)
    $blockers = [Collections.Generic.List[string]]::new()
    if (-not [bool]$Effective.active) { $blockers.Add('null-profile-not-effective') }
    if (-not [bool]$Runtime.active) { $blockers.Add('null-runtime-not-active') }
    if (-not [bool]$Runtime.headPoseReady) { $blockers.Add('head-pose-not-qualified') }
    if ($ExternalDrivers.errors.Count -gt 0) { $blockers.Add('external-driver-inventory-incomplete') }
    if ($ExternalDrivers.conflicts.Count -gt 0) { $blockers.Add('external-display-redirector-present') }
    if ($DiagnosticDisplayOverride) { $blockers.Add('diagnostic-display-override') }
    $contract['measurementReady'] = $blockers.Count -eq 0
    $contract['measurementBlockers'] = @($blockers)
    $contract['dashboardProcessTelemetryOnly'] = $true
    return $contract
}

$targetControl = $null
$targetLock = $null
$recoveredTransaction = $null
$pendingAuthoritativeTransaction = $null
$startupAttemptStartedUtc = $null
$startupAttemptAccepted = $false
$startupCleanup = $null
try {
    if ([string]::IsNullOrWhiteSpace($OpenVRPathsPath)) { throw 'OpenVRPathsPath is required to identify the complete live transaction target.' }
    $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) { throw 'The Windows LocalApplicationData folder could not be resolved for target-owned transaction control.' }
    $transactionControlRoot = Join-Path $localApplicationData 'CSX-VR-Automation\SteamVR\transactions'
    if (-not [string]::IsNullOrWhiteSpace($env:CSX_STEAMVR_TRANSACTION_ROOT)) {
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $fixtureSettings = [IO.Path]::GetFullPath($SettingsPath)
        $fixtureControl = [IO.Path]::GetFullPath($env:CSX_STEAMVR_TRANSACTION_ROOT)
        if (-not $fixtureSettings.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or -not ($fixtureControl.TrimEnd('\') + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'CSX_STEAMVR_TRANSACTION_ROOT is test-only and requires both settings and control paths inside the OS temporary directory.'
        }
        $transactionControlRoot = $fixtureControl
    }
    $targetControl = Get-SteamVRTargetControl -Settings $SettingsPath -OpenVRPaths $OpenVRPathsPath -ControlRoot $transactionControlRoot
    $targetLock = Enter-SteamVRTargetLock -Control $targetControl -TimeoutMilliseconds $TransactionLockTimeoutMilliseconds
    if (Test-Path -LiteralPath ([string]$targetControl.journalPath) -PathType Leaf) {
        $pendingAuthoritativeTransaction = Read-JsonHashtable -Path ([string]$targetControl.journalPath)
        Assert-SteamVRJournalTargets -Journal $pendingAuthoritativeTransaction -ExpectedSettingsPath $SettingsPath -ExpectedOpenVRPathsPath $OpenVRPathsPath
    }
    if (Test-SteamVRJournalTerminal $pendingAuthoritativeTransaction) {
        $recoveredTransaction = $pendingAuthoritativeTransaction
    }
    else {
        $preRecoveryRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
        $preRecoveryProcesses = @(Get-SteamVRProcesses | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.path) -and [IO.Path]::GetFullPath([string]$_.path).StartsWith($preRecoveryRoot, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($preRecoveryProcesses.Count -gt 0 -and $Command -ne 'stop') {
            throw "An interrupted SteamVR target transaction requires recovery, but SteamVR is running from the configured root: $($preRecoveryProcesses.name -join ', ')"
        }
        if ($preRecoveryProcesses.Count -eq 0) {
            $recoveredTransaction = Resolve-PendingSteamVRJournal -JournalPath ([string]$targetControl.journalPath)
        }
    }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "SteamVR settings file does not exist: $SettingsPath"
    }
    if (-not (Test-Path -LiteralPath $NullProfilePath -PathType Leaf) -and $Command -eq 'restore') {
        $restoreEvidenceDirectory = if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { [IO.Path]::GetFullPath($EvidenceDirectory) } elseif ($null -ne $recoveredTransaction -and (Test-JsonDictionaryContains $recoveredTransaction 'evidenceDirectory')) { [IO.Path]::GetFullPath([string]$recoveredTransaction['evidenceDirectory']) } else { $null }
        if ($restoreEvidenceDirectory) {
            $restoreReceiptPath = Join-Path $restoreEvidenceDirectory 'steamvr-null-receipt.json'
            if (Test-Path -LiteralPath $restoreReceiptPath -PathType Leaf) {
                $restoreReceiptProfile = Read-JsonHashtable -Path $restoreReceiptPath
                foreach ($field in @('profileEvidencePath', 'profilePath')) {
                    if ($restoreReceiptProfile.Contains($field) -and -not [string]::IsNullOrWhiteSpace([string]$restoreReceiptProfile[$field])) {
                        $candidateProfilePath = [IO.Path]::GetFullPath([string]$restoreReceiptProfile[$field])
                        if ((Test-Path -LiteralPath $candidateProfilePath -PathType Leaf) -and (Get-HashOrNull $candidateProfilePath) -eq [string]$restoreReceiptProfile['profileSha256']) {
                            $NullProfilePath = $candidateProfilePath
                            break
                        }
                    }
                }
            }
        }
    }
    if (-not (Test-Path -LiteralPath $NullProfilePath -PathType Leaf)) {
        throw "Null-HMD profile does not exist and no receipt-bound evidence copy is available: $NullProfilePath"
    }
    $settings = Read-JsonHashtable -Path $SettingsPath
    $profile = Read-JsonHashtable -Path $NullProfilePath
    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides', 'headPoseProviderContract', 'automationInputContract')) {
        if (-not $profile.ContainsKey($section)) { throw "Null-HMD profile is missing '$section'." }
    }
    $processes = @(Get-SteamVRProcesses)
    $resolvedSteamVRRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $ownedProcesses = @($processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $unprovenProcesses = @($processes | Where-Object { $_ -notin $ownedProcesses })
    $effective = Get-EffectiveState -Settings $settings -Profile $profile
    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
    $externalDrivers = Get-ExternalDriverInventory -Path $OpenVRPathsPath
    $authoritativeEvidenceDirectory = if ($null -ne $recoveredTransaction -and (Test-JsonDictionaryContains $recoveredTransaction 'evidenceDirectory')) { [string]$recoveredTransaction['evidenceDirectory'] } else { $null }
    $authoritativeOwnsAppliedState = $effective.active -and $null -ne $recoveredTransaction -and (
        ([string]$recoveredTransaction['operation'] -eq 'apply' -and [string]$recoveredTransaction['phase'] -eq 'committed') -or
        ([string]$recoveredTransaction['operation'] -eq 'restore' -and [string]$recoveredTransaction['phase'] -in @('rolled-back', 'recovered'))
    )

    if ($Command -eq 'stop') {
        if ($ownedProcesses.Count -eq 0) {
            if (-not (Test-SteamVRJournalTerminal $pendingAuthoritativeTransaction)) {
                $recoveredTransaction = Resolve-PendingSteamVRJournal -JournalPath ([string]$targetControl.journalPath)
            }
            $result = New-Result -Ok $true -State 'already-stopped' -Data @{ processes = @(); unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        elseif ($WhatIf) {
            $result = New-Result -Ok $true -State 'dry-run' -Data @{ processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        else {
            if ($Force) {
                $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
                foreach ($process in $ownedProcesses) {
                    if ([string]::IsNullOrWhiteSpace([string]$process.path)) {
                        throw "Cannot prove executable ownership for SteamVR PID $($process.id)."
                    }
                    $resolvedProcessPath = [IO.Path]::GetFullPath([string]$process.path)
                    if (-not $resolvedProcessPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to terminate PID $($process.id): '$resolvedProcessPath' is outside '$resolvedRoot'."
                    }
                }
                foreach ($process in $ownedProcesses) {
                    Stop-Process -Id ([int]$process.id) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                $monitor = @($ownedProcesses | Where-Object name -eq 'vrmonitor' | Select-Object -First 1)
                if ($monitor.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$monitor[0].path)) {
                    $helper = Start-Process -FilePath ([string]$monitor[0].path) -ArgumentList '-shutdown' -WindowStyle Hidden -PassThru
                    $null = $helper.WaitForExit(5000)
                }
                foreach ($process in @($ownedProcesses | Where-Object name -eq 'vrmonitor')) {
                    $live = Get-Process -Id ([int]$process.id) -ErrorAction SilentlyContinue
                    if ($live) { $null = $live.CloseMainWindow() }
                }
            }

            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 250
                    $remaining = @(Get-SteamVRProcesses | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
                        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
                    })
            } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

            if ($remaining.Count -eq 0) {
                if (-not (Test-SteamVRJournalTerminal $pendingAuthoritativeTransaction)) {
                    $recoveredTransaction = Resolve-PendingSteamVRJournal -JournalPath ([string]$targetControl.journalPath)
                }
                $result = New-Result -Ok $true -State 'stopped' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = @(); force = [bool]$Force }
            }
            else {
                $result = New-Result -Ok $false -State 'stop-incomplete' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = $remaining; force = [bool]$Force } -Errors @(
                    $(if ($Force) { 'One or more verified SteamVR processes remained after forced termination.' } else { 'SteamVR did not accept the graceful shutdown request; retry with -Force after reviewing the exact process inventory.' })
                )
            }
        }
    }
    elseif ($Command -eq 'inspect') {
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers
        $state = if ($externalDrivers.errors.Count -gt 0) { 'external-driver-inventory-failed' } elseif ($providerDriver.Count -ne 1) { 'head-pose-provider-unavailable' } elseif ($externalDrivers.conflicts.Count -gt 0) { 'external-driver-conflict' } elseif ($runtime.headPoseAuthorizationError) { 'head-pose-provider-authorization-failed' } elseif ($runtime.active -and -not $runtime.headPoseReady) { 'head-pose-provider-not-ready' } elseif ($runtime.active -and $effective.active) { 'null-runtime-active-head-pose-ready' } elseif ($effective.active) { 'null-configured-runtime-stopped' } else { 'null-inactive' }
        $result = New-Result -Ok (-not [bool]$runtime.headPoseAuthorizationError) -State $state -Data @{
            settingsPath = $SettingsPath
            settingsSha256 = Get-HashOrNull $SettingsPath
            profilePath = $NullProfilePath
            profileSha256 = Get-HashOrNull $NullProfilePath
            processes = $processes
            effective = $effective
            runtime = $runtime
            externalDrivers = $externalDrivers
            inputContract = $inputContract
            targetControl = $targetControl
            recoveredTransaction = $recoveredTransaction
        }
    }
    elseif ($Command -eq 'start') {
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        if ($externalDrivers.errors.Count -gt 0) {
            $result = New-Result -Ok $false -State 'external-driver-inventory-failed' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers } -Errors @('The external OpenVR driver inventory could not be read reliably; refusing null-HMD startup.')
        }
        elseif ($providerDriver.Count -ne 1) {
            $result = New-Result -Ok $false -State 'head-pose-provider-unavailable' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; requiredDriverName = $profile['headPoseProviderContract']['driverName'] } -Errors @('The CSX SteamVR head-pose driver must be installed and registered exactly once before null-HMD startup.')
        }
        elseif ($externalDrivers.conflicts.Count -gt 0 -and -not $AllowExternalDisplayRedirector) {
            $names = @($externalDrivers.conflicts | ForEach-Object { if ([string]::IsNullOrWhiteSpace([string]$_.name)) { $_.root } else { $_.name } })
            $result = New-Result -Ok $false -State 'external-driver-conflict' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; explicitDiagnosticOverrideRequired = $true } -Errors @("Refusing null-HMD startup because external OpenVR display driver(s) redirect the display path: $($names -join ', '). Disable or unregister the exact driver registration, or use -AllowExternalDisplayRedirector only for an explicitly authorized diagnostic coexistence run.")
        }
        elseif (-not $effective.active) {
            $result = New-Result -Ok $false -State 'null-not-configured' -Data @{ effective = $effective; runtime = $runtime } -Errors @('Apply the null-HMD settings transaction before starting SteamVR.')
        }
        elseif ($runtime.headPoseAuthorizationError) {
            $result = New-Result -Ok $false -State 'head-pose-provider-authorization-failed' -Data @{ effective = $effective; runtime = $runtime } -Errors @([string]$runtime.headPoseAuthorizationError)
        }
        elseif ($runtime.active -and -not $runtime.headPoseReady) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $false -State 'head-pose-provider-not-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract } -Errors @('The Valve null display is active, but the synthetic standing head pose is not qualified.')
        }
        elseif ($runtime.active) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $true -State 'already-running-head-pose-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract }
        }
        elseif ($ownedProcesses.Count -gt 0) {
            $result = New-Result -Ok $false -State 'ambiguous-runtime' -Data @{ effective = $effective; runtime = $runtime; processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses } -Errors @('SteamVR processes are running from the configured root, but current-session null-driver activation is not proven. Stop and inspect them before retrying.')
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($authoritativeEvidenceDirectory)) {
                if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
                    $EvidenceDirectory = $authoritativeEvidenceDirectory
                }
                elseif (-not [string]::Equals([IO.Path]::GetFullPath($EvidenceDirectory), [IO.Path]::GetFullPath($authoritativeEvidenceDirectory), [StringComparison]::OrdinalIgnoreCase)) {
                    throw "The live null-HMD transaction is owned by a different evidence directory: $authoritativeEvidenceDirectory"
                }
            }
            if ([string]::IsNullOrWhiteSpace($EvidenceDirectory) -or -not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
                throw 'start requires an existing -EvidenceDirectory owned by the apply transaction.'
            }
            $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $applyReceipt = Read-JsonHashtable -Path $receiptPath
            $isolation = if ($applyReceipt.ContainsKey('externalDriverIsolation')) { $applyReceipt['externalDriverIsolation'] } else { $null }
            $isolationValidation = if ($null -ne $isolation -and [bool]$isolation['enabled']) {
                $isolationBackupPath = [string]$isolation['backupPath']
                if (-not (Test-Path -LiteralPath $isolationBackupPath -PathType Leaf)) { throw "Exact OpenVR registration backup is missing: $isolationBackupPath" }
                if ((Get-HashOrNull $isolationBackupPath) -ne [string]$isolation['sha256Before']) { throw 'The exact OpenVR registration backup hash does not match the apply receipt.' }
                Get-IsolationValidation -Isolation $isolation -BackupPath $isolationBackupPath -CurrentPath ([string]$isolation['openVRPathsPath'])
            }
            else { $null }
            $isolationDrift = $null -ne $isolationValidation -and -not [bool]$isolationValidation.semanticMatch
            $startupPath = Join-Path $SteamVRRoot 'bin\win64\vrstartup.exe'
            if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) { throw "SteamVR startup executable does not exist: $startupPath" }
            if ($isolationDrift) {
                $result = New-Result -Ok $false -State 'external-driver-isolation-drift' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation } -Errors @('The OpenVR registration file is semantically different from the isolated state reconstructed from the exact backup. Refusing startup until the drift is classified or the exact transaction is restored.')
            }
            elseif ($WhatIf) {
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                $result = New-Result -Ok $true -State 'dry-run' -Data @{ startupPath = $startupPath; effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation; inputContract = $inputContract }
            }
            else {
                $startedUtc = [DateTime]::UtcNow
                $launcher = Start-Process -FilePath $startupPath -WindowStyle Hidden -PassThru
                $startupAttemptStartedUtc = $startedUtc
                $script:SteamVRStartupAttemptActive = $true
                $deadline = $startedUtc.AddSeconds($StartupTimeoutSeconds)
                $logReadReserveMilliseconds = [int][Math]::Min(2000, [Math]::Max(500, $StartupTimeoutSeconds * 50))
                $qualificationDeadline = $deadline.AddMilliseconds(-$logReadReserveMilliseconds)
                $runtimeProbeAttempts = 0
                $lastRuntimeProbeError = $null
                $runtimeConfirmationAttempted = $false
                $runtimeConfirmationTimedOut = $false
                do {
                    $remainingBeforeProbeMilliseconds = [long]($qualificationDeadline - [DateTime]::UtcNow).TotalMilliseconds
                    if ($remainingBeforeProbeMilliseconds -le 0) { break }
                    Start-Sleep -Milliseconds ([int][Math]::Min(250, $remainingBeforeProbeMilliseconds))
                    if ([DateTime]::UtcNow -ge $qualificationDeadline) { break }
                    $processes = @(Get-SteamVRProcesses)
                    try {
                        $runtimeProbeAttempts++
                        $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile -DeadlineUtc $deadline
                    }
                    catch [TimeoutException] {
                        $lastRuntimeProbeError = $_.Exception.Message
                        break
                    }
                    if ($runtime.headPoseAuthorizationError) {
                        $lastRuntimeProbeError = [string]$runtime.headPoseAuthorizationError
                        break
                    }
                } while (-not $runtime.active -or -not $runtime.headPoseReady)
                if ($InternalTestFailurePoint -ne 'runtime-final-admission-timeout-no-confirmation' -and $runtime.active -and $runtime.headPoseReady -and [DateTime]::UtcNow.AddMilliseconds(2250) -lt $qualificationDeadline) {
                    $runtimeConfirmationAttempted = $true
                    Start-Sleep -Seconds 2
                    $processes = @(Get-SteamVRProcesses)
                    try {
                        $runtimeProbeAttempts++
                        if ($InternalTestFailurePoint -in @('runtime-confirmation-timeout', 'runtime-confirmation-timeout-receipt-failure')) {
                            throw [TimeoutException]::new('Injected runtime confirmation timeout.')
                        }
                        $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile -DeadlineUtc $deadline
                    }
                    catch [TimeoutException] {
                        $lastRuntimeProbeError = $_.Exception.Message
                        $runtimeConfirmationTimedOut = $true
                    }
                }
                if ($InternalTestFailurePoint -in @('runtime-final-admission-timeout', 'runtime-final-admission-timeout-no-confirmation')) {
                    $deadline = [DateTime]::UtcNow.AddMilliseconds(-1)
                }
                $runtimeReceiptPath = Join-Path $EvidenceDirectory 'steamvr-null-runtime.receipt.json'
                $runtimeReceipt = [ordered]@{
                    schemaVersion = 1
                    startedUtc = $startedUtc.ToString('o')
                    launcherPid = $launcher.Id
                    startupPath = $startupPath
                    runtimeActive = [bool]$runtime.active
                    runtime = $runtime
                    startupDeadlineUtc = $deadline.ToString('o')
                    qualificationDeadlineUtc = $qualificationDeadline.ToString('o')
                    logReadReserveMilliseconds = $logReadReserveMilliseconds
                    runtimeProbeAttempts = $runtimeProbeAttempts
                    lastRuntimeProbeError = $lastRuntimeProbeError
                    runtimeConfirmationAttempted = $runtimeConfirmationAttempted
                    runtimeConfirmationTimedOut = $runtimeConfirmationTimedOut
                    runtimeAccepted = $false
                    admissionState = 'pending'
                    acceptedUtc = $null
                    externalDrivers = $externalDrivers
                    externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector
                    externalDriverIsolationValidation = $isolationValidation
                }
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                $failureState = $null
                $failureErrors = [Collections.Generic.List[string]]::new()
                if ($runtimeConfirmationTimedOut) {
                    $failureState = 'runtime-confirmation-timeout'
                    $failureErrors.Add([string]$lastRuntimeProbeError)
                    $failureErrors.Add('The current runtime confirmation did not complete before its deadline.')
                }
                elseif ([DateTime]::UtcNow -ge $deadline) {
                    $failureState = 'startup-deadline-exceeded'
                    $failureErrors.Add('The absolute startup deadline elapsed before final runtime admission.')
                }
                elseif ($runtime.headPoseAuthorizationError) {
                    $failureState = 'head-pose-provider-authorization-failed'
                    $failureErrors.Add([string]$runtime.headPoseAuthorizationError)
                }
                elseif ($runtime.active -and -not $runtime.headPoseReady) {
                    $failureState = 'head-pose-provider-not-ready'
                    $failureErrors.Add('SteamVR activated the Valve null display, but the synthetic standing head pose was not loaded and acknowledged.')
                }
                elseif (-not $runtime.active) {
                    $failureState = 'startup-incomplete'
                    $failureErrors.Add('SteamVR started, but current-session Valve null-driver and active-HMD log proof was not observed before the timeout.')
                }

                $runtimeReceiptPersisted = $false
                $runtimeReceiptError = $null
                if ($null -eq $failureState) {
                    $runtimeReceipt['runtimeAccepted'] = $true
                    $runtimeReceipt['admissionState'] = 'accepted'
                    $runtimeReceipt['acceptedUtc'] = [DateTime]::UtcNow.ToString('o')
                    Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt
                    $runtimeReceiptPersisted = $true
                    if ($InternalTestFailurePoint -eq 'runtime-post-receipt-timeout') {
                        $deadline = [DateTime]::UtcNow.AddMilliseconds(-1)
                    }
                    if ([DateTime]::UtcNow -ge $deadline) {
                        $failureState = 'startup-deadline-exceeded'
                        $failureErrors.Add('The absolute startup deadline elapsed during final runtime admission.')
                    }
                }

                if ($null -ne $failureState) {
                    # Cleanup is mandatory once admission fails, even if diagnostic persistence also fails.
                    $startupCleanup = Stop-ExactStartedSteamVRProcesses -StartedUtc $startedUtc
                    $inputContract['measurementReady'] = $false
                    $inputContract['measurementBlockers'] = @($inputContract['measurementBlockers']) + $failureState
                    $runtimeReceipt['runtimeAccepted'] = $false
                    $runtimeReceipt['admissionState'] = $failureState
                    $runtimeReceipt['acceptedUtc'] = $null
                    $runtimeReceipt['startupCleanup'] = $startupCleanup
                    try {
                        if ($InternalTestFailurePoint -eq 'runtime-confirmation-timeout-receipt-failure') {
                            throw [IO.IOException]::new('Injected runtime receipt persistence failure.')
                        }
                        Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt
                        $runtimeReceiptPersisted = $true
                    }
                    catch {
                        $runtimeReceiptPersisted = $false
                        $runtimeReceiptError = $_.Exception.Message
                        $failureErrors.Add("Runtime receipt persistence failed after cleanup: $runtimeReceiptError")
                    }
                    if ([bool]$startupCleanup.verified) {
                        $failureErrors.Add('Exact SteamVR processes started by this attempt were stopped and verified.')
                    }
                    else {
                        $failureErrors.Add('Exact-attempt cleanup did not verify a fully stopped runtime; inspect startupCleanup before retrying.')
                    }
                    $result = New-Result -Ok $false -State $failureState -Data @{ effective = $effective; runtime = $runtime; processes = $processes; runtimeReceiptPath = $runtimeReceiptPath; runtimeReceiptPersisted = $runtimeReceiptPersisted; runtimeReceiptError = $runtimeReceiptError; inputContract = $inputContract; startupCleanup = $startupCleanup } -Errors @($failureErrors)
                }
                else {
                    $successResult = New-Result -Ok $true -State $(if ($AllowExternalDisplayRedirector) { 'null-runtime-started-head-pose-ready-unqualified-display-route' } else { 'null-runtime-started-head-pose-ready' }) -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; runtimeReceiptPersisted = $runtimeReceiptPersisted; inputContract = $inputContract; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation }
                    if ([DateTime]::UtcNow -ge $deadline) {
                        $startupCleanup = Stop-ExactStartedSteamVRProcesses -StartedUtc $startedUtc
                        $inputContract['measurementReady'] = $false
                        $inputContract['measurementBlockers'] = @($inputContract['measurementBlockers']) + 'startup-deadline-exceeded'
                        $runtimeReceipt['runtimeAccepted'] = $false
                        $runtimeReceipt['admissionState'] = 'startup-deadline-exceeded'
                        $runtimeReceipt['acceptedUtc'] = $null
                        $runtimeReceipt['startupCleanup'] = $startupCleanup
                        try { Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt }
                        catch { $runtimeReceiptError = $_.Exception.Message }
                        $result = New-Result -Ok $false -State 'startup-deadline-exceeded' -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; runtimeReceiptPersisted = [string]::IsNullOrWhiteSpace($runtimeReceiptError); runtimeReceiptError = $runtimeReceiptError; inputContract = $inputContract; startupCleanup = $startupCleanup } -Errors @('The absolute startup deadline elapsed at the final success boundary; exact SteamVR processes started by this attempt were stopped.')
                    }
                    else {
                        $startupAttemptAccepted = $true
                        $result = $successResult
                    }
                }
            }
        }
    }
    else {
        if ($Command -eq 'restore' -and -not [string]::IsNullOrWhiteSpace($authoritativeEvidenceDirectory)) {
            if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
                $EvidenceDirectory = $authoritativeEvidenceDirectory
            }
            elseif (-not [string]::Equals([IO.Path]::GetFullPath($EvidenceDirectory), [IO.Path]::GetFullPath($authoritativeEvidenceDirectory), [StringComparison]::OrdinalIgnoreCase)) {
                throw "The live null-HMD transaction is owned by a different evidence directory: $authoritativeEvidenceDirectory"
            }
        }
        if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
            throw 'EvidenceDirectory is required for apply and restore.'
        }
        if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
            throw "Evidence directory does not exist: $EvidenceDirectory"
        }
        if ($ownedProcesses.Count -gt 0) {
            throw "SteamVR must be stopped before $Command. Running from configured root: $($ownedProcesses.name -join ', ')"
        }
        $backupPath = Join-Path $EvidenceDirectory 'steamvr.vrsettings.before'
        $openVRPathsBackupPath = Join-Path $EvidenceDirectory 'openvrpaths.vrpath.before'
        $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'
        $applyJournalPath = Join-Path $EvidenceDirectory 'steamvr-null-apply.journal.json'
        $restoreJournalPath = Join-Path $EvidenceDirectory 'steamvr-null-restore.journal.json'
        $authoritativeJournalPath = [string]$targetControl.journalPath

        if ($Command -eq 'apply') {
            if ($authoritativeOwnsAppliedState) {
                $result = New-Result -Ok $true -State 'already-applied' -Data @{
                    settingsPath = $SettingsPath
                    receiptPath = if ([string]$recoveredTransaction['operation'] -eq 'apply') { [string]$recoveredTransaction['receiptPath'] } else { Join-Path $authoritativeEvidenceDirectory 'steamvr-null-receipt.json' }
                    evidenceDirectory = $authoritativeEvidenceDirectory
                    targetControl = $targetControl
                    effective = $effective
                }
            }
            elseif ($effective.active) {
                throw 'SteamVR null settings are already effective but no committed authoritative apply transaction owns them; refusing to create a false baseline.'
            }
            else {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                throw "Refusing to replace the existing exact backup: $backupPath"
            }
            $isolationTargets = if ($IsolateExternalDisplayRedirectors) { @(Get-ExternalDisplayIsolationTargets -Inventory $externalDrivers -RequestedRoots $ExternalDisplayRedirectorRoot) } else { @() }
            if ($IsolateExternalDisplayRedirectors -and (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) {
                throw "Refusing to replace the existing exact OpenVR registration backup: $openVRPathsBackupPath"
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldBackup = $SettingsPath
                    backupPath = $backupPath
                    wouldApplyProfile = $NullProfilePath
                    settingsSha256Before = Get-HashOrNull $SettingsPath
                    externalDriverIsolation = [ordered]@{
                        enabled = [bool]$IsolateExternalDisplayRedirectors
                        openVRPathsPath = $OpenVRPathsPath
                        wouldBackupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                        targets = $isolationTargets
                    }
                }
            }
            else {
                $profileEvidencePath = Join-Path $EvidenceDirectory 'steamvr-null.profile.applied.json'
                $profileSha256 = Get-HashOrNull $NullProfilePath
                Copy-FileAtomicVerified -Source $NullProfilePath -Destination $profileEvidencePath -ExpectedSha256 $profileSha256
                $profile = Read-JsonHashtable -Path $profileEvidencePath
                foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides', 'headPoseProviderContract', 'automationInputContract')) {
                    if (-not $profile.ContainsKey($section)) { throw "Staged null-HMD profile is missing '$section'." }
                }
                if ($InternalTestFailurePoint -eq 'apply-source-drift-after-stage') {
                    $driftedSourceProfile = Read-JsonHashtable -Path $NullProfilePath
                    $driftedSourceProfile['driver_codex_head_pose']['eyeHeightMeters'] = 9.25
                    Write-JsonAtomic -Path $NullProfilePath -Value $driftedSourceProfile
                }
                $effective = Get-EffectiveState -Settings $settings -Profile $profile
                if ($effective.active) {
                    throw 'SteamVR null settings already match the staged profile but no committed authoritative apply transaction owns them; refusing to create a false baseline.'
                }
                Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
                $beforeHash = Get-HashOrNull $backupPath
                $openVRPathsBeforeHash = $null
                $openVRPathsIsolatedHash = $null
                $openVRPathsBeforeSemanticHash = $null
                $openVRPathsIsolatedSemanticHash = $null
                $isolationMutation = $null
                if ($IsolateExternalDisplayRedirectors) {
                    if (-not (Test-Path -LiteralPath $OpenVRPathsPath -PathType Leaf)) { throw "OpenVR registration file does not exist: $OpenVRPathsPath" }
                    Copy-Item -LiteralPath $OpenVRPathsPath -Destination $openVRPathsBackupPath
                    $openVRPathsBeforeHash = Get-HashOrNull $openVRPathsBackupPath
                    $openVRPathsBeforeSemanticHash = Get-JsonSemanticSha256 -Path $openVRPathsBackupPath
                }
                $transactionId = [guid]::NewGuid().ToString('N')
                $rollbackTargets = @([ordered]@{ name = 'steamvr-settings'; path = [IO.Path]::GetFullPath($SettingsPath); backupPath = [IO.Path]::GetFullPath($backupPath); expectedHash = $beforeHash })
                if ($IsolateExternalDisplayRedirectors) { $rollbackTargets += [ordered]@{ name = 'openvr-registrations'; path = [IO.Path]::GetFullPath($OpenVRPathsPath); backupPath = [IO.Path]::GetFullPath($openVRPathsBackupPath); expectedHash = $openVRPathsBeforeHash } }
                $journal = [ordered]@{
                    contractVersion = '1.0.0'; operation = 'apply'; transactionId = $transactionId; phase = 'prepared'
                    settingsPath = [IO.Path]::GetFullPath($SettingsPath); openVRPathsPath = if ($IsolateExternalDisplayRedirectors) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                    evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory); evidenceJournalPath = [IO.Path]::GetFullPath($applyJournalPath)
                    rollbackTargets = $rollbackTargets; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                }
                Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                try {
                    if ($IsolateExternalDisplayRedirectors) {
                        $isolationMutation = Disable-ExternalDriverRegistrations -Path $OpenVRPathsPath -Targets $isolationTargets
                        $journal['phase'] = 'openvr-isolated-uncommitted'; Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                        if ($InternalTestFailurePoint -eq 'apply-after-openvr') { throw 'Injected apply failure after OpenVR isolation.' }
                        $isolatedInventory = Get-ExternalDriverInventory -Path $OpenVRPathsPath
                        if ($isolatedInventory.errors.Count -gt 0 -or $isolatedInventory.conflicts.Count -gt 0) {
                            throw 'External display-driver isolation did not produce a complete, conflict-free OpenVR inventory.'
                        }
                        foreach ($target in $isolationTargets) {
                            if (@($isolatedInventory.drivers | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq (Get-NormalizedPath ([string]$target.root)) }).Count -ne 0) {
                                throw "External display redirector remained registered after isolation: $($target.root)"
                            }
                        }
                        $openVRPathsIsolatedHash = Get-HashOrNull $OpenVRPathsPath
                        $openVRPathsIsolatedSemanticHash = Get-JsonSemanticSha256 -Path $OpenVRPathsPath
                    }
                    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides')) {
                        if (-not $settings.ContainsKey($section)) { $settings[$section] = [ordered]@{} }
                        foreach ($key in $profile[$section].Keys) { $settings[$section][$key] = $profile[$section][$key] }
                    }
                    Write-JsonAtomic -Path $SettingsPath -Value $settings
                    $journal['phase'] = 'settings-applied-uncommitted'; Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                    $afterSettings = Read-JsonHashtable -Path $SettingsPath
                    $afterEffective = Get-EffectiveState -Settings $afterSettings -Profile $profile
                    if (-not $afterEffective.active) { throw 'The written settings do not match the null-HMD profile.' }
                    $receipt = [ordered]@{
                        schemaVersion = 2
                        operation = 'apply'
                        transactionId = $transactionId
                        journalPath = $authoritativeJournalPath
                        evidenceJournalPath = $applyJournalPath
                        appliedUtc = [DateTime]::UtcNow.ToString('o')
                        settingsPath = $SettingsPath
                        backupPath = $backupPath
                        settingsSha256Before = $beforeHash
                        settingsSha256Null = Get-HashOrNull $SettingsPath
                        settingsSemanticSha256Before = Get-JsonSemanticSha256 -Path $backupPath
                        settingsSemanticSha256Null = Get-JsonSemanticSha256 -Path $SettingsPath
                        profilePath = $profileEvidencePath
                        profileEvidencePath = $profileEvidencePath
                        sourceProfilePath = $NullProfilePath
                        profileSha256 = $profileSha256
                        externalDriverIsolation = [ordered]@{
                            enabled = [bool]$IsolateExternalDisplayRedirectors
                            openVRPathsPath = if ($IsolateExternalDisplayRedirectors) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                            backupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                            sha256Before = $openVRPathsBeforeHash
                            sha256Isolated = $openVRPathsIsolatedHash
                            semanticSha256Before = $openVRPathsBeforeSemanticHash
                            semanticSha256Isolated = $openVRPathsIsolatedSemanticHash
                            targets = $isolationTargets
                            mutation = $isolationMutation
                        }
                    }
                    Write-JsonAtomic -Path $receiptPath -Value $receipt
                    $journal['phase'] = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o'); $journal['receiptPath'] = $receiptPath
                    Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                }
                catch {
                    $failure = $_.Exception.Message
                    Restore-SteamVRTransactionTargets -Targets $rollbackTargets -Journal $journal -JournalPath $authoritativeJournalPath -FailureContext "Null-HMD apply failed: $failure"
                    throw "Null-HMD apply failed; every exact backup was restored and verified. $failure"
                }
                $result = New-Result -Ok $true -State 'null-applied' -Data @{
                    settingsPath = $SettingsPath
                    backupPath = $backupPath
                    receiptPath = $receiptPath
                    settingsSha256Before = $beforeHash
                    settingsSha256Null = Get-HashOrNull $SettingsPath
                    settingsSemanticSha256Before = Get-JsonSemanticSha256 -Path $backupPath
                    settingsSemanticSha256Null = Get-JsonSemanticSha256 -Path $SettingsPath
                    effective = $afterEffective
                    externalDriverIsolation = $receipt['externalDriverIsolation']
                    targetControl = $targetControl
                }
            }
            }
        }
        else {
            $pendingRestore = $recoveredTransaction
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Exact backup is missing: $backupPath" }
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $receipt = Read-JsonHashtable -Path $receiptPath
            $backupHash = Get-HashOrNull $backupPath
            if ($backupHash -ne $receipt['settingsSha256Before']) { throw 'The exact backup hash does not match the apply receipt.' }
            if (-not $receipt.ContainsKey('settingsPath') -or [string]::IsNullOrWhiteSpace([string]$receipt['settingsPath'])) { throw 'The apply receipt does not identify its SteamVR settings path.' }
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$receipt['settingsPath']), [IO.Path]::GetFullPath($SettingsPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The requested SteamVR settings path does not match the apply receipt.'
            }
            if (-not $receipt.ContainsKey('settingsSha256Null') -or [string]::IsNullOrWhiteSpace([string]$receipt['settingsSha256Null'])) { throw 'The apply receipt does not identify the applied SteamVR settings hash.' }
            $settingsLiveHash = Get-HashOrNull $SettingsPath
            $restoreAlreadyCommitted = $null -ne $pendingRestore -and [string]$pendingRestore['phase'] -eq 'committed' -and $settingsLiveHash -eq $backupHash
            $settingsValidation = $null
            if (-not $restoreAlreadyCommitted) {
                $settingsValidation = Get-SettingsRestoreValidation -Receipt $receipt -BackupPath $backupPath -CurrentPath $SettingsPath
                if (-not [bool]$settingsValidation.authorized) {
                    $details = @($settingsValidation.controlledDifferences + $settingsValidation.unclassifiedDifferencePaths | Select-Object -Unique)
                    throw "SteamVR settings changed after apply outside the authorized runtime-managed contract; refusing to overwrite drift: $($details -join ', ')"
                }
            }
            $isolation = if ($receipt.ContainsKey('externalDriverIsolation')) { $receipt['externalDriverIsolation'] } else { $null }
            $restoreExternalDrivers = $null -ne $isolation -and [bool]$isolation['enabled']
            $isolationValidation = $null
            if ($restoreExternalDrivers) {
                if ([IO.Path]::GetFullPath([string]$isolation['openVRPathsPath']) -ne [IO.Path]::GetFullPath($OpenVRPathsPath)) {
                    throw 'The requested OpenVR registration path does not match the apply receipt.'
                }
                if (-not (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) { throw "Exact OpenVR registration backup is missing: $openVRPathsBackupPath" }
                if ((Get-HashOrNull $openVRPathsBackupPath) -ne [string]$isolation['sha256Before']) { throw 'The exact OpenVR registration backup hash does not match the apply receipt.' }
                $openVRLiveHash = Get-HashOrNull $OpenVRPathsPath
                if ($restoreAlreadyCommitted) {
                    if ($openVRLiveHash -ne [string]$isolation['sha256Before']) { throw 'Committed restore journal exists but OpenVR registrations do not match the exact baseline.' }
                }
                else {
                    $isolationValidation = Get-IsolationValidation -Isolation $isolation -BackupPath $openVRPathsBackupPath -CurrentPath $OpenVRPathsPath
                    $isolationValidation | Add-Member -NotePropertyName baselineAlreadyRestored -NotePropertyValue ($openVRLiveHash -eq [string]$isolation['sha256Before'])
                    if (-not [bool]$isolationValidation.semanticMatch -and -not [bool]$isolationValidation.baselineAlreadyRestored) { throw 'The OpenVR registration file changed semantically after isolation. Refusing to overwrite unclassified registration drift.' }
                }
                foreach ($target in @($isolation['targets'])) {
                    if ((Get-HashOrNull ([string]$target['manifestPath'])) -ne [string]$target['manifestSha256']) {
                        throw "Suppressed driver manifest changed after apply: $($target['manifestPath'])"
                    }
                }
            }
            if ($restoreAlreadyCommitted) {
                $result = New-Result -Ok $true -State 'already-restored' -Data @{
                    settingsPath = $SettingsPath; restoredSha256 = $settingsLiveHash; backupPath = $backupPath; backupRetained = $true
                    externalDriverIsolation = $isolation; openVRPathsRestoredSha256 = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }
                    settingsRestoreValidation = $settingsValidation; externalDriverIsolationValidation = $isolationValidation; restoreJournalPath = $authoritativeJournalPath; evidenceJournalPath = $restoreJournalPath; targetControl = $targetControl
                }
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldRestore = $backupPath
                    settingsPath = $SettingsPath
                    expectedSha256 = $backupHash
                    backupRetained = $true
                    settingsRestoreValidation = $settingsValidation
                    externalDriverIsolation = $isolation
                    externalDriverIsolationValidation = $isolationValidation
                    wouldRestoreOpenVRPaths = if ($restoreExternalDrivers) { $openVRPathsBackupPath } else { $null }
                }
            }
            elseif (-not $restoreAlreadyCommitted) {
                $transactionId = [guid]::NewGuid().ToString('N')
                $settingsRollbackPath = Join-Path $EvidenceDirectory ("steamvr.vrsettings.applied.$transactionId")
                Copy-Item -LiteralPath $SettingsPath -Destination $settingsRollbackPath
                $rollbackTargets = @([ordered]@{ name = 'steamvr-settings'; path = [IO.Path]::GetFullPath($SettingsPath); backupPath = $settingsRollbackPath; expectedHash = $settingsLiveHash })
                if ($restoreExternalDrivers) {
                    $openVRRollbackPath = Join-Path $EvidenceDirectory ("openvrpaths.vrpath.isolated.$transactionId")
                    Copy-Item -LiteralPath $OpenVRPathsPath -Destination $openVRRollbackPath
                    $rollbackTargets += [ordered]@{ name = 'openvr-registrations'; path = [IO.Path]::GetFullPath($OpenVRPathsPath); backupPath = $openVRRollbackPath; expectedHash = $openVRLiveHash }
                }
                $journal = [ordered]@{
                    contractVersion = '1.0.0'; operation = 'restore'; transactionId = $transactionId; phase = 'prepared'
                    applyTransactionId = [string]$receipt['transactionId']; settingsPath = [IO.Path]::GetFullPath($SettingsPath)
                    openVRPathsPath = if ($restoreExternalDrivers) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                    evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory); evidenceJournalPath = [IO.Path]::GetFullPath($restoreJournalPath)
                    rollbackTargets = $rollbackTargets; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                }
                Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                try {
                    Copy-FileAtomic -Source $backupPath -Destination $SettingsPath
                    $journal['phase'] = 'settings-restored-uncommitted'; Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                    if ($InternalTestFailurePoint -eq 'restore-after-settings') { throw 'Injected restore failure after settings restoration.' }
                    if ($restoreExternalDrivers) { Copy-FileAtomic -Source $openVRPathsBackupPath -Destination $OpenVRPathsPath }
                    $journal['phase'] = 'all-targets-restored-uncommitted'; Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                    $restoredHash = Get-HashOrNull $SettingsPath
                    if ($restoredHash -ne $backupHash) { throw 'Restored SteamVR settings hash does not match the exact backup.' }
                    if ($restoreExternalDrivers -and (Get-HashOrNull $OpenVRPathsPath) -ne [string]$isolation['sha256Before']) { throw 'Restored OpenVR registration hash does not match the exact backup.' }
                    $restoreReceiptPath = Join-Path $EvidenceDirectory ("steamvr-null-restore.$transactionId.receipt.json")
                    Write-JsonAtomic -Path $restoreReceiptPath -Value ([ordered]@{
                        schemaVersion = 1; operation = 'restore'; transactionId = $transactionId; applyTransactionId = [string]$receipt['transactionId']
                        settingsPath = [IO.Path]::GetFullPath($SettingsPath); settingsSha256Restored = $restoredHash
                        settingsRestoreValidation = $settingsValidation
                        openVRPathsPath = if ($restoreExternalDrivers) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                        openVRPathsSha256Restored = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }; restoredUtc = [DateTime]::UtcNow.ToString('o')
                    })
                    $journal['phase'] = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o'); $journal['receiptPath'] = $restoreReceiptPath
                    Write-SteamVRTransactionJournal -AuthoritativePath $authoritativeJournalPath -Journal $journal
                }
                catch {
                    $failure = $_.Exception.Message
                    Restore-SteamVRTransactionTargets -Targets $rollbackTargets -Journal $journal -JournalPath $authoritativeJournalPath -FailureContext "Null-HMD restore failed: $failure"
                    throw "Null-HMD restore failed; the exact applied state was restored and verified. $failure"
                }
                $result = New-Result -Ok $true -State 'restored' -Data @{
                    settingsPath = $SettingsPath; restoredSha256 = $restoredHash; backupPath = $backupPath; backupRetained = $true
                    externalDriverIsolation = $isolation; openVRPathsRestoredSha256 = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }
                    settingsRestoreValidation = $settingsValidation; externalDriverIsolationValidation = $isolationValidation; restoreJournalPath = $authoritativeJournalPath; evidenceJournalPath = $restoreJournalPath; restoreReceiptPath = $restoreReceiptPath; targetControl = $targetControl
                }
            }
        }
    }
}
catch {
    $startupCleanupError = $null
    if ($null -ne $startupAttemptStartedUtc -and -not $startupAttemptAccepted -and $null -eq $startupCleanup) {
        try { $startupCleanup = Stop-ExactStartedSteamVRProcesses -StartedUtc $startupAttemptStartedUtc }
        catch { $startupCleanupError = $_.Exception.Message }
    }
    $errors = @($_.Exception.Message)
    if ($startupCleanupError) { $errors += "Startup cleanup failed: $startupCleanupError" }
    $result = New-Result -Ok $false -State 'blocked' -Data @{ settingsPath = $SettingsPath; profilePath = $NullProfilePath; evidenceDirectory = $EvidenceDirectory; targetControl = $targetControl; startupCleanup = $startupCleanup } -Errors $errors
}
finally {
    if ($targetLock) { $targetLock.Dispose() }
}

$jsonParameters = @{ InputObject = $result; Depth = 20 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
