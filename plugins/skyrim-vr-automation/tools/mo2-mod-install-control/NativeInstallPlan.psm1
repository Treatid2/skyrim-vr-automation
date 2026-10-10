# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only admission foundation, NOT a deployment or ownership interface.
function Initialize-NativePlanFileProof {
    if ('SkyrimVRAutomation.NativePlanFileProofV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace SkyrimVRAutomation {
    public static class NativePlanFileProofV1 {
        [StructLayout(LayoutKind.Sequential)]
        public struct FileId { public ulong Volume; public ulong Low; public ulong High; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
        public static extern uint GetDriveTypeW(string root);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint QueryDosDeviceW(string name, [Out] char[] buffer, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out FileId id, uint size);
        public static string Device(string drive) {
            var buffer = new char[32768];
            uint count = QueryDosDeviceW(drive, buffer, (uint)buffer.Length);
            if (count == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            int end = Array.IndexOf(buffer, '\0', 0, (int)count);
            if (end <= 0) throw new InvalidOperationException("Unknown DOS device mapping.");
            // Only the first entry is current; later entries may be historical mappings.
            return new string(buffer, 0, end);
        }
        public static string[] Opened(SafeFileHandle handle) {
            var path = new StringBuilder(32768);
            uint count = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 2); // VOLUME_NAME_NT
            if (count == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (count >= path.Capacity) throw new InvalidOperationException("Opened path exceeds proof budget.");
            FileId id;
            if (!GetFileInformationByHandleEx(handle, 18, out id, (uint)Marshal.SizeOf<FileId>()))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return new [] { path.ToString(), id.Volume.ToString("x16") + ":" + id.Low.ToString("x16") + id.High.ToString("x16") };
        }
    }
}
'@
}

# Narrow private OS seams; fixtures replace these, not the admission predicates.
function Get-NativePlanNamespaceData([string]$Path) {
    Initialize-NativePlanFileProof
    $drive = $Path.Substring(0, 2)
    return @{ driveType=[SkyrimVRAutomation.NativePlanFileProofV1]::GetDriveTypeW($drive+'\');
        device=[SkyrimVRAutomation.NativePlanFileProofV1]::Device($drive) }
}
function Get-NativePlanOpenedFileData([IO.FileStream]$Stream) {
    Initialize-NativePlanFileProof
    $data = [SkyrimVRAutomation.NativePlanFileProofV1]::Opened($Stream.SafeFileHandle)
    return @{ path=$data[0]; identity=$data[1] }
}
function Get-NativePlanLocalDevice([string]$Path) {
    $data = Get-NativePlanNamespaceData $Path
    # Conservative supported namespace: fixed local HarddiskVolume only. Refuse
    # UNC/network, SUBST/path-backed DOS mappings and unknown device classes.
    if ($data.driveType -ne 3 -or $data.device -isnot [string] -or
        $data.device -cnotmatch '\A\\Device\\HarddiskVolume[0-9]+\z') {
        throw 'Native plan namespace is not a supported fixed local volume.'
    }
    return $data.device
}
function Get-NativePlanOpenedIdentity([IO.FileStream]$Stream, [string]$Path) {
    $device = Get-NativePlanLocalDevice $Path
    $data = Get-NativePlanOpenedFileData $Stream
    $expected = $device + $Path.Substring(2)
    if ($data.path -isnot [string] -or -not [string]::Equals($data.path, $expected, [StringComparison]::OrdinalIgnoreCase) -or
        $data.identity -isnot [string] -or $data.identity -cnotmatch '\A[a-f0-9]{16}:[a-f0-9]{32}\z') {
        throw 'Native plan opened-file namespace or identity does not match its exact path.'
    }
    return $data.identity
}
function Assert-NativePlanDeadline([datetime]$DeadlineUtc) {
    if ([datetime]::UtcNow -ge $DeadlineUtc) { throw 'Native plan validation deadline exceeded.' }
}

function Assert-NativePlanObject($Value, [string[]]$Fields, [string]$Label) {
    if ($Value -isnot [Collections.IDictionary]) { throw "$Label must be a JSON object." }
    if ($Value.Count -ne $Fields.Count) { throw "$Label has missing or unexpected fields." }
    foreach ($key in $Value.Keys) {
        if ([string]$key -cnotin $Fields) { throw "$Label has an unknown or case-mismatched field." }
    }
}

function ConvertFrom-NativePlanJson([byte[]]$Bytes) {
    # JsonDocument retains duplicate properties, unlike ConvertFrom-Json.
    # Reject them before any projection, including case aliases in all objects.
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 12
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.AllowTrailingCommas = $false
    $document = [Text.Json.JsonDocument]::Parse($text, $options)
    try {
        $nodes = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $nodes.Push($document.RootElement)
        $count = 0
        while ($nodes.Count) {
            if (++$count -gt 20000) { throw 'Native plan JSON node budget exceeded.' }
            $node = $nodes.Pop()
            if ($node.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $node.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'Native plan JSON contains duplicate or case-aliased keys.' }
                    $nodes.Push($property.Value)
                }
            } elseif ($node.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $node.EnumerateArray()) { $nodes.Push($item) }
            }
        }
        return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 12
    } finally { $document.Dispose() }
}

function Assert-NativePlanSafePath([string]$Path) {
    # This Windows-only contract admits explicit local drive paths, not UNC,
    # device paths, ADS, environment expansion, aliases or relative paths.
    if ($Path -notmatch '\A[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or $Path.Contains('%') -or $Path.Contains('~')) {
        throw 'Native plan source must be an explicit local drive path.'
    }
    foreach ($part in $Path.Substring(3).Split([char[]]@('\', '/'))) {
        if ($part.Length -eq 0 -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '[*?"<>|\x00-\x1F]') { throw 'Native plan path contains an ambiguous Windows component.' }
    }
    $full = [IO.Path]::GetFullPath($Path)
    $null = Get-NativePlanLocalDevice $full
    $cursor = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Native plan path traverses a reparse point.' }
        $cursor = if ($cursor -is [IO.FileInfo]) { $cursor.Directory } else { $cursor.Parent }
    }
    return $full
}

function Read-NativePlanBoundedFile([string]$Path, [long]$MaximumBytes, [datetime]$DeadlineUtc) {
    Assert-NativePlanDeadline $DeadlineUtc
    $full = Assert-NativePlanSafePath $Path
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        $identity = Get-NativePlanOpenedIdentity $stream $full
        if ($stream.Length -gt $MaximumBytes) { throw 'Native plan metadata exceeds its byte limit.' }
        $buffer = [byte[]]::new(65536)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Assert-NativePlanDeadline $DeadlineUtc
            if ($memory.Length + $read -gt $MaximumBytes) { throw 'Native plan metadata grew beyond its byte limit.' }
            $memory.Write($buffer, 0, $read)
        }
        $null = Assert-NativePlanSafePath $full
        if ((Get-NativePlanOpenedIdentity $stream $full) -cne $identity) { throw 'Native plan metadata identity changed during validation.' }
        return ,$memory.ToArray()
    } finally { $memory.Dispose(); $stream.Dispose() }
}

function Assert-NativePlanName($Value, [string]$Label) {
    if ($Value -isnot [string] -or $Value.Length -lt 1 -or $Value.Length -gt 120 -or $Value -cne $Value.Trim() -or
        $Value -match '[\\/:*?"<>|\x00-\x1F]' -or $Value.EndsWith('.') -or $Value -in @('.', '..') -or
        $Value -match '\A(CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])(?:\.|\z)') { throw "$Label is not a safe exact Windows directory name." }
}

function Get-VerifiedNativeInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedProfile,
        [Parameter(Mandatory)][string]$ExpectedLeaseId,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 30
    )
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    if ($ExpectedPlanSha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $ExpectedSourceCommit -cnotmatch '\A[a-f0-9]{40}\z') {
        throw 'Expected identities must be exact lowercase hexadecimal.'
    }
    $planBytes = Read-NativePlanBoundedFile $PlanPath 65536 $deadline
    $planHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($planBytes)).ToLowerInvariant()
    if ($planHash -cne $ExpectedPlanSha256) { throw 'Exact native plan digest mismatch.' }
    $plan = ConvertFrom-NativePlanJson $planBytes
    Assert-NativePlanObject $plan @('schema', 'installId', 'sourceCommit', 'profile', 'leaseId', 'modName', 'buildReceipt', 'files') 'Native plan'
    if ($plan.schema -isnot [string] -or $plan.schema -cne 'mo2.native-install-plan.1' -or
        $plan.installId -isnot [string] -or $plan.installId -cnotmatch '\A[a-f0-9]{32}\z' -or
        $plan.sourceCommit -isnot [string] -or $plan.sourceCommit -cne $ExpectedSourceCommit -or
        $plan.profile -isnot [string] -or $plan.profile -cne $ExpectedProfile -or
        $plan.leaseId -isnot [string] -or $plan.leaseId -cne $ExpectedLeaseId -or
        $plan.leaseId -cnotmatch '\Alease-\d{8}T\d{6}Z-[a-f0-9]{8}\z') { throw 'Native plan candidate/profile/public lease/schema identity mismatch.' }
    Assert-NativePlanName $plan.profile 'Profile'
    Assert-NativePlanName $plan.modName 'Mod name'
    Assert-NativePlanObject $plan.buildReceipt @('path', 'sha256') 'Build receipt reference'
    if ($plan.buildReceipt.path -isnot [string] -or $plan.buildReceipt.sha256 -isnot [string] -or
        $plan.buildReceipt.sha256 -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Malformed build receipt reference.' }
    $receiptBytes = Read-NativePlanBoundedFile $plan.buildReceipt.path 1048576 $deadline
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receiptBytes)).ToLowerInvariant() -cne $plan.buildReceipt.sha256) { throw 'Build receipt digest mismatch.' }
    $receipt = ConvertFrom-NativePlanJson $receiptBytes
    if ($receipt -isnot [Collections.IDictionary] -or -not $receipt.Contains('commit') -or $receipt.commit -isnot [string] -or
        $receipt.commit -cne $ExpectedSourceCommit -or -not $receipt.Contains('artifacts') -or
        $receipt.artifacts -isnot [array] -or $receipt.artifacts.Count -gt 128) { throw 'Build receipt lacks exact candidate and bounded artifact inventory.' }
    if ($plan.files -isnot [array] -or $plan.files.Count -lt 1 -or $plan.files.Count -gt 32) { throw 'Native plan requires 1..32 declared files.' }
    $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $physicalSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $verified = [Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    foreach ($file in $plan.files) {
        Assert-NativePlanDeadline $deadline
        Assert-NativePlanObject $file @('sourcePath', 'relativePath', 'bytes', 'sha256') 'Native file'
        if ($file.sourcePath -isnot [string] -or $file.relativePath -isnot [string] -or $file.sha256 -isnot [string] -or
            $file.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or ($file.bytes -isnot [long] -and $file.bytes -isnot [int]) -or
            $file.bytes -lt 1 -or $file.bytes -gt 268435456 -or
            $file.relativePath -cnotmatch '\ASKSE/Plugins/[A-Za-z0-9_][A-Za-z0-9_.-]{0,100}\.(dll|pdb)\z') { throw 'Only typed, bounded Data-root native DLL/PDB file declarations are admitted.' }
        $leaf = [IO.Path]::GetFileName($file.relativePath)
        Assert-NativePlanName $leaf 'Native filename'
        if (-not $targets.Add($file.relativePath)) { throw 'Duplicate or case-colliding native target.' }
        $totalBytes += [long]$file.bytes
        if ($totalBytes -gt 536870912) { throw 'Native plan aggregate exceeds 512 MiB.' }
    }
    # Admit the whole declared byte budget before opening any native payload.
    foreach ($file in $plan.files) {
        Assert-NativePlanDeadline $deadline
        $leaf = [IO.Path]::GetFileName($file.relativePath)
        $source = Assert-NativePlanSafePath $file.sourcePath
        if (-not $sources.Add($source)) { throw 'Duplicate native source path.' }
        if ([IO.Path]::GetFileName($source) -cne $leaf) { throw 'Native source filename does not match its declared target.' }
        $matches = @($receipt.artifacts | Where-Object {
            $_ -is [Collections.IDictionary] -and $_.Contains('path') -and $_.path -is [string] -and
            [string]::Equals($_.path, $source, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1 -or -not $matches[0].Contains('bytes') -or -not $matches[0].Contains('sha256') -or
            ($matches[0].bytes -isnot [long] -and $matches[0].bytes -isnot [int]) -or $matches[0].bytes -ne $file.bytes -or
            $matches[0].sha256 -isnot [string] -or $matches[0].sha256 -cne $file.sha256) { throw 'Native file is not uniquely bound to its issued artifact receipt.' }
        $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $identity = Get-NativePlanOpenedIdentity $stream $source
            if (-not $physicalSources.Add($identity)) { throw 'Duplicate physical native source identity.' }
            if ($stream.Length -ne $file.bytes) { throw 'Native source size mismatch.' }
            $buffer = [byte[]]::new(1048576)
            $readBytes = 0L
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                Assert-NativePlanDeadline $deadline
                $readBytes += $read
                if ($readBytes -gt $file.bytes) { throw 'Native source grew during validation.' }
                $hasher.AppendData($buffer, 0, $read)
            }
            if ($readBytes -ne $file.bytes -or [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant() -cne $file.sha256) { throw 'Native source hash mismatch.' }
            $null = Assert-NativePlanSafePath $source
            if ((Get-NativePlanOpenedIdentity $stream $source) -cne $identity) { throw 'Native source identity changed during validation.' }
        } finally { $hasher.Dispose(); $stream.Dispose() }
        $verified.Add([pscustomobject]@{ sourcePath=$source; relativePath=$file.relativePath; bytes=[long]$file.bytes; sha256=$file.sha256; sourceIdentity=$identity })
    }
    if (@($verified | Where-Object relativePath -CLike '*.dll').Count -eq 0) { throw 'Native plan must contain a DLL.' }
    foreach ($file in $verified) {
        if ($file.relativePath.EndsWith('.pdb', [StringComparison]::Ordinal) -and
            -not $targets.Contains($file.relativePath.Substring(0, $file.relativePath.Length-4)+'.dll')) { throw 'PDB must accompany the matching declared DLL.' }
    }
    Assert-NativePlanDeadline $deadline
    return [pscustomobject][ordered]@{
        schema='mo2.native-install-plan-validation.1'; ok=$true
        planPath=[IO.Path]::GetFullPath($PlanPath); planSha256=$planHash
        installId=$plan.installId; sourceCommit=$plan.sourceCommit; profile=$plan.profile
        leaseId=$plan.leaseId; modName=$plan.modName
        buildReceiptPath=[IO.Path]::GetFullPath($plan.buildReceipt.path); buildReceiptSha256=$plan.buildReceipt.sha256
        files=$verified.ToArray(); bytes=$totalBytes; validatedAtUtc=[datetime]::UtcNow.ToString('o')
        mutationAuthorized=$false; deploymentPerformed=$false; enablePerformed=$false
        requiresFreshDeploymentValidation=$true
    }
}

Export-ModuleMember -Function Get-VerifiedNativeInstallPlan
