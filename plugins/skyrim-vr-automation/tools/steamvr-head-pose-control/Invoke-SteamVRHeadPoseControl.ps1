# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'set', 'qualify', 'install')]
    [string]$Command = 'inspect',

    [string]$MapName = 'Local\CSXVRHeadPose-v2',

    [Nullable[double]]$PositionX,
    [Nullable[double]]$EyeHeightMeters,
    [Nullable[double]]$PositionZ,
    [Nullable[double]]$YawDegrees,
    [Nullable[double]]$PitchDegrees,
    [Nullable[double]]$RollDegrees,
    [Nullable[bool]]$Enabled,

    [ValidateRange(0.25, 10.0)]
    [double]$MinimumEyeHeightMeters = 1.0,

    [ValidateRange(0.25, 10.0)]
    [double]$MaximumEyeHeightMeters = 2.5,

    [ValidateRange(100, 10000)]
    [int]$AcknowledgementTimeoutMilliseconds = 2000,

    [ValidateRange(1, 60)]
    [int]$ProbeTimeoutSeconds = 10,

    [switch]$NoWait,

    [string]$DriverPackagePath,

    [string]$InstallRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CSX-VR-Automation\SteamVR\drivers\codex_head_pose' } else { $null }),

    [string]$PoseProbePath,

    [string]$ExpectedPackageProvenanceSha256,

    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',

    [string]$VRPathRegPath = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrpathreg.exe',

    [string]$OpenVRPathsPath = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath' } else { $null }),

    [string]$EvidenceDirectory,

    [ValidateRange(100, 60000)]
    [int]$InstallLockTimeoutMilliseconds = 5000,

    [switch]$SkipOpenVRProbe,

    [switch]$RequireControllers,
    [switch]$ProbeDiagnosticFailedRoles,
    [switch]$Upgrade,

    [Parameter(DontShow)]
    [ValidateSet('', 'install-after-replacement')]
    [string]$InternalTestFailurePoint = '',

    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PoseMagic = 0x48505343
$script:PoseVersion = 2
$script:PoseSize = 128
$script:InstallControl = $null
. (Join-Path $PSScriptRoot 'DriverPackageAuthority.ps1')

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

function Get-HashOrNull([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function New-Result([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @()) {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @($Errors)
        data = $Data
    }
}

function Open-PoseMap([IO.MemoryMappedFiles.MemoryMappedFileRights]$Rights) {
    return [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($MapName, $Rights)
}

function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-OpenVRDriverRegistration([string]$TargetRoot) {
    if ([string]::IsNullOrWhiteSpace($OpenVRPathsPath) -or -not (Test-Path -LiteralPath $OpenVRPathsPath -PathType Leaf)) {
        throw "The authoritative OpenVR registration file does not exist: $OpenVRPathsPath"
    }
    $document = Get-Content -LiteralPath $OpenVRPathsPath -Raw | ConvertFrom-Json -AsHashtable
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $registrations = @(
        foreach ($entry in @($document['external_drivers'])) {
            if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
            $normalized = [IO.Path]::GetFullPath([string]$entry).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            [pscustomobject][ordered]@{
                recordedPath = [string]$entry
                normalizedPath = $normalized
                matchesTarget = [string]::Equals($normalized, $target, [StringComparison]::OrdinalIgnoreCase)
            }
        }
    )
    $matches = @($registrations | Where-Object matchesTarget)
    return [pscustomobject][ordered]@{
        openVrPathsPath = [IO.Path]::GetFullPath($OpenVRPathsPath)
        openVrPathsSha256 = Get-HashOrNull $OpenVRPathsPath
        targetPath = $target
        matchCount = $matches.Count
        matches = $matches
        registrations = $registrations
    }
}

function Get-InstallTransactionControl([string]$TargetRoot, [string]$RegistrationPath) {
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\').ToLowerInvariant()
    $registration = [IO.Path]::GetFullPath($RegistrationPath).TrimEnd('\').ToLowerInvariant()
    $identity = "$target`n$registration"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $key = [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($identity))).ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    $root = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CSX-VR-Automation\SteamVR\install-transactions'
    if (-not [string]::IsNullOrWhiteSpace($env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT)) {
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $fixtureRoot = [IO.Path]::GetFullPath($env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT)
        if (-not ([IO.Path]::GetFullPath($TargetRoot).StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) -or -not ($fixtureRoot.TrimEnd('\') + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'CSX_HEAD_POSE_INSTALL_CONTROL_ROOT is test-only and requires both install and control paths inside the OS temporary directory.'
        }
        $root = $fixtureRoot
    }
    $directory = Join-Path $root $key
    return [pscustomobject][ordered]@{
        key = $key; directory = $directory; lockPath = Join-Path $directory 'target.lock'
        journalPath = Join-Path $directory 'install.journal.json'; target = [IO.Path]::GetFullPath($TargetRoot)
        openVrPathsPath = [IO.Path]::GetFullPath($RegistrationPath)
    }
}

function Enter-InstallTransactionLock($Control) {
    [IO.Directory]::CreateDirectory([string]$Control.directory) | Out-Null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($InstallLockTimeoutMilliseconds)
    do {
        try {
            $stream = [IO.File]::Open([string]$Control.lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $owner = [ordered]@{ pid = $PID; command = $Command; acquiredUtc = [DateTime]::UtcNow.ToString('o'); targetKey = [string]$Control.key } | ConvertTo-Json -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($owner)
            $stream.SetLength(0); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
            return $stream
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out acquiring the head-pose installation lock after $InstallLockTimeoutMilliseconds ms: $($Control.lockPath)" }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Write-InstallJournal($Journal, $Control) {
    Write-JsonAtomic -Path ([string]$Control.journalPath) -Value $Journal
    if ($Journal.Contains('evidenceJournalPath') -and -not [string]::IsNullOrWhiteSpace([string]$Journal.evidenceJournalPath)) {
        try { Write-JsonAtomic -Path ([string]$Journal.evidenceJournalPath) -Value $Journal }
        catch { $Journal['evidenceMirrorError'] = $_.Exception.Message }
    }
}

function Assert-InstallJournalContract($Journal, $Control) {
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Journal.target), [string]$Control.target, [StringComparison]::OrdinalIgnoreCase)) { throw 'The authoritative install journal target does not match its lock domain.' }
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Journal.openVrPathsPath), [string]$Control.openVrPathsPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'The authoritative install journal registration target does not match its lock domain.' }
    $preimage = [IO.Path]::GetFullPath([string]$Journal.openVrPathsPreimagePath)
    if (-not ($preimage.StartsWith(([string]$Control.directory).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'The authoritative install journal registration preimage escaped its control directory.' }
    foreach ($name in @('staging', 'previousInstall', 'quarantine')) {
        $path = [string]$Journal[$name]
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not [IO.Path]::GetFullPath($path).StartsWith(([string]$Control.target) + '.', [StringComparison]::OrdinalIgnoreCase)) { throw "The authoritative install journal $name path escaped the owned install namespace." }
    }
}

function ConvertTo-CanonicalInstallJsonValue([AllowNull()]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $result[$key] = ConvertTo-CanonicalInstallJsonValue $Value[$key] }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { return ,@($Value | ForEach-Object { ConvertTo-CanonicalInstallJsonValue $_ }) }
    return $Value
}

function Get-RegistrationWithoutTargetSemanticJson([byte[]]$Bytes, [string]$TargetRoot) {
    $document = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json -AsHashtable
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $remaining = @(
        foreach ($entry in @($document['external_drivers'])) {
            if ([string]::IsNullOrWhiteSpace([string]$entry)) { continue }
            $normalized = [IO.Path]::GetFullPath([string]$entry).TrimEnd('\')
            if (-not [string]::Equals($normalized, $target, [StringComparison]::OrdinalIgnoreCase)) { $normalized.ToLowerInvariant() }
        }
    ) | Sort-Object -CaseSensitive
    $document['external_drivers'] = @($remaining)
    return (ConvertTo-CanonicalInstallJsonValue $document) | ConvertTo-Json -Depth 32 -Compress
}

function Recover-PendingInstallTransaction($Control) {
    if (-not (Test-Path -LiteralPath ([string]$Control.journalPath) -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath ([string]$Control.journalPath) -Raw | ConvertFrom-Json -AsHashtable
    Assert-InstallJournalContract -Journal $journal -Control $Control
    if ([string]$journal.phase -in @('committed', 'rolled-back', 'recovered')) { return $journal }
    $preimagePath = [string]$journal.openVrPathsPreimagePath
    if (-not (Test-Path -LiteralPath $preimagePath -PathType Leaf) -or (Get-HashOrNull $preimagePath) -ne [string]$journal.openVrPathsPreimageSha256) { throw 'The interrupted install registration preimage is missing or has changed.' }
    $liveRegistrationHash = Get-HashOrNull ([string]$Control.openVrPathsPath)
    $allowedRegistrationHashes = @([string]$journal.openVrPathsPreimageSha256, [string]$journal.openVrPathsResultSha256) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($liveRegistrationHash -notin $allowedRegistrationHashes -and [string]$journal.phase -eq 'registration-command-uncommitted') {
        $preimageSemantic = Get-RegistrationWithoutTargetSemanticJson -Bytes ([IO.File]::ReadAllBytes($preimagePath)) -TargetRoot ([string]$Control.target)
        $liveSemantic = Get-RegistrationWithoutTargetSemanticJson -Bytes ([IO.File]::ReadAllBytes([string]$Control.openVrPathsPath)) -TargetRoot ([string]$Control.target)
        if ($preimageSemantic -ceq $liveSemantic -and (Get-OpenVRDriverRegistration -TargetRoot ([string]$Control.target)).matchCount -eq 1) {
            $journal.openVrPathsResultSha256 = $liveRegistrationHash
            $allowedRegistrationHashes += $liveRegistrationHash
        }
    }
    if ($liveRegistrationHash -notin $allowedRegistrationHashes) { throw 'The OpenVR registration file drifted outside the interrupted install transaction; manual recovery is required.' }
    if ($liveRegistrationHash -ne [string]$journal.openVrPathsPreimageSha256) {
        Write-BytesAtomic -Path ([string]$Control.openVrPathsPath) -Bytes ([IO.File]::ReadAllBytes($preimagePath))
    }
    $target = [string]$Control.target
    $previous = [string]$journal.previousInstall
    $replacementMayBeActive = [string]$journal.phase -ne 'prepared'
    if ($replacementMayBeActive -and (Test-Path -LiteralPath $target)) {
        $targetIsOriginal = -not [string]::IsNullOrWhiteSpace($previous) -and (Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')) -eq [string]$journal.originalDllSha256 -and (Get-HashOrNull (Join-Path $target '.csx-vr-automation-driver.json')) -eq [string]$journal.originalMarkerSha256
        if (-not $targetIsOriginal) {
            $quarantine = [string]$journal.quarantine
            if (Test-Path -LiteralPath $quarantine) { throw "Interrupted install quarantine already exists while an unverified target is still active: $quarantine" }
            Move-Item -LiteralPath $target -Destination $quarantine
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($previous) -and (Test-Path -LiteralPath $previous)) {
        if (Test-Path -LiteralPath $target) { throw 'The original install cannot be restored because the live target still exists.' }
        Move-Item -LiteralPath $previous -Destination $target
    }
    $staging = [string]$journal.staging
    if (-not [string]::IsNullOrWhiteSpace($staging) -and (Test-Path -LiteralPath $staging)) {
        $stagingQuarantine = "$staging.uncommitted"
        if (Test-Path -LiteralPath $stagingQuarantine) { throw "Interrupted staging quarantine already exists: $stagingQuarantine" }
        Move-Item -LiteralPath $staging -Destination $stagingQuarantine
    }
    if ($journal.Contains('receiptPath') -and -not [string]::IsNullOrWhiteSpace([string]$journal.receiptPath) -and (Test-Path -LiteralPath ([string]$journal.receiptPath) -PathType Leaf)) {
        $receiptQuarantine = "$($journal.receiptPath).uncommitted-$($journal.transactionId)"
        if (Test-Path -LiteralPath $receiptQuarantine) { throw "Interrupted install receipt quarantine already exists: $receiptQuarantine" }
        Move-Item -LiteralPath ([string]$journal.receiptPath) -Destination $receiptQuarantine
    }
    if ((Get-HashOrNull ([string]$Control.openVrPathsPath)) -ne [string]$journal.openVrPathsPreimageSha256) { throw 'Recovered OpenVR registration bytes do not match the exact preimage.' }
    if (-not [string]::IsNullOrWhiteSpace($previous)) {
        if ((Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')) -ne [string]$journal.originalDllSha256 -or (Get-HashOrNull (Join-Path $target '.csx-vr-automation-driver.json')) -ne [string]$journal.originalMarkerSha256) { throw 'Recovered original driver provenance does not match the install journal.' }
    }
    elseif ($replacementMayBeActive -and (Test-Path -LiteralPath $target)) { throw 'Recovered new installation still occupies the live target.' }
    $journal.phase = 'recovered'; $journal.recoveredUtc = [DateTime]::UtcNow.ToString('o')
    Write-InstallJournal -Journal $journal -Control $Control
    return $journal
}

function Read-AtomicUInt64([IO.MemoryMappedFiles.MemoryMappedViewAccessor]$View, [long]$Offset) {
    return [uint64][SkyrimVRAutomation.Native.SharedPoseAtomics]::ReadInt64(
        $View.SafeMemoryMappedViewHandle,
        $View.PointerOffset,
        $Offset)
}

function Write-AtomicUInt64([IO.MemoryMappedFiles.MemoryMappedViewAccessor]$View, [long]$Offset, [uint64]$Value) {
    $signedValue = [BitConverter]::ToInt64([BitConverter]::GetBytes($Value), 0)
    $null = [SkyrimVRAutomation.Native.SharedPoseAtomics]::ExchangeInt64(
        $View.SafeMemoryMappedViewHandle,
        $View.PointerOffset,
        $Offset,
        $signedValue)
}

function New-RandomNonce {
    $bytes = [byte[]]::new(8)
    do {
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $value = [BitConverter]::ToUInt64($bytes, 0)
    } while ($value -eq 0)
    return $value
}

function Get-WriterMutexName {
    $bytes = [Text.Encoding]::UTF8.GetBytes($MapName)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    return "Local\CSXVRHeadPoseWriter-$($hash.Substring(0, 24))"
}

function Test-DriverIdentity([uint32]$CreatorPid, [uint64]$DriverStartedFileTimeUtc) {
    $script:LastCreatorAuthority = Get-HeadPoseCreatorAuthority -CreatorPid $CreatorPid -DriverStartedFileTimeUtc $DriverStartedFileTimeUtc -SteamVRRoot $SteamVRRoot -DriverRoot $InstallRoot
    return [bool]$script:LastCreatorAuthority.verified
}

function Read-PoseState {
    $mapping = $null
    $view = $null
    try {
        # Interlocked.Read uses an atomic read/compare operation that requires a
        # writable view even though this function does not mutate the contract.
        $mapping = Open-PoseMap -Rights ([IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
        $view = $mapping.CreateViewAccessor(0, $script:PoseSize, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $firstSequence = Read-AtomicUInt64 -View $view -Offset 8
            if (($firstSequence % 2) -ne 0) {
                [Threading.Thread]::Sleep(1)
                continue
            }
            $state = [ordered]@{
                magic = $view.ReadUInt32(0)
                version = $view.ReadUInt16(4)
                size = $view.ReadUInt16(6)
                requestedSequence = $firstSequence
                appliedSequence = Read-AtomicUInt64 -View $view -Offset 16
                status = $view.ReadUInt32(24)
                enabled = ($view.ReadUInt32(28) -band 1) -eq 1
                positionX = $view.ReadDouble(32)
                eyeHeightMeters = $view.ReadDouble(40)
                positionZ = $view.ReadDouble(48)
                quaternionW = $view.ReadDouble(56)
                quaternionX = $view.ReadDouble(64)
                quaternionY = $view.ReadDouble(72)
                quaternionZ = $view.ReadDouble(80)
                writerNonce = $view.ReadUInt64(88)
                acknowledgedWriterNonce = $view.ReadUInt64(96)
                driverInstanceNonce = $view.ReadUInt64(104)
                driverCreatorPid = $view.ReadUInt32(112)
                driverStartedFileTimeUtc = $view.ReadUInt64(120)
            }
            $secondSequence = Read-AtomicUInt64 -View $view -Offset 8
            if ($firstSequence -eq $secondSequence -and ($secondSequence % 2) -eq 0) {
                $state['available'] = $true
                $state['stable'] = $true
                $state['protocolValid'] = $state.magic -eq $script:PoseMagic -and $state.version -eq $script:PoseVersion -and $state.size -eq $script:PoseSize
                $state['driverIdentityVerified'] = Test-DriverIdentity -CreatorPid $state.driverCreatorPid -DriverStartedFileTimeUtc $state.driverStartedFileTimeUtc
                $state['creatorAuthority'] = $script:LastCreatorAuthority
                $state['acknowledged'] = $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.writerNonce -ne 0 -and $state.acknowledgedWriterNonce -eq $state.writerNonce -and $state.status -eq 1
                $state['eyeHeightQualified'] = $state.eyeHeightMeters -ge $MinimumEyeHeightMeters -and $state.eyeHeightMeters -le $MaximumEyeHeightMeters
                $state['qualified'] = $state.protocolValid -and $state.driverIdentityVerified -and $state.driverInstanceNonce -ne 0 -and $state.acknowledged -and $state.eyeHeightQualified -and $state.enabled
                return [pscustomobject]$state
            }
        }
        throw 'The shared pose changed continuously and could not be read atomically.'
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The head-pose provider is not running.' }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }
}

function Convert-EulerToQuaternion([double]$Yaw, [double]$Pitch, [double]$Roll) {
    $halfYaw = $Yaw * [Math]::PI / 360.0
    $halfPitch = $Pitch * [Math]::PI / 360.0
    $halfRoll = $Roll * [Math]::PI / 360.0
    $cy = [Math]::Cos($halfYaw); $sy = [Math]::Sin($halfYaw)
    $cp = [Math]::Cos($halfPitch); $sp = [Math]::Sin($halfPitch)
    $cr = [Math]::Cos($halfRoll); $sr = [Math]::Sin($halfRoll)
    return @(
        ($cy * $cp * $cr + $sy * $sp * $sr)
        ($cy * $sp * $cr + $sy * $cp * $sr)
        ($sy * $cp * $cr - $cy * $sp * $sr)
        ($cy * $cp * $sr - $sy * $sp * $cr)
    )
}

function Set-PoseState {
    $mutex = [Threading.Mutex]::new($false, (Get-WriterMutexName))
    $lockHeld = $false
    $mapping = $null
    $view = $null
    try {
        try { $lockHeld = $mutex.WaitOne($AcknowledgementTimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        if (-not $lockHeld) {
            return New-Result -Ok $false -State 'pose-writer-busy' -Data @{ mutexName = Get-WriterMutexName } -Errors @('Another writer owns the bounded head-pose transaction lease.')
        }

        $current = Read-PoseState
        if (-not $current.available) { throw $current.error }
        if (-not $current.protocolValid) { throw 'The running head-pose provider uses an incompatible shared-memory contract.' }
        if (-not $current.driverIdentityVerified -or $current.driverInstanceNonce -eq 0) { throw 'The shared-memory mapping is not owned by a live, identified driver instance.' }

        $x = if ($null -ne $PositionX) { [double]$PositionX } else { [double]$current.positionX }
        $y = if ($null -ne $EyeHeightMeters) { [double]$EyeHeightMeters } else { [double]$current.eyeHeightMeters }
        $z = if ($null -ne $PositionZ) { [double]$PositionZ } else { [double]$current.positionZ }
        $active = if ($null -ne $Enabled) { [bool]$Enabled } else { [bool]$current.enabled }
        foreach ($value in @($x, $y, $z)) {
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or [Math]::Abs($value) -gt 1000.0) {
                throw 'Pose positions must be finite and within 1000 metres of the origin.'
            }
        }

        $orientationSupplied = $null -ne $YawDegrees -or $null -ne $PitchDegrees -or $null -ne $RollDegrees
        $quaternion = if ($orientationSupplied) {
            Convert-EulerToQuaternion `
                -Yaw $(if ($null -ne $YawDegrees) { [double]$YawDegrees } else { 0.0 }) `
                -Pitch $(if ($null -ne $PitchDegrees) { [double]$PitchDegrees } else { 0.0 }) `
                -Roll $(if ($null -ne $RollDegrees) { [double]$RollDegrees } else { 0.0 })
        }
        else { @($current.quaternionW, $current.quaternionX, $current.quaternionY, $current.quaternionZ) }

        $mapping = Open-PoseMap -Rights ([IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
        $view = $mapping.CreateViewAccessor(0, $script:PoseSize, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        $baseSequence = Read-AtomicUInt64 -View $view -Offset 8
        if (($baseSequence % 2) -ne 0) { $baseSequence++ }
        $oddSequence = $baseSequence + 1
        $requestedSequence = $baseSequence + 2
        $writerNonce = New-RandomNonce
        Write-AtomicUInt64 -View $view -Offset 8 -Value $oddSequence
        $view.Write(24, [uint32]0)
        $view.Write(28, [uint32]$(if ($active) { 1 } else { 0 }))
        $view.Write(32, $x); $view.Write(40, $y); $view.Write(48, $z)
        $view.Write(56, [double]$quaternion[0]); $view.Write(64, [double]$quaternion[1])
        $view.Write(72, [double]$quaternion[2]); $view.Write(80, [double]$quaternion[3])
        $view.Write(88, [uint64]$writerNonce)
        $view.Flush()
        Write-AtomicUInt64 -View $view -Offset 8 -Value $requestedSequence
        $view.Flush()

        if ($NoWait) {
            return New-Result -Ok $true -State 'pose-submitted' -Data @{ requestedSequence = $requestedSequence; writerNonce = $writerNonce; driverInstanceNonce = $current.driverInstanceNonce; acknowledged = $false }
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($AcknowledgementTimeoutMilliseconds)
        $observed = $null
        do {
            [Threading.Thread]::Sleep(10)
            $observed = Read-PoseState
            if ($observed.available -and $observed.appliedSequence -eq $requestedSequence -and $observed.acknowledgedWriterNonce -eq $writerNonce) { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $observed.available -or $observed.appliedSequence -ne $requestedSequence -or $observed.acknowledgedWriterNonce -ne $writerNonce) {
            return New-Result -Ok $false -State 'pose-acknowledgement-timeout' -Data @{ requestedSequence = $requestedSequence; writerNonce = $writerNonce; observed = $observed } -Errors @('The provider did not acknowledge this exact writer nonce and sequence before the bounded deadline.')
        }
        if ($observed.status -ne 1) {
            return New-Result -Ok $false -State 'pose-rejected' -Data @{ requestedSequence = $requestedSequence; writerNonce = $writerNonce; observed = $observed } -Errors @('The provider rejected the pose as invalid.')
        }
        return New-Result -Ok $true -State 'pose-applied' -Data @{ requestedSequence = $requestedSequence; writerNonce = $writerNonce; pose = $observed }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
        if ($lockHeld) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-PassiveControllerProbeObservation($Payload) {
    try {
        $pair = $Payload.controllers
        if ($pair.required -isnot [bool] -or -not $pair.required -or
            $pair.valid -isnot [bool] -or -not $pair.valid) { return $false }
        foreach ($value in @($pair.leftIndex, $pair.rightIndex, $pair.neutralSamples, $pair.inputEvents)) {
            if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint32]) { return $false }
        }
        # Matches the pinned OpenVR tracked-device array; index zero is the HMD.
        return $pair.leftIndex -gt 0 -and $pair.leftIndex -lt 64 -and
            $pair.rightIndex -gt 0 -and $pair.rightIndex -lt 64 -and
            $pair.leftIndex -ne $pair.rightIndex -and
            $pair.neutralSamples -eq 100 -and $pair.inputEvents -eq 0
    }
    catch { return $false }
}

function Invoke-PoseProbe {
    param([Parameter(Mandatory)]$PreProbePose)
    $resolvedProbe = if (-not [string]::IsNullOrWhiteSpace($PoseProbePath)) { $PoseProbePath } elseif (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { Join-Path $InstallRoot 'tools\csx_openvr_pose_probe.exe' } else { $null }
    if ([string]::IsNullOrWhiteSpace($resolvedProbe) -or -not (Test-Path -LiteralPath $resolvedProbe -PathType Leaf)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $resolvedProbe; error = 'The independent OpenVR pose probe is not installed.' }
    }
    try {
        $bundledProvenance = Join-Path $PSScriptRoot '..\..\drivers\codex_head_pose\build-provenance.json'
        $packageAuthority = Get-HeadPosePackageAuthority -Root $InstallRoot -RegistrationPath $OpenVRPathsPath -BundledProvenancePath $bundledProvenance -ExpectedProvenanceSha256 $ExpectedPackageProvenanceSha256
        if (-not $packageAuthority.verified) { throw "Package qualification refused before probe execution: $($packageAuthority.errors -join '; ')" }
        $continuityBefore = New-HeadPoseContinuityIdentity -Pose $PreProbePose -PackageAuthority $packageAuthority
        if ((Get-HeadPoseCanonicalPath $resolvedProbe) -ne (Get-HeadPoseCanonicalPath (Join-Path $InstallRoot 'tools\csx_openvr_pose_probe.exe'))) { throw 'PoseProbePath may identify only the exact owned package probe; use an explicitly digest-authorized custom package instead.' }
        $boundedRunner = Join-Path (Split-Path -Parent $PSScriptRoot) 'process-control\Invoke-BoundedProcess.ps1'
        if (-not (Test-Path -LiteralPath $boundedRunner -PathType Leaf)) { throw "The bounded process controller is unavailable: $boundedRunner" }
        $probeArguments = @()
        if ($RequireControllers) { $probeArguments += '--require-controllers' }
        if ($ProbeDiagnosticFailedRoles) { $probeArguments += '--diagnostic-failed-roles' }
        $run = & $boundedRunner -FilePath $resolvedProbe -ArgumentList $probeArguments -WorkingDirectory (Split-Path -Parent $resolvedProbe) -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds $ProbeTimeoutSeconds -RetryPatterns @() -EvidenceDirectory $EvidenceDirectory -NoExit -Compact | ConvertFrom-Json
        if (-not $run.ok -or @($run.attempts).Count -ne 1) {
            return [pscustomobject][ordered]@{ available = $true; qualified = $false; probePath = $resolvedProbe; probeSha256 = Get-HashOrNull $resolvedProbe; boundedRun = $run; error = 'The independent OpenVR pose probe did not complete successfully within its bounded budget.' }
        }
        $attempt = @($run.attempts)[0]
        $payload = [string]$attempt.stdout | ConvertFrom-Json -ErrorAction Stop
        $afterAuthority = Get-HeadPosePackageAuthority -Root $InstallRoot -RegistrationPath $OpenVRPathsPath -BundledProvenancePath $bundledProvenance -ExpectedProvenanceSha256 $ExpectedPackageProvenanceSha256
        if (-not $afterAuthority.verified -or $afterAuthority.markerSha256 -ne $packageAuthority.markerSha256) { throw 'Package identity changed during the independent probe.' }
        $afterPose = Read-PoseState
        $continuityAfter = New-HeadPoseContinuityIdentity -Pose $afterPose -PackageAuthority $afterAuthority
        Assert-HeadPoseContinuity -Before $continuityBefore -After $continuityAfter
        $stereoQualified = $payload.stereo -and $payload.stereo.valid -and [double]$payload.stereo.eyeSeparationMeters -ge 0.01 -and [double]$payload.stereo.eyeSeparationMeters -le 0.20
        $controllersQualified = Test-PassiveControllerProbeObservation $payload
        return [pscustomobject][ordered]@{
            available = $true
            qualified = $run.ok -and $payload.ok -and $payload.standing.connected -and $payload.standing.valid -and [double]$payload.standing.position[1] -ge $MinimumEyeHeightMeters -and [double]$payload.standing.position[1] -le $MaximumEyeHeightMeters -and $stereoQualified -and (-not $RequireControllers -or $controllersQualified)
            controllersRequired = [bool]$RequireControllers
            controllersQualified = $controllersQualified
            probePath = [IO.Path]::GetFullPath($resolvedProbe)
            probeSha256 = Get-HashOrNull $resolvedProbe
            driverDllPath = $(if ($InstallRoot) { [IO.Path]::GetFullPath((Join-Path $InstallRoot 'bin\win64\driver_codex_head_pose.dll')) } else { $null })
            driverDllSha256 = $(if ($InstallRoot) { Get-HashOrNull (Join-Path $InstallRoot 'bin\win64\driver_codex_head_pose.dll') } else { $null })
            openVrPathsPath = $(if ($OpenVRPathsPath) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null })
            openVrPathsSha256 = $(if ($OpenVRPathsPath) { Get-HashOrNull $OpenVRPathsPath } else { $null })
            boundedRun = $run
            observation = $payload
            packageAuthority = $afterAuthority
            providerContinuity = $continuityAfter
            poseAfterProbe = $afterPose
        }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $resolvedProbe; error = $_.Exception.Message }
    }
}

function Install-DriverCore {
    if ([string]::IsNullOrWhiteSpace($DriverPackagePath)) {
        $bundledPackage = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'drivers\codex_head_pose'
        if (Test-Path -LiteralPath $bundledPackage -PathType Container) {
            $DriverPackagePath = $bundledPackage
        }
        else {
            throw 'install requires -DriverPackagePath because no bundled driver package is present.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'The stable driver install root could not be resolved.' }
    if (-not (Test-Path -LiteralPath $VRPathRegPath -PathType Leaf)) { throw "vrpathreg.exe does not exist: $VRPathRegPath" }
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw 'SteamVR must be stopped before installing the head-pose driver.' }
    }
    $source = [IO.Path]::GetFullPath($DriverPackagePath)
    foreach ($relative in @('driver.vrdrivermanifest', 'bin\win64\driver_codex_head_pose.dll', 'resources\settings\default.vrsettings', 'tools\csx_openvr_pose_probe.exe', 'tools\openvr_api.dll', 'licenses\OpenVR-LICENSE.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "Driver package is missing $relative" }
    }
    $inputProfileRelativePath = 'resources\input\passive_controller_profile.json'
    $defaultSettings = Get-Content -LiteralPath (Join-Path $source 'resources\settings\default.vrsettings') -Raw | ConvertFrom-Json -AsHashtable
    $hasControllerContract = $defaultSettings['driver_codex_head_pose'].ContainsKey('enableControllers')
    if ($hasControllerContract -and -not (Test-Path -LiteralPath (Join-Path $source $inputProfileRelativePath) -PathType Leaf)) {
        throw "Controller-capable driver package is missing $inputProfileRelativePath"
    }
    if (Test-Path -LiteralPath (Join-Path $source $inputProfileRelativePath) -PathType Leaf) {
        $inputProfile = Get-Content -LiteralPath (Join-Path $source $inputProfileRelativePath) -Raw | ConvertFrom-Json
        if ($inputProfile.jsonid -cne 'input_profile' -or $inputProfile.driver_name -cne 'codex_head_pose' -or $inputProfile.device_class -cne 'TrackedDeviceClass_Controller') {
            throw 'The passive controller input profile does not identify the expected driver and Controller class.'
        }
    }
    $target = [IO.Path]::GetFullPath($InstallRoot)
    $previousInstall = $null
    $originalDllSha256 = $null
    $originalMarkerSha256 = $null
    if (Test-Path -LiteralPath $target) {
        $marker = Join-Path $target '.csx-vr-automation-driver.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to replace an unowned driver directory: $target" }
        $owned = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($owned.driverName -ne 'codex_head_pose') { throw "The existing driver marker does not identify codex_head_pose: $marker" }
        if (-not $Upgrade) { throw "The driver is already installed. Use -Upgrade to retain and replace the owned installation: $target" }
        $originalDllSha256 = Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')
        $originalMarkerSha256 = Get-HashOrNull $marker
        $previousInstall = "$target.previous-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))"
        if (Test-Path -LiteralPath $previousInstall) { throw "The retained upgrade path already exists: $previousInstall" }
    }

    $parent = Split-Path -Parent $target
    $transactionId = [guid]::NewGuid().ToString('N')
    $staging = "$target.staging-$transactionId"
    $quarantine = "$target.uncommitted-$transactionId"
    $journalDirectory = if ($EvidenceDirectory) { [IO.Path]::GetFullPath($EvidenceDirectory) } else { $parent }
    $evidenceJournalPath = Join-Path $journalDirectory "steamvr-head-pose-install-$transactionId.journal.json"
    $journalPath = [string]$script:InstallControl.journalPath
    $registrationPreimagePath = Join-Path ([string]$script:InstallControl.directory) "openvrpaths.preimage-$transactionId"
    $registrationPreimage = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($OpenVRPathsPath))
    $registrationPreimageSha256 = Get-HashOrNull $OpenVRPathsPath
    $registrationBefore = Get-OpenVRDriverRegistration -TargetRoot $target
    if ($registrationBefore.matchCount -gt 1) { throw "The target driver has duplicate OpenVR registrations ($($registrationBefore.matchCount)): $target" }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    New-Item -ItemType Directory -Path $journalDirectory -Force | Out-Null
    Write-BytesAtomic -Path $registrationPreimagePath -Bytes $registrationPreimage
    $journal = [ordered]@{
        schemaVersion = 1
        operation = 'install-driver'
        transactionId = $transactionId
        phase = 'prepared'
        target = $target
        staging = $staging
        previousInstall = $previousInstall
        quarantine = $quarantine
        originalDllSha256 = $originalDllSha256
        originalMarkerSha256 = $originalMarkerSha256
        openVrPathsPath = [IO.Path]::GetFullPath($OpenVRPathsPath)
        openVrPathsPreimagePath = $registrationPreimagePath
        openVrPathsPreimageSha256 = $registrationPreimageSha256
        openVrPathsResultSha256 = $null
        evidenceDirectory = if ($EvidenceDirectory) { [IO.Path]::GetFullPath($EvidenceDirectory) } else { $null }
        evidenceJournalPath = $evidenceJournalPath
        sourceProvenance = [ordered]@{
            manifestSha256 = Get-HashOrNull (Join-Path $source 'driver.vrdrivermanifest')
            dllSha256 = Get-HashOrNull (Join-Path $source 'bin\win64\driver_codex_head_pose.dll')
            poseProbeSha256 = Get-HashOrNull (Join-Path $source 'tools\csx_openvr_pose_probe.exe')
            defaultSettingsSha256 = Get-HashOrNull (Join-Path $source 'resources\settings\default.vrsettings')
            passiveControllerInputProfileSha256 = Get-HashOrNull (Join-Path $source $inputProfileRelativePath)
            openVrApiSha256 = Get-HashOrNull (Join-Path $source 'tools\openvr_api.dll')
            buildProvenanceSha256 = Get-HashOrNull (Join-Path $source 'build-provenance.json')
        }
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-InstallJournal -Journal $journal -Control $script:InstallControl
    try {
        Copy-Item -LiteralPath $source -Destination $staging -Recurse
        $marker = [ordered]@{
            schemaVersion = 3
            driverName = 'codex_head_pose'
            installRoot = $target
            transactionId = $transactionId
            installedUtc = [DateTime]::UtcNow.ToString('o')
            sourcePackage = $source
            dllSha256 = Get-HashOrNull (Join-Path $staging 'bin\win64\driver_codex_head_pose.dll')
            poseProbeSha256 = Get-HashOrNull (Join-Path $staging 'tools\csx_openvr_pose_probe.exe')
            defaultSettingsSha256 = Get-HashOrNull (Join-Path $staging 'resources\settings\default.vrsettings')
            passiveControllerInputProfileSha256 = Get-HashOrNull (Join-Path $staging $inputProfileRelativePath)
            manifestSha256 = Get-HashOrNull (Join-Path $staging 'driver.vrdrivermanifest')
            openVrApiSha256 = Get-HashOrNull (Join-Path $staging 'tools\openvr_api.dll')
            buildProvenanceSha256 = Get-HashOrNull (Join-Path $staging 'build-provenance.json')
        }
        Write-JsonAtomic -Path (Join-Path $staging '.csx-vr-automation-driver.json') -Value $marker
        $journal.phase = 'replacement-command-uncommitted'
        Write-InstallJournal -Journal $journal -Control $script:InstallControl
        if ($previousInstall) { Move-Item -LiteralPath $target -Destination $previousInstall }
        Move-Item -LiteralPath $staging -Destination $target
        $journal.phase = 'replacement-active-uncommitted'
        Write-InstallJournal -Journal $journal -Control $script:InstallControl
        if ($InternalTestFailurePoint -eq 'install-after-replacement') { throw 'Injected failure after replacement activation.' }

        $registration = Get-OpenVRDriverRegistration -TargetRoot $target
        if ($registration.matchCount -eq 0) {
            $journal.phase = 'registration-command-uncommitted'
            Write-InstallJournal -Journal $journal -Control $script:InstallControl
            $registrationOutput = & $VRPathRegPath adddriver $target 2>&1
            if ($LASTEXITCODE -ne 0) { throw "vrpathreg adddriver failed ($LASTEXITCODE): $($registrationOutput -join ' ')" }
            $registration = Get-OpenVRDriverRegistration -TargetRoot $target
        }
        if ($registration.matchCount -ne 1) { throw "The authoritative OpenVR inventory does not contain exactly one canonical registration for the installed target (count=$($registration.matchCount))." }
        if (-not [string]::Equals([string]$registration.matches[0].normalizedPath, $target.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw 'The authoritative OpenVR registration does not resolve to the exact install root.' }
        $journal.openVrPathsResultSha256 = Get-HashOrNull $OpenVRPathsPath
        $journal.phase = 'registered-uncommitted'
        Write-InstallJournal -Journal $journal -Control $script:InstallControl
        $installedManifestSha256 = Get-HashOrNull (Join-Path $target 'driver.vrdrivermanifest')
        $installedDllSha256 = Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')
        $installedPoseProbeSha256 = Get-HashOrNull (Join-Path $target 'tools\csx_openvr_pose_probe.exe')
        $installedDefaultSettingsSha256 = Get-HashOrNull (Join-Path $target 'resources\settings\default.vrsettings')
        $installedInputProfileSha256 = Get-HashOrNull (Join-Path $target $inputProfileRelativePath)
        foreach ($member in @('openVrApiSha256', 'buildProvenanceSha256')) {
            if ($marker[$member] -ne $journal.sourceProvenance[$member]) { throw 'Installed runtime/provenance hash does not match the source package.' }
        }
        if ($installedManifestSha256 -ne $journal.sourceProvenance.manifestSha256 -or $installedDllSha256 -ne $journal.sourceProvenance.dllSha256 -or $installedPoseProbeSha256 -ne $journal.sourceProvenance.poseProbeSha256 -or $installedDefaultSettingsSha256 -ne $journal.sourceProvenance.defaultSettingsSha256 -or $installedInputProfileSha256 -ne $journal.sourceProvenance.passiveControllerInputProfileSha256) {
            throw 'Installed driver provenance does not match the receipt-bound source package.'
        }
        $receipt = [ordered]@{
            schemaVersion = 2
            transactionId = $transactionId
            installedUtc = [DateTime]::UtcNow.ToString('o')
            installRoot = $target
            manifestSha256 = $installedManifestSha256
            dllSha256 = $installedDllSha256
            poseProbeSha256 = $installedPoseProbeSha256
            defaultSettingsSha256 = $installedDefaultSettingsSha256
            passiveControllerInputProfileSha256 = $installedInputProfileSha256
            openVrApiSha256 = $marker.openVrApiSha256
            buildProvenanceSha256 = $marker.buildProvenanceSha256
            markerSha256 = Get-HashOrNull (Join-Path $target '.csx-vr-automation-driver.json')
            previousInstallRoot = $previousInstall
            openVrPathsPath = $registration.openVrPathsPath
            openVrPathsSha256 = $registration.openVrPathsSha256
            registration = $registration
            journalPath = $journalPath
            evidenceJournalPath = $evidenceJournalPath
            installControl = $script:InstallControl
        }
        if ($EvidenceDirectory) {
            New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
            $receiptPath = Join-Path $EvidenceDirectory ("steamvr-head-pose-install-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).receipt.json")
            $journal.receiptPath = $receiptPath
            $journal.phase = 'receipt-publication-uncommitted'
            Write-InstallJournal -Journal $journal -Control $script:InstallControl
            Write-JsonAtomic -Path $receiptPath -Value $receipt
            $receipt['receiptPath'] = $receiptPath
        }
        $journal.phase = 'committed'
        $journal.committedUtc = [DateTime]::UtcNow.ToString('o')
        $journal.installedDllSha256 = $receipt.dllSha256
        $journal.installedMarkerSha256 = $receipt.markerSha256
        Write-InstallJournal -Journal $journal -Control $script:InstallControl
        return New-Result -Ok $true -State $(if ($previousInstall) { 'driver-upgraded' } else { 'driver-installed' }) -Data $receipt
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        try { Write-BytesAtomic -Path $OpenVRPathsPath -Bytes $registrationPreimage } catch { $rollbackErrors.Add("OpenVR registration rollback failed: $($_.Exception.Message)") }
        try {
            if (Test-Path -LiteralPath $target) {
                if (Test-Path -LiteralPath $quarantine) { throw "Uncommitted quarantine path already exists: $quarantine" }
                Move-Item -LiteralPath $target -Destination $quarantine
            }
        }
        catch { $rollbackErrors.Add("Replacement quarantine failed: $($_.Exception.Message)") }
        try {
            if ($previousInstall -and (Test-Path -LiteralPath $previousInstall) -and -not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $previousInstall -Destination $target
            }
        }
        catch { $rollbackErrors.Add("Original install restoration failed: $($_.Exception.Message)") }
        if (Test-Path -LiteralPath $staging) {
            try { Move-Item -LiteralPath $staging -Destination "$staging.uncommitted" } catch { $rollbackErrors.Add("Staging quarantine failed: $($_.Exception.Message)") }
        }
        if ((Get-HashOrNull $OpenVRPathsPath) -ne $registrationPreimageSha256) { $rollbackErrors.Add('OpenVR registration rollback hash did not match its exact preimage.') }
        if ($previousInstall) {
            if ((Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')) -ne $originalDllSha256) { $rollbackErrors.Add('Restored driver DLL hash did not match the original installation.') }
        }
        elseif (Test-Path -LiteralPath $target) { $rollbackErrors.Add('A new uncommitted installation remains active at the target path.') }
        $journal.phase = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
        $journal.failure = $failure
        $journal.rollbackErrors = @($rollbackErrors)
        $journal.completedUtc = [DateTime]::UtcNow.ToString('o')
        try { Write-InstallJournal -Journal $journal -Control $script:InstallControl } catch { $rollbackErrors.Add("Recovery journal update failed: $($_.Exception.Message)") }
        if ($rollbackErrors.Count -gt 0) { throw "$failure Rollback is incomplete: $($rollbackErrors -join '; '). Recovery journal: $journalPath" }
        throw "$failure The exact previous install and OpenVR registration preimage were restored; the uncommitted replacement was quarantined at $quarantine."
    }
}

function Install-Driver {
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'The stable driver install root could not be resolved.' }
    if ([string]::IsNullOrWhiteSpace($OpenVRPathsPath)) { throw 'The authoritative OpenVR registration path could not be resolved.' }
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw 'SteamVR must be stopped before installing or recovering the head-pose driver.' }
    }
    $script:InstallControl = Get-InstallTransactionControl -TargetRoot $InstallRoot -RegistrationPath $OpenVRPathsPath
    $installLock = $null
    try {
        $installLock = Enter-InstallTransactionLock -Control $script:InstallControl
        $recovered = Recover-PendingInstallTransaction -Control $script:InstallControl
        $result = Install-DriverCore
        if ($null -ne $recovered -and $result.data -is [Collections.IDictionary]) { $result.data['recoveredTransaction'] = $recovered }
        return $result
    }
    finally {
        if ($installLock) { $installLock.Dispose() }
    }
}

try {
    switch ($Command) {
        'inspect' {
            $pose = Read-PoseState
            $result = New-Result -Ok $true -State $(if ($pose.available) { 'provider-running' } else { 'provider-stopped' }) -Data @{ mapName = $MapName; pose = $pose }
        }
        'qualify' {
            $pose = Read-PoseState
            $applicationPose = if ($SkipOpenVRProbe) { [pscustomobject][ordered]@{ available = $false; qualified = $false; skipped = $true; error = 'Independent stereo qualification was explicitly skipped.' } } elseif (-not $pose.qualified) { [pscustomobject]@{ available = $false; qualified = $false; error = 'Exact provider creator/pose authority is not qualified; probe was not executed.' } } else { Invoke-PoseProbe -PreProbePose $pose }
            if ($applicationPose.qualified) {
                $pose = $applicationPose.poseAfterProbe
            }
            $qualified = [bool]$pose.qualified -and [bool]$applicationPose.qualified
            $qualificationErrors = @()
            if (-not $pose.qualified) { $qualificationErrors += 'The running provider does not expose an acknowledged standing head pose within the configured height range.' }
            # Aggregate probe failure can be controller-only, stereo-only,
            # skipped, or an execution failure; it is not proof of a bad HMD.
            if (-not $applicationPose.qualified) { $qualificationErrors += 'The independent OpenVR application pose qualification did not succeed; inspect the retained probe result for the failed component or execution error.' }
            if ($RequireControllers -and -not $applicationPose.qualified) { $qualificationErrors += 'The required passive left/right controller pair was not independently qualified; skipping the probe cannot satisfy this gate.' }
            $result = New-Result -Ok $qualified -State $(if ($qualified) { 'head-pose-qualified' } else { 'head-pose-not-qualified' }) -Data @{ mapName = $MapName; pose = $pose; applicationPose = $applicationPose; controllersRequired = [bool]$RequireControllers; minimumEyeHeightMeters = $MinimumEyeHeightMeters; maximumEyeHeightMeters = $MaximumEyeHeightMeters } -Errors $qualificationErrors
        }
        'set' { $result = Set-PoseState }
        'install' { $result = Install-Driver }
    }
}
catch {
    $result = New-Result -Ok $false -State 'blocked' -Data @{ mapName = $MapName; installRoot = $InstallRoot; installControl = $script:InstallControl } -Errors @($_.Exception.Message)
}

$jsonParameters = @{ InputObject = $result; Depth = 16 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
