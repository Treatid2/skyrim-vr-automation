# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$script:MO2ControlContractVersion = '1.1.0'

if (-not ('SkyrimVRAutomation.Native.DirectoryIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SkyrimVRAutomation.Native {
    public static class DirectoryIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_ID_INFO {
            public ulong VolumeSerialNumber;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
            public byte[] FileId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string path, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle handle, int infoClass, out FILE_ID_INFO info,
            uint size);

        public static string Get(string path) {
            const uint FILE_READ_ATTRIBUTES = 0x80;
            const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, FILE_SHARE_DELETE = 4;
            const uint OPEN_EXISTING = 3, FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
            using (SafeFileHandle handle = CreateFileW(
                path, FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS,
                IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                FILE_ID_INFO info;
                if (!GetFileInformationByHandleEx(
                    handle, 18, out info,
                    (uint)Marshal.SizeOf(typeof(FILE_ID_INFO)))) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return info.VolumeSerialNumber.ToString("X16") + ":" +
                    BitConverter.ToString(info.FileId).Replace("-", "");
            }
        }
    }
}
'@
}

function Resolve-MO2ControlPath {
    param([Parameter(Mandatory)][string]$Path)

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function ConvertFrom-MO2JsonText {
    param([Parameter(Mandatory)][string]$Json)

    $parameters = @{
        InputObject = $Json
        ErrorAction = 'Stop'
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $parameters['DateKind'] = 'String'
    }
    return ConvertFrom-Json @parameters
}

function Read-MO2ControlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $resolved = Resolve-MO2ControlPath $ConfigPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "MO2 control configuration does not exist: $resolved"
    }

    try {
        $config = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop)
    }
    catch {
        throw "MO2 control configuration is not valid JSON: $resolved. $($_.Exception.Message)"
    }

    foreach ($property in @('contractVersion', 'machine', 'mo2', 'defaults', 'storage', 'limits', 'session')) {
        if (-not $config.PSObject.Properties[$property]) {
            throw "MO2 control configuration is missing required property '$property': $resolved"
        }
    }

    return $config
}

function Read-MO2IniFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sections = [ordered]@{}
    $sectionName = ''
    $sections[$sectionName] = [ordered]@{}

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $sectionName = $Matches[1]
            if (-not $sections.Contains($sectionName)) {
                $sections[$sectionName] = [ordered]@{}
            }
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $sections[$sectionName][$key] = $value
    }

    return $sections
}

function Test-MO2SamePath {
    param([string]$Left, [string]$Right)

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    return [string]::Equals(
        [IO.Path]::GetFullPath($Left).TrimEnd('\', '/'),
        [IO.Path]::GetFullPath($Right).TrimEnd('\', '/'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-MO2ShaderCacheTransactionTool {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'),
        (Join-Path $PSScriptRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1')
    )
    $matches = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one shader-cache transaction controller beside the MO2 controller; found $($matches.Count)."
    }
    return $matches[0]
}

function Get-MO2PreparedCacheShadowVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$ProviderResult,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$CacheModName,
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [switch]$AllowPreparedCacheGrowth
    )

    $errors = [Collections.Generic.List[string]]::new()
    $expectedReceiptPath = [IO.Path]::GetFullPath((Join-Path $EvidenceDirectory 'shader-cache-provider-shadow.receipt.json'))
    $shadow = if ($Plan.PSObject.Properties['providerShadow']) { $Plan.providerShadow } else { $null }
    $embeddedReceipt = if ($null -ne $shadow -and $shadow.PSObject.Properties['receipt']) { $shadow.receipt } else { $null }
    $declaredReceiptPath = if ($null -ne $shadow -and $shadow.PSObject.Properties['receiptPath']) { [string]$shadow.receiptPath } else { $null }
    if ($null -eq $shadow -or $null -eq $embeddedReceipt -or -not (Test-MO2SamePath $declaredReceiptPath $expectedReceiptPath)) {
        $errors.Add('The prepared cache plan does not bind the exact provider-shadow receipt.')
    }

    $receipt = $null
    if (-not (Test-Path -LiteralPath $expectedReceiptPath -PathType Leaf)) {
        $errors.Add("The provider-shadow receipt does not exist: $expectedReceiptPath")
    }
    else {
        try { $receipt = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $expectedReceiptPath -Raw -ErrorAction Stop) }
        catch { $errors.Add("The provider-shadow receipt is unreadable: $expectedReceiptPath. $($_.Exception.Message)") }
    }

    $winner = if ($ProviderResult.ok) { $ProviderResult.data.effectiveWinnerAmongEnabledMods } else { $null }
    $liveInventory = if ($null -ne $winner -and $winner.PSObject.Properties['inventory']) { $winner.inventory } else { $null }
    $expectedPreparedHash = if ($Plan.PSObject.Properties['preparedTreeSha256']) { [string]$Plan.preparedTreeSha256 } else { $null }
    $receiptPreparedHash = if ($null -ne $receipt -and $receipt.PSObject.Properties['preparedInventory'] -and $null -ne $receipt.preparedInventory) { [string]$receipt.preparedInventory.treeSha256 } else { $null }
    $embeddedPreparedHash = if ($null -ne $embeddedReceipt -and $embeddedReceipt.PSObject.Properties['preparedInventory'] -and $null -ne $embeddedReceipt.preparedInventory) { [string]$embeddedReceipt.preparedInventory.treeSha256 } else { $null }
    $livePreparedHash = if ($null -ne $liveInventory) { [string]$liveInventory.treeSha256 } else { $null }

    if ($expectedPreparedHash -notmatch '^[0-9A-Fa-f]{64}$' -or
        $receiptPreparedHash -cne $expectedPreparedHash -or
        $embeddedPreparedHash -cne $expectedPreparedHash) {
        $errors.Add('The cache plan and provider-shadow receipts do not agree on the exact prepared tree hash.')
    }
    if (-not $AllowPreparedCacheGrowth -and $livePreparedHash -cne $expectedPreparedHash) {
        $errors.Add('The winning task cache changed after prepare and before its first launch.')
    }

    if ($null -ne $receipt) {
        if ([string]$receipt.state -cne 'materialized' -or
            -not (Test-MO2SamePath ([string]$receipt.profilePath) $ProfilePath) -or
            [string]$receipt.profileSha256 -cne [string]$ProviderResult.data.profileSha256 -or
            [string]$receipt.cacheModName -cne $CacheModName -or
            -not (Test-MO2SamePath ([string]$receipt.cachePath) $CachePath)) {
            $errors.Add('The provider-shadow receipt does not bind the current task profile and winning cache mod.')
        }
    }

    $targetPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $liveInventory) {
        foreach ($entry in @($liveInventory.entries)) { $null = $targetPaths.Add([string]$entry.relativePath) }
    }
    $requiredPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($provider in @($ProviderResult.data.providers | Where-Object {
        [bool]$_.enabled -and [string]$_.providerType -ceq 'directory' -and
        -not [string]::Equals([string]$_.modName, $CacheModName, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object lineNumber)) {
        foreach ($entry in @($provider.inventory.entries)) {
            $relative = [string]$entry.relativePath
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                $errors.Add("A lower shader-cache provider returned an unsafe relative path: '$relative'.")
                continue
            }
            $null = $requiredPaths.Add($relative)
        }
    }
    $missingPaths = @($requiredPaths | Where-Object { -not $targetPaths.Contains([string]$_) } | Sort-Object)
    if ($missingPaths.Count -gt 0) {
        $errors.Add("The winning task cache no longer shadows $($missingPaths.Count) lower-provider path(s): $($missingPaths -join ', ')")
    }
    if ($null -ne $receipt -and
        (-not $receipt.PSObject.Properties['requiredLowerProviderFiles'] -or
         [int]$receipt.requiredLowerProviderFiles -ne $requiredPaths.Count)) {
        $errors.Add('The provider-shadow receipt no longer covers the current lower-provider inventory.')
    }

    return [pscustomobject][ordered]@{
        ok = $errors.Count -eq 0
        allowPreparedCacheGrowth = [bool]$AllowPreparedCacheGrowth
        receiptPath = $expectedReceiptPath
        preparedTreeSha256 = $expectedPreparedHash
        liveTreeSha256 = $livePreparedHash
        requiredLowerProviderFiles = $requiredPaths.Count
        missingLowerProviderPaths = $missingPaths
        errors = @($errors)
    }
}

function Get-MO2PreparedBackupShadowVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Output,
        [Parameter(Mandatory)]$ProviderResult,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$OutputModName,
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$AllowPreparedCacheGrowth
    )

    $errors = [Collections.Generic.List[string]]::new()
    $receipt = if ($Output.PSObject.Properties['shadowReceipt']) { $Output.shadowReceipt } else { $null }
    $winner = if ($ProviderResult.ok) { $ProviderResult.data.effectiveWinnerAmongEnabledMods } else { $null }
    $liveInventory = if ($null -ne $winner -and $winner.PSObject.Properties['inventory']) { $winner.inventory } else { $null }
    if (-not $ProviderResult.ok -or $null -eq $winner -or
        [string]$winner.modName -cne $OutputModName -or
        [string]$winner.providerType -cne 'directory' -or
        -not (Test-MO2SamePath ([string]$winner.providerPath) $BackupPath)) {
        $observed = if ($null -eq $winner) { '<none>' } else { [string]$winner.modName }
        $errors.Add("The task runtime-output mod is not the effective enabled backup provider; observed '$observed'.")
    }

    $preparedHash = if ($null -ne $receipt -and $receipt.PSObject.Properties['preparedInventory'] -and $null -ne $receipt.preparedInventory) {
        [string]$receipt.preparedInventory.treeSha256
    }
    else { $null }
    $liveHash = if ($null -ne $liveInventory) { [string]$liveInventory.treeSha256 } else { $null }
    if ($null -eq $receipt -or
        [string]$receipt.contractVersion -cne '2.0.0' -or
        [string]$receipt.relativePath -cne 'backup' -or
        [string]$receipt.state -cne 'materialized' -or
        -not (Test-MO2SamePath ([string]$receipt.profilePath) $ProfilePath) -or
        [string]$receipt.targetModName -cne $OutputModName -or
        -not (Test-MO2SamePath ([string]$receipt.targetPath) $BackupPath)) {
        $errors.Add('The backup-shadow receipt does not bind the current task profile and winning output mod.')
    }
    if ($preparedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        $errors.Add('The backup-shadow receipt lacks an exact prepared tree hash.')
    }
    elseif (-not $AllowPreparedCacheGrowth -and $liveHash -cne $preparedHash) {
        $errors.Add('The winning task backup tree changed after workspace creation and before its first launch.')
    }

    $targetPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $liveInventory) {
        foreach ($entry in @($liveInventory.entries)) { $null = $targetPaths.Add([string]$entry.relativePath) }
    }
    $required = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($provider in @($ProviderResult.data.providers | Where-Object {
        [bool]$_.enabled -and -not [string]::Equals([string]$_.modName, $OutputModName, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object lineNumber)) {
        if ([string]$provider.providerType -cne 'directory' -or $null -eq $provider.inventory) {
            $errors.Add("A lower backup provider is not an inventoried directory: $($provider.modName).")
            continue
        }
        foreach ($entry in @($provider.inventory.entries)) {
            $relative = ([string]$entry.relativePath).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                $errors.Add("A lower backup provider returned an unsafe relative path: '$relative'.")
                continue
            }
            if (-not $required.ContainsKey($relative)) {
                $required.Add($relative, [pscustomobject][ordered]@{
                    relativePath = $relative; sourceModName = [string]$provider.modName
                    sha256 = [string]$entry.sha256
                })
            }
        }
    }

    $receiptCopies = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $receipt -and $receipt.PSObject.Properties['copied']) {
        foreach ($copy in @($receipt.copied)) {
            $relative = ([string]$copy.relativePath).Replace('/', '\')
            if ($receiptCopies.ContainsKey($relative)) {
                $errors.Add("The backup-shadow receipt repeats relative path '$relative'.")
            }
            else { $receiptCopies.Add($relative, $copy) }
        }
    }
    $changedSources = [Collections.Generic.List[string]]::new()
    foreach ($requiredEntry in $required.Values) {
        $relative = [string]$requiredEntry.relativePath
        if (-not $receiptCopies.ContainsKey($relative)) {
            $changedSources.Add($relative)
            continue
        }
        $copy = $receiptCopies[$relative]
        if ([string]$copy.sourceModName -cne [string]$requiredEntry.sourceModName -or
            [string]$copy.sha256 -cne [string]$requiredEntry.sha256) {
            $changedSources.Add($relative)
        }
    }
    $missingPaths = @($required.Keys | Where-Object { -not $targetPaths.Contains([string]$_) } | Sort-Object)
    if ($missingPaths.Count -gt 0) {
        $errors.Add("The winning task backup tree no longer shadows $($missingPaths.Count) lower-provider path(s): $($missingPaths -join ', ')")
    }
    if ($changedSources.Count -gt 0 -or $receiptCopies.Count -ne $required.Count -or
        $null -eq $receipt -or -not $receipt.PSObject.Properties['requiredLowerProviderFiles'] -or
        [int]$receipt.requiredLowerProviderFiles -ne $required.Count) {
        $errors.Add('The backup-shadow receipt no longer covers the current lower-provider inventory.')
    }

    return [pscustomobject][ordered]@{
        ok = $errors.Count -eq 0; allowPreparedCacheGrowth = [bool]$AllowPreparedCacheGrowth
        preparedTreeSha256 = $preparedHash; liveTreeSha256 = $liveHash
        requiredLowerProviderFiles = $required.Count; missingLowerProviderPaths = $missingPaths
        changedLowerProviderPaths = @($changedSources | Sort-Object); errors = @($errors)
    }
}

function Resolve-MO2CommunityShadersBuildBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionTool,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ModsPath
    )

    $relativePluginPath = 'SKSE\Plugins\CommunityShaders.dll'
    $providers = ConvertFrom-MO2JsonText ([string](& $TransactionTool providers -ProfilePath $ProfilePath -ModsPath $ModsPath -RelativeCachePath $relativePluginPath -NoExit -Confirm:$false))
    if (-not $providers.ok) { throw "Could not inspect the winning Community Shaders provider: $(@($providers.errors) -join '; ')" }
    $winner = $providers.data.effectiveWinnerAmongEnabledMods
    if ($null -eq $winner -or [string]$winner.providerType -cne 'file') { throw 'The task profile has no exact enabled loose-file CommunityShaders.dll winner.' }
    $pluginPath = [IO.Path]::GetFullPath([string]$winner.providerPath)
    $manifestPath = [IO.Path]::GetFullPath((Join-Path ([string]$winner.modRoot) 'SKSE\Plugins\CSX.BuildManifest.json'))
    if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The winning Community Shaders provider lacks its DLL or CSX.BuildManifest.json.'
    }
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $artifact = if ($manifest.PSObject.Properties['artifact']) { $manifest.artifact } else { $null }
    $identity = if ($manifest.PSObject.Properties['identity']) { $manifest.identity } else { $null }
    $cacheIdentity = if ($null -ne $identity -and $identity.PSObject.Properties['shaderCache']) { $identity.shaderCache } else { $null }
    $buildId = if ($manifest.PSObject.Properties['buildId']) { [string]$manifest.buildId } else { '' }
    $declaredHash = if ($null -ne $artifact -and $artifact.PSObject.Properties['sha256']) { [string]$artifact.sha256 } else { '' }
    $declaredBytes = if ($null -ne $artifact -and $artifact.PSObject.Properties['sizeBytes']) { [long]$artifact.sizeBytes } else { -1 }
    $cacheAbi = if ($null -ne $cacheIdentity -and $cacheIdentity.PSObject.Properties['abiId']) { [string]$cacheIdentity.abiId } else { '' }
    if ([string]::IsNullOrWhiteSpace($buildId) -or $declaredHash -notmatch '^[0-9A-Fa-f]{64}$' -or [string]::IsNullOrWhiteSpace($cacheAbi)) {
        throw 'The winning Community Shaders build manifest lacks an exact build ID, DLL hash, or shader-cache ABI.'
    }
    $plugin = Get-Item -LiteralPath $pluginPath
    $actualHash = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    if ($actualHash -cne $declaredHash -or ($declaredBytes -ge 0 -and [long]$plugin.Length -ne $declaredBytes)) {
        throw 'The winning Community Shaders DLL does not match its build manifest.'
    }
    return [pscustomobject][ordered]@{
        profilePath = [string]$providers.data.profilePath; profileSha256 = [string]$providers.data.profileSha256
        modsPath = [string]$providers.data.modsPath; relativePluginPath = $relativePluginPath
        modName = [string]$winner.modName; pluginPath = $pluginPath; manifestPath = $manifestPath
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        buildId = $buildId; artifactSha256 = $actualHash; artifactBytes = [long]$plugin.Length
        shaderCacheAbi = $cacheAbi
    }
}

function Test-MO2CommunityShadersBuildBinding($Expected, $Current) {
    if ($null -eq $Expected -or $null -eq $Current) { return $false }
    foreach ($required in @('profilePath', 'profileSha256', 'modsPath', 'modName', 'pluginPath', 'manifestPath', 'manifestSha256', 'buildId', 'artifactSha256', 'artifactBytes', 'shaderCacheAbi')) {
        if (-not $Expected.PSObject.Properties[$required] -or -not $Current.PSObject.Properties[$required]) { return $false }
    }
    return (Test-MO2SamePath ([string]$Expected.profilePath) ([string]$Current.profilePath)) -and
        [string]$Expected.profileSha256 -ceq [string]$Current.profileSha256 -and
        (Test-MO2SamePath ([string]$Expected.modsPath) ([string]$Current.modsPath)) -and
        [string]$Expected.modName -ceq [string]$Current.modName -and
        (Test-MO2SamePath ([string]$Expected.pluginPath) ([string]$Current.pluginPath)) -and
        (Test-MO2SamePath ([string]$Expected.manifestPath) ([string]$Current.manifestPath)) -and
        [string]$Expected.manifestSha256 -ceq [string]$Current.manifestSha256 -and
        [string]$Expected.buildId -ceq [string]$Current.buildId -and
        [string]$Expected.artifactSha256 -ceq [string]$Current.artifactSha256 -and
        [long]$Expected.artifactBytes -eq [long]$Current.artifactBytes -and
        [string]$Expected.shaderCacheAbi -ceq [string]$Current.shaderCacheAbi
}

function Get-MO2OverwriteProviderShadowVerification {
    [CmdletBinding()]
    param(
        $Receipt,
        $ProviderResult,
        $Inventory,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RequiredCountProperty
    )

    $errors = [Collections.Generic.List[string]]::new()
    $required = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $ProviderResult -or -not [bool]$ProviderResult.ok) {
        $errors.Add("The current $RelativePath provider union is unavailable.")
    }
    else {
        foreach ($provider in @($ProviderResult.data.providers | Where-Object enabled | Sort-Object lineNumber)) {
            if ([string]$provider.providerType -cne 'directory' -or $null -eq $provider.inventory) {
                $errors.Add("An enabled $RelativePath provider is not an inventoried directory: $($provider.modName).")
                continue
            }
            foreach ($entry in @($provider.inventory.entries)) {
                $relative = ([string]$entry.relativePath).Replace('/', '\')
                if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                    $errors.Add("An enabled $RelativePath provider returned an unsafe relative path: '$relative'.")
                    continue
                }
                if (-not $required.ContainsKey($relative)) {
                    $required.Add($relative, [pscustomobject][ordered]@{
                        relativePath = $relative; sourceModName = [string]$provider.modName
                        bytes = [long]$entry.bytes; sha256 = [string]$entry.sha256
                    })
                }
            }
        }
    }

    $live = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Inventory -and $Inventory.PSObject.Properties['entries']) {
        foreach ($entry in @($Inventory.entries)) { $live[([string]$entry.relativePath).Replace('/', '\')] = $entry }
    }
    $copied = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $preExisting = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $receiptShapeValid = $null -ne $Receipt -and $Receipt.PSObject.Properties['copied'] -and
        $Receipt.PSObject.Properties['alreadyPresent'] -and $Receipt.PSObject.Properties[$RequiredCountProperty]
    if (-not $receiptShapeValid) {
        $errors.Add("The $RelativePath provider-shadow receipt is missing required ownership records.")
    }
    else {
        foreach ($entry in @($Receipt.copied)) {
            if ($null -eq $entry -or -not $entry.PSObject.Properties['relativePath']) {
                $errors.Add("The $RelativePath copied-provider receipt contains a malformed record.")
                continue
            }
            $relative = ([string]$entry.relativePath).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative)) {
                $errors.Add("The $RelativePath copied-provider receipt contains an empty path.")
                continue
            }
            if ($copied.ContainsKey($relative)) { $errors.Add("The $RelativePath copied-provider receipt repeats '$relative'.") }
            else { $copied.Add($relative, $entry) }
        }
        foreach ($entry in @($Receipt.alreadyPresent)) {
            if ($null -eq $entry -or -not $entry.PSObject.Properties['relativePath']) {
                $errors.Add("The $RelativePath pre-existing Overwrite receipt contains a malformed record.")
                continue
            }
            $relative = ([string]$entry.relativePath).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative)) {
                $errors.Add("The $RelativePath pre-existing Overwrite receipt contains an empty path.")
                continue
            }
            if ($preExisting.ContainsKey($relative) -or $copied.ContainsKey($relative)) { $errors.Add("The $RelativePath pre-existing Overwrite receipt repeats '$relative'.") }
            else { $preExisting.Add($relative, $entry) }
        }
    }

    $missingPaths = [Collections.Generic.List[string]]::new()
    $changedProviderPaths = [Collections.Generic.List[string]]::new()
    $changedOverwritePaths = [Collections.Generic.List[string]]::new()
    foreach ($requiredEntry in $required.Values) {
        $relative = [string]$requiredEntry.relativePath
        if (-not $live.ContainsKey($relative)) { $missingPaths.Add($relative); continue }
        $liveEntry = $live[$relative]
        if ($copied.ContainsKey($relative)) {
            $copy = $copied[$relative]
            $copyValid = $null -ne $copy -and $copy.PSObject.Properties['winnerClass'] -and
                $copy.PSObject.Properties['sourceModName'] -and $copy.PSObject.Properties['bytes'] -and
                $copy.PSObject.Properties['sha256']
            if (-not $copyValid -or [string]$copy.winnerClass -cne 'copied-provider' -or
                [string]$copy.sourceModName -cne [string]$requiredEntry.sourceModName -or
                [long]$copy.bytes -ne [long]$requiredEntry.bytes -or
                [string]$copy.sha256 -cne [string]$requiredEntry.sha256) {
                $changedProviderPaths.Add($relative)
            }
            if (-not $copyValid -or [long]$liveEntry.bytes -ne [long]$copy.bytes -or [string]$liveEntry.sha256 -cne [string]$copy.sha256) {
                $changedOverwritePaths.Add($relative)
            }
        }
        elseif ($preExisting.ContainsKey($relative)) {
            $winner = $preExisting[$relative]
            $winnerValid = $null -ne $winner -and $winner.PSObject.Properties['winnerClass'] -and
                $winner.PSObject.Properties['bytes'] -and $winner.PSObject.Properties['sha256']
            if (-not $winnerValid -or [string]$winner.winnerClass -cne 'pre-existing-overwrite' -or
                [long]$liveEntry.bytes -ne [long]$winner.bytes -or [string]$liveEntry.sha256 -cne [string]$winner.sha256) {
                $changedOverwritePaths.Add($relative)
            }
        }
        else { $changedProviderPaths.Add($relative) }
    }
    if ($receiptShapeValid -and ([int]$Receipt.$RequiredCountProperty -ne $required.Count -or
        $copied.Count + $preExisting.Count -ne $required.Count)) {
        $errors.Add("The $RelativePath provider-shadow receipt no longer covers the complete current provider map.")
    }
    if ($missingPaths.Count -gt 0) { $errors.Add("MO2 Overwrite $RelativePath lacks $($missingPaths.Count) enabled-provider path(s): $($missingPaths -join ', ')") }
    if ($changedProviderPaths.Count -gt 0) { $errors.Add("The $RelativePath copied-provider identity changed for: $($changedProviderPaths -join ', ')") }
    if ($changedOverwritePaths.Count -gt 0) { $errors.Add("The $RelativePath Overwrite winner changed after materialization for: $($changedOverwritePaths -join ', ')") }
    return [pscustomobject][ordered]@{
        ok = $errors.Count -eq 0; requiredFiles = $required.Count
        copiedProviderFiles = $copied.Count; preExistingOverwriteFiles = $preExisting.Count
        missingPaths = @($missingPaths); changedProviderPaths = @($changedProviderPaths)
        changedOverwritePaths = @($changedOverwritePaths); errors = @($errors)
    }
}

function Get-MO2OverwriteWorkspaceIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Executable,
        [string]$AccessId,
        [switch]$RequirePreparedCache,
        [switch]$AllowPreparedCacheGrowth
    )

    $manifest = $Owned.data
    $output = $manifest.runtimeOutput
    $errors = [Collections.Generic.List[string]]::new()
    $checks = [Collections.Generic.List[object]]::new()
    $requiredOutputPaths = @(
        'overwritePath', 'cachePath', 'backupPath', 'ownerMarkerPath',
        'cachePlanPath', 'cacheCompletionPath', 'backupCompletionPath'
    )
    foreach ($field in $requiredOutputPaths) {
        if ($null -eq $output -or -not $output.PSObject.Properties[$field] -or
            [string]::IsNullOrWhiteSpace([string]$output.$field)) {
            $errors.Add("Task runtime-output manifest lacks required path '$field'.")
        }
    }
    foreach ($field in @('mode', 'executable', 'ownerMarkerSha256')) {
        if ($null -eq $output -or -not $output.PSObject.Properties[$field] -or
            [string]::IsNullOrWhiteSpace([string]$output.$field)) {
            $errors.Add("Task runtime-output manifest lacks required field '$field'.")
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject][ordered]@{
            applicable = $true; ok = $false; profile = $Profile; executable = $Executable
            workspace = $Owned; runtimeOutput = $output; cachePlan = $null
            backupVerification = $null; checks = @($checks); errors = @($errors)
        }
    }
    if ([string]$manifest.status -cne 'ready') { $errors.Add("Task workspace status must be 'ready' before launch; observed '$($manifest.status)'.") }
    if ([string]::IsNullOrWhiteSpace($AccessId) -or [string]$manifest.accessId -cne $AccessId) { $errors.Add('Task workspace and MO2 session must use the exact explicit access lease.') }

    $profilesRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory))
    )
    $modsRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.modsDirectory)))
    $overwriteRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.overwriteDirectory)))
    $expectedProfilePath = Join-Path $profilesRoot $Profile
    $modListPath = Join-Path $expectedProfilePath 'modlist.txt'
    $expectedCachePath = Join-Path $overwriteRoot 'ShaderCache'
    $expectedBackupPath = Join-Path $overwriteRoot 'backup'
    $expectedMarkerPath = Join-Path $overwriteRoot '.codex-workspace-output-owner.json'
    $outputCompleted = (Test-Path -LiteralPath ([string]$output.cacheCompletionPath) -PathType Leaf) -and
        (Test-Path -LiteralPath ([string]$output.backupCompletionPath) -PathType Leaf)
    foreach ($check in @(
        [pscustomobject]@{ name = 'binding-mode'; passed = [string]$output.mode -ceq 'mo2-overwrite-output' },
        [pscustomobject]@{ name = 'profile-path'; passed = Test-MO2SamePath ([string]$manifest.profilePath) $expectedProfilePath },
        [pscustomobject]@{ name = 'overwrite-path'; passed = Test-MO2SamePath ([string]$output.overwritePath) $overwriteRoot },
        [pscustomobject]@{ name = 'shader-cache-path'; passed = Test-MO2SamePath ([string]$output.cachePath) $expectedCachePath },
        [pscustomobject]@{ name = 'backup-path'; passed = Test-MO2SamePath ([string]$output.backupPath) $expectedBackupPath },
        [pscustomobject]@{ name = 'executable-binding'; passed = [string]$output.executable -ceq $Executable },
        [pscustomobject]@{ name = 'shader-cache-directory'; passed = $outputCompleted -or (Test-Path -LiteralPath $expectedCachePath -PathType Container) },
        [pscustomobject]@{ name = 'backup-directory'; passed = $outputCompleted -or (Test-Path -LiteralPath $expectedBackupPath -PathType Container) }
    )) {
        $checks.Add($check)
        if (-not $check.passed) { $errors.Add("Task MO2 Overwrite check failed: $($check.name).") }
    }

    $markerExists = Test-Path -LiteralPath $expectedMarkerPath -PathType Leaf
    if (-not (Test-MO2SamePath ([string]$output.ownerMarkerPath) $expectedMarkerPath) -or
        (-not $outputCompleted -and -not $markerExists)) {
        $errors.Add('The exact task-owned MO2 Overwrite marker is missing.')
    }
    elseif ($markerExists) {
        try {
            $markerHash = (Get-FileHash -LiteralPath $expectedMarkerPath -Algorithm SHA256).Hash
            $marker = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $expectedMarkerPath -Raw)
            if ($markerHash -cne [string]$output.ownerMarkerSha256 -or
                [string]$marker.workspaceId -cne [string]$manifest.workspaceId -or
                [string]$marker.ownershipId -cne [string]$manifest.ownershipId -or
                [string]$marker.mode -cne 'mo2-overwrite-output' -or
                -not (Test-MO2SamePath ([string]$marker.overwritePath) $overwriteRoot)) {
                $errors.Add('The MO2 Overwrite owner marker does not match the workspace manifest.')
            }
        }
        catch { $errors.Add("The MO2 Overwrite owner marker is unreadable: $($_.Exception.Message)") }
    }

    $settingsPath = Join-Path $expectedProfilePath 'settings.ini'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        $errors.Add("Task profile settings do not exist: $settingsPath")
    }
    else {
        $settings = Read-MO2IniFile -Path $settingsPath
        $forbiddenMappings = @()
        if ($settings.Contains('custom_overwrites')) {
            $forbiddenMappings = @($settings['custom_overwrites'].Keys | Where-Object {
                [string]::Equals([string]$_, $Executable, [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals([string]$_, 'Synthesis', [StringComparison]::OrdinalIgnoreCase)
            })
        }
        if ($forbiddenMappings.Count -gt 0) {
            $errors.Add("Task profile still diverts generated output through custom_overwrites: $($forbiddenMappings -join ', ').")
        }
    }

    $cacheProviders = $null; $backupProviders = $null; $cacheInventory = $null; $backupInventory = $null; $currentBuild = $null
    try {
        $transactionTool = Resolve-MO2ShaderCacheTransactionTool
        if (-not $outputCompleted) {
            $currentBuild = Resolve-MO2CommunityShadersBuildBinding -TransactionTool $transactionTool -ProfilePath $modListPath -ModsPath $modsRoot
            $cacheProviders = ConvertFrom-MO2JsonText ([string](& $transactionTool providers -ProfilePath $modListPath -ModsPath $modsRoot -RelativeCachePath 'ShaderCache' -DeepInventory -IncludeInventoryEntries -NoExit -Confirm:$false))
            $backupProviders = ConvertFrom-MO2JsonText ([string](& $transactionTool providers -ProfilePath $modListPath -ModsPath $modsRoot -RelativeCachePath 'backup' -DeepInventory -IncludeInventoryEntries -NoExit -Confirm:$false))
            $cacheInspection = ConvertFrom-MO2JsonText ([string](& $transactionTool inspect -CachePath $expectedCachePath -RelativeCachePath 'ShaderCache' -NoExit -Confirm:$false))
            $backupInspection = ConvertFrom-MO2JsonText ([string](& $transactionTool inspect -CachePath $expectedBackupPath -RelativeCachePath 'backup' -NoExit -Confirm:$false))
            foreach ($operation in @(
                [pscustomobject]@{ name = 'ShaderCache providers'; result = $cacheProviders },
                [pscustomobject]@{ name = 'backup providers'; result = $backupProviders },
                [pscustomobject]@{ name = 'ShaderCache inspection'; result = $cacheInspection },
                [pscustomobject]@{ name = 'backup inspection'; result = $backupInspection }
            )) {
                if (-not [bool]$operation.result.ok) {
                    throw "$($operation.name) failed: $(@($operation.result.errors) -join '; ')"
                }
            }
            $cacheInventory = $cacheInspection.data
            $backupInventory = $backupInspection.data
        }
    }
    catch { $errors.Add("Could not inspect bound MO2 Overwrite output: $($_.Exception.Message)") }

    $expectedBuild = if ($output.PSObject.Properties['communityShadersPlugin']) { $output.communityShadersPlugin } else { $null }
    if (-not $outputCompleted -and -not (Test-MO2CommunityShadersBuildBinding -Expected $expectedBuild -Current $currentBuild)) {
        $errors.Add('The winning Community Shaders DLL, manifest, build ID, or shader-cache ABI changed after workspace creation.')
    }
    if ($RequirePreparedCache -and $outputCompleted) {
        $errors.Add('The task output transactions are already complete and cannot authorize another launch.')
    }

    $backupCompletionPath = [string]$output.backupCompletionPath
    $backupCompleted = Test-Path -LiteralPath $backupCompletionPath -PathType Leaf
    $backupVerification = $null
    if ($null -ne $backupProviders -and $null -ne $backupInventory) {
        $receipt = if ($output.PSObject.Properties['shadowReceipt']) { $output.shadowReceipt } else { $null }
        if ($RequirePreparedCache -and $backupCompleted) { $errors.Add('The task backup transaction is already complete and cannot authorize another launch.') }
        $receiptValid = $null -ne $receipt -and
            $receipt.PSObject.Properties['contractVersion'] -and
            $receipt.PSObject.Properties['bindingMode'] -and
            $receipt.PSObject.Properties['profilePath'] -and
            $receipt.PSObject.Properties['profileSha256'] -and
            $receipt.PSObject.Properties['targetPath'] -and
            $receipt.PSObject.Properties['preparedInventory'] -and
            $null -ne $receipt.preparedInventory -and
            $receipt.preparedInventory.PSObject.Properties['treeSha256'] -and
            $receipt.PSObject.Properties['requiredProviderFiles'] -and
            $receipt.PSObject.Properties['beforeTreeSha256']
        if (-not $backupCompleted) {
            if (-not $receiptValid -or [string]$receipt.contractVersion -cne '3.0.0' -or
                [string]$receipt.bindingMode -cne 'mo2-overwrite-output' -or
                -not (Test-MO2SamePath ([string]$receipt.profilePath) $modListPath) -or
                [string]$receipt.profileSha256 -cne [string]$backupProviders.data.profileSha256 -or
                -not (Test-MO2SamePath ([string]$receipt.targetPath) $expectedBackupPath)) {
                $errors.Add('The backup receipt does not bind the current task profile and MO2 Overwrite tree.')
            }
            $coverage = Get-MO2OverwriteProviderShadowVerification -Receipt $receipt -ProviderResult $backupProviders -Inventory $backupInventory -RelativePath 'backup' -RequiredCountProperty 'requiredProviderFiles'
            foreach ($coverageError in @($coverage.errors)) { $errors.Add([string]$coverageError) }
            if ($receiptValid -and -not $AllowPreparedCacheGrowth -and [string]$backupInventory.treeSha256 -cne [string]$receipt.preparedInventory.treeSha256) {
                $errors.Add('MO2 Overwrite backup changed after workspace creation and before its first launch.')
            }
            $backupVerification = [pscustomobject]@{
                ok = [bool]$coverage.ok
                allowPreparedCacheGrowth = [bool]$AllowPreparedCacheGrowth
                requiredProviderFiles = [int]$coverage.requiredFiles
                missingProviderPaths = @($coverage.missingPaths)
                changedProviderPaths = @($coverage.changedProviderPaths)
                changedOverwritePaths = @($coverage.changedOverwritePaths)
            }
        }
        else {
            try {
                $backupCompletion = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $backupCompletionPath -Raw)
                if (-not $receiptValid -or [string]$backupCompletion.state -cne 'complete' -or
                    -not (Test-MO2SamePath ([string]$backupCompletion.backupPath) $expectedBackupPath) -or
                    ($receiptValid -and [string]$backupCompletion.restoredTreeSha256 -cne [string]$receipt.beforeTreeSha256)) {
                    $errors.Add('The backup completion does not restore the exact pre-task MO2 Overwrite tree.')
                }
            }
            catch { $errors.Add("The backup completion is unreadable: $($_.Exception.Message)") }
        }
    }

    $planPath = [string]$output.cachePlanPath
    $completionPath = [string]$output.cacheCompletionPath
    $plan = $null; $cacheVerification = $null
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        try { $plan = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $planPath -Raw) }
        catch { $errors.Add("Shader-cache plan is unreadable: $planPath. $($_.Exception.Message)") }
    }
    elseif ($RequirePreparedCache) { $errors.Add("Task launch requires the bound shader-cache prepare plan: $planPath") }
    $planComplete = $null -ne $plan
    foreach ($requiredPlanField in @(
        'state', 'requireMaterializedOutput', 'preparedTreeSha256', 'cachePath',
        'evidenceDirectory', 'beforeTreeSha256', 'transactionReceiptPath',
        'catalog', 'cacheBinding', 'providerShadow'
    )) {
        if ($planComplete -and -not $plan.PSObject.Properties[$requiredPlanField]) { $planComplete = $false }
    }
    if ($planComplete) {
        foreach ($requiredTextField in @('state', 'preparedTreeSha256', 'cachePath', 'evidenceDirectory', 'beforeTreeSha256', 'transactionReceiptPath')) {
            if ([string]::IsNullOrWhiteSpace([string]$plan.$requiredTextField)) { $planComplete = $false }
        }
        $planComplete = $planComplete -and $null -ne $plan.catalog -and
            $plan.catalog.PSObject.Properties['path'] -and
            -not [string]::IsNullOrWhiteSpace([string]$plan.catalog.path) -and
            $null -ne $plan.cacheBinding -and $null -ne $plan.providerShadow -and
            $plan.providerShadow.PSObject.Properties['receipt'] -and
            $null -ne $plan.providerShadow.receipt -and
            (Test-Path -LiteralPath ([string]$plan.transactionReceiptPath) -PathType Leaf)
    }
    if ($null -ne $plan -and -not $planComplete) {
        $errors.Add('Shader-cache plan is missing required state or preparation fields, including binding, provider, or recovery-catalog evidence.')
    }
    if ($null -ne $plan -and $null -ne $cacheProviders -and $null -ne $cacheInventory) {
        $binding = if ($plan.PSObject.Properties['cacheBinding']) { $plan.cacheBinding } else { $null }
        $bindingComplete = $null -ne $binding
        foreach ($requiredBindingField in @('mode', 'profilePath', 'modsPath', 'overwriteRoot', 'cachePath', 'relativeCachePath', 'profileSha256', 'workspaceId', 'ownershipId', 'ownerMarkerPath', 'ownerMarkerSha256', 'communityShadersPlugin')) {
            if ($bindingComplete -and -not $binding.PSObject.Properties[$requiredBindingField]) { $bindingComplete = $false }
        }
        $completionExists = Test-Path -LiteralPath $completionPath -PathType Leaf
        $bindingCurrent = $bindingComplete -and
            [string]$binding.mode -ceq 'mo2-overwrite-output' -and
            (Test-MO2SamePath ([string]$binding.profilePath) $modListPath) -and
            (Test-MO2SamePath ([string]$binding.modsPath) $modsRoot) -and
            (Test-MO2SamePath ([string]$binding.overwriteRoot) $overwriteRoot) -and
            (Test-MO2SamePath ([string]$binding.cachePath) $expectedCachePath) -and
            [string]$binding.relativeCachePath -ceq 'ShaderCache' -and
            [string]$binding.profileSha256 -ceq [string]$cacheProviders.data.profileSha256 -and
            [string]$binding.workspaceId -ceq [string]$manifest.workspaceId -and
            [string]$binding.ownershipId -ceq [string]$manifest.ownershipId -and
            (Test-MO2SamePath ([string]$binding.ownerMarkerPath) $expectedMarkerPath) -and
            [string]$binding.ownerMarkerSha256 -ceq [string]$output.ownerMarkerSha256 -and
            (Test-MO2CommunityShadersBuildBinding -Expected $binding.communityShadersPlugin -Current $currentBuild)
        $restored = $planComplete -and -not $RequirePreparedCache -and $completionExists -and [string]$plan.state -ceq 'restored' -and $bindingCurrent
        $prepared = $planComplete -and [string]$plan.state -ceq 'prepared' -and $bindingCurrent -and
            [bool]$plan.requireMaterializedOutput
        if (-not ($restored -or $prepared)) { $errors.Add('Shader-cache plan is not bound to the exact task profile and MO2 Overwrite tree.') }
        if ($RequirePreparedCache -and $prepared) {
            if ($completionExists) { $errors.Add('The task shader-cache transaction is already complete and cannot authorize another launch.') }
            $shadowReceipt = if ($plan.PSObject.Properties['providerShadow'] -and $null -ne $plan.providerShadow -and $plan.providerShadow.PSObject.Properties['receipt']) { $plan.providerShadow.receipt } else { $null }
            $coverage = Get-MO2OverwriteProviderShadowVerification -Receipt $shadowReceipt -ProviderResult $cacheProviders -Inventory $cacheInventory -RelativePath 'ShaderCache' -RequiredCountProperty 'requiredLowerProviderFiles'
            foreach ($coverageError in @($coverage.errors)) { $errors.Add([string]$coverageError) }
            if ($planComplete -and -not $AllowPreparedCacheGrowth -and [string]$cacheInventory.treeSha256 -cne [string]$plan.preparedTreeSha256) {
                $errors.Add('MO2 Overwrite ShaderCache changed after prepare and before its first launch.')
            }
            if ($null -eq $shadowReceipt -or -not $shadowReceipt.PSObject.Properties['bindingMode'] -or
                [string]$shadowReceipt.bindingMode -cne 'mo2-overwrite-output') {
                $errors.Add('The shader-cache provider receipt no longer covers the current enabled-provider inventory.')
            }
            $cacheVerification = [pscustomobject]@{
                ok = [bool]$coverage.ok
                allowPreparedCacheGrowth = [bool]$AllowPreparedCacheGrowth
                requiredProviderFiles = [int]$coverage.requiredFiles
                missingProviderPaths = @($coverage.missingPaths)
                changedProviderPaths = @($coverage.changedProviderPaths)
                changedOverwritePaths = @($coverage.changedOverwritePaths)
            }
        }
    }

    return [pscustomobject][ordered]@{
        applicable = $true; ok = $errors.Count -eq 0; profile = $Profile; executable = $Executable
        workspace = $Owned; runtimeOutput = $output
        cachePlan = [pscustomobject]@{ required = [bool]$RequirePreparedCache; path = $planPath; completionPath = $completionPath; verification = $cacheVerification }
        backupVerification = $backupVerification; checks = @($checks); errors = @($errors)
    }
}

function Get-MO2TaskWorkspaceIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Executable,
        [string]$AccessId,
        [switch]$RequirePreparedCache,
        [switch]$AllowPreparedCacheGrowth
    )

    if (-not $Profile.StartsWith('Codex Task - ', [StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{
            applicable = $false; ok = $true; profile = $Profile
            executable = $Executable; checks = @(); errors = @()
        }
    }

    $errors = [Collections.Generic.List[string]]::new()
    $checks = [Collections.Generic.List[object]]::new()
    $stagingRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)))
    $workspaceRoot = Join-Path $stagingRoot 'workspaces'
    $manifests = @()
    if (Test-Path -LiteralPath $workspaceRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $workspaceRoot -Filter '*.json' -File -ErrorAction Stop)) {
            if (-not [regex]::IsMatch($file.BaseName, '^[a-z0-9][a-z0-9-]*$')) { continue }
            try {
                $candidate = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop)
                if ([string]$candidate.profile -ceq $Profile) {
                    $manifests += [pscustomobject]@{ path = $file.FullName; data = $candidate }
                }
            }
            catch {
                $errors.Add("Workspace manifest is unreadable: $($file.FullName). $($_.Exception.Message)")
            }
        }
    }
    if (@($manifests).Count -ne 1) {
        $errors.Add("Expected exactly one owned workspace manifest for task profile '$Profile'; found $(@($manifests).Count).")
        return [pscustomobject][ordered]@{
            applicable = $true; ok = $false; profile = $Profile
            executable = $Executable; workspace = $null; runtimeOutput = $null
            cachePlan = $null; backupVerification = $null; checks = @($checks); errors = @($errors)
        }
    }

    $owned = $manifests[0]
    $manifest = $owned.data
    if ([string]$manifest.status -cne 'ready') {
        $errors.Add("Task workspace status must be 'ready' before launch; observed '$($manifest.status)'.")
    }
    if ([string]::IsNullOrWhiteSpace($AccessId)) {
        $errors.Add('Task workspaces require the exact explicit MO2 access lease.')
    }
    elseif ([string]$manifest.accessId -cne $AccessId) {
        $errors.Add('Task workspace and MO2 session are owned by different access leases.')
    }
    if (-not $manifest.PSObject.Properties['runtimeOutput'] -or $null -eq $manifest.runtimeOutput) {
        $errors.Add('Task workspace has no owned runtime-output contract. Recreate it with the current workspace controller.')
        return [pscustomobject][ordered]@{
            applicable = $true; ok = $false; profile = $Profile
            executable = $Executable; workspace = $owned; runtimeOutput = $null
            cachePlan = $null; backupVerification = $null; checks = @($checks); errors = @($errors)
        }
    }

    $output = $manifest.runtimeOutput
    foreach ($requiredField in @('mode', 'executable')) {
        if (-not $output.PSObject.Properties[$requiredField] -or [string]::IsNullOrWhiteSpace([string]$output.$requiredField)) {
            $errors.Add("Task runtime-output manifest lacks required field '$requiredField'.")
        }
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject][ordered]@{
            applicable = $true; ok = $false; profile = $Profile
            executable = $Executable; workspace = $owned; runtimeOutput = $output
            cachePlan = $null; backupVerification = $null; checks = @($checks); errors = @($errors)
        }
    }
    if ([string]$output.mode -ceq 'mo2-overwrite-output') {
        foreach ($requiredPath in @('cacheCompletionPath', 'backupCompletionPath')) {
            if (-not $output.PSObject.Properties[$requiredPath] -or [string]::IsNullOrWhiteSpace([string]$output.$requiredPath)) {
                $errors.Add("Task runtime-output manifest lacks required path '$requiredPath'.")
            }
        }
        if ($errors.Count -gt 0) {
            return [pscustomobject][ordered]@{
                applicable = $true; ok = $false; profile = $Profile
                executable = $Executable; workspace = $owned; runtimeOutput = $output
                cachePlan = $null; backupVerification = $null; checks = @($checks); errors = @($errors)
            }
        }
        return Get-MO2OverwriteWorkspaceIsolation -Config $Config -Owned $owned -Profile $Profile -Executable $Executable -AccessId $AccessId -RequirePreparedCache:$RequirePreparedCache -AllowPreparedCacheGrowth:$AllowPreparedCacheGrowth
    }
    $profilesRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)))
    $modsRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.modsDirectory)))
    $expectedProfilePath = Join-Path $profilesRoot $Profile
    $expectedModPath = Join-Path $modsRoot ([string]$output.modName)
    $expectedCachePath = Join-Path $expectedModPath 'ShaderCache'
    $expectedBackupPath = Join-Path $expectedModPath 'backup'
    $profilePath = [string]$manifest.profilePath
    $modPath = [string]$output.modPath
    $cachePath = [string]$output.cachePath

    foreach ($check in @(
        [pscustomobject]@{ name = 'profile-path'; passed = Test-MO2SamePath $profilePath $expectedProfilePath },
        [pscustomobject]@{ name = 'runtime-output-path'; passed = Test-MO2SamePath $modPath $expectedModPath },
        [pscustomobject]@{ name = 'shader-cache-path'; passed = Test-MO2SamePath $cachePath $expectedCachePath },
        [pscustomobject]@{ name = 'runtime-output-directory'; passed = Test-Path -LiteralPath $expectedModPath -PathType Container },
        [pscustomobject]@{ name = 'shader-cache-directory'; passed = Test-Path -LiteralPath $expectedCachePath -PathType Container },
        [pscustomobject]@{ name = 'backup-directory'; passed = Test-Path -LiteralPath $expectedBackupPath -PathType Container },
        [pscustomobject]@{ name = 'executable-binding'; passed = [string]$output.executable -ceq $Executable }
    )) {
        $checks.Add($check)
        if (-not $check.passed) { $errors.Add("Task runtime-output check failed: $($check.name).") }
    }

    $initialNameMatches = @($manifest.initialModNames | Where-Object { [string]$_ -ceq [string]$output.modName })
    if (@($initialNameMatches).Count -ne 0) { $errors.Add('The runtime-output mod existed before the workspace and is not task-owned.') }
    $registeredMatches = @($manifest.registeredMods | Where-Object {
        [string]$_.name -ceq [string]$output.modName -and (Test-MO2SamePath ([string]$_.path) $expectedModPath)
    })
    if (@($registeredMatches).Count -ne 1 -or -not [bool]$registeredMatches[0].enabled) {
        $errors.Add('The runtime-output mod is not the one enabled task-owned registration.')
    }

    $modListPath = Join-Path $expectedProfilePath 'modlist.txt'
    $enabledLines = if (Test-Path -LiteralPath $modListPath -PathType Leaf) {
        @(Get-Content -LiteralPath $modListPath | Where-Object { $_ -ceq ('+' + [string]$output.modName) })
    }
    else { @() }
    if (@($enabledLines).Count -ne 1) { $errors.Add('The runtime-output mod is not enabled exactly once in the task profile.') }
    $providerResult = $null
    $backupProviderResult = $null
    $backupVerification = $null
    if (Test-Path -LiteralPath $modListPath -PathType Leaf) {
        try {
            $transactionTool = Resolve-MO2ShaderCacheTransactionTool
            $providerJson = & $transactionTool providers -ProfilePath $modListPath -ModsPath $modsRoot -RelativeCachePath 'ShaderCache' -DeepInventory:$RequirePreparedCache -IncludeInventoryEntries:$RequirePreparedCache -NoExit -Confirm:$false
            $providerResult = ConvertFrom-MO2JsonText ([string]$providerJson)
            $winner = $providerResult.data.effectiveWinnerAmongEnabledMods
            if (-not $providerResult.ok -or $null -eq $winner -or
                [string]$winner.modName -cne [string]$output.modName -or
                -not (Test-MO2SamePath ([string]$winner.cachePath) $expectedCachePath)) {
                $observed = if ($null -eq $winner) { '<none>' } else { [string]$winner.modName }
                $errors.Add("The task runtime-output mod is not the effective enabled ShaderCache provider; observed '$observed'.")
            }
        }
        catch { $errors.Add("Could not verify the current ShaderCache provider: $($_.Exception.Message)") }
        try {
            if ([string]::IsNullOrWhiteSpace([string]$transactionTool)) { $transactionTool = Resolve-MO2ShaderCacheTransactionTool }
            $backupProviderJson = & $transactionTool providers -ProfilePath $modListPath -ModsPath $modsRoot -RelativeCachePath 'backup' -DeepInventory -IncludeInventoryEntries -NoExit -Confirm:$false
            $backupProviderResult = ConvertFrom-MO2JsonText ([string]$backupProviderJson)
            $backupVerification = Get-MO2PreparedBackupShadowVerification `
                -Output $output -ProviderResult $backupProviderResult -ProfilePath $modListPath `
                -OutputModName ([string]$output.modName) -BackupPath $expectedBackupPath `
                -AllowPreparedCacheGrowth:$AllowPreparedCacheGrowth
            foreach ($backupError in @($backupVerification.errors)) { $errors.Add([string]$backupError) }
        }
        catch {
            $message = "Could not verify the current backup provider shadow: $($_.Exception.Message)"
            $errors.Add($message)
            $backupVerification = [pscustomobject][ordered]@{ ok = $false; errors = @($message) }
        }
    }

    $settingsPath = Join-Path $expectedProfilePath 'settings.ini'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        $errors.Add("Task profile settings do not exist: $settingsPath")
    }
    else {
        $settings = Read-MO2IniFile -Path $settingsPath
        $mappingMatches = if ($settings.Contains('custom_overwrites')) {
            @($settings['custom_overwrites'].Keys | Where-Object { [string]$_ -ceq $Executable })
        }
        else { @() }
        if (@($mappingMatches).Count -ne 1 -or [string]$settings['custom_overwrites'][$Executable] -cne [string]$output.modName) {
            $errors.Add("Task profile does not map executable '$Executable' to its owned runtime-output mod.")
        }
    }

    $planPath = Join-Path ([string]$output.cacheEvidenceDirectory) 'shader-cache-task.plan.json'
    $completionPath = Join-Path ([string]$output.cacheEvidenceDirectory) 'shader-cache-task.completion.json'
    $plan = $null
    $cacheVerification = $null
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        try { $plan = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $planPath -Raw -ErrorAction Stop) }
        catch { $errors.Add("Shader-cache plan is unreadable: $planPath. $($_.Exception.Message)") }
    }
    elseif ($RequirePreparedCache) {
        $errors.Add("Task launch requires the bound shader-cache prepare plan: $planPath")
    }

    if ($null -ne $plan) {
        $binding = if ($plan.PSObject.Properties['cacheBinding']) { $plan.cacheBinding } else { $null }
        $completionExists = Test-Path -LiteralPath $completionPath -PathType Leaf
        $completedPlanForRetirement = -not $RequirePreparedCache -and
            $completionExists -and [string]$plan.state -ceq 'restored'
        $planContractValid = $completedPlanForRetirement -or (
            [string]$plan.state -ceq 'prepared' -and
            $null -ne $binding -and
            [string]$binding.mode -ceq 'mo2-winning-loose-provider' -and
            (Test-MO2SamePath ([string]$binding.profilePath) $modListPath) -and
            (Test-MO2SamePath ([string]$binding.modsPath) $modsRoot) -and
            [string]$binding.modName -ceq [string]$output.modName -and
            (Test-MO2SamePath ([string]$binding.modRoot) $expectedModPath) -and
            (Test-MO2SamePath ([string]$binding.cachePath) $expectedCachePath) -and
            $null -ne $providerResult -and
            [string]$binding.profileSha256 -ceq [string]$providerResult.data.profileSha256 -and
            [bool]$plan.requireMaterializedOutput
        )
        if (-not $planContractValid) {
            $errors.Add('Shader-cache plan is not prepared with the exact task profile, winning output mod, and RequireMaterializedOutput contract.')
        }
        elseif ($RequirePreparedCache) {
            try {
                $cacheVerification = Get-MO2PreparedCacheShadowVerification `
                    -Plan $plan -ProviderResult $providerResult -ProfilePath $modListPath `
                    -CacheModName ([string]$output.modName) -CachePath $expectedCachePath `
                    -EvidenceDirectory ([string]$output.cacheEvidenceDirectory) `
                    -AllowPreparedCacheGrowth:$AllowPreparedCacheGrowth
                foreach ($cacheError in @($cacheVerification.errors)) { $errors.Add([string]$cacheError) }
            }
            catch {
                $message = "Could not verify the prepared task cache and provider shadow: $($_.Exception.Message)"
                $errors.Add($message)
                $cacheVerification = [pscustomobject][ordered]@{ ok = $false; errors = @($message) }
            }
        }
        if ($RequirePreparedCache -and $completionExists) {
            $errors.Add('The task shader-cache transaction is already complete and cannot authorize another launch.')
        }
    }

    return [pscustomobject][ordered]@{
        applicable = $true; ok = $errors.Count -eq 0; profile = $Profile
        executable = $Executable; workspace = $owned; runtimeOutput = $output
        cachePlan = [pscustomobject][ordered]@{
            required = [bool]$RequirePreparedCache; path = $planPath
            exists = Test-Path -LiteralPath $planPath -PathType Leaf
            completionPath = $completionPath
            completed = Test-Path -LiteralPath $completionPath -PathType Leaf
            verification = $cacheVerification
        }
        backupVerification = $backupVerification
        checks = @($checks); errors = @($errors)
    }
}

function Get-MO2SelectedTaskWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [AllowNull()][string]$Profile
    )

    if ([string]::IsNullOrWhiteSpace($Profile) -or
        -not $Profile.StartsWith('Codex Task - ', [StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{
            applicable = $false; profile = $Profile; identified = $false
            legacy = $false; recoverable = $false; runtimeOutputMode = $null; errors = @()
        }
    }

    $errors = [Collections.Generic.List[string]]::new()
    $stagingRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)))
    $workspaceRoot = Join-Path $stagingRoot 'workspaces'
    $matches = @()
    if (Test-Path -LiteralPath $workspaceRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $workspaceRoot -Filter '*.json' -File -ErrorAction Stop)) {
            if (-not [regex]::IsMatch($file.BaseName, '^[a-z0-9][a-z0-9-]*$')) { continue }
            try {
                $candidate = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop)
                $candidateProfile = if ($candidate.PSObject.Properties['profileName']) {
                    [string]$candidate.profileName
                }
                else { [string]$candidate.profile }
                if ($candidateProfile -ceq $Profile) {
                    $matches += [pscustomobject]@{ path = $file.FullName; data = $candidate }
                }
            }
            catch {
                $errors.Add("Workspace manifest is unreadable: $($file.FullName). $($_.Exception.Message)")
            }
        }
    }

    if ($matches.Count -ne 1) {
        $errors.Add("Expected exactly one workspace manifest for selected task profile '$Profile'; found $($matches.Count).")
        return [pscustomobject][ordered]@{
            applicable = $true; profile = $Profile; identified = $false
            legacy = $true; recoverable = $false; manifestPath = $null
            workspaceId = $null; contractVersion = $null; status = $null
            sourceProfile = $null; profilePath = $null; hasRuntimeOutput = $false; runtimeOutputMode = $null
            errors = @($errors)
        }
    }

    $owned = $matches[0]
    $manifest = $owned.data
    $workspaceId = [string]$manifest.workspaceId
    $hasRuntimeOutput = $manifest.PSObject.Properties['runtimeOutput'] -and $null -ne $manifest.runtimeOutput
    $sourceProfile = [string]$manifest.sourceProfile
    $configuredSource = if ($Config.defaults.PSObject.Properties['testProfileSource']) {
        [string]$Config.defaults.testProfileSource
    }
    else { '' }
    $profilesRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)))
    $expectedProfilePath = Join-Path $profilesRoot $Profile
    $profilePath = if ($manifest.PSObject.Properties['profileDirectory']) {
        [string]$manifest.profileDirectory
    }
    else { [string]$manifest.profilePath }
    $sourcePath = if ([string]::IsNullOrWhiteSpace($configuredSource)) { $null } else { Join-Path $profilesRoot $configuredSource }
    $manifestSourcePath = if ($manifest.PSObject.Properties['sourceProfilePath']) {
        [string]$manifest.sourceProfilePath
    }
    else { '' }
    $expectedManifestPath = if ($workspaceId -match '^[a-z0-9-]+$') {
        Join-Path $workspaceRoot ($workspaceId + '.json')
    }
    else { $null }
    $recoverable = (
        $errors.Count -eq 0 -and
        -not $hasRuntimeOutput -and
        -not [string]::IsNullOrWhiteSpace($expectedManifestPath) -and
        (Test-MO2SamePath ([string]$owned.path) $expectedManifestPath) -and
        $Profile -ceq ('Codex Task - ' + $workspaceId) -and
        $sourceProfile -ceq $configuredSource -and
        (Test-MO2SamePath $profilePath $expectedProfilePath) -and
        -not [string]::IsNullOrWhiteSpace($sourcePath) -and
        (Test-MO2SamePath $manifestSourcePath $sourcePath) -and
        (Test-Path -LiteralPath $expectedProfilePath -PathType Container) -and
        (Test-Path -LiteralPath $sourcePath -PathType Container)
    )

    return [pscustomobject][ordered]@{
        applicable = $true; profile = $Profile; identified = $true
        legacy = -not $hasRuntimeOutput; recoverable = $recoverable
        manifestPath = [string]$owned.path; workspaceId = $workspaceId
        contractVersion = [string]$manifest.contractVersion; status = [string]$manifest.status
        sourceProfile = $sourceProfile; profilePath = $profilePath
        hasRuntimeOutput = [bool]$hasRuntimeOutput
        runtimeOutputMode = $(if ($hasRuntimeOutput -and $manifest.runtimeOutput.PSObject.Properties['mode']) { [string]$manifest.runtimeOutput.mode } else { $null })
        errors = @($errors)
    }
}

function New-MO2SelectedTaskWorkspaceCheck {
    param([Parameter(Mandatory)]$SelectedTaskWorkspace)

    if (-not $SelectedTaskWorkspace.applicable) { return $null }
    if (-not $SelectedTaskWorkspace.identified) {
        return New-MO2Check -Name 'selected-task-workspace' -Status 'warn' -Message (
            "MO2 selects task profile '$($SelectedTaskWorkspace.profile)', but its exact workspace ownership could not be identified. Do not launch it."
        ) -Details $SelectedTaskWorkspace
    }
    if ($SelectedTaskWorkspace.legacy) {
        return New-MO2Check -Name 'selected-task-workspace' -Status 'warn' -Message (
            "MO2 selects legacy task profile '$($SelectedTaskWorkspace.profile)' without runtime-output isolation. Do not launch it; use workspace recover-legacy-selection after MO2 and Skyrim are closed."
        ) -Details $SelectedTaskWorkspace
    }
    return New-MO2Check -Name 'selected-task-workspace' -Status 'info' -Message (
        "MO2 selects task profile '$($SelectedTaskWorkspace.profile)' with a declared runtime-output contract; prepare and launch perform the full isolation check."
    ) -Details $SelectedTaskWorkspace
}

function ConvertFrom-MO2ByteArrayValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -match '^@ByteArray\((.*)\)$') {
        return $Matches[1]
    }

    return $Value
}

function ConvertTo-MO2WindowsPath {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $path = $Value -replace '/', '\'
    # MO2's INI serializer may retain escaped backslashes. They are accepted by
    # Windows, but canonical paths make comparisons and diagnostics reliable.
    return ($path -replace '\\{2,}', '\')
}

function Find-MO2IniValue {
    param(
        [Parameter(Mandatory)]$Ini,
        [Parameter(Mandatory)][string]$Key
    )

    foreach ($section in $Ini.Keys) {
        if ($Ini[$section].Contains($Key)) {
            return $Ini[$section][$Key]
        }
    }

    return $null
}

function Get-MO2ExecutableCapabilities {
    param([AllowNull()][string]$Binary)

    if ([string]::IsNullOrWhiteSpace($Binary)) { return @() }
    $leaf = [IO.Path]::GetFileName($Binary)
    $capabilities = [Collections.Generic.List[string]]::new()
    if ($leaf -match '(?i)^skse(?:vr)?_loader\.exe$') { $capabilities.Add('skse-loader') }
    if ($leaf -ieq 'SkyrimVR.exe') { $capabilities.Add('plain-game') }
    return @($capabilities)
}

function Get-MO2RegisteredExecutables {
    param([Parameter(Mandatory)]$Ini)

    if (-not $Ini.Contains('customExecutables')) {
        return @()
    }

    $groups = [ordered]@{}
    foreach ($key in $Ini['customExecutables'].Keys) {
        if ($key -notmatch '^(\d+)\\(.+)$') {
            continue
        }

        # OrderedDictionary treats an integer key as a positional index. MO2's
        # executable group number is an identifier, so retain it as a string.
        $index = [string]$Matches[1]
        $field = $Matches[2]
        if (-not $groups.Contains($index)) {
            $groups[$index] = [ordered]@{}
        }
        $groups[$index][$field] = $Ini['customExecutables'][$key]
    }

    $records = @()
    foreach ($index in ($groups.Keys | Sort-Object)) {
        $entry = $groups[$index]
        $binary = if ($entry.Contains('binary')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['binary']) } else { $null }
        $records += [pscustomobject][ordered]@{
            index = [int]$index
            title = if ($entry.Contains('title')) { ConvertFrom-MO2ByteArrayValue $entry['title'] } else { $null }
            binary = $binary
            arguments = if ($entry.Contains('arguments')) { ConvertFrom-MO2ByteArrayValue $entry['arguments'] } else { $null }
            workingDirectory = if ($entry.Contains('workingDirectory')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['workingDirectory']) } else { $null }
            capabilities = @(Get-MO2ExecutableCapabilities -Binary $binary)
        }
    }

    return @($records)
}

function Get-MO2ExecutableModOwner {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Binary
    )

    $modsRoot = if ($Config.mo2.PSObject.Properties['modsDirectory']) {
        Resolve-MO2ControlPath ([string]$Config.mo2.modsDirectory)
    }
    else {
        Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.root)) 'mods'
    }
    $resolvedModsRoot = [IO.Path]::GetFullPath($modsRoot).TrimEnd('\')
    $resolvedBinary = [IO.Path]::GetFullPath($Binary)
    $prefix = $resolvedModsRoot + '\'
    if (-not $resolvedBinary.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{ managedByMod = $false; binary = $resolvedBinary; modsRoot = $resolvedModsRoot }
    }

    $relative = [IO.Path]::GetRelativePath($resolvedModsRoot, $resolvedBinary)
    $parts = @($relative -split '[\\/]', 2)
    $modName = $parts[0]
    $profilePath = Join-Path (Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) $Profile) 'modlist.txt'
    $ownerMarkers = @()
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $profilePath) {
            $lineNumber++
            if ($line -notmatch '^(?<marker>[+-])(?<name>.+)$') { continue }
            if ($Matches.name.TrimEnd("`r") -ceq $modName) {
                $ownerMarkers += [pscustomobject][ordered]@{ lineNumber = $lineNumber; marker = $Matches.marker; modName = $modName }
            }
        }
    }
    $state = if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        'profile-missing'
    }
    elseif ($ownerMarkers.Count -eq 0) {
        'missing'
    }
    elseif ($ownerMarkers.Count -gt 1) {
        'ambiguous'
    }
    elseif ($ownerMarkers[0].marker -eq '+') {
        'enabled'
    }
    else {
        'disabled'
    }
    return [pscustomobject][ordered]@{
        managedByMod = $true
        binary = $resolvedBinary
        modsRoot = $resolvedModsRoot
        relativeBinaryPath = $relative
        modName = $modName
        profilePath = $profilePath
        state = $state
        matches = @($ownerMarkers)
    }
}

function Get-MO2DirectoryPhysicalIdentity {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return [SkyrimVRAutomation.Native.DirectoryIdentity]::Get(
            [IO.Path]::GetFullPath($Path))
    }
    catch {
        throw "physical directory identity could not be proven: $($_.Exception.Message)"
    }
}

function Get-MO2ProfileRuntimeProviders {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Profile,
        [scriptblock]$IdentityResolver = ${function:Get-MO2DirectoryPhysicalIdentity}
    )

    $profilesRoot = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)).TrimEnd('\'))
    $modsRoot = if ($Config.mo2.PSObject.Properties['modsDirectory']) {
        [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.modsDirectory)).TrimEnd('\'))
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.root)) 'mods').TrimEnd('\'))
    }
    $modListPath = Join-Path (Join-Path $profilesRoot $Profile) 'modlist.txt'
    $records = @()
    $errors = @()
    $providerPaths = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $modListPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ profile = $Profile; modListPath = $modListPath; providers = @(); errors = @("Profile mod list does not exist: $modListPath") }
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $modListPath) {
        $lineNumber++
        if ($line -notmatch '^(?<marker>[+-])(?<name>.+)$') { continue }
        $modName = $Matches.name.TrimEnd("`r")
        try {
            $modPath = [IO.Path]::GetFullPath((Join-Path $modsRoot $modName))
            $directParent = [IO.Path]::GetDirectoryName($modPath)
            if (-not $modPath.StartsWith($modsRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($directParent, $modsRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'mod name does not resolve to one direct child of the configured mods directory'
            }
            $openVrApi = Join-Path $modPath 'root\openvr_api.dll'
            $openCompositeIni = Join-Path $modPath 'root\opencomposite.ini'
            $openCompositeInput = Join-Path $modPath 'SKSE\Plugins\OpenCompositeInput.dll'
            $hasOpenVrApi = Test-Path -LiteralPath $openVrApi -PathType Leaf
            $hasOpenCompositeIni = Test-Path -LiteralPath $openCompositeIni -PathType Leaf
            $hasOpenCompositeInput = Test-Path -LiteralPath $openCompositeInput -PathType Leaf
            if (-not ($hasOpenVrApi -or $hasOpenCompositeIni -or $hasOpenCompositeInput)) { continue }
            $modItem = Get-Item -LiteralPath $modPath -Force -ErrorAction Stop
            if (($modItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'runtime-provider mod directories must not be reparse points because physical identity cannot be proven'
            }
            $providerKey = & $IdentityResolver $modPath
            if ([string]::IsNullOrWhiteSpace([string]$providerKey)) {
                throw 'physical directory identity resolver returned no identity'
            }
            if ($providerPaths.ContainsKey($providerKey)) {
                throw "runtime-provider physical directory is repeated or contradicted by modlist line $($providerPaths[$providerKey])"
            }
            $providerPaths.Add($providerKey, $lineNumber)
            $classification = if ($hasOpenVrApi -and ($hasOpenCompositeIni -or $hasOpenCompositeInput)) { 'OCU' } else { 'unclassified-openvr-provider' }
            $records += [pscustomobject][ordered]@{
                classification = $classification; modName = $modName; modPath = $modPath
                lineNumber = $lineNumber; marker = $Matches.marker; enabled = $Matches.marker -eq '+'
                markers = [pscustomobject][ordered]@{
                    rootOpenVrApi = $hasOpenVrApi; rootOpenCompositeIni = $hasOpenCompositeIni
                    openCompositeInput = $hasOpenCompositeInput
                }
            }
        }
        catch { $errors += "modlist line $lineNumber ('$modName'): $($_.Exception.Message)" }
    }
    return [pscustomobject][ordered]@{ profile = $Profile; modListPath = $modListPath; providers = @($records); errors = @($errors) }
}

function Get-MO2ProcessRecords {
    param([string[]]$Names)

    $records = @()
    foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $parentId = $(try { [int](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop).ParentProcessId } catch { $null })
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                parentId = $parentId
                parentStartTime = $(try { (Get-Process -Id $parentId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $null })
                path = $(try { [IO.Path]::GetFullPath($process.Path) } catch { $null })
                startTime = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                cpuSeconds = $(try { [math]::Round($process.CPU, 3) } catch { $null })
                workingSetBytes = $(try { [long]$process.WorkingSet64 } catch { $null })
            }
        }
    }

    return @($records | Sort-Object name, id)
}

function ConvertTo-MO2CanonicalUtcTimestamp {
    param([Parameter(Mandatory)][string]$Value)

    $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $parsed.UtcDateTime.ToString('o')
}

function Test-MO2ProcessRecordIdentity {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    try {
        $expectedPath = [IO.Path]::GetFullPath([string]$Expected.path)
        $actualPath = [IO.Path]::GetFullPath([string]$Actual.path)
        $expectedStart = [DateTimeOffset]::Parse([string]$Expected.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $actualStart = [DateTimeOffset]::Parse([string]$Actual.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'process-identity-malformed'; detail = $_.Exception.Message }
    }
    $idMatches = [int]$Expected.id -eq [int]$Actual.id
    $nameMatches = [string]::Equals([string]$Expected.name, [string]$Actual.name, [StringComparison]::OrdinalIgnoreCase)
    $pathMatches = [string]::Equals($expectedPath, $actualPath, [StringComparison]::OrdinalIgnoreCase)
    $startMatches = [math]::Abs(($actualStart - $expectedStart).TotalMilliseconds) -lt 1.0
    return [pscustomobject][ordered]@{
        ok = $idMatches -and $nameMatches -and $pathMatches -and $startMatches
        reason = if (-not $idMatches) { 'process-id-mismatch' } elseif (-not $nameMatches) { 'process-name-mismatch' } elseif (-not $pathMatches) { 'process-path-mismatch' } elseif (-not $startMatches) { 'process-start-time-mismatch' } else { 'process-identity-matched' }
        expectedPath = $expectedPath; actualPath = $actualPath
        expectedStartTime = $expectedStart.ToString('o'); actualStartTime = $actualStart.ToString('o')
    }
}

function Get-MO2ExpectedGameProcessPaths {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned
    )

    try {
        $iniPath = Resolve-MO2ControlPath ([string]$Config.mo2.ini)
        $ini = Read-MO2IniFile -Path $iniPath
        $registered = @(Get-MO2RegisteredExecutables -Ini $ini | Where-Object { [string]$_.title -ceq [string]$Owned.data.executable })
        if ($registered.Count -ne 1) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'registered-executable-not-exact'; pathsByName = @{} }
        }
        $entry = $registered[0]
        $pathsByName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($configuredName in @($Config.mo2.gameProcessNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $name = [string]$configuredName
            $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $isRegisteredBinaryRole = -not [string]::IsNullOrWhiteSpace([string]$entry.binary) -and
                [string]::Equals([IO.Path]::GetFileNameWithoutExtension([string]$entry.binary), $name, [StringComparison]::OrdinalIgnoreCase)
            if ($isRegisteredBinaryRole) {
                $null = $paths.Add([IO.Path]::GetFullPath([string]$entry.binary))
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.workingDirectory)) {
                $null = $paths.Add([IO.Path]::GetFullPath((Join-Path ([string]$entry.workingDirectory) ($name + '.exe'))))
            }
            $pathsByName[$name] = $paths
        }
        return [pscustomobject][ordered]@{ ok = $true; reason = 'configured-game-paths-resolved'; pathsByName = $pathsByName; registeredExecutable = $entry }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'configured-game-paths-unavailable'; detail = $_.Exception.Message; pathsByName = @{} }
    }
}

function Get-MO2BoundedDirectoryStats {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaximumFiles
    )

    $result = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Container
        fileCount = 0
        bytes = [long]0
        truncated = $false
        errors = @()
    }

    if (-not $result.exists) {
        return [pscustomobject]$result
    }

    try {
        $enumerator = [System.IO.Directory]::EnumerateFiles(
            $Path,
            '*',
            [System.IO.SearchOption]::AllDirectories
        ).GetEnumerator()

        try {
            while ($enumerator.MoveNext()) {
                if ($result.fileCount -ge $MaximumFiles) {
                    $result.truncated = $true
                    break
                }

                $result.fileCount++
                try {
                    $result.bytes += [System.IO.FileInfo]::new($enumerator.Current).Length
                }
                catch {
                    $result.errors += "Could not stat '$($enumerator.Current)': $($_.Exception.Message)"
                }
            }
        }
        finally {
            if ($enumerator -is [System.IDisposable]) {
                $enumerator.Dispose()
            }
        }
    }
    catch {
        $result.errors += $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-MO2OverwriteShaderCacheRecords {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaximumFiles
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    $matches = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction Stop | Where-Object { $_.Name -match '^(?i:ShaderCache)(?:[.]|$)' } | Sort-Object FullName)
    $roots = @()
    foreach ($match in $matches) {
        if (@($roots | Where-Object { $match.FullName.StartsWith($_.path + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        $stats = Get-MO2BoundedDirectoryStats -Path $match.FullName -MaximumFiles $MaximumFiles
        $role = switch -Regex ($match.Name) {
            '^(?i:ShaderCache)$' { 'active'; break }
            '^(?i:ShaderCache[.]Previous)$' { 'rollback'; break }
            '^(?i:ShaderCache[.]Swap)$' { 'temporary-swap'; break }
            default { 'legacy-other' }
        }
        $ageHours = [math]::Round(([DateTime]::UtcNow - $match.LastWriteTimeUtc).TotalHours, 2)
        $roots += [pscustomobject][ordered]@{
            name = $match.Name; role = $role; relativePath = [IO.Path]::GetRelativePath($Path, $match.FullName)
            path = $match.FullName; fileCount = $stats.fileCount; bytes = $stats.bytes
            truncated = $stats.truncated; errors = @($stats.errors); lastWriteTimeUtc = $match.LastWriteTimeUtc.ToString('o')
            ageHours = $ageHours; stale = $role -eq 'temporary-swap' -and $ageHours -ge 1
        }
    }
    return @($roots)
}

function Get-MO2JsonRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Archived = $false
    )

    $record = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        archived = $Archived
        valid = $false
        bytes = $null
        lastWriteTimeUtc = $null
        error = $null
    }

    if (-not $record.exists) {
        $record.error = 'File does not exist.'
        return [pscustomobject]$record
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $record.bytes = [long]$item.Length
    $record.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')

    if ($Archived) {
        $record.valid = $null
        return [pscustomobject]$record
    }

    try {
        $null = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $record.valid = $true
    }
    catch {
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function Get-MO2RootBuilderRecords {
    param([Parameter(Mandatory)]$Config)

    $active = @()
    $archived = @()

    foreach ($pathValue in @($Config.mo2.rootBuilderDefinitions)) {
        $path = Resolve-MO2ControlPath ([string]$pathValue)
        $active += Get-MO2JsonRecord -Path $path
    }

    $dataRoot = Resolve-MO2ControlPath ([string]$Config.mo2.rootBuilderDataDirectory)
    if (Test-Path -LiteralPath $dataRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '(?i)\.corrupt-') {
                $archived += Get-MO2JsonRecord -Path $file.FullName -Archived $true
            }
            elseif ($file.Name -in @('BuildData.json', 'GameData.json', 'VersionManifest.json')) {
                $active += Get-MO2JsonRecord -Path $file.FullName
            }
        }
    }

    return [pscustomobject][ordered]@{
        dataDirectory = $dataRoot
        active = @($active)
        archived = @($archived)
    }
}

function Get-MO2StorageRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $qualifier = Split-Path -Qualifier $resolved
    $driveRoot = if ($qualifier) { "$qualifier\" } else { $null }

    return [pscustomobject][ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Container
        drive = $qualifier
        driveAvailable = if ($driveRoot) { Test-Path -LiteralPath $driveRoot -PathType Container } else { $false }
    }
}

function Get-MO2SessionLockRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $record = [ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Leaf
        valid = $null
        ownerPid = $null
        ownerRunning = $false
        ownerIdentityMatched = $false
        ownerIdentityEvidenceComplete = $false
        ownerStartTimeMatched = $null
        ownerPathMatched = $null
        sessionId = $null
        accessId = $null
        leaseId = $null
        acquisitionMode = $null
        status = $null
        data = $null
        error = $null
    }

    if (-not $record.exists) {
        return [pscustomobject]$record
    }

    try {
        $data = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop)
        $record.valid = $true
        $record.data = $data
        if ($data.PSObject.Properties['ownerPid']) {
            $record.ownerPid = [int]$data.ownerPid
            $ownerProcess = Get-Process -Id $record.ownerPid -ErrorAction SilentlyContinue
            if ($null -ne $ownerProcess) {
                $startTimeEvidencePresent = $data.PSObject.Properties['processStartTime'] -and -not [string]::IsNullOrWhiteSpace([string]$data.processStartTime)
                $pathEvidencePresent = $data.PSObject.Properties['processPath'] -and -not [string]::IsNullOrWhiteSpace([string]$data.processPath)
                $identityMatched = $true
                if ($startTimeEvidencePresent) {
                    try {
                        $expectedStart = [DateTimeOffset]::Parse([string]$data.processStartTime, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                        $actualStart = $ownerProcess.StartTime.ToUniversalTime()
                        $record.ownerStartTimeMatched = [math]::Abs(($actualStart - $expectedStart).TotalMilliseconds) -lt 1.0
                        $identityMatched = $identityMatched -and [bool]$record.ownerStartTimeMatched
                    }
                    catch {
                        $record.ownerStartTimeMatched = $false
                        $identityMatched = $false
                    }
                }
                if ($pathEvidencePresent) {
                    try {
                        $expectedPath = [IO.Path]::GetFullPath([string]$data.processPath)
                        $actualPath = [IO.Path]::GetFullPath([string]$ownerProcess.Path)
                        $record.ownerPathMatched = [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)
                        $identityMatched = $identityMatched -and [bool]$record.ownerPathMatched
                    }
                    catch {
                        $record.ownerPathMatched = $false
                        $identityMatched = $false
                    }
                }
                $record.ownerIdentityEvidenceComplete = [bool]$startTimeEvidencePresent -and [bool]$pathEvidencePresent
                # Pre-identity locks remain readable, but do not prove authority over a live process.
                $record.ownerIdentityMatched = $record.ownerIdentityEvidenceComplete -and $identityMatched
                $record.ownerRunning = $record.ownerIdentityMatched
            }
        }
        if ($data.PSObject.Properties['sessionId']) {
            $record.sessionId = [string]$data.sessionId
        }
        if ($data.PSObject.Properties['accessId']) {
            $record.accessId = [string]$data.accessId
        }
        if ($data.PSObject.Properties['leaseId']) {
            $record.leaseId = [string]$data.leaseId
        }
        if ($data.PSObject.Properties['acquisitionMode']) {
            $record.acquisitionMode = [string]$data.acquisitionMode
        }
        if ($data.PSObject.Properties['status']) {
            $record.status = [string]$data.status
        }
    }
    catch {
        $record.valid = $false
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function New-MO2Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        $Details = $null
    )

    return [pscustomobject][ordered]@{
        name = $Name
        status = $Status
        message = $Message
        details = $Details
    }
}

function Get-MO2InspectionData {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedProfile,
        [string]$RequestedExecutable
    )

    $mo2Root = Resolve-MO2ControlPath ([string]$Config.mo2.root)
    $mo2Exe = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    $mo2Ini = Resolve-MO2ControlPath ([string]$Config.mo2.ini)
    $profilesRoot = Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)
    $overwriteRoot = Resolve-MO2ControlPath ([string]$Config.mo2.overwriteDirectory)

    $ini = if (Test-Path -LiteralPath $mo2Ini -PathType Leaf) { Read-MO2IniFile -Path $mo2Ini } else { [ordered]@{} }
    $selectedProfile = if ($ini.Count -gt 0) { ConvertFrom-MO2ByteArrayValue (Find-MO2IniValue -Ini $ini -Key 'selected_profile') } else { $null }
    $selectedTaskWorkspace = Get-MO2SelectedTaskWorkspace -Config $Config -Profile $selectedProfile
    $profiles = if (Test-Path -LiteralPath $profilesRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction Stop | Sort-Object Name | ForEach-Object Name)
    }
    else {
        @()
    }
    $executables = if ($ini.Count -gt 0) { @(Get-MO2RegisteredExecutables -Ini $ini) } else { @() }

    $profile = if ([string]::IsNullOrWhiteSpace($RequestedProfile)) { [string]$Config.defaults.profile } else { $RequestedProfile }
    $executable = if ([string]::IsNullOrWhiteSpace($RequestedExecutable)) { [string]$Config.defaults.executable } else { $RequestedExecutable }

    $mo2Processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
    $gameProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.gameProcessNames))
    $runtimeProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.runtimeProcessNames))

    $overwrite = Get-MO2BoundedDirectoryStats -Path $overwriteRoot -MaximumFiles ([int]$Config.limits.maxEnumeratedFiles)
    $overwrite | Add-Member -NotePropertyName shaderCaches -NotePropertyValue @(Get-MO2OverwriteShaderCacheRecords -Path $overwriteRoot -MaximumFiles ([int]$Config.limits.maxEnumeratedFiles))

    return [pscustomobject][ordered]@{
        machine = [string]$Config.machine
        config = [pscustomobject][ordered]@{
            inputContractVersion = [string]$Config.contractVersion
            mo2Root = $mo2Root
            mo2Executable = $mo2Exe
            mo2Ini = $mo2Ini
            profilesDirectory = $profilesRoot
        }
        requested = [pscustomobject][ordered]@{
            profile = $profile
            executable = $executable
        }
        selectedProfile = $selectedProfile
        selectedTaskWorkspace = $selectedTaskWorkspace
        profiles = @($profiles)
        executables = @($executables)
        processes = [pscustomobject][ordered]@{
            mo2 = @($mo2Processes)
            game = @($gameProcesses)
            runtime = @($runtimeProcesses)
        }
        overwrite = $overwrite
        rootBuilder = Get-MO2RootBuilderRecords -Config $Config
        runtimeProviders = Get-MO2ProfileRuntimeProviders -Config $Config -Profile $profile
        storage = [pscustomobject][ordered]@{
            staging = Get-MO2StorageRecord -Path ([string]$Config.storage.sessionStaging)
            archive = Get-MO2StorageRecord -Path ([string]$Config.storage.archive)
        }
        sessionLock = Get-MO2SessionLockRecord -Path ([string]$Config.session.lockFile)
    }
}

function ConvertTo-MO2Result {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Checks,
        [Parameter(Mandatory)]$Data,
        [string]$PreferredState
    )

    $errors = @($Checks | Where-Object status -eq 'fail' | ForEach-Object message)
    $warnings = @($Checks | Where-Object status -eq 'warn' | ForEach-Object message)
    $ok = $errors.Count -eq 0

    if (-not [string]::IsNullOrWhiteSpace($PreferredState)) {
        $state = $PreferredState
    }
    elseif (-not $ok) {
        $state = 'blocked'
    }
    elseif ($Data.processes.game.Count -gt 0) {
        $state = 'game-running'
    }
    elseif ($Data.processes.mo2.Count -gt 0) {
        $state = 'mo2-running'
    }
    elseif ($warnings.Count -gt 0) {
        $state = 'degraded'
    }
    else {
        $state = 'ready'
    }

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = $Command
        ok = $ok
        state = $state
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @($Checks)
        warnings = @($warnings)
        errors = @($errors)
        data = $Data
    }
}

function Invoke-MO2Inspect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()

    $checks += New-MO2Check -Name 'mo2-root' -Status $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'MO2 root exists.' } else { "MO2 root does not exist: $($data.config.mo2Root)" })
    $checks += New-MO2Check -Name 'mo2-executable' -Status $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'MO2 executable exists.' } else { "MO2 executable does not exist: $($data.config.mo2Executable)" })
    $checks += New-MO2Check -Name 'mo2-ini' -Status $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'MO2 INI exists and was read.' } else { "MO2 INI does not exist: $($data.config.mo2Ini)" })
    $checks += New-MO2Check -Name 'process-state' -Status 'info' -Message "MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count), runtime=$($data.processes.runtime.Count)."
    $selectedTaskWorkspaceCheck = New-MO2SelectedTaskWorkspaceCheck -SelectedTaskWorkspace $data.selectedTaskWorkspace
    if ($null -ne $selectedTaskWorkspaceCheck) { $checks += $selectedTaskWorkspaceCheck }
    $overwriteNeedsAttention = (
        $data.overwrite.errors.Count -gt 0 -or
        $data.overwrite.shaderCaches.Count -gt 0 -or
        $data.overwrite.truncated -or
        $data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or
        $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes
    )
    $checks += New-MO2Check -Name 'overwrite-scan' -Status $(if ($overwriteNeedsAttention) { 'warn' } else { 'pass' }) -Message $(
        if ($data.overwrite.errors.Count -gt 0) { 'Overwrite inspection completed with filesystem errors.' }
        elseif ($data.overwrite.shaderCaches.Count -gt 0) { "Overwrite contains $($data.overwrite.shaderCaches.Count) ShaderCache tree(s); task launch requires an exact workspace output transaction." }
        elseif ($data.overwrite.truncated) { "Overwrite inspection stopped at the configured limit of $($Config.limits.maxEnumeratedFiles) files." }
        elseif ($overwriteNeedsAttention) { "Overwrite needs attention: $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
        else { "Overwrite contains $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
    ) -Details $data.overwrite

    return ConvertTo-MO2Result -Config $Config -Command 'inspect' -Checks $checks -Data $data
}

function Invoke-MO2Validate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [switch]$RequireSKSE,
        [switch]$RequireClosed,
        [switch]$RequireRuntimeRoute,
        [string]$OwnedSessionId,
        [string]$OwnedAccessId
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()
    $requestedTaskWorkspace = Get-MO2SelectedTaskWorkspace -Config $Config -Profile ([string]$data.requested.profile)
    $overwriteIsTaskOutput = $requestedTaskWorkspace.identified -and [string]$requestedTaskWorkspace.runtimeOutputMode -ceq 'mo2-overwrite-output'

    foreach ($pathCheck in @(
        @{ Name = 'mo2-root'; Path = $data.config.mo2Root; Type = 'Container' },
        @{ Name = 'mo2-executable'; Path = $data.config.mo2Executable; Type = 'Leaf' },
        @{ Name = 'mo2-ini'; Path = $data.config.mo2Ini; Type = 'Leaf' },
        @{ Name = 'profiles-directory'; Path = $data.config.profilesDirectory; Type = 'Container' }
    )) {
        $exists = Test-Path -LiteralPath $pathCheck.Path -PathType $pathCheck.Type
        $checks += New-MO2Check -Name $pathCheck.Name -Status $(if ($exists) { 'pass' } else { 'fail' }) -Message $(if ($exists) { "$($pathCheck.Name) exists." } else { "$($pathCheck.Name) is missing: $($pathCheck.Path)" })
    }

    $profileExists = $data.profiles -contains $data.requested.profile
    $checks += New-MO2Check -Name 'requested-profile' -Status $(if ($profileExists) { 'pass' } else { 'fail' }) -Message $(if ($profileExists) { "Exact profile exists: $($data.requested.profile)" } else { "Exact profile does not exist: $($data.requested.profile). No fallback is permitted." }) -Details @{ availableProfiles = $data.profiles }

    if ($profileExists -and $data.selectedProfile -ne $data.requested.profile) {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'warn' -Message "MO2 currently selects '$($data.selectedProfile)', not requested '$($data.requested.profile)'."
    }
    else {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'pass' -Message "MO2 selected profile matches the request: $($data.requested.profile)"
    }

    $selectedTaskWorkspaceCheck = New-MO2SelectedTaskWorkspaceCheck -SelectedTaskWorkspace $data.selectedTaskWorkspace
    if ($null -ne $selectedTaskWorkspaceCheck) { $checks += $selectedTaskWorkspaceCheck }

    $registered = @($data.executables | Where-Object title -eq $data.requested.executable)
    if ($registered.Count -eq 1) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'pass' -Message "Registered executable exists exactly once: $($data.requested.executable)" -Details $registered[0]
        $binaryExists = -not [string]::IsNullOrWhiteSpace($registered[0].binary) -and (Test-Path -LiteralPath $registered[0].binary -PathType Leaf)
        $checks += New-MO2Check -Name 'registered-binary' -Status $(if ($binaryExists) { 'pass' } else { 'fail' }) -Message $(if ($binaryExists) { "Registered binary exists: $($registered[0].binary)" } else { "Registered binary is missing: $($registered[0].binary)" })
        if ($binaryExists) {
            if ($RequireSKSE) {
                $hasSKSE = @($registered[0].capabilities) -contains 'skse-loader'
                $checks += New-MO2Check -Name 'required-skse-loader' -Status $(if ($hasSKSE) { 'pass' } else { 'fail' }) -Message $(
                    if ($hasSKSE) { "Registered executable is an SKSE loader: $($registered[0].binary)" }
                    else { "DevBench/SKSE-required workflow refused non-SKSE executable: $($registered[0].binary)" }
                ) -Details @{ requiredCapability = 'skse-loader'; observedCapabilities = @($registered[0].capabilities) }
            }
            $owner = Get-MO2ExecutableModOwner -Config $Config -Profile $data.requested.profile -Binary $registered[0].binary
            if ($owner.managedByMod) {
                $ownerEnabled = $owner.state -eq 'enabled'
                $checks += New-MO2Check -Name 'registered-binary-owner-mod' -Status $(if ($ownerEnabled) { 'pass' } else { 'fail' }) -Message $(
                    if ($ownerEnabled) { "Registered binary owner mod is enabled in the exact profile: $($owner.modName)" }
                    else { "Registered binary owner mod '$($owner.modName)' is $($owner.state) in profile '$($data.requested.profile)'." }
                ) -Details $owner
            }
            else {
                $checks += New-MO2Check -Name 'registered-binary-owner-mod' -Status 'info' -Message 'Registered binary is outside the MO2 mods directory; no profile marker applies.' -Details $owner
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($registered[0].workingDirectory)) {
            $workingExists = Test-Path -LiteralPath $registered[0].workingDirectory -PathType Container
            $checks += New-MO2Check -Name 'registered-working-directory' -Status $(if ($workingExists) { 'pass' } else { 'fail' }) -Message $(if ($workingExists) { "Registered working directory exists: $($registered[0].workingDirectory)" } else { "Registered working directory is missing: $($registered[0].workingDirectory)" })
        }
    }
    elseif ($registered.Count -eq 0) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable does not exist: $($data.requested.executable)" -Details @{ availableExecutables = @($data.executables.title) }
    }
    else {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable is ambiguous ($($registered.Count) matches): $($data.requested.executable)"
    }

    $invalidJson = @($data.rootBuilder.active | Where-Object { -not $_.exists -or $_.valid -ne $true })
    $checks += New-MO2Check -Name 'rootbuilder-json' -Status $(if ($invalidJson.Count -eq 0) { 'pass' } else { 'fail' }) -Message $(if ($invalidJson.Count -eq 0) { "All $($data.rootBuilder.active.Count) active RootBuilder JSON files parse successfully." } else { "$($invalidJson.Count) active RootBuilder JSON file(s) are missing or invalid." }) -Details $invalidJson
    if ($data.rootBuilder.archived.Count -gt 0) {
        $checks += New-MO2Check -Name 'rootbuilder-archives' -Status 'warn' -Message "$($data.rootBuilder.archived.Count) quarantined RootBuilder JSON artifact(s) are retained as diagnostic evidence; they are not active state." -Details $data.rootBuilder.archived
    }

    if (-not $data.overwrite.exists) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite directory does not exist: $($data.overwrite.path)"
    }
    elseif ($data.overwrite.errors.Count -gt 0) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message 'MO2 overwrite inspection encountered filesystem errors.' -Details $data.overwrite
    }
    elseif ($data.overwrite.shaderCaches.Count -gt 0) {
        $checks += New-MO2Check -Name 'overwrite' -Status $(if ($overwriteIsTaskOutput) { 'pass' } else { 'fail' }) -Message $(
            if ($overwriteIsTaskOutput) { "MO2 Overwrite ShaderCache is declared task output; prepare and launch verify its exact owner, profile binding, provider union, and transaction." }
            else { "MO2 Overwrite contains ShaderCache trees without a requested task-workspace output contract. Run workspace prepare-source before creating a task workspace: $($data.overwrite.shaderCaches.relativePath -join ', ')." }
        ) -Details $data.overwrite
    }
    elseif ($data.overwrite.truncated -or $data.overwrite.fileCount -ge [int]$Config.limits.overwriteBlockFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteBlockBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite exceeds or cannot be proven below the automation safety limit: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes), truncated=$($data.overwrite.truncated)." -Details $data.overwrite
    }
    elseif ($data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'warn' -Message "MO2 overwrite is above the warning threshold: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }
    else {
        $checks += New-MO2Check -Name 'overwrite' -Status 'pass' -Message "MO2 overwrite is below automation thresholds: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }

    foreach ($storageName in @('staging', 'archive')) {
        $record = $data.storage.$storageName
        if ($record.exists) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'pass' -Message "Storage directory exists: $($record.path)"
        }
        elseif ($record.driveAvailable) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'warn' -Message "Storage drive is available but the directory has not been created: $($record.path)"
        }
        else {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'fail' -Message "Storage drive is unavailable: $($record.path)"
        }
    }

    if ($data.sessionLock.exists -and $data.sessionLock.valid -and -not [string]::IsNullOrWhiteSpace($OwnedSessionId) -and $data.sessionLock.sessionId -eq $OwnedSessionId) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message "The requested control session owns the lock: $OwnedSessionId" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists -and $data.sessionLock.valid -and -not [string]::IsNullOrWhiteSpace($OwnedAccessId) -and $data.sessionLock.accessId -eq $OwnedAccessId) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message "The requested access lease owns the lock: $OwnedAccessId" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists -and $data.sessionLock.valid) {
        $lockOwner = if (Test-MO2HasAccessLease -Lock $data.sessionLock) { "access lease $($data.sessionLock.leaseId)" } else { "session $($data.sessionLock.sessionId)" }
        $checks += New-MO2Check -Name 'session-lock' -Status 'fail' -Message "Another MO2 control $lockOwner owns the lock." -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'warn' -Message 'A stale or invalid session lock exists and requires documented recovery before mutation.' -Details $data.sessionLock
    }
    else {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message 'No active MO2 control session lock exists.'
    }

    if ($RequireRuntimeRoute) {
        $persistedRuntimeRoute = if ($data.sessionLock.exists -and $data.sessionLock.valid -and $data.sessionLock.data.PSObject.Properties['runtimeRoute']) { $data.sessionLock.data.runtimeRoute } else { $null }
        $runtimeRoute = $null
        $runtimeRouteError = $null
        try {
            $runtimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $persistedRuntimeRoute
        }
        catch {
            $runtimeRouteError = $_.Exception.Message
        }
        if ($runtimeRouteError) {
            $details = [pscustomobject][ordered]@{ runtimeRoute = $persistedRuntimeRoute; inventory = $data.runtimeProviders; error = $runtimeRouteError }
            $checks += New-MO2Check -Name 'runtime-route-provider' -Status 'fail' -Message "Runtime-route qualification failed: $runtimeRouteError" -Details $details
        }
        elseif ($data.runtimeProviders.errors.Count -gt 0) {
            $checks += New-MO2Check -Name 'runtime-route-provider' -Status 'fail' -Message 'Runtime-provider discovery could not prove the exact profile state.' -Details $data.runtimeProviders
        }
        else {
            $enabledProviders = @($data.runtimeProviders.providers | Where-Object enabled)
            $enabledOpenVrReplacements = @($enabledProviders | Where-Object { $_.markers.rootOpenVrApi })
            $enabledOcu = @($enabledProviders | Where-Object classification -eq 'OCU')
            $routeId = [string]$runtimeRoute.id
            $providerValid = if ($routeId -eq 'OCU') {
                $enabledOcu.Count -eq 1 -and $enabledOpenVrReplacements.Count -eq 1
            }
            else {
                $enabledOpenVrReplacements.Count -eq 0
            }
            $message = if ($providerValid -and $routeId -eq 'OCU') {
                "The exact profile enables one qualified OCU provider: $($enabledOcu[0].modName)"
            }
            elseif ($providerValid) {
                "The exact profile has no enabled OpenVR replacement for the $routeId route."
            }
            elseif ($routeId -eq 'OCU') {
                "The OCU route requires exactly one enabled OCU provider and no additional root OpenVR replacement; observed OCU=$($enabledOcu.Count), root OpenVR replacements=$($enabledOpenVrReplacements.Count)."
            }
            else {
                "The $routeId route is incompatible with enabled profile-local OpenVR replacement providers: $($enabledOpenVrReplacements.modName -join ', ')."
            }
            $details = [pscustomobject][ordered]@{ runtimeRoute = $runtimeRoute; inventory = $data.runtimeProviders }
            $checks += New-MO2Check -Name 'runtime-route-provider' -Status $(if ($providerValid) { 'pass' } else { 'fail' }) -Message $message -Details $details
        }
    }
    else {
        $checks += New-MO2Check -Name 'runtime-route-provider' -Status 'info' -Message 'Runtime-route provider qualification was not requested.' -Details $data.runtimeProviders
    }

    if ($RequireClosed) {
        $closed = $data.processes.mo2.Count -eq 0 -and $data.processes.game.Count -eq 0
        $checks += New-MO2Check -Name 'closed-state' -Status $(if ($closed) { 'pass' } else { 'fail' }) -Message $(if ($closed) { 'MO2 and game processes are closed.' } else { 'MO2 or the game is running; closed-state validation failed.' }) -Details $data.processes
    }
    else {
        $checks += New-MO2Check -Name 'closed-state' -Status 'info' -Message "Closed state was not required. MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count)."
    }

    return ConvertTo-MO2Result -Config $Config -Command 'validate' -Checks $checks -Data $data
}

function ConvertTo-MO2SafeLabel {
    param([Parameter(Mandatory)][string]$Label)

    $safe = ($Label.Trim() -replace '[^A-Za-z0-9._-]+', '-') -replace '-{2,}', '-'
    $safe = $safe.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'automation'
    }
    if ($safe.Length -gt 48) {
        return $safe.Substring(0, 48)
    }
    return $safe
}

function ConvertTo-MO2CommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Write-MO2JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$CreateNew
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 16
    $encoding = [System.Text.UTF8Encoding]::new($false)
    if ($CreateNew) {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($stream, $encoding)
            try { $writer.Write($json) } finally { $writer.Dispose() }
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
        return
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, $json, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-WithMO2LeaseTransitionLock {
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [AllowEmptyCollection()][object[]]$ArgumentList = @(),
        [ValidateRange(100, 60000)][int]$TimeoutMilliseconds = 10000
    )

    $resolvedLockPath = Resolve-MO2ControlPath $LockPath
    $transitionPath = "$resolvedLockPath.transition.lock"
    $parent = Split-Path -Parent $transitionPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [System.IO.File]::Open(
                $transitionPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for the MO2 lease transition lock: $transitionPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }

    try {
        return & $Action @ArgumentList
    }
    finally {
        $stream.Dispose()
    }
}

function Get-MO2NextLeaseGeneration {
    param($Lease)

    $current = 0L
    if ($null -ne $Lease -and $Lease.PSObject.Properties['generation']) {
        $current = [long]$Lease.generation
    }
    return $current + 1L
}

function Write-MO2SessionManifestProjection {
    param([Parameter(Mandatory)]$SessionData)

    if (-not $SessionData.PSObject.Properties['sessionPath'] -or
        [string]::IsNullOrWhiteSpace([string]$SessionData.sessionPath)) { return }
    $manifestPath = Join-Path ([string]$SessionData.sessionPath) 'session.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The bound session manifest does not exist: $manifestPath"
    }

    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop)
    foreach ($property in @($SessionData.PSObject.Properties)) {
        $manifest | Add-Member -NotePropertyName ([string]$property.Name) -NotePropertyValue $property.Value -Force
    }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
}

function Assert-MO2OwnedSessionTransitionCurrent {
    param([Parameter(Mandatory)]$Owned)

    $sessionId = [string]$Owned.sessionId
    $current = Get-MO2SessionLockRecord -Path ([string]$Owned.path)
    if (-not $current.valid -or $current.sessionId -ne $sessionId -or $current.accessId -ne [string]$Owned.accessId) {
        throw "Session '$sessionId' no longer owns the MO2 lease transition."
    }
    $expectedGeneration = if ($Owned.data.PSObject.Properties['generation']) { [long]$Owned.data.generation } else { 0L }
    $currentGeneration = if ($current.data.PSObject.Properties['generation']) { [long]$current.data.generation } else { 0L }
    if ($currentGeneration -ne $expectedGeneration) {
        throw "Session '$sessionId' lease transition is stale: expected generation $expectedGeneration, current generation $currentGeneration."
    }
    return $current
}

function Write-MO2OwnedSessionUnderTransitionLock {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Value,
        [scriptblock]$ManifestProjectionAction
    )

    $updated = $Value
    foreach ($propertyName in @('contractVersion', 'accessId', 'leaseId', 'acquisitionMode', 'accessKind', 'label', 'requestedUtc', 'lastRenewedUtc', 'estimatedDurationMinutes', 'estimatedReleaseUtc', 'ownerRequestPid', 'ownerRequestStartTime', 'runtimeRoute')) {
        if ($Current.data.PSObject.Properties[$propertyName]) {
            $updated | Add-Member -NotePropertyName $propertyName -NotePropertyValue $Current.data.$propertyName -Force
        }
    }
    $updated | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $Current.data) -Force
    Write-MO2JsonAtomic -Path ([string]$Owned.path) -Value $updated
    $Owned.data = $updated
    try {
        if ($ManifestProjectionAction) { & $ManifestProjectionAction $updated }
        else { Write-MO2SessionManifestProjection -SessionData $updated }
    }
    catch {
        throw "The authoritative MO2 ownership lock committed generation $($updated.generation), but its session manifest projection failed and must be reconciled from that lock: $($_.Exception.Message)"
    }
    return Get-MO2SessionLockRecord -Path ([string]$Owned.path)
}

function Write-MO2OwnedSessionAtomic {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Value,
        [scriptblock]$ManifestProjectionAction
    )

    $sessionId = [string]$Owned.sessionId
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'A session-bound lease is required for an owned session update.'
    }

    $updatedRecord = Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action {
        $current = Assert-MO2OwnedSessionTransitionCurrent -Owned $Owned
        return Write-MO2OwnedSessionUnderTransitionLock -Owned $Owned -Current $current -Value $Value -ManifestProjectionAction $ManifestProjectionAction
    }
    $Owned.data = $updatedRecord.data
    return $updatedRecord
}

function Invoke-MO2OwnedSessionMutation {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $lockedMutation = {
        param($CurrentOwned, $MutationAction)
        $current = Assert-MO2OwnedSessionTransitionCurrent -Owned $CurrentOwned
        $outcome = & $MutationAction $current.data
        if ($null -eq $outcome -or -not $outcome.PSObject.Properties['sessionData']) {
            throw 'The serialized MO2 mutation did not return sessionData.'
        }
        $commit = -not $outcome.PSObject.Properties['commit'] -or [bool]$outcome.commit
        $record = if ($commit) { Write-MO2OwnedSessionUnderTransitionLock -Owned $CurrentOwned -Current $current -Value $outcome.sessionData } else { $current }
        return [pscustomobject][ordered]@{ record = $record; result = $outcome.result }
    }
    $transaction = Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action $lockedMutation -ArgumentList @($Owned, $Action)
    $Owned.data = $transaction.record.data
    return $transaction.result
}

function New-MO2DurableSessionController {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionPath,
        [switch]$WhatIf
    )
    $controllerDirectory = Join-Path $SessionPath 'controller'
    $entryPath = Join-Path $controllerDirectory 'Invoke-MO2Control.ps1'
    $configDirectory = Join-Path $controllerDirectory 'config'
    $configPath = Join-Path $configDirectory 'machine.local.json'
    $receiptPath = Join-Path $controllerDirectory 'controller-bundle.json'
    $sourceFiles = @(
        [pscustomobject]@{ source = (Join-Path $PSScriptRoot 'Invoke-MO2Control.ps1'); relativePath = 'Invoke-MO2Control.ps1' },
        [pscustomobject]@{ source = (Join-Path $PSScriptRoot 'ConfigResolution.psm1'); relativePath = 'ConfigResolution.psm1' },
        [pscustomobject]@{ source = (Join-Path $PSScriptRoot 'MO2Control.psm1'); relativePath = 'MO2Control.psm1' },
        [pscustomobject]@{ source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'); relativePath = 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1' },
        [pscustomobject]@{ source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'shader-cache-control\ShaderCacheInventory.ps1'); relativePath = 'shader-cache-control\ShaderCacheInventory.ps1' }
    )
    if ($WhatIf) {
        return [pscustomobject][ordered]@{ controllerPath = $entryPath; configPath = $configPath; receiptPath = $receiptPath; durable = $true; wouldCopy = @($sourceFiles | ForEach-Object relativePath) }
    }
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $files = @()
    foreach ($sourceFile in $sourceFiles) {
        $source = [string]$sourceFile.source
        $target = Join-Path $controllerDirectory ([string]$sourceFile.relativePath)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "MO2 session controller source is missing: $source" }
        $targetDirectory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) { New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null }
        Copy-Item -LiteralPath $source -Destination $target
        $files += [pscustomobject][ordered]@{ name = [string]$sourceFile.relativePath; path = $target; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
    }
    Write-MO2JsonAtomic -Path $configPath -Value $Config -CreateNew
    $files += [pscustomobject][ordered]@{ name = 'config/machine.local.json'; path = $configPath; sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash }
    Write-MO2JsonAtomic -Path $receiptPath -Value ([pscustomobject][ordered]@{
        contractVersion = '1.0.0'; createdUtc = [DateTime]::UtcNow.ToString('o'); durable = $true
        purpose = 'Session-scoped lifecycle controller retained independently of the versioned Codex plugin cache.'
        controllerPath = $entryPath; configPath = $configPath; files = $files
    }) -CreateNew
    return [pscustomobject][ordered]@{ controllerPath = $entryPath; configPath = $configPath; receiptPath = $receiptPath; durable = $true; files = $files }
}

function Get-MO2OwnedSession {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'SessionId is required for this command.'
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $lock = Get-MO2SessionLockRecord -Path $lockPath
    if (-not $lock.exists) {
        throw "No MO2 control session lock exists: $lockPath"
    }
    if (-not $lock.valid) {
        throw "The MO2 control session lock is invalid: $($lock.error)"
    }
    if ($lock.sessionId -ne $SessionId) {
        throw "Session '$SessionId' does not own the active lock '$($lock.sessionId)'."
    }
    if (-not $lock.data.PSObject.Properties['sessionPath'] -or -not (Test-Path -LiteralPath ([string]$lock.data.sessionPath) -PathType Container)) {
        throw 'The active lock does not reference an existing session directory.'
    }
    return $lock
}

function New-MO2ActionResult {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Data,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $cleanWarnings = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $cleanErrors = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = $cleanWarnings
        errors = $cleanErrors
        data = $Data
    }
}

function Test-MO2HasAccessLease {
    param([Parameter(Mandatory)]$Lock)

    return -not [string]::IsNullOrWhiteSpace([string]$Lock.leaseId) -or
        -not [string]::IsNullOrWhiteSpace([string]$Lock.accessId) -or
        ($Lock.data -and $Lock.data.PSObject.Properties['accessCredentialSha256'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Lock.data.accessCredentialSha256))
}

function Resolve-MO2RuntimeRouteContract {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OCU', 'SteamVR', 'SteamVRNull')]
        [string]$RuntimeRoute
    )

    switch ($RuntimeRoute) {
        'OCU' {
            return [pscustomobject][ordered]@{
                id = 'OCU'
                runtimeFamily = 'OpenComposite'
                hmdMode = 'live'
                requiresSteamVR = $false
                requiresNullHmd = $false
                incompatibleWith = @('SteamVR', 'SteamVRNull')
            }
        }
        'SteamVR' {
            return [pscustomobject][ordered]@{
                id = 'SteamVR'
                runtimeFamily = 'SteamVR'
                hmdMode = 'live'
                requiresSteamVR = $true
                requiresNullHmd = $false
                incompatibleWith = @('OCU', 'SteamVRNull')
            }
        }
        'SteamVRNull' {
            return [pscustomobject][ordered]@{
                id = 'SteamVRNull'
                runtimeFamily = 'SteamVR'
                hmdMode = 'null'
                requiresSteamVR = $true
                requiresNullHmd = $true
                incompatibleWith = @('OCU', 'SteamVR')
            }
        }
    }
}

function Resolve-MO2PersistedRuntimeRouteContract {
    param([Parameter(Mandatory)]$RuntimeRoute)

    $requiredProperties = @('id', 'runtimeFamily', 'hmdMode', 'requiresSteamVR', 'requiresNullHmd', 'incompatibleWith')
    foreach ($propertyName in $requiredProperties) {
        if (-not $RuntimeRoute.PSObject.Properties[$propertyName]) {
            throw "Persisted runtime route is missing required property '$propertyName'."
        }
    }

    $routeId = [string]$RuntimeRoute.id
    if ($routeId -cnotin @('OCU', 'SteamVR', 'SteamVRNull')) {
        throw "Persisted runtime route id '$routeId' is not supported."
    }
    if ($RuntimeRoute.requiresSteamVR -isnot [bool] -or $RuntimeRoute.requiresNullHmd -isnot [bool]) {
        throw 'Persisted runtime-route boolean properties must be JSON booleans.'
    }

    $canonical = Resolve-MO2RuntimeRouteContract -RuntimeRoute $routeId
    foreach ($propertyName in @('id', 'runtimeFamily', 'hmdMode', 'requiresSteamVR', 'requiresNullHmd')) {
        if ($RuntimeRoute.$propertyName -cne $canonical.$propertyName) {
            throw "Persisted runtime route property '$propertyName' does not match the canonical '$routeId' contract."
        }
    }
    $persistedIncompatible = @($RuntimeRoute.incompatibleWith)
    $canonicalIncompatible = @($canonical.incompatibleWith)
    if ($persistedIncompatible.Count -ne $canonicalIncompatible.Count -or
        [string]::Join("`n", $persistedIncompatible) -cne [string]::Join("`n", $canonicalIncompatible)) {
        throw "Persisted runtime route property 'incompatibleWith' does not match the canonical '$routeId' contract."
    }
    return $canonical
}

function Get-MO2RuntimeRouteContractFingerprint {
    param([Parameter(Mandatory)]$RuntimeRoute)

    $canonical = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $RuntimeRoute
    return [string]::Join('|', @(
        [string]$canonical.id,
        [string]$canonical.runtimeFamily,
        [string]$canonical.hmdMode,
        [string][bool]$canonical.requiresSteamVR,
        [string][bool]$canonical.requiresNullHmd,
        [string]::Join(',', @($canonical.incompatibleWith))))
}

function Get-MO2AccessLeaseSummary {
    param([Parameter(Mandatory)]$Lock)

    if (-not $Lock.exists) {
        return [pscustomobject][ordered]@{
            state = 'available'
            lockPath = $Lock.path
            leaseId = $null
            sessionId = $null
            label = $null
            estimatedReleaseUtc = $null
            estimateOverdue = $false
        }
    }
    if (-not $Lock.valid) {
        return [pscustomobject][ordered]@{
            state = 'invalid-lock'
            lockPath = $Lock.path
            leaseId = $null
            sessionId = $null
            label = $null
            estimatedReleaseUtc = $null
            estimateOverdue = $false
            error = $Lock.error
        }
    }

    $estimatedReleaseUtc = if ($Lock.data.PSObject.Properties['estimatedReleaseUtc']) { [string]$Lock.data.estimatedReleaseUtc } else { $null }
    $estimateOverdue = $false
    if (-not [string]::IsNullOrWhiteSpace($estimatedReleaseUtc)) {
        try {
            $estimateOverdue = [DateTimeOffset]::Parse($estimatedReleaseUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime -lt [DateTime]::UtcNow
        }
        catch {
            $estimateOverdue = $false
        }
    }

    return [pscustomobject][ordered]@{
        state = $(if ([string]::IsNullOrWhiteSpace([string]$Lock.sessionId)) { 'access-held' } else { 'session-held' })
        lockPath = $Lock.path
        leaseId = $(if (-not [string]::IsNullOrWhiteSpace([string]$Lock.leaseId)) { $Lock.leaseId } else { 'legacy-access-lease' })
        sessionId = $Lock.sessionId
        label = $(if ($Lock.data.PSObject.Properties['label']) { [string]$Lock.data.label } else { $null })
        ownerTaskId = $(if ($Lock.data.PSObject.Properties['ownerTaskId']) { [string]$Lock.data.ownerTaskId } else { $null })
        accessKind = $(if ($Lock.data.PSObject.Properties['accessKind']) { [string]$Lock.data.accessKind } else { 'automation' })
        profile = $(if ($Lock.data.PSObject.Properties['profile']) { [string]$Lock.data.profile } else { $null })
        acquisitionMode = $Lock.acquisitionMode
        requestedUtc = $(if ($Lock.data.PSObject.Properties['requestedUtc']) { [string]$Lock.data.requestedUtc } else { $null })
        lastRenewedUtc = $(if ($Lock.data.PSObject.Properties['lastRenewedUtc']) { [string]$Lock.data.lastRenewedUtc } else { $null })
        estimatedDurationMinutes = $(if ($Lock.data.PSObject.Properties['estimatedDurationMinutes']) { $Lock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $estimatedReleaseUtc
        estimateOverdue = $estimateOverdue
        ownerRequestPid = $(if ($Lock.data.PSObject.Properties['ownerRequestPid']) { $Lock.data.ownerRequestPid } else { $null })
        ownerRequestStartTime = $(if ($Lock.data.PSObject.Properties['ownerRequestStartTime']) { [string]$Lock.data.ownerRequestStartTime } else { $null })
        runtimeRoute = $(if ($Lock.data.PSObject.Properties['runtimeRoute']) { $Lock.data.runtimeRoute } else { $null })
        generation = $(if ($Lock.data.PSObject.Properties['generation']) { [long]$Lock.data.generation } else { 0L })
    }
}

function Get-MO2OwnedAccessLease {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId
    )

    if ([string]::IsNullOrWhiteSpace($AccessId)) {
        throw 'AccessId is required for this command.'
    }
    $lock = Get-MO2SessionLockRecord -Path (Resolve-MO2ControlPath ([string]$Config.session.lockFile))
    if (-not $lock.exists) {
        throw "No MO2 access lock exists: $($lock.path)"
    }
    if (-not $lock.valid) {
        throw "The MO2 access lock is invalid: $($lock.error)"
    }
    if (-not (Test-MO2HasAccessLease -Lock $lock)) {
        throw 'The active lock predates cooperative access leases and must be completed through its exact SessionId.'
    }
    if ($lock.accessId -ne $AccessId) {
        throw "The supplied access credential does not own lease '$($lock.leaseId)'."
    }
    return $lock
}

function Resolve-MO2CallerTaskId {
    param(
        [string]$TaskId,
        [string]$Purpose = 'This operation'
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_TASK_ID)) { $env:CODEX_TASK_ID } else { $null }
    }
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        throw "$Purpose requires the exact recipient TaskId; pass -TaskId or run from a Codex task with CODEX_THREAD_ID/CODEX_TASK_ID."
    }
    if ($TaskId.Length -gt 256 -or $TaskId -match '[\r\n]') {
        throw 'TaskId is malformed.'
    }
    return $TaskId
}

function Test-MO2PrivateCredential {
    param(
        [AllowNull()][string]$ExpectedHash,
        [AllowNull()][string]$Supplied
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash) -or [string]::IsNullOrWhiteSpace($Supplied)) { return $false }
    $encoding = [Text.Encoding]::UTF8
    $expectedBytes = [Convert]::FromHexString($ExpectedHash)
    $suppliedBytes = [Security.Cryptography.SHA256]::HashData($encoding.GetBytes($Supplied))
    if ($expectedBytes.Length -ne $suppliedBytes.Length) { return $false }
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedBytes, $suppliedBytes)
}

function Invoke-MO2RequestAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Label = 'automation',
        [string]$TaskId,
        [ValidateSet('automation', 'human')]
        [string]$AccessKind = 'automation',
        [string]$Profile,
        [ValidateSet('OCU', 'SteamVR', 'SteamVRNull')]
        [string]$RuntimeRoute,
        [Nullable[int]]$EstimatedMinutes,
        [ValidateRange(0, 600)][int]$WaitSeconds = 0,
        [switch]$WhatIf
    )

    if ($null -ne $EstimatedMinutes -and ($EstimatedMinutes -lt 1 -or $EstimatedMinutes -gt 1440)) {
        throw 'EstimatedMinutes must be between 1 and 1440 when supplied.'
    }
    if ($AccessKind -eq 'automation' -and [string]::IsNullOrWhiteSpace($RuntimeRoute)) {
        throw 'Automation access requires exactly one RuntimeRoute: OCU, SteamVR, or SteamVRNull.'
    }
    if ($AccessKind -eq 'human' -and -not [string]::IsNullOrWhiteSpace($RuntimeRoute)) {
        throw 'Human access reserves MO2/Skyrim independent of runtime route; do not supply RuntimeRoute.'
    }
    if ($AccessKind -eq 'human') {
        $TaskId = Resolve-MO2CallerTaskId -TaskId $TaskId -Purpose 'Human access delegation'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TaskId) -and ($TaskId.Length -gt 256 -or $TaskId -match '[\r\n]')) {
        throw 'TaskId is malformed.'
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $now = [DateTime]::UtcNow
    $accessId = 'access-{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $leaseId = 'lease-{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $humanMutationId = if ($AccessKind -eq 'human') { 'human-mutation-{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N')) } else { $null }
    $humanMutationHash = if ($AccessKind -eq 'human') { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($humanMutationId))) } else { $null }
    $estimatedReleaseUtc = if ($null -ne $EstimatedMinutes) { $now.AddMinutes([int]$EstimatedMinutes).ToString('o') } else { $null }
    $runtimeRouteContract = if ($AccessKind -eq 'automation') { Resolve-MO2RuntimeRouteContract -RuntimeRoute $RuntimeRoute } else { $null }
    $leaseProfile = $null
    if ($AccessKind -eq 'human') {
        $inspection = Get-MO2InspectionData -Config $Config
        $leaseProfile = if ([string]::IsNullOrWhiteSpace($Profile)) { [string]$inspection.selectedProfile } else { [string]$Profile }
        if ([string]::IsNullOrWhiteSpace($leaseProfile) -or @($inspection.profiles | Where-Object { $_ -ceq $leaseProfile }).Count -ne 1) {
            throw "Human access requires one exact existing profile; requested '$leaseProfile'."
        }
        if ([string]$inspection.selectedProfile -cne $leaseProfile) {
            throw "Human access profile '$leaseProfile' is not MO2's exact selected profile '$($inspection.selectedProfile)'."
        }
    }
    $lease = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $accessId
        leaseId = $leaseId
        acquisitionMode = 'explicit-access'
        accessKind = $AccessKind
        status = 'access-held'
        label = $safeLabel
        ownerTaskId = $TaskId
        humanMutationHash = $humanMutationHash
        humanMutationTaskId = $(if ($AccessKind -eq 'human') { $TaskId } else { $null })
        requestedUtc = $now.ToString('o')
        lastRenewedUtc = $now.ToString('o')
        estimatedDurationMinutes = $EstimatedMinutes
        estimatedReleaseUtc = $estimatedReleaseUtc
        ownerRequestPid = $PID
        ownerRequestStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        runtimeRoute = $runtimeRouteContract
        profile = $leaseProfile
        generation = 1L
        sessionId = $null
        sessionPath = $null
    }
    $accessGrant = $lease | Select-Object * -ExcludeProperty humanMutationHash
    if ($AccessKind -eq 'human') {
        $accessGrant | Add-Member -NotePropertyName humanMutationId -NotePropertyValue $humanMutationId
    }

    $existing = Get-MO2SessionLockRecord -Path $lockPath
    if ($WhatIf) {
        $available = -not $existing.exists
        return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $available -State $(if ($available) { 'dry-run' } else { 'access-busy' }) -Data @{ access = $accessGrant; current = Get-MO2AccessLeaseSummary -Lock $existing; requestedRuntimeRoute = $runtimeRouteContract; waitSeconds = $WaitSeconds; wouldCreateLock = $available; estimateIsAdvisory = $true } -Errors $(if ($available) { @() } else { @('MO2 access is already held. The estimate never expires or transfers ownership automatically.') })
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $started = [DateTime]::UtcNow
    while ($true) {
        $attempt = Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
            $current = Get-MO2SessionLockRecord -Path $lockPath
            if ($current.exists) {
                return [pscustomobject]@{ acquired = $false; current = $current }
            }
            Write-MO2JsonAtomic -Path $lockPath -Value $lease -CreateNew
            return [pscustomobject]@{ acquired = $true; current = $null }
        }
        if ($attempt.acquired) {
            return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $true -State 'access-acquired' -Data @{ access = $accessGrant; lockPath = $lockPath; waitedSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3); estimateIsAdvisory = $true }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $false -State 'access-busy' -Data @{ current = Get-MO2AccessLeaseSummary -Lock $attempt.current; requestedRuntimeRoute = $runtimeRouteContract; waitedSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3); requestedWaitSeconds = $WaitSeconds; retryable = $true; estimateIsAdvisory = $true } -Errors @('MO2 access is already held. Retry later or explicitly recover an abandoned lease; an overdue estimate does not unlock it.')
        }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-MO2AccessStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$AccessId
    )

    $lock = Get-MO2SessionLockRecord -Path (Resolve-MO2ControlPath ([string]$Config.session.lockFile))
    $summary = Get-MO2AccessLeaseSummary -Lock $lock
    if (-not $lock.exists) {
        return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $true -State 'available' -Data @{ access = $summary }
    }
    if (-not $lock.valid) {
        return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $false -State 'invalid-lock' -Data @{ access = $summary } -Errors @('The lock is invalid and requires explicit classification before recovery.')
    }
    $owned = -not [string]::IsNullOrWhiteSpace($AccessId) -and $lock.accessId -eq $AccessId
    $state = if ($owned) { 'access-owned' } elseif (-not (Test-MO2HasAccessLease -Lock $lock)) { 'legacy-session-held' } else { 'access-busy' }
    return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $true -State $state -Data @{ access = $summary; credentialSupplied = -not [string]::IsNullOrWhiteSpace($AccessId); owned = $owned; estimateIsAdvisory = $true }
}

function Invoke-MO2RenewAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [Nullable[int]]$EstimatedMinutes,
        [switch]$WhatIf
    )

    if ($null -ne $EstimatedMinutes -and ($EstimatedMinutes -lt 1 -or $EstimatedMinutes -gt 1440)) {
        throw 'EstimatedMinutes must be between 1 and 1440 when supplied.'
    }
    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'renew-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldGeneration = (Get-MO2NextLeaseGeneration -Lease $owned.data); estimateIsAdvisory = $true }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        $updated = $current.data
        $now = [DateTime]::UtcNow
        $updated | Add-Member -NotePropertyName lastRenewedUtc -NotePropertyValue ($now.ToString('o')) -Force
        if ($null -ne $EstimatedMinutes) {
            $updated | Add-Member -NotePropertyName estimatedDurationMinutes -NotePropertyValue $EstimatedMinutes -Force
            $updated | Add-Member -NotePropertyName estimatedReleaseUtc -NotePropertyValue ($now.AddMinutes([int]$EstimatedMinutes).ToString('o')) -Force
        }
        $updated | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $updated) -Force
        Write-MO2JsonAtomic -Path $current.path -Value $updated
        try {
            Write-MO2SessionManifestProjection -SessionData $updated
        }
        catch {
            throw "The authoritative MO2 ownership lock committed generation $($updated.generation), but its session manifest projection failed and must be reconciled from that lock: $($_.Exception.Message)"
        }
        return New-MO2ActionResult -Config $Config -Command 'renew-access' -Ok $true -State 'access-renewed' -Data @{ access = Get-MO2AccessLeaseSummary -Lock (Get-MO2SessionLockRecord -Path $current.path); estimateIsAdvisory = $true }
    }
}

function Invoke-MO2ReleaseAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if (-not [string]::IsNullOrWhiteSpace([string]$owned.sessionId)) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'session-release-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned } -Errors @('The access lease still has a bound session. Stop MO2/the game and release that exact SessionId first.')
    }
    $inspection = Get-MO2InspectionData -Config $Config
    $accessKind = if ($owned.data.PSObject.Properties['accessKind']) { [string]$owned.data.accessKind } else { 'automation' }
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($accessKind -ne 'human' -and ($inspection.processes.mo2.Count -gt 0 -or $inspection.processes.game.Count -gt 0 -or $activeBuildData.Count -gt 0)) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; processes = $inspection.processes; activeBuildData = $activeBuildData } -Errors @('Access cannot be released while MO2, the game, or a RootBuilder deployment transaction remains active.')
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldRemoveLock = $true; liveStateRetained = $accessKind -eq 'human'; processes = $inspection.processes; activeBuildData = $activeBuildData }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$current.sessionId)) {
            return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'session-release-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $current } -Errors @('The access lease acquired a session before release; release that exact SessionId first.')
        }
        Remove-Item -LiteralPath $current.path -Force
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $true -State 'access-released' -Data @{ accessId = $AccessId; leaseId = $current.leaseId; accessKind = $accessKind; lockPath = $current.path; lockRemoved = $true; liveStateRetained = $accessKind -eq 'human'; processes = $inspection.processes; activeBuildData = $activeBuildData }
    }
}

function Invoke-MO2RecoverAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [string]$Label = 'abandoned-access-recovery',
        [switch]$ConfirmAbandoned,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if (-not $ConfirmAbandoned) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $false -State 'confirmation-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; requiredSwitch = 'ConfirmAbandoned' } -Errors @('Recovery never infers abandonment from an elapsed estimate. Supply -ConfirmAbandoned only after classifying the owning task as abandoned.')
    }
    $inspection = Get-MO2InspectionData -Config $Config
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($inspection.processes.mo2.Count -gt 0 -or $inspection.processes.game.Count -gt 0 -or $activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; processes = $inspection.processes; activeBuildData = $activeBuildData } -Errors @('Abandoned access recovery requires closed MO2/game state and no active RootBuilder deployment transaction.')
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldRemoveLock = $true; wouldMarkSessionAbandoned = -not [string]::IsNullOrWhiteSpace([string]$owned.sessionId) }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$current.sessionId) -and -not [string]::IsNullOrWhiteSpace([string]$current.data.sessionPath)) {
            $manifestPath = Join-Path ([string]$current.data.sessionPath) 'session.json'
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
                $manifest.status = 'abandoned'
                $manifest | Add-Member -NotePropertyName abandonedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                $manifest | Add-Member -NotePropertyName abandonmentReason -NotePropertyValue (ConvertTo-MO2SafeLabel $Label) -Force
                Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
            }
        }
        Remove-Item -LiteralPath $current.path -Force
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $true -State 'access-recovered' -Data @{ accessId = $AccessId; lockPath = $current.path; lockRemoved = $true; reason = ConvertTo-MO2SafeLabel $Label }
    }
}

function Test-MO2ExactProcessPath {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$Record.path)) {
        return $false
    }
    return [string]::Equals(
        [IO.Path]::GetFullPath([string]$Record.path).TrimEnd('\'),
        [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Initialize-MO2UiAutomation {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-MO2NativeWindowAccess {
    if ('MO2Control.NativeWindows' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace MO2Control {
    public static class NativeWindows {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maximum);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maximum);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        public static IntPtr[] GetTopLevelWindows(int processId) {
            var windows = new List<IntPtr>();
            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner == (uint)processId) windows.Add(hWnd);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        public static string GetTitle(IntPtr hWnd) {
            var value = new StringBuilder(2048);
            GetWindowText(hWnd, value, value.Capacity);
            return value.ToString();
        }

        public static string GetClass(IntPtr hWnd) {
            var value = new StringBuilder(512);
            GetClassName(hWnd, value, value.Capacity);
            return value.ToString();
        }

        public static bool IsVisible(IntPtr hWnd) { return IsWindowVisible(hWnd); }
        public static bool RequestClose(IntPtr hWnd) { return PostMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero); }
        public static bool HasInteractiveShell() { return GetShellWindow() != IntPtr.Zero; }
    }
}
'@
}

function Test-MO2InteractiveDesktop {
    Initialize-MO2NativeWindowAccess
    return [MO2Control.NativeWindows]::HasInteractiveShell()
}

function Get-MO2NativeWindows {
    param([Parameter(Mandatory)][int]$ProcessId)

    Initialize-MO2NativeWindowAccess
    $records = @()
    foreach ($handle in @([MO2Control.NativeWindows]::GetTopLevelWindows($ProcessId))) {
        $records += [pscustomobject][ordered]@{
            processId = $ProcessId
            handle = [int64]$handle
            title = [MO2Control.NativeWindows]::GetTitle($handle)
            className = [MO2Control.NativeWindows]::GetClass($handle)
            visible = [MO2Control.NativeWindows]::IsVisible($handle)
        }
    }
    return @($records)
}

function Get-MO2AutomationWindows {
    param([Parameter(Mandatory)][int]$ProcessId)

    if (-not (Initialize-MO2UiAutomation)) {
        return @()
    }
    $windows = @()
    foreach ($record in @(Get-MO2NativeWindows -ProcessId $ProcessId | Where-Object visible)) {
        try {
            $windows += [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$record.handle)
        }
        catch {
            # Native window inventory remains available even when a provider does
            # not expose this particular Qt window to UI Automation.
        }
    }
    return @($windows)
}

function Get-MO2UnlockButtons {
    param([Parameter(Mandatory)]$Window)

    return @(Get-MO2NamedButtons -Window $Window -Name 'Unlock')
}

function Invoke-MO2UiAutomationFindAll {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Scope,
        [Parameter(Mandatory)]$Condition,
        [ValidateRange(1, 3)][int]$MaxAttempts = 2,
        [ValidateRange(0, 1000)][int]$RetryDelayMilliseconds = 100
    )

    $failures = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return @($Window.FindAll($Scope, $Condition))
        }
        catch {
            $failures.Add("attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -lt $MaxAttempts -and $RetryDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
            }
        }
    }
    throw "UI Automation descendant enumeration failed after $MaxAttempts bounded attempts: $($failures -join '; ')"
}

function Get-MO2NamedButtons {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Name
    )

    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name,
        [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
    )
    $condition = [System.Windows.Automation.AndCondition]::new($buttonCondition, $nameCondition)
    return @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)
}

function Get-MO2WindowTextElements {
    param([Parameter(Mandatory)]$Window)

    $condition = [System.Windows.Automation.OrCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text
        ),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document
        )
    )
    $values = [Collections.Generic.List[string]]::new()
    foreach ($element in @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)) {
        $name = ConvertTo-MO2ControlName ([string]$element.Current.Name)
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $values.Contains($name)) {
            $values.Add($(if ($name.Length -gt 512) { $name.Substring(0, 512) } else { $name }))
        }
        if ($values.Count -ge 32) { break }
    }
    return @($values)
}

function Get-MO2KnownDialogKind {
    param(
        [AllowNull()][string]$Title,
        [AllowEmptyCollection()][string[]]$Texts = @(),
        [AllowEmptyCollection()][object[]]$Buttons = @()
    )
    $buttonNames = @($Buttons | ForEach-Object {
        if ($_ -is [string]) { ConvertTo-MO2ControlName ([string]$_) }
        elseif ($_.PSObject.Properties['name']) { ConvertTo-MO2ControlName ([string]$_.name) }
        else { '' }
    })
    if (@($buttonNames | Where-Object { $_ -ieq 'Unlock' }).Count -eq 1) { return 'unlock-required' }
    $combined = ((@($Title) + @($Texts)) -join "`n")
    if ($combined -match '(?i)preparing\s+(?:the\s+)?(?:vfs|virtual file system)' -and @($buttonNames | Where-Object { $_ -ieq 'Cancel' }).Count -eq 1) { return 'preparing-vfs' }
    if ($combined -match '(?i)failed to write settings') { return 'failed-to-write-settings' }
    if ($combined -match '(?i)failed to (run|start|launch)') { return 'failed-to-run' }
    return $null
}

function Get-MO2NamedMenuItems {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Name
    )

    $menuCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::MenuItem
    )
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name,
        [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
    )
    $condition = [System.Windows.Automation.AndCondition]::new($menuCondition, $nameCondition)
    return @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)
}

function Expand-MO2AutomationMenu {
    param([Parameter(Mandatory)]$MenuItem)

    $pattern = $null
    if ($MenuItem.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.ExpandCollapsePattern]$pattern).Expand()
        return $true
    }
    return $false
}

function ConvertTo-MO2ControlName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    return (($Name -replace '&', '').Trim() -replace '\s+', ' ')
}

function Get-MO2WindowSnapshot {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes)

    $records = @()
    foreach ($processRecord in $Processes) {
        $automationByHandle = @{}
        foreach ($window in @(Get-MO2AutomationWindows -ProcessId ([int]$processRecord.id))) {
            $automationByHandle[[string][int64]$window.Current.NativeWindowHandle] = $window
        }
        foreach ($native in @(Get-MO2NativeWindows -ProcessId ([int]$processRecord.id))) {
            $buttons = @()
            $texts = @()
            $window = $automationByHandle[[string][int64]$native.handle]
            $automationId = $(if ($window) { [string]$window.Current.AutomationId } else { $null })
            if ($window -and $native.visible -and $automationId -ine 'MainWindow') {
                $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button
                )
                foreach ($button in @(Invoke-MO2UiAutomationFindAll -Window $window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $buttonCondition)) {
                    $buttons += [pscustomobject][ordered]@{
                        name = ConvertTo-MO2ControlName ([string]$button.Current.Name)
                        automationId = [string]$button.Current.AutomationId
                        enabled = [bool]$button.Current.IsEnabled
                    }
                }
                $texts = @(Get-MO2WindowTextElements -Window $window)
            }
            $dialogKind = Get-MO2KnownDialogKind -Title ([string]$native.title) -Texts $texts -Buttons $buttons
            $records += [pscustomobject][ordered]@{
                processId = [int]$processRecord.id
                handle = [int64]$native.handle
                title = [string]$native.title
                className = [string]$native.className
                visible = [bool]$native.visible
                automationAvailable = $null -ne $window
                automationId = $automationId
                buttons = @($buttons)
                texts = @($texts)
                dialogKind = $dialogKind
            }
        }
    }
    return @($records)
}

function Invoke-MO2AutomationButton {
    param(
        [Parameter(Mandatory)]$Button,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    if (-not $Button.Current.IsEnabled -or (ConvertTo-MO2ControlName ([string]$Button.Current.Name)) -ine $ExpectedName) {
        return $false
    }
    $pattern = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        return $true
    }
    $pattern = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.LegacyIAccessiblePattern]$pattern).DoDefaultAction()
        return $true
    }
    return $false
}

function Request-MO2AutomationWindowClose {
    param([Parameter(Mandatory)]$Window)

    $pattern = $null
    if ($Window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.WindowPattern]$pattern).Close()
        return $true
    }
    Initialize-MO2NativeWindowAccess
    return [MO2Control.NativeWindows]::RequestClose([IntPtr][int64]$Window.Current.NativeWindowHandle)
}

function Invoke-MO2RetainedSessionDialogCleanup {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        [scriptblock]$BindingFactory,
        [scriptblock]$WindowFactory,
        [scriptblock]$OwnedAction
    )
    if ($Processes.Count -eq 0) {
        return [pscustomobject][ordered]@{ cleared = $true; before = @(); actions = @(); remaining = @(); needsAttention = @() }
    }
    Assert-MO2ExactProcessTargets -Config $Config -Processes $Processes
    if (-not $BindingFactory) {
        $BindingFactory = {
            param([int]$ProcessId)
            $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $process) { return [pscustomobject][ordered]@{ available=$false; reason='process-exited'; process=$null; record=$null } }
            try {
                $handle = $process.SafeHandle
                if ($handle.IsInvalid -or $handle.IsClosed) { throw 'The process handle is unavailable.' }
                $record = [pscustomobject][ordered]@{
                    name=$process.ProcessName; id=$process.Id; path=[IO.Path]::GetFullPath($process.Path)
                    startTime=$process.StartTime.ToUniversalTime().ToString('o')
                }
                return [pscustomobject][ordered]@{ available=$true; reason='bound'; process=$process; record=$record }
            }
            catch {
                $process.Dispose()
                return [pscustomobject][ordered]@{ available=$false; reason='live-process-identity-unavailable'; process=$null; record=$null; detail=$_.Exception.Message }
            }
        }
    }
    if (-not $WindowFactory) { $WindowFactory = { param($Binding) @(Get-MO2AutomationWindows -ProcessId ([int]$Binding.record.id)) } }
    if (-not $OwnedAction) {
        $OwnedAction = {
            param($AuthorityOwned, $Binding, $Action, [object[]]$Arguments)
            Invoke-MO2OwnedProcessAction -Config $Config -Owned $AuthorityOwned -Process $Binding.process -Action $Action -ArgumentList $Arguments
        }.GetNewClosure()
    }
    $before = @(Get-MO2WindowSnapshot -Processes $Processes)
    $actions = [Collections.Generic.List[object]]::new()
    $blockedReason = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $handled = $false
        foreach ($record in $Processes) {
            $binding = & $BindingFactory ([int]$record.id)
            if (-not $binding.available) { $blockedReason = [string]$binding.reason; break }
            try {
                if ($binding.PSObject.Properties['record']) {
                    $identity = Test-MO2ProcessRecordIdentity -Expected $record -Actual $binding.record
                    if (-not $identity.ok) { $blockedReason = [string]$identity.reason; break }
                }
                foreach ($window in @(& $WindowFactory $binding)) {
                    if ([string]$window.Current.AutomationId -eq 'MainWindow') { continue }
                    $kind = Get-MO2KnownDialogKind -Title ([string]$window.Current.Name) -Texts @(Get-MO2WindowTextElements -Window $window)
                    if ($kind -ne 'failed-to-run') { continue }
                    $accepted = $false
                    foreach ($name in @('OK', 'Close')) {
                        foreach ($button in @(Get-MO2NamedButtons -Window $window -Name $name)) {
                            try {
                                $invoked = & $OwnedAction $Owned $binding { param($targetButton, $expectedName) Invoke-MO2AutomationButton -Button $targetButton -ExpectedName $expectedName } @($button, $name)
                                $accepted = [bool]$invoked -or $accepted
                            }
                            catch { $blockedReason = if ($_.Exception.Message -match 'lease transition is stale') { 'stale-session-generation' } else { $_.Exception.Message }; break }
                        }
                        if ($blockedReason) { break }
                    }
                    if ($blockedReason) { break }
                    if (-not $accepted) {
                        try { $accepted = [bool](& $OwnedAction $Owned $binding { param($targetWindow) Request-MO2AutomationWindowClose -Window $targetWindow } @($window)) }
                        catch { $blockedReason = if ($_.Exception.Message -match 'lease transition is stale') { 'stale-session-generation' } else { $_.Exception.Message }; break }
                    }
                    $actions.Add([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o'); processId = [int]$record.id
                        windowHandle = [int64]$window.Current.NativeWindowHandle; windowTitle = [string]$window.Current.Name
                        dialogKind = $kind; action = 'acknowledge-retained-failed-to-run'; accepted = [bool]$accepted
                    })
                    $handled = $true
                }
            }
            finally {
                if ($binding.process -is [IDisposable]) { $binding.process.Dispose() }
            }
            if ($blockedReason) { break }
        }
        if ($blockedReason) { break }
        if (-not $handled) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $remaining = @(Get-MO2WindowSnapshot -Processes $Processes)
    $remainingKnown = @($remaining | Where-Object { $_.visible -and $_.dialogKind -eq 'failed-to-run' })
    $needsAttention = @($remaining | Where-Object {
        $_.visible -and $_.automationId -ine 'MainWindow' -and $_.dialogKind -ne 'unlock-required' -and $_.dialogKind -ne 'failed-to-run'
    })
    return [pscustomobject][ordered]@{
        cleared = $null -eq $blockedReason -and $remainingKnown.Count -eq 0; before = $before; actions = @($actions)
        remaining = $remaining; remainingKnown = $remainingKnown; needsAttention = $needsAttention; blockedReason = $blockedReason
    }
}

function Assert-MO2ExactProcessTargets {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Processes
    )

    $expectedPath = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    $invalid = @($Processes | Where-Object { -not (Test-MO2ExactProcessPath -Record $_ -ExpectedPath $expectedPath) })
    if ($invalid.Count -gt 0) {
        $identities = @($invalid | ForEach-Object { "PID $($_.id) path '$($_.path)'" }) -join '; '
        throw "Refusing to control a process that cannot be proven to be the configured MO2 executable '$expectedPath': $identities"
    }
}

function Invoke-MO2OwnedProcessAction {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][scriptblock]$Action,
        [AllowEmptyCollection()][object[]]$ArgumentList = @()
    )

    $payload = [pscustomobject][ordered]@{
        owned = $Owned
        process = $Process
        action = $Action
        arguments = @($ArgumentList)
        config = $Config
    }
    return Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action {
        param($Context)
        $CurrentOwned = $Context.owned
        $BoundProcess = $Context.process
        $ExternalAction = $Context.action
        $ExternalArguments = @($Context.arguments)
        $FixtureConfig = $Context.config
        $current = Assert-MO2OwnedSessionTransitionCurrent -Owned $CurrentOwned
        $currentOwnedView = [pscustomobject][ordered]@{
            path = $CurrentOwned.path
            sessionId = $CurrentOwned.sessionId
            accessId = $CurrentOwned.accessId
            data = $current.data
        }
        $BoundProcess.Refresh()
        $handle = $BoundProcess.SafeHandle
        if ($handle.IsInvalid -or $handle.IsClosed -or $BoundProcess.HasExited) {
            throw 'The retained MO2 process binding is no longer available.'
        }
        $boundRecord = [pscustomobject][ordered]@{
            name = $BoundProcess.ProcessName
            id = $BoundProcess.Id
            path = [IO.Path]::GetFullPath($BoundProcess.Path)
            startTime = $BoundProcess.StartTime.ToUniversalTime().ToString('o')
        }
        $resolution = Resolve-MO2OwnedProcessTarget -Config $FixtureConfig -Owned $currentOwnedView -Processes @($boundRecord)
        if (-not $resolution.ok -or @($resolution.targets).Count -ne 1) {
            throw "The retained MO2 process no longer has current session authority: $([string]$resolution.reason)"
        }
        return & $ExternalAction @ExternalArguments
    } -ArgumentList @($payload)
}

function Invoke-MO2CooperativeCloseCore {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][object[]]$InitialProcesses,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [scriptblock]$ProcessInventoryFactory
    )

    Assert-MO2ExactProcessTargets -Config $Config -Processes $InitialProcesses
    $targetIds = @($InitialProcesses | ForEach-Object { [int]$_.id } | Select-Object -Unique)
    $actions = [System.Collections.Generic.List[object]]::new()
    $beforeWindows = @(Get-MO2WindowSnapshot -Processes $InitialProcesses)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $blockedReason = $null
    $ownershipResolution = $null
    if (-not $ProcessInventoryFactory) {
        $ProcessInventoryFactory = { param($fixtureConfig) @(Get-MO2ProcessRecords -Names @($fixtureConfig.mo2.processNames)) }
    }

    do {
        $currentInventory = @(& $ProcessInventoryFactory $Config)
        if ($currentInventory.Count -eq 0) { break }
        $ownershipResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes $currentInventory
        if (-not $ownershipResolution.ok -or @($ownershipResolution.targets).Count -ne 1) {
            $blockedReason = [string]$ownershipResolution.reason
            break
        }
        $liveRecords = @($ownershipResolution.targets)

        foreach ($record in $liveRecords) {
            $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
            if (-not $process) { continue }
            try {
                # Keep the kernel process object open for the complete UI-action
                # boundary so this PID cannot be recycled underneath window APIs.
                $handle = $process.SafeHandle
                if ($handle.IsInvalid -or $handle.IsClosed) { throw 'The process handle is unavailable.' }
                $boundRecord = [pscustomobject][ordered]@{
                    name = $process.ProcessName
                    id = $process.Id
                    path = [IO.Path]::GetFullPath($process.Path)
                    startTime = $process.StartTime.ToUniversalTime().ToString('o')
                }
                $boundIdentity = Test-MO2OwnedProcessIdentity -Owned $Owned -ProcessRecord $boundRecord
                if (-not $boundIdentity.ok) {
                    $blockedReason = [string]$boundIdentity.reason
                    break
                }
            $nativeVisibility = @{}
            foreach ($native in @(Get-MO2NativeWindows -ProcessId ([int]$record.id))) {
                $nativeVisibility[[string][int64]$native.handle] = [bool]$native.visible
            }
            $windows = @(Get-MO2AutomationWindows -ProcessId ([int]$record.id) | Where-Object {
                $nativeVisibility[[string][int64]$_.Current.NativeWindowHandle]
            })

            # Process.MainWindowHandle can temporarily point at a modal warning
            # or the VFS Unlock dialog. Prefer MO2's stable UIA identity so that
            # those windows remain eligible for exact dialog handling.
            $automationMain = @($windows | Where-Object {
                [string]$_.Current.AutomationId -eq 'MainWindow'
            } | Select-Object -First 1)
            $mainHandle = if ($automationMain.Count -gt 0) {
                [int64]$automationMain[0].Current.NativeWindowHandle
            }
            else {
                [int64]$process.MainWindowHandle
            }
            $exitRequested = $false
            foreach ($window in $windows) {
                $unlockButtons = @(Get-MO2UnlockButtons -Window $window)
                if ($unlockButtons.Count -gt 0) {
                    foreach ($button in $unlockButtons) {
                        $invoked = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                            param($targetButton)
                            Invoke-MO2AutomationButton -Button $targetButton -ExpectedName 'Unlock'
                        } -ArgumentList @($button)
                        $actions.Add([pscustomobject][ordered]@{
                            timestampUtc = [DateTime]::UtcNow.ToString('o')
                            processId = [int]$record.id
                            windowHandle = [int64]$window.Current.NativeWindowHandle
                            windowTitle = [string]$window.Current.Name
                            action = 'invoke-exact-unlock'
                            accepted = $invoked
                        })
                    }
                    continue
                }
                $windowTexts = @(Get-MO2WindowTextElements -Window $window)
                $cancelButtons = @(Get-MO2NamedButtons -Window $window -Name 'Cancel')
                $dialogKind = Get-MO2KnownDialogKind -Title ([string]$window.Current.Name) -Texts $windowTexts -Buttons $cancelButtons
                if ($dialogKind -eq 'preparing-vfs') {
                    foreach ($button in $cancelButtons) {
                        $invoked = Invoke-MO2AutomationButton -Button $button -ExpectedName 'Cancel'
                        $actions.Add([pscustomobject][ordered]@{
                            timestampUtc = [DateTime]::UtcNow.ToString('o')
                            processId = [int]$record.id
                            windowHandle = [int64]$window.Current.NativeWindowHandle
                            windowTitle = [string]$window.Current.Name
                            action = 'invoke-exact-preparing-vfs-cancel'
                            accepted = $invoked
                        })
                    }
                    continue
                }
                foreach ($menuItem in @(Get-MO2NamedMenuItems -Window $window -Name 'Exit')) {
                    $invoked = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                        param($targetMenuItem)
                        Invoke-MO2AutomationButton -Button $targetMenuItem -ExpectedName 'Exit'
                    } -ArgumentList @($menuItem)
                    $exitRequested = $exitRequested -or $invoked
                    $actions.Add([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                        processId = [int]$record.id
                        windowHandle = [int64]$window.Current.NativeWindowHandle
                        windowTitle = [string]$window.Current.Name
                        action = 'invoke-exact-exit'
                        accepted = $invoked
                    })
                }
                if ($mainHandle -ne 0 -and [int64]$window.Current.NativeWindowHandle -eq $mainHandle) {
                    if (-not $exitRequested) {
                        foreach ($fileMenu in @(Get-MO2NamedMenuItems -Window $window -Name 'File')) {
                            $expanded = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                                param($targetMenuItem)
                                Expand-MO2AutomationMenu -MenuItem $targetMenuItem
                            } -ArgumentList @($fileMenu)
                            $exitRequested = $exitRequested -or $expanded
                            $actions.Add([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString('o')
                                processId = [int]$record.id
                                windowHandle = [int64]$window.Current.NativeWindowHandle
                                windowTitle = [string]$window.Current.Name
                                action = 'expand-exact-file-menu'
                                accepted = $expanded
                            })
                        }
                    }
                    if ($exitRequested) {
                        Start-Sleep -Milliseconds 100
                        foreach ($menuItem in @(Get-MO2NamedMenuItems -Window $window -Name 'Exit')) {
                            $invoked = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                                param($targetMenuItem)
                                Invoke-MO2AutomationButton -Button $targetMenuItem -ExpectedName 'Exit'
                            } -ArgumentList @($menuItem)
                            $exitRequested = $exitRequested -or $invoked
                            $actions.Add([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString('o')
                                processId = [int]$record.id
                                windowHandle = [int64]$window.Current.NativeWindowHandle
                                windowTitle = [string]$window.Current.Name
                                action = 'invoke-exact-exit-after-expand'
                                accepted = $invoked
                            })
                        }
                    }
                    continue
                }
                if ($dialogKind -eq 'failed-to-write-settings') {
                    foreach ($button in @(Get-MO2NamedButtons -Window $window -Name 'OK')) {
                        $invoked = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                            param($targetButton)
                            Invoke-MO2AutomationButton -Button $targetButton -ExpectedName 'OK'
                        } -ArgumentList @($button)
                        $actions.Add([pscustomobject][ordered]@{
                            timestampUtc = [DateTime]::UtcNow.ToString('o')
                            processId = [int]$record.id
                            windowHandle = [int64]$window.Current.NativeWindowHandle
                            windowTitle = [string]$window.Current.Name
                            action = 'acknowledge-failed-to-write-settings'
                            accepted = $invoked
                        })
                    }
                }
            }

            if ($windows.Count -gt 0) {
                $secondary = @($windows | Where-Object {
                    $candidateTexts = @(Get-MO2WindowTextElements -Window $_)
                    $candidateButtons = @(Get-MO2NamedButtons -Window $_ -Name 'Cancel')
                    $candidateKind = Get-MO2KnownDialogKind -Title ([string]$_.Current.Name) -Texts $candidateTexts -Buttons $candidateButtons
                    [int64]$_.Current.NativeWindowHandle -ne $mainHandle -and @(Get-MO2UnlockButtons -Window $_).Count -eq 0 -and $candidateKind -ne 'preparing-vfs'
                })
                foreach ($window in $secondary) {
                    $requested = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                        param($targetWindow)
                        Request-MO2AutomationWindowClose -Window $targetWindow
                    } -ArgumentList @($window)
                    $actions.Add([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                        processId = [int]$record.id
                        windowHandle = [int64]$window.Current.NativeWindowHandle
                        windowTitle = [string]$window.Current.Name
                        action = 'request-modal-window-close'
                        accepted = $requested
                    })
                }
            }

            if (-not $exitRequested) {
                $accepted = Invoke-MO2OwnedProcessAction -Config $Config -Owned $Owned -Process $process -Action {
                    param($boundProcess)
                    $boundProcess.CloseMainWindow()
                } -ArgumentList @($process)
                $actions.Add([pscustomobject][ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString('o')
                    processId = [int]$record.id
                    windowHandle = [int64]$process.MainWindowHandle
                    windowTitle = [string]$process.MainWindowTitle
                    action = 'request-main-window-close-fallback'
                    accepted = [bool]$accepted
                })
            }
            }
            catch {
                $blockedReason = if ($_.Exception.Message -match 'lease transition is stale') { 'stale-session-generation' } else { $_.Exception.Message }
                break
            }
            finally {
                $process.Dispose()
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($blockedReason)) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(& $ProcessInventoryFactory $Config)
    if ($remaining.Count -gt 0 -and [string]::IsNullOrWhiteSpace($blockedReason)) {
        $ownershipResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes $remaining
        if (-not $ownershipResolution.ok -or @($ownershipResolution.targets).Count -ne 1) {
            $blockedReason = [string]$ownershipResolution.reason
        }
    }
    return [pscustomobject][ordered]@{
        closed = $remaining.Count -eq 0 -and [string]::IsNullOrWhiteSpace($blockedReason)
        ownerIdentityVerified = [string]::IsNullOrWhiteSpace($blockedReason)
        blockedReason = $blockedReason
        ownershipResolution = $ownershipResolution
        targetProcessIds = @($targetIds)
        beforeWindows = @($beforeWindows)
        actions = @($actions)
        remaining = @($remaining)
        remainingWindows = @(Get-MO2WindowSnapshot -Processes $remaining)
        forceTermination = $false
        unrelatedProcessesTouched = @()
    }
}

function Invoke-MO2CooperativeClose {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][object[]]$InitialProcesses,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90
    )

    $directWindows = @(Get-MO2WindowSnapshot -Processes $InitialProcesses)
    if ($directWindows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            closed = $false
            route = 'interactive-desktop-required'
            targetProcessIds = @($InitialProcesses | ForEach-Object { [int]$_.id })
            beforeWindows = @()
            actions = @()
            remaining = @($InitialProcesses)
            remainingWindows = @()
            requiresInteractiveDesktop = $true
            requiredIdentity = 'logged-on user owning the MO2 desktop'
            forceTermination = $false
            unrelatedProcessesTouched = @()
        }
    }
    $close = Invoke-MO2CooperativeCloseCore -Config $Config -Owned $Owned -InitialProcesses $InitialProcesses -TimeoutSeconds $TimeoutSeconds
    $close | Add-Member -NotePropertyName route -NotePropertyValue 'current-interactive-desktop' -Force
    return $close
}

function Set-MO2OwnedSessionStatus {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$TimestampProperty,
        [hashtable]$Properties
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    $Owned.data.status = $Status
    if ($Owned.data.PSObject.Properties[$TimestampProperty]) {
        $Owned.data.$TimestampProperty = $timestamp
    }
    else {
        $Owned.data | Add-Member -NotePropertyName $TimestampProperty -NotePropertyValue $timestamp
    }
    if ($null -ne $Properties) {
        foreach ($propertyName in @($Properties.Keys)) {
            $Owned.data | Add-Member -NotePropertyName $propertyName -NotePropertyValue $Properties[$propertyName] -Force
        }
    }
    $null = Write-MO2OwnedSessionAtomic -Owned $Owned -Value $Owned.data
}

function Set-MO2OwnedSessionOwnerData {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$ProcessRecord,
        [Parameter(Mandatory)][string]$Reason
    )

    $previousOwnerPid = if ($Data.PSObject.Properties['ownerPid']) { [int]$Data.ownerPid } else { 0 }
    $adoption = [pscustomobject][ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        previousOwnerPid = $previousOwnerPid
        ownerPid = [int]$ProcessRecord.id
        processPath = [string]$ProcessRecord.path
        processStartTime = [string]$ProcessRecord.startTime
        reason = $Reason
    }
    $Data | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$ProcessRecord.id) -Force
    $Data | Add-Member -NotePropertyName processPath -NotePropertyValue ([IO.Path]::GetFullPath([string]$ProcessRecord.path)) -Force
    $Data | Add-Member -NotePropertyName processStartTime -NotePropertyValue ([string]$ProcessRecord.startTime) -Force
    [object[]]$adoptions = @()
    if ($Data.PSObject.Properties['ownerAdoptions']) {
        $adoptions = @($Data.ownerAdoptions)
    }
    [object[]]$updatedAdoptions = @($adoptions)
    $updatedAdoptions += $adoption
    $Data | Add-Member -NotePropertyName ownerAdoptions -NotePropertyValue @($updatedAdoptions) -Force
    return $adoption
}

function Set-MO2OwnedSessionOwner {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$ProcessRecord,
        [Parameter(Mandatory)][string]$Reason
    )

    $adoption = Set-MO2OwnedSessionOwnerData -Data $Owned.data -ProcessRecord $ProcessRecord -Reason $Reason
    $null = Write-MO2OwnedSessionAtomic -Owned $Owned -Value $Owned.data
    return $adoption
}

function Test-MO2OwnedProcessIdentity {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$ProcessRecord
    )
    if (-not $Owned.data.PSObject.Properties['processPath'] -or
        -not $Owned.data.PSObject.Properties['processStartTime'] -or
        [string]::IsNullOrWhiteSpace([string]$Owned.data.processPath) -or
        [string]::IsNullOrWhiteSpace([string]$Owned.data.processStartTime)) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'recorded-owner-identity-unbound'; expectedPath = $null; actualPath = [string]$ProcessRecord.path; expectedStartTime = $null; actualStartTime = [string]$ProcessRecord.startTime }
    }
    try {
        $expectedPath = [IO.Path]::GetFullPath([string]$Owned.data.processPath)
        $actualPath = [IO.Path]::GetFullPath([string]$ProcessRecord.path)
        $expectedStart = [DateTimeOffset]::Parse([string]$Owned.data.processStartTime, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $actualStart = [DateTimeOffset]::Parse([string]$ProcessRecord.startTime, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'recorded-owner-identity-malformed'; expectedPath = [string]$Owned.data.processPath; actualPath = [string]$ProcessRecord.path; expectedStartTime = [string]$Owned.data.processStartTime; actualStartTime = [string]$ProcessRecord.startTime; detail = $_.Exception.Message }
    }
    $pathMatches = [string]::Equals($expectedPath, $actualPath, [StringComparison]::OrdinalIgnoreCase)
    $startMatches = [math]::Abs(($actualStart - $expectedStart).TotalMilliseconds) -lt 1.0
    return [pscustomobject][ordered]@{
        ok = $pathMatches -and $startMatches
        reason = if (-not $pathMatches) { 'recorded-owner-path-mismatch' } elseif (-not $startMatches) { 'recorded-owner-start-time-mismatch' } else { 'recorded-owner-identity-matched' }
        expectedPath = $expectedPath; actualPath = $actualPath
        expectedStartTime = $expectedStart.ToString('o'); actualStartTime = $actualStart.ToString('o')
    }
}

function Get-MO2DispatchBoundChildEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$ParentProcess,
        [Parameter(Mandatory)][string]$ParentStartTime,
        [Parameter(Mandatory)][string]$DispatchStartedUtc,
        [ValidateRange(0, 5000)][int]$TimeoutMilliseconds = 750
    )

    # Retaining the parent process handle prevents its PID from being recycled
    # while direct children are inventoried. Persist the known parent lifetime
    # with each child so later status calls do not depend on the parent remaining
    # alive merely to reconstruct that proof.
    $parentHandle = $ParentProcess.SafeHandle
    if ($parentHandle.IsInvalid -or $parentHandle.IsClosed) { return @() }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $dispatchUtc = [DateTimeOffset]::Parse($DispatchStartedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
    do {
        $children = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames) | Where-Object {
            $_.PSObject.Properties['parentId'] -and [int]$_.parentId -eq [int]$ParentProcess.Id -and
            -not [string]::IsNullOrWhiteSpace([string]$_.startTime) -and
            ([DateTimeOffset]::Parse([string]$_.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime -ge $dispatchUtc)
        })
        if ($children.Count -gt 0) {
            return @($children | ForEach-Object {
                [pscustomobject][ordered]@{
                    id = [int]$_.id
                    name = [string]$_.name
                    path = [IO.Path]::GetFullPath([string]$_.path)
                    startTime = ConvertTo-MO2CanonicalUtcTimestamp ([string]$_.startTime)
                    parentId = [int]$ParentProcess.Id
                    parentStartTime = ConvertTo-MO2CanonicalUtcTimestamp $ParentStartTime
                }
            })
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 25
    } while ($true)
    return @()
}

function Test-MO2DetachedOwnerAdoptionEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Candidate
    )

    if (-not $Owned.data.PSObject.Properties['ownerTransition']) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-transition-unavailable' }
    }
    $transition = $Owned.data.ownerTransition
    if (-not $transition.PSObject.Properties['detachedAdoptionAllowed'] -or -not [bool]$transition.detachedAdoptionAllowed) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-transition-not-authorized' }
    }
    if ($transition.PSObject.Properties['detachedAdoptionCompletedUtc'] -and -not [string]::IsNullOrWhiteSpace([string]$transition.detachedAdoptionCompletedUtc)) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-transition-already-consumed' }
    }

    $kind = [string]$transition.kind
    $requiredStatus = if ($kind -ceq 'launch') { 'launching' } elseif ($kind -ceq 'open') { 'opening' } else { $null }
    $receiptName = if ($kind -ceq 'launch') { 'mo2-launch-started.json' } elseif ($kind -ceq 'open') { 'mo2-open-started.json' } else { $null }
    if ([string]::IsNullOrWhiteSpace($requiredStatus) -or [string]$Owned.data.status -cne $requiredStatus) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-transition-state-mismatch'; transitionKind = $kind; sessionStatus = [string]$Owned.data.status }
    }
    if (-not $Owned.data.PSObject.Properties['ownerPid'] -or -not $Owned.data.PSObject.Properties['processPath'] -or
        -not $Owned.data.PSObject.Properties['processStartTime'] -or
        [int]$Owned.data.ownerPid -le 0 -or [string]::IsNullOrWhiteSpace([string]$Owned.data.processPath) -or
        [string]::IsNullOrWhiteSpace([string]$Owned.data.processStartTime)) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-original-identity-unbound' }
    }

    try {
        $sessionPath = [IO.Path]::GetFullPath([string]$Owned.data.sessionPath)
        $expectedReceiptPath = [IO.Path]::GetFullPath((Join-Path $sessionPath $receiptName))
        $actualReceiptPath = [IO.Path]::GetFullPath([string]$transition.receiptPath)
        if (-not [string]::Equals($expectedReceiptPath, $actualReceiptPath, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $expectedReceiptPath -PathType Leaf)) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-receipt-unavailable'; expectedReceiptPath = $expectedReceiptPath; actualReceiptPath = $actualReceiptPath }
        }
        $receipt = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $expectedReceiptPath -Raw -ErrorAction Stop)
        $sessionId = if ($Owned.PSObject.Properties['sessionId']) { [string]$Owned.sessionId } else { [string]$Owned.data.sessionId }
        if ([string]$receipt.sessionId -cne $sessionId -or [string]$receipt.attemptId -cne [string]$transition.attemptId -or
            [int]$receipt.requestedPid -ne [int]$transition.requestedPid -or [int]$receipt.requestedPid -le 0 -or
            -not $transition.PSObject.Properties['requestedProcessStartTime'] -or
            -not $receipt.PSObject.Properties['requestedProcessStartTime']) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-receipt-identity-mismatch' }
        }
        $configuredPath = [IO.Path]::GetFullPath([string]$Config.mo2.executable)
        $receiptMO2Path = [IO.Path]::GetFullPath([string]$receipt.mo2Path)
        $requestedProcessPath = [IO.Path]::GetFullPath([string]$transition.requestedProcessPath)
        $candidatePath = [IO.Path]::GetFullPath([string]$Candidate.path)
        $requestedStartUtc = [DateTimeOffset]::Parse([string]$transition.requestedProcessStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $receiptRequestedStartUtc = [DateTimeOffset]::Parse([string]$receipt.requestedProcessStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $recordedOwnerStartUtc = [DateTimeOffset]::Parse([string]$Owned.data.processStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $recordedOwnerPath = [IO.Path]::GetFullPath([string]$Owned.data.processPath)
        if ([int]$Owned.data.ownerPid -ne [int]$transition.requestedPid -or
            -not [string]::Equals($recordedOwnerPath, $requestedProcessPath, [StringComparison]::OrdinalIgnoreCase) -or
            [math]::Abs(($recordedOwnerStartUtc - $requestedStartUtc).TotalMilliseconds) -ge 1.0 -or
            [math]::Abs(($receiptRequestedStartUtc - $requestedStartUtc).TotalMilliseconds) -ge 1.0) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-original-identity-mismatch' }
        }
        $isRequestedProcess = [int]$Candidate.id -eq [int]$transition.requestedPid -and
            [math]::Abs(([DateTimeOffset]::Parse([string]$Candidate.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime - $requestedStartUtc).TotalMilliseconds) -lt 1.0
        $isLiveDirectHandoff = $Candidate.PSObject.Properties['parentId'] -and [int]$Candidate.parentId -eq [int]$transition.requestedPid -and
            $Candidate.PSObject.Properties['parentStartTime'] -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.parentStartTime) -and
            [math]::Abs(([DateTimeOffset]::Parse([string]$Candidate.parentStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime - $requestedStartUtc).TotalMilliseconds) -lt 1.0
        [object[]]$transitionChildren = if ($transition.PSObject.Properties['dispatchBoundChildren']) { @($transition.dispatchBoundChildren) } else { @() }
        [object[]]$receiptChildren = if ($receipt.PSObject.Properties['dispatchBoundChildren']) { @($receipt.dispatchBoundChildren) } else { @() }
        $durableChild = @()
        foreach ($transitionChild in $transitionChildren) {
            $candidateIdentity = Test-MO2ProcessRecordIdentity -Expected $transitionChild -Actual $Candidate
            if (-not $candidateIdentity.ok) { continue }
            if (-not $transitionChild.PSObject.Properties['parentId'] -or [int]$transitionChild.parentId -ne [int]$transition.requestedPid) { continue }
            if (-not $transitionChild.PSObject.Properties['parentStartTime']) { continue }
            $durableParentStartUtc = [DateTimeOffset]::Parse([string]$transitionChild.parentStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
            if ([math]::Abs(($durableParentStartUtc - $requestedStartUtc).TotalMilliseconds) -ge 1.0) { continue }
            $matchingReceiptChildren = @($receiptChildren | Where-Object {
                (Test-MO2ProcessRecordIdentity -Expected $transitionChild -Actual $_).ok -and
                $_.PSObject.Properties['parentId'] -and [int]$_.parentId -eq [int]$transition.requestedPid -and
                $_.PSObject.Properties['parentStartTime'] -and
                [math]::Abs(([DateTimeOffset]::Parse([string]$_.parentStartTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime - $requestedStartUtc).TotalMilliseconds) -lt 1.0
            })
            if (@($matchingReceiptChildren).Count -eq 1) { $durableChild = @($transitionChild); break }
        }
        $isDirectHandoff = $isLiveDirectHandoff -or @($durableChild).Count -eq 1
        if (-not $isRequestedProcess -and -not $isDirectHandoff) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-handoff-unproven'; requestedPid = [int]$transition.requestedPid; requestedProcessStartTime = $requestedStartUtc.ToString('o'); candidatePid = [int]$Candidate.id; candidateParentPid = $(if ($Candidate.PSObject.Properties['parentId']) { [int]$Candidate.parentId } else { $null }); candidateParentStartTime = $(if ($Candidate.PSObject.Properties['parentStartTime']) { [string]$Candidate.parentStartTime } else { $null }); dispatchBoundChildCount = @($transitionChildren).Count; receiptBoundChildCount = @($receiptChildren).Count; matchedDurableChildCount = @($durableChild).Count }
        }
        if (-not [string]::Equals($configuredPath, $receiptMO2Path, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($configuredPath, $requestedProcessPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($configuredPath, $candidatePath, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-path-mismatch'; configuredPath = $configuredPath; receiptPath = $receiptMO2Path; requestedProcessPath = $requestedProcessPath; candidatePath = $candidatePath }
        }
        $dispatchUtc = [DateTimeOffset]::Parse([string]$transition.dispatchStartedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $receiptDispatchUtc = [DateTimeOffset]::Parse([string]$receipt.dispatchStartedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        $candidateStartUtc = [DateTimeOffset]::Parse([string]$Candidate.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
        if ([math]::Abs(($receiptDispatchUtc - $dispatchUtc).TotalMilliseconds) -ge 1.0 -or $candidateStartUtc -lt $dispatchUtc) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-dispatch-boundary-mismatch'; dispatchStartedUtc = $dispatchUtc.ToString('o'); receiptDispatchStartedUtc = $receiptDispatchUtc.ToString('o'); candidateStartTime = $candidateStartUtc.ToString('o') }
        }
        $transitionPreDispatch = @($transition.preDispatchProcesses)
        $receiptPreDispatch = @($receipt.preDispatchProcesses)
        if ($transitionPreDispatch.Count -ne $receiptPreDispatch.Count -or @($transitionPreDispatch | Where-Object {
            $expected = $_
            @($receiptPreDispatch | Where-Object { (Test-MO2ProcessRecordIdentity -Expected $expected -Actual $_).ok }).Count -ne 1
        }).Count -gt 0) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-pre-dispatch-evidence-mismatch' }
        }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-evidence-malformed'; detail = $_.Exception.Message }
    }

    foreach ($prior in @($transition.preDispatchProcesses)) {
        if ((Test-MO2ProcessRecordIdentity -Expected $prior -Actual $Candidate).ok) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'detached-owner-present-before-dispatch'; candidate = $Candidate }
        }
    }
    return [pscustomobject][ordered]@{ ok = $true; reason = 'dispatch-bound-detached-owner'; transitionKind = $kind; receiptPath = $expectedReceiptPath; dispatchStartedUtc = $dispatchUtc.ToString('o') }
}

function Resolve-MO2OwnedProcessTarget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [switch]$AdoptDetachedOwner
    )

    $ownerPid = if ($Owned.data.PSObject.Properties['ownerPid']) { [int]$Owned.data.ownerPid } else { 0 }
    $ownedTargets = @($Processes | Where-Object { [int]$_.id -eq $ownerPid })
    if ($Processes.Count -eq 0) {
        return [pscustomobject][ordered]@{
            ok = $true
            ownerPid = $ownerPid
            targets = @()
            adopted = $false
            adoption = $null
            reason = 'already-closed'
        }
    }
    if ($ownedTargets.Count -eq 1 -and $Processes.Count -ne 1) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'ambiguous-process-set' }
    }
    if ($ownedTargets.Count -eq 1) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes @($ownedTargets[0])
        $identity = Test-MO2OwnedProcessIdentity -Owned $Owned -ProcessRecord $ownedTargets[0]
        if (-not $identity.ok) {
            return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = [string]$identity.reason; identity = $identity }
        }
        return [pscustomobject][ordered]@{ ok = $true; ownerPid = $ownerPid; targets = @($ownedTargets); adopted = $false; adoption = $null; reason = 'recorded-owner'; identity = $identity }
    }
    if (-not $AdoptDetachedOwner -or $Processes.Count -ne 1 -or $ownedTargets.Count -ne 0) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'ambiguous-process-set' }
    }
    if ($ownerPid -gt 0 -and $null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'recorded-owner-still-running' }
    }

    $candidate = $Processes[0]
    Assert-MO2ExactProcessTargets -Config $Config -Processes @($candidate)
    $evidence = Test-MO2DetachedOwnerAdoptionEvidence -Config $Config -Owned $Owned -Candidate $candidate
    if (-not $evidence.ok) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = [string]$evidence.reason; evidence = $evidence }
    }
    $Owned.data.ownerTransition | Add-Member -NotePropertyName detachedAdoptionCompletedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $Owned.data.ownerTransition | Add-Member -NotePropertyName detachedOwnerPid -NotePropertyValue ([int]$candidate.id) -Force
    $adoption = Set-MO2OwnedSessionOwner -Owned $Owned -ProcessRecord $candidate -Reason 'adopted one dispatch-bound detached MO2 runtime after the recorded launcher exited'
    return [pscustomobject][ordered]@{
        ok = $true
        ownerPid = [int]$candidate.id
        targets = @($candidate)
        adopted = $true
        adoption = $adoption
        reason = 'detached-owner-adopted'
        evidence = $evidence
    }
}

function Bind-MO2PreparedAccessLease {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)]$PreparedLock,
        [Parameter(Mandatory)]$ExpectedRuntimeRoute,
        [Parameter(Mandatory)][string]$ExpectedRuntimeRouteFingerprint
    )

    Invoke-WithMO2LeaseTransitionLock -LockPath $LockPath -Action {
        $currentAccess = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$currentAccess.sessionId)) {
            throw 'The access lease acquired a session before this prepare could bind it.'
        }
        $validatedRuntimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $currentAccess.data.runtimeRoute
        $currentRuntimeRouteFingerprint = Get-MO2RuntimeRouteContractFingerprint -RuntimeRoute $validatedRuntimeRoute
        if ($currentRuntimeRouteFingerprint -cne $ExpectedRuntimeRouteFingerprint) {
            throw "The access lease runtime route changed before session binding ('$($ExpectedRuntimeRoute.id)' to '$($validatedRuntimeRoute.id)')."
        }
        $bound = $currentAccess.data
        foreach ($propertyName in @('sessionId', 'sessionPath', 'status', 'createdUtc', 'profile', 'profileName', 'profileDirectory', 'modListPath', 'executable', 'requirements', 'controllerPath', 'ownerPid')) {
            $bound | Add-Member -NotePropertyName $propertyName -NotePropertyValue $PreparedLock.$propertyName -Force
        }
        $bound | Add-Member -NotePropertyName runtimeRoute -NotePropertyValue $validatedRuntimeRoute -Force
        $bound | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $currentAccess.data) -Force
        Write-MO2JsonAtomic -Path $LockPath -Value $bound
        try {
            Write-MO2SessionManifestProjection -SessionData $bound
        }
        catch {
            throw "The authoritative MO2 ownership lock committed generation $($bound.generation), but its session manifest projection failed and must be reconciled from that lock: $($_.Exception.Message)"
        }
    } | Out-Null
}

function Get-MO2PrepareRouteAdmission {
    param(
        [Parameter(Mandatory)]$Validation,
        [Parameter(Mandatory)]$AccessLock
    )

    $validatedRuntimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $Validation.data.sessionLock.data.runtimeRoute
    $currentRuntimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $AccessLock.data.runtimeRoute
    $validatedFingerprint = Get-MO2RuntimeRouteContractFingerprint -RuntimeRoute $validatedRuntimeRoute
    $currentFingerprint = Get-MO2RuntimeRouteContractFingerprint -RuntimeRoute $currentRuntimeRoute
    return [pscustomobject][ordered]@{
        matched = $validatedFingerprint -ceq $currentFingerprint
        validatedRuntimeRoute = $validatedRuntimeRoute
        currentRuntimeRoute = $currentRuntimeRoute
        validatedFingerprint = $validatedFingerprint
        currentFingerprint = $currentFingerprint
    }
}

function Invoke-MO2Prepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [switch]$RequireSKSE,
        [string]$Label = 'automation',
        [string]$AccessId,
        [switch]$WhatIf
    )

    if ([string]::IsNullOrWhiteSpace($AccessId)) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'missing-access-id' -Data @{ requiredParameter = 'AccessId'; supplied = $false } -Errors @('Prepare requires -AccessId from a route-qualified request-access lease.')
    }

    $accessLock = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    $accessKind = if ($accessLock.data.PSObject.Properties['accessKind']) { [string]$accessLock.data.accessKind } else { 'automation' }
    if ($accessKind -eq 'human') {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'human-lease-session-forbidden' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock } -Errors @('A human lease reserves the live environment and may authorize bounded mutations, but it cannot be bound to an automation launch session.')
    }

    $validation = Invoke-MO2Validate -Config $Config -Profile $Profile -Executable $Executable -RequireSKSE:$RequireSKSE -RequireClosed -RequireRuntimeRoute -OwnedAccessId $AccessId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ validation = $validation } -Warnings $validation.warnings -Errors $validation.errors
    }

    $profileName = [string]$validation.data.requested.profile
    $executableName = [string]$validation.data.requested.executable
    $runtimeOutputIsolation = Get-MO2TaskWorkspaceIsolation -Config $Config -Profile $profileName -Executable $executableName -AccessId $AccessId -RequirePreparedCache
    if (-not $runtimeOutputIsolation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ validation = $validation; runtimeOutputIsolation = $runtimeOutputIsolation } -Warnings $validation.warnings -Errors $runtimeOutputIsolation.errors
    }
    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $sessionId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $safeLabel, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $stagingRoot = Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)
    $sessionPath = Join-Path $stagingRoot $sessionId
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $arguments = @('--profile', $profileName, 'run', '--executable', $executableName)
    $explicitAccess = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$accessLock.sessionId)) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock } -Errors @('The access lease already has a bound session. Release that session before preparing another one.')
    }
    $routeAdmission = Get-MO2PrepareRouteAdmission -Validation $validation -AccessLock $accessLock
    $runtimeRoute = $routeAdmission.validatedRuntimeRoute
    $runtimeRouteFingerprint = [string]$routeAdmission.validatedFingerprint
    if (-not $routeAdmission.matched) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{
            validation = $validation
            validatedRuntimeRoute = $runtimeRoute
            currentRuntimeRoute = $routeAdmission.currentRuntimeRoute
        } -Errors @("The access lease runtime route changed after validation ('$($runtimeRoute.id)' to '$($routeAdmission.currentRuntimeRoute.id)'). Prepare created no session artifacts.")
    }

    $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath -WhatIf
    $profileDirectory = Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) $profileName
    $manifest = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $sessionId
        label = $safeLabel
        createdUtc = [DateTime]::UtcNow.ToString('o')
        status = 'prepared'
        profile = $profileName
        profileName = $profileName
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = $executableName
        requirements = [pscustomobject][ordered]@{ skseLoader = [bool]$RequireSKSE }
        runtimeRoute = $runtimeRoute
        mo2Path = [string]$validation.data.config.mo2Executable
        arguments = $arguments
        selectedProfileBefore = [string]$validation.data.selectedProfile
        launcherPid = $null
        launchedUtc = $null
        stoppedUtc = $null
        accessId = $AccessId
        acquisitionMode = 'explicit-access'
        controllerPath = [string]$controller.controllerPath
        controllerConfigPath = [string]$controller.configPath
        controllerReceiptPath = [string]$controller.receiptPath
        runtimeOutputIsolation = $runtimeOutputIsolation
    }
    $lock = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $AccessId
        acquisitionMode = 'explicit-access'
        label = $(if ($accessLock.data.PSObject.Properties['label']) { [string]$accessLock.data.label } else { $safeLabel })
        requestedUtc = $(if ($accessLock.data.PSObject.Properties['requestedUtc']) { [string]$accessLock.data.requestedUtc } else { $manifest.createdUtc })
        lastRenewedUtc = $(if ($accessLock.data.PSObject.Properties['lastRenewedUtc']) { [string]$accessLock.data.lastRenewedUtc } else { $manifest.createdUtc })
        estimatedDurationMinutes = $(if ($accessLock.data.PSObject.Properties['estimatedDurationMinutes']) { $accessLock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $(if ($accessLock.data.PSObject.Properties['estimatedReleaseUtc']) { $accessLock.data.estimatedReleaseUtc } else { $null })
        ownerRequestPid = $(if ($accessLock.data.PSObject.Properties['ownerRequestPid']) { $accessLock.data.ownerRequestPid } else { $PID })
        generation = Get-MO2NextLeaseGeneration -Lease $accessLock.data
        sessionId = $sessionId
        sessionPath = $sessionPath
        status = 'prepared'
        createdUtc = $manifest.createdUtc
        profile = $profileName
        profileName = $profileName
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = $executableName
        requirements = [pscustomobject][ordered]@{ skseLoader = [bool]$RequireSKSE }
        runtimeRoute = $runtimeRoute
        controllerPath = [string]$controller.controllerPath
        ownerPid = $PID
    }

    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'dry-run' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath; accessId = $AccessId; explicitAccess = $true; controller = $controller; controllerPath = [string]$controller.controllerPath; wouldCreate = @($sessionPath, (Join-Path $sessionPath 'session.json'), [string]$controller.controllerPath); wouldCreateLock = $false; wouldBindAccessLock = $true } -Warnings $validation.warnings
    }

    New-Item -ItemType Directory -Path $sessionPath -ErrorAction Stop | Out-Null
    try {
        $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath
        Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $manifest -CreateNew
        Bind-MO2PreparedAccessLease -Config $Config -AccessId $AccessId -LockPath $lockPath -PreparedLock $lock -ExpectedRuntimeRoute $runtimeRoute -ExpectedRuntimeRouteFingerprint $runtimeRouteFingerprint
    }
    catch {
        throw "Failed to prepare session '$sessionId'. The evidence directory is retained at '$sessionPath'. $($_.Exception.Message)"
    }

    return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'prepared' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath; accessId = $AccessId; explicitAccess = $explicitAccess; controller = $controller; controllerPath = [string]$controller.controllerPath } -Warnings $validation.warnings
}

function Set-MO2OwnedSessionGameProcesses {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [string]$Status,
        [string]$TimestampProperty,
        [scriptblock]$OwnerProcessInventoryFactory
    )
    if ([string]::IsNullOrWhiteSpace($Status) -ne [string]::IsNullOrWhiteSpace($TimestampProperty)) {
        throw 'Game-process adoption status and timestamp property must be supplied together.'
    }
    $records = @($Processes | ForEach-Object {
        [pscustomobject][ordered]@{ id = [int]$_.id; name = [string]$_.name; path = [IO.Path]::GetFullPath([string]$_.path); startTime = ConvertTo-MO2CanonicalUtcTimestamp ([string]$_.startTime) }
    })
    $commit = Invoke-MO2OwnedSessionMutation -Owned $Owned -Action {
        param($currentData)
        $currentOwned = [pscustomobject][ordered]@{ path = $Owned.path; sessionId = $Owned.sessionId; accessId = $Owned.accessId; data = $currentData }
        $ownerProcesses = if ($OwnerProcessInventoryFactory) { @(& $OwnerProcessInventoryFactory) } else { @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames)) }
        $ownerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $currentOwned -Processes $ownerProcesses
        if (-not $ownerResolution.ok -or @($ownerResolution.targets).Count -ne 1) {
            return [pscustomobject][ordered]@{
                commit = $false
                sessionData = $currentData
                result = [pscustomobject][ordered]@{ ok = $false; reason = 'mo2-owner-changed-before-game-process-commit'; ownershipResolution = $ownerResolution; records = @() }
            }
        }

        $timestamp = [DateTime]::UtcNow.ToString('o')
        $currentData | Add-Member -NotePropertyName gameProcesses -NotePropertyValue $records -Force
        $currentData | Add-Member -NotePropertyName gameProcessesRecordedUtc -NotePropertyValue $timestamp -Force
        if ($currentData.PSObject.Properties['launchAttemptId']) {
            $currentData | Add-Member -NotePropertyName gameProcessesLaunchAttemptId -NotePropertyValue ([string]$currentData.launchAttemptId) -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($Status)) {
            $currentData.status = $Status
            $currentData | Add-Member -NotePropertyName $TimestampProperty -NotePropertyValue $timestamp -Force
        }
        return [pscustomobject][ordered]@{
            sessionData = $currentData
            result = [pscustomobject][ordered]@{ ok = $true; reason = 'exact-live-mo2-owner'; ownershipResolution = $ownerResolution; records = @($records) }
        }
    }
    if (-not $commit.ok) {
        throw "The exact live MO2 owner changed before game-process persistence; no running state was committed ($($commit.ownershipResolution.reason))."
    }
    return @($commit.records)
}

function Reset-MO2GameProcessStateForLaunch {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$LaunchAttemptId,
        [Parameter(Mandatory)][string]$LaunchDispatchedUtc,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PreLaunchGameProcesses
    )

    $priorProcesses = if ($Data.PSObject.Properties['gameProcesses']) { @($Data.gameProcesses) } else { @() }
    if ($priorProcesses.Count -gt 0) {
        $history = if ($Data.PSObject.Properties['gameProcessHistory']) { @($Data.gameProcessHistory) } else { @() }
        $history += [pscustomobject][ordered]@{
            launchAttemptId = if ($Data.PSObject.Properties['gameProcessesLaunchAttemptId']) { [string]$Data.gameProcessesLaunchAttemptId } elseif ($Data.PSObject.Properties['launchAttemptId']) { [string]$Data.launchAttemptId } else { $null }
            launchedUtc = if ($Data.PSObject.Properties['launchDispatchedUtc']) { [string]$Data.launchDispatchedUtc } elseif ($Data.PSObject.Properties['launchedUtc']) { [string]$Data.launchedUtc } else { $null }
            recordedUtc = if ($Data.PSObject.Properties['gameProcessesRecordedUtc']) { [string]$Data.gameProcessesRecordedUtc } else { $null }
            retiredUtc = [DateTime]::UtcNow.ToString('o')
            processes = @($priorProcesses)
        }
        $Data | Add-Member -NotePropertyName gameProcessHistory -NotePropertyValue @($history) -Force
    }
    $Data | Add-Member -NotePropertyName gameProcesses -NotePropertyValue @() -Force
    $Data | Add-Member -NotePropertyName gameProcessesRecordedUtc -NotePropertyValue $null -Force
    $Data | Add-Member -NotePropertyName gameProcessesLaunchAttemptId -NotePropertyValue $null -Force
    $Data | Add-Member -NotePropertyName launchAttemptId -NotePropertyValue $LaunchAttemptId -Force
    $Data | Add-Member -NotePropertyName launchDispatchedUtc -NotePropertyValue $LaunchDispatchedUtc -Force
    $Data | Add-Member -NotePropertyName preLaunchGameProcesses -NotePropertyValue @($PreLaunchGameProcesses) -Force
}

function Get-MO2ObservedGameProcessAdoption {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [scriptblock]$OwnerProcessInventoryFactory
    )
    $reasons = [Collections.Generic.List[string]]::new()
    if ([string]$Owned.data.status -cne 'launching') { $reasons.Add('session-not-launching') }
    if ($Owned.data.PSObject.Properties['gameProcesses'] -and @($Owned.data.gameProcesses).Count -gt 0) { $reasons.Add('game-processes-already-recorded') }
    $freshOwnerProcesses = if ($null -ne $OwnerProcessInventoryFactory) { @(& $OwnerProcessInventoryFactory) } else { @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames)) }
    $ownershipResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes @($freshOwnerProcesses)
    if (-not [bool]$ownershipResolution.ok -or @($ownershipResolution.targets).Count -ne 1) {
        $reasons.Add('mo2-owner-not-exact')
    }
    elseif ($Owned.data.PSObject.Properties['ownerPid'] -and [int]$Owned.data.ownerPid -gt 0 -and
        [int]$ownershipResolution.targets[0].id -ne [int]$Owned.data.ownerPid) {
        $reasons.Add('mo2-owner-identity-mismatch')
    }
    else {
        $ownerIdentity = Test-MO2OwnedProcessIdentity -Owned $Owned -ProcessRecord $ownershipResolution.targets[0]
        if (-not $ownerIdentity.ok) { $reasons.Add([string]$ownerIdentity.reason) }
    }
    [DateTimeOffset]$launchDispatchedUtc = [DateTimeOffset]::MinValue
    $hasLaunchBoundary = $Owned.data.PSObject.Properties['launchDispatchedUtc'] -and
        [DateTimeOffset]::TryParse([string]$Owned.data.launchDispatchedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$launchDispatchedUtc)
    if (-not $hasLaunchBoundary) {
        $reasons.Add('launch-dispatch-time-unavailable')
    }
    if ($Processes.Count -eq 0) { $reasons.Add('no-game-process-observed') }
    $expectedPaths = Get-MO2ExpectedGameProcessPaths -Config $Config -Owned $Owned
    if (-not $expectedPaths.ok) { $reasons.Add([string]$expectedPaths.reason) }
    $preLaunchProcesses = if ($Owned.data.PSObject.Properties['preLaunchGameProcesses']) { @($Owned.data.preLaunchGameProcesses) } else { @() }
    $records = [Collections.Generic.List[object]]::new()
    $seenIds = [Collections.Generic.HashSet[int]]::new()
    $seenRoles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($process in $Processes) {
        $id = [int]$process.id
        $name = [string]$process.name
        $path = [string]$process.path
        $startTimeText = [string]$process.startTime
        [DateTimeOffset]$startTime = [DateTimeOffset]::MinValue
        if ($id -le 0 -or -not $seenIds.Add($id)) { $reasons.Add("invalid-or-duplicate-game-pid:$id"); continue }
        if (-not $seenRoles.Add($name)) { $reasons.Add("ambiguous-game-role:$name"); continue }
        $configuredPaths = if ($expectedPaths.ok -and $expectedPaths.pathsByName.ContainsKey($name)) { $expectedPaths.pathsByName[$name] } else { $null }
        $resolvedPath = try { [IO.Path]::GetFullPath($path) } catch { $null }
        if ($null -eq $configuredPaths -or [string]::IsNullOrWhiteSpace($resolvedPath) -or -not $configuredPaths.Contains($resolvedPath)) {
            $reasons.Add("unconfigured-game-identity:$id"); continue
        }
        if (-not [DateTimeOffset]::TryParse($startTimeText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$startTime)) {
            $reasons.Add("invalid-game-start-time:$id"); continue
        }
        if ($hasLaunchBoundary -and $startTime.UtcDateTime -lt $launchDispatchedUtc.UtcDateTime) {
            $reasons.Add("game-predates-launch:$id"); continue
        }
        $observedRecord = [pscustomobject][ordered]@{ id = $id; name = $name; path = $resolvedPath; startTime = $startTime.UtcDateTime.ToString('o') }
        if (@($preLaunchProcesses | Where-Object { (Test-MO2ProcessRecordIdentity -Expected $_ -Actual $observedRecord).ok }).Count -gt 0) {
            $reasons.Add("game-present-before-dispatch:$id"); continue
        }
        $records.Add($observedRecord)
    }
    $primaryGameProcessName = [string]@($Config.mo2.gameProcessNames)[0]
    if ([string]::IsNullOrWhiteSpace($primaryGameProcessName) -or -not $seenRoles.Contains($primaryGameProcessName)) {
        $reasons.Add('primary-game-not-observed')
    }
    return [pscustomobject][ordered]@{ eligible = $reasons.Count -eq 0; reasons = @($reasons); records = @($records); ownershipResolution = $ownershipResolution; expectedPaths = $expectedPaths }
}

function Invoke-MO2UnlockOnly {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [ValidateRange(0, 1000)][int]$PollMilliseconds = 250,
        [scriptblock]$InspectionFactory,
        [scriptblock]$UnlockAction,
        [scriptblock]$BindingFactory,
        [scriptblock]$OwnerIdentityFactory,
        [scriptblock]$WindowFactory,
        [scriptblock]$UnlockControlFactory,
        [scriptblock]$UnlockControlAction
    )
    if (-not $InspectionFactory) {
        $InspectionFactory = { Get-MO2InspectionData -Config $Config }.GetNewClosure()
    }
    if (-not $BindingFactory) {
        $BindingFactory = {
            param([int]$ProcessId)
            $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $process) { return [pscustomobject][ordered]@{ available=$false; reason='process-exited'; process=$null } }
            try {
                $handle = $process.SafeHandle
                if ($handle.IsInvalid -or $handle.IsClosed) { throw 'The process handle is unavailable.' }
                return [pscustomobject][ordered]@{ available=$true; reason='bound'; process=$process }
            }
            catch {
                $process.Dispose()
                return [pscustomobject][ordered]@{ available=$false; reason='live-process-identity-unavailable'; process=$null; detail=$_.Exception.Message }
            }
        }
    }
    if (-not $OwnerIdentityFactory) {
        $OwnerIdentityFactory = {
            param($Binding)
            try {
                if ($Binding.process.HasExited) { return $null }
                return [pscustomobject][ordered]@{
                    name = [string]$Binding.process.ProcessName
                    id = [int]$Binding.process.Id
                    path = [IO.Path]::GetFullPath([string]$Binding.process.Path)
                    startTime = $Binding.process.StartTime.ToUniversalTime().ToString('o')
                }
            }
            catch { return $null }
        }
    }
    if (-not $WindowFactory) {
        $WindowFactory = { param($Binding) @(Get-MO2AutomationWindows -ProcessId ([int]$Binding.process.Id)) }
    }
    $actions = [Collections.Generic.List[object]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $blockedReason = $null
    $ownerResolution = $null
    do {
        $inspection = & $InspectionFactory
        $buildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if ($buildData.Count -eq 0) { break }
        $ownerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes @($inspection.processes.mo2)
        if (-not $ownerResolution.ok -or @($ownerResolution.targets).Count -ne 1) {
            $blockedReason = if ($ownerResolution.reason) { [string]$ownerResolution.reason } else { 'mo2-owner-not-exact' }
            break
        }
        $record = $ownerResolution.targets[0]
        $binding = & $BindingFactory ([int]$record.id)
        if (-not $binding.available) {
            $blockedReason = [string]$binding.reason
            break
        }
        try {
            $actionBlocked = $false
            $assertBoundOwner = {
                param($AuthorityOwned)
                $liveRecord = & $OwnerIdentityFactory $binding
                if ($null -eq $liveRecord) { return [pscustomobject][ordered]@{ ok=$false; reason='bound-owner-exited'; record=$null } }
                $identity = Test-MO2OwnedProcessIdentity -Owned $AuthorityOwned -ProcessRecord $liveRecord
                if (-not $identity.ok) { return [pscustomobject][ordered]@{ ok=$false; reason=[string]$identity.reason; record=$liveRecord; identity=$identity } }
                if (-not (Test-MO2ExactProcessPath -Record $liveRecord -ExpectedPath (Resolve-MO2ControlPath ([string]$Config.mo2.executable))) -or @($Config.mo2.processNames) -notcontains [string]$liveRecord.name) {
                    return [pscustomobject][ordered]@{ ok=$false; reason='bound-owner-not-exact-configured-mo2'; record=$liveRecord }
                }
                return [pscustomobject][ordered]@{ ok=$true; reason='bound-owner-exact'; record=$liveRecord; identity=$identity }
            }
            $preSelection = & $assertBoundOwner $Owned
            if (-not $preSelection.ok) {
                $blockedReason = [string]$preSelection.reason
                break
            }
            if ($UnlockAction) {
                $authorizedAction = {
                    param($AuthorityOwned)
                    $preAction = & $assertBoundOwner $AuthorityOwned
                    if (-not $preAction.ok) { return [pscustomobject][ordered]@{ ok=$false; reason=[string]$preAction.reason; record=$preAction.record; accepted=$false } }
                    return [pscustomobject][ordered]@{ ok=$true; reason='unlock-invoked'; record=$preAction.record; accepted=[bool](& $UnlockAction $preAction.record) }
                }
                try {
                    if ($Owned.PSObject.Properties['path'] -and $Owned.PSObject.Properties['accessId']) {
                        $actionResult = Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action {
                            $current = Assert-MO2OwnedSessionTransitionCurrent -Owned $Owned
                            $authorityOwned = [pscustomobject][ordered]@{ path=$Owned.path; sessionId=$Owned.sessionId; accessId=$Owned.accessId; data=$current.data }
                            & $authorizedAction $authorityOwned
                        }
                    }
                    else { $actionResult = & $authorizedAction $Owned }
                }
                catch {
                    $reason = if ($_.Exception.Message -match 'lease transition is stale|no longer owns the MO2 lease transition') { 'lease-transition-stale' } else { 'unlock-action-failed' }
                    $actionResult = [pscustomobject][ordered]@{ ok=$false; reason=$reason; detail=$_.Exception.Message; record=$null; accepted=$false }
                }
                if (-not $actionResult.ok) { $blockedReason = [string]$actionResult.reason; break }
                $accepted = [bool]$actionResult.accepted
                $actions.Add([pscustomobject][ordered]@{ timestampUtc=[DateTime]::UtcNow.ToString('o'); processId=[int]$actionResult.record.id; windowTitle=$null; action='invoke-exact-unlock'; accepted=$accepted })
            }
            else {
                [object[]]$unlockControls = if ($UnlockControlFactory) {
                    @(& $UnlockControlFactory $binding)
                }
                else {
                    @(& $WindowFactory $binding | ForEach-Object {
                        $window = $_
                        @(Get-MO2UnlockButtons -Window $window) | ForEach-Object {
                            [pscustomobject][ordered]@{ window=$window; button=$_; windowTitle=[string]$window.Current.Name }
                        }
                    })
                }
                foreach ($unlockControl in $unlockControls) {
                        $authorizedAction = {
                            param($AuthorityOwned)
                            $preAction = & $assertBoundOwner $AuthorityOwned
                            if (-not $preAction.ok) { return [pscustomobject][ordered]@{ ok=$false; reason=[string]$preAction.reason; record=$preAction.record; accepted=$false } }
                            $accepted = if ($UnlockControlAction) { [bool](& $UnlockControlAction $unlockControl) } else { Invoke-MO2AutomationButton -Button $unlockControl.button -ExpectedName 'Unlock' }
                            return [pscustomobject][ordered]@{ ok=$true; reason='unlock-invoked'; record=$preAction.record; accepted=$accepted }
                        }
                        try {
                            if ($Owned.PSObject.Properties['path'] -and $Owned.PSObject.Properties['accessId']) {
                                $current = Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action {
                                    $authority = Assert-MO2OwnedSessionTransitionCurrent -Owned $Owned
                                    $authorityOwned = [pscustomobject][ordered]@{ path=$Owned.path; sessionId=$Owned.sessionId; accessId=$Owned.accessId; data=$authority.data }
                                    & $authorizedAction $authorityOwned
                                }
                            }
                            else { $current = & $authorizedAction $Owned }
                        }
                        catch {
                            $reason = if ($_.Exception.Message -match 'lease transition is stale|no longer owns the MO2 lease transition') { 'lease-transition-stale' } else { 'unlock-action-failed' }
                            $current = [pscustomobject][ordered]@{ ok=$false; reason=$reason; detail=$_.Exception.Message; record=$null; accepted=$false }
                        }
                        if (-not $current.ok) { $blockedReason = [string]$current.reason; $actionBlocked = $true; break }
                        $actions.Add([pscustomobject][ordered]@{ timestampUtc=[DateTime]::UtcNow.ToString('o'); processId=[int]$current.record.id; windowTitle=[string]$unlockControl.windowTitle; action='invoke-exact-unlock'; accepted=[bool]$current.accepted })
                }
            }
        }
        finally {
            if ($binding.process -is [IDisposable]) { $binding.process.Dispose() }
        }
        if ($actionBlocked) { break }
        if ($PollMilliseconds -gt 0) { Start-Sleep -Milliseconds $PollMilliseconds }
    } while ([DateTime]::UtcNow -lt $deadline)
    $final = & $InspectionFactory
    $remainingBuildData = @($final.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $finalOwnerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes @($final.processes.mo2)
    $ownerIdentityVerified = $finalOwnerResolution.ok -and @($finalOwnerResolution.targets).Count -eq 1
    if (-not $ownerIdentityVerified -and [string]::IsNullOrWhiteSpace($blockedReason)) {
        $blockedReason = if ($finalOwnerResolution.reason) { [string]$finalOwnerResolution.reason } else { 'mo2-owner-not-exact' }
    }
    return [pscustomobject][ordered]@{ restored = $remainingBuildData.Count -eq 0 -and $ownerIdentityVerified; ownerIdentityVerified=$ownerIdentityVerified; blockedReason=$blockedReason; ownerResolution=$finalOwnerResolution; actions=@($actions); remainingBuildData=@($remainingBuildData | ForEach-Object path); mo2Processes=@($final.processes.mo2); gameProcesses=@($final.processes.game) }
}

function Test-MO2OpeningReady {
    param(
        [Parameter(Mandatory)]$Owned,
        [AllowNull()]$OwnershipResolution,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MO2Processes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GameProcesses,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Windows
    )

    if ([string]$Owned.data.status -cne 'opening' -or $GameProcesses.Count -ne 0 -or $MO2Processes.Count -ne 1) { return $false }
    if ($null -eq $OwnershipResolution -or -not [bool]$OwnershipResolution.ok -or @($OwnershipResolution.targets).Count -ne 1) { return $false }
    return @($Windows | Where-Object { $_.visible -and [string]$_.automationId -ceq 'MainWindow' }).Count -eq 1
}

function Get-MO2SynchronousCompletionSupersession {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('launch', 'open')][string]$Operation,
        [Parameter(Mandatory)][string]$AttemptId
    )

    $current = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $expectedGeneration = if ($Owned.data.PSObject.Properties['generation']) { [long]$Owned.data.generation } else { 0L }
    $currentGeneration = if ($current.data.PSObject.Properties['generation']) { [long]$current.data.generation } else { 0L }
    $superseded = $currentGeneration -ne $expectedGeneration
    $currentAttemptId = if ($Operation -eq 'launch' -and $current.data.PSObject.Properties['launchAttemptId']) {
        [string]$current.data.launchAttemptId
    }
    elseif ($current.data.PSObject.Properties['ownerTransition'] -and
        [string]$current.data.ownerTransition.kind -ceq $Operation) {
        [string]$current.data.ownerTransition.attemptId
    }
    else { $null }
    $sameAttempt = -not [string]::IsNullOrWhiteSpace($currentAttemptId) -and $currentAttemptId -ceq $AttemptId
    $equivalentSuccess = if ($Operation -eq 'launch') {
        $sameAttempt -and [string]$current.data.status -ceq 'running' -and
            $current.data.PSObject.Properties['gameProcessesLaunchAttemptId'] -and
            [string]$current.data.gameProcessesLaunchAttemptId -ceq $AttemptId -and
            $current.data.PSObject.Properties['gameProcesses'] -and @($current.data.gameProcesses).Count -gt 0
    }
    else { $sameAttempt -and [string]$current.data.status -ceq 'mo2-open' }
    return [pscustomobject][ordered]@{
        superseded = $superseded
        equivalentSuccess = $equivalentSuccess
        sameAttempt = $sameAttempt
        operation = $Operation
        attemptId = $AttemptId
        currentAttemptId = $currentAttemptId
        expectedGeneration = $expectedGeneration
        currentGeneration = $currentGeneration
        current = $current
    }
}

function New-MO2SynchronousCompletionSupersededResult {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Supersession,
        [Parameter(Mandatory)][string]$SessionId
    )

    $operation = [string]$Supersession.operation
    $successState = if ($operation -eq 'launch') { 'game-running' } else { 'mo2-open' }
    $supersededState = if ($operation -eq 'launch') { 'launch-superseded' } else { 'open-superseded' }
    $data = @{
        sessionId = $SessionId
        completionSuperseded = $true
        sameAttempt = [bool]$Supersession.sameAttempt
        attemptId = [string]$Supersession.attemptId
        currentAttemptId = [string]$Supersession.currentAttemptId
        expectedGeneration = [long]$Supersession.expectedGeneration
        currentGeneration = [long]$Supersession.currentGeneration
        currentStatus = [string]$Supersession.current.data.status
        lock = $Supersession.current
    }
    if ($Supersession.equivalentSuccess) {
        return New-MO2ActionResult -Config $Config -Command $operation -Ok $true -State $successState -Data $data `
            -Warnings @("The synchronous $operation completion was superseded after the same attempt had already reached '$successState'; the newer lifecycle was preserved.")
    }
    return New-MO2ActionResult -Config $Config -Command $operation -Ok $false -State $supersededState -Data $data `
        -Errors @("The synchronous $operation completion lost its initiating session generation to a newer lifecycle; no stale completion was written.")
}

function Get-MO2HumanMutationAuthority {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HumanMutationId,
        [string]$TaskId
    )

    $callerTaskId = Resolve-MO2CallerTaskId -TaskId $TaskId -Purpose 'Human mutation authority'
    $lock = Get-MO2SessionLockRecord -Path (Resolve-MO2ControlPath ([string]$Config.session.lockFile))
    if (-not $lock.exists) { throw 'No MO2 access lease exists.' }
    if (-not $lock.valid) { throw "The MO2 access lock is invalid: $($lock.error)" }
    $accessKind = if ($lock.data.PSObject.Properties['accessKind']) { [string]$lock.data.accessKind } else { 'automation' }
    if ($accessKind -cne 'human' -or -not [string]::IsNullOrWhiteSpace([string]$lock.sessionId)) {
        throw 'The active MO2 lease does not grant human mutation authority.'
    }
    if (-not $lock.data.PSObject.Properties['humanMutationHash'] -or
        -not (Test-MO2PrivateCredential -ExpectedHash ([string]$lock.data.humanMutationHash) -Supplied $HumanMutationId) -or
        -not $lock.data.PSObject.Properties['humanMutationTaskId'] -or
        [string]$lock.data.humanMutationTaskId -cne $callerTaskId) {
        throw 'The supplied human mutation credential is not authorized for this task.'
    }
    if (-not $lock.data.PSObject.Properties['profile'] -or [string]::IsNullOrWhiteSpace([string]$lock.data.profile)) {
        throw 'The human lease has no exact profile binding.'
    }
    return $lock
}

function Get-MO2HumanMutationValidationUnderLock {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HumanMutationId,
        [Parameter(Mandatory)][string]$Profile,
        [string]$TaskId
    )

    $owned = Get-MO2HumanMutationAuthority -Config $Config -HumanMutationId $HumanMutationId -TaskId $TaskId
    $leaseId = [string]$owned.leaseId
    $expectedProfile = [string]$owned.data.profile
    if ([string]$Profile -cne $expectedProfile) {
        return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'profile-mismatch' -Data @{ leaseId = $leaseId; authorizedProfile = $expectedProfile; requestedProfile = $Profile } -Errors @("Human lease '$leaseId' is bound to profile '$expectedProfile', not '$Profile'.")
    }

    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile $expectedProfile
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'game-close-required' -Data @{ leaseId = $leaseId; profile = $expectedProfile; processes = $inspection.processes } -Errors @('Human-authorized profile mutation requires Skyrim and its loader to be closed.')
    }
    if ($activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'known-ground-state-required' -Data @{ leaseId = $leaseId; profile = $expectedProfile; activeBuildData = @($activeBuildData | ForEach-Object path); recovery = 'Close or recover-close the exact MO2 state, then recover RootBuilder before mutation.' } -Errors @('Active RootBuilder deployment makes the live MO2 state uncertain; establish a known closed state before mutation.')
    }
    if ([string]$inspection.selectedProfile -cne $expectedProfile) {
        return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'profile-drift' -Data @{ leaseId = $leaseId; authorizedProfile = $expectedProfile; selectedProfile = [string]$inspection.selectedProfile } -Errors @('MO2 selected a different profile after the human lease was established.')
    }
    if ($inspection.processes.mo2.Count -gt 1) {
        return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'known-ground-state-required' -Data @{ leaseId = $leaseId; profile = $expectedProfile; processes = $inspection.processes; recovery = 'Use the exact close/recover-close route before mutation.' } -Errors @("Human-authorized profile mutation permits zero or one exact MO2 process; found $($inspection.processes.mo2.Count).")
    }

    $windows = @()
    if ($inspection.processes.mo2.Count -eq 1) {
        $primary = $inspection.processes.mo2[0]
        Assert-MO2ExactProcessTargets -Config $Config -Processes @($primary)
        $windows = @(Get-MO2WindowSnapshot -Processes @($primary))
        $mainWindows = @($windows | Where-Object { $_.visible -and $_.automationAvailable -and [string]$_.automationId -ceq 'MainWindow' })
        $otherVisible = @($windows | Where-Object { $_.visible -and [string]$_.automationId -cne 'MainWindow' })
        if ($mainWindows.Count -ne 1 -or $otherVisible.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $false -State 'known-ground-state-required' -Data @{ leaseId = $leaseId; profile = $expectedProfile; windows = $windows; recovery = 'Resolve the exact modal/Unlock state or use close/recover-close before mutation.' } -Errors @('The live MO2 window state is not one unblocked exact MainWindow; a known ground state is required.')
        }
    }

    return New-MO2ActionResult -Config $Config -Command 'validate-human-mutation' -Ok $true -State 'human-mutation-authorized' -Data @{ leaseId = $leaseId; profile = $expectedProfile; mo2Open = $inspection.processes.mo2.Count -eq 1; refreshRequiredAfterMutation = $inspection.processes.mo2.Count -eq 1; processes = $inspection.processes; windows = $windows }
}

function Invoke-MO2ValidateHumanMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HumanMutationId,
        [Parameter(Mandatory)][string]$Profile,
        [string]$TaskId
    )

    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        Get-MO2HumanMutationValidationUnderLock -Config $Config -HumanMutationId $HumanMutationId -Profile $Profile -TaskId $TaskId
    }
}

function Invoke-MO2HumanMutationTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HumanMutationId,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$TaskId,
        [ValidateRange(100, 60000)][int]$TimeoutMilliseconds = 10000
    )

    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $transitionAction = {
        param($transactionConfig, $mutationCredential, $transactionProfile, $callerTaskId, $mutationAction)
        $authority = Get-MO2HumanMutationValidationUnderLock -Config $transactionConfig -HumanMutationId $mutationCredential -Profile $transactionProfile -TaskId $callerTaskId
        if (-not $authority.ok) {
            return [pscustomobject][ordered]@{ ok = $false; authority = $authority; actionResult = @() }
        }
        $actionResult = @(& $mutationAction)
        return [pscustomobject][ordered]@{ ok = $true; authority = $authority; actionResult = $actionResult }
    }
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -TimeoutMilliseconds $TimeoutMilliseconds -Action $transitionAction -ArgumentList @($Config, $HumanMutationId, $Profile, $TaskId, $Action)
}

function Invoke-MO2RefreshHelperProcess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1, 600)][int]$TimeoutSeconds
    )

    $process = Start-Process -FilePath $Path -ArgumentList 'refresh' -WorkingDirectory $WorkingDirectory -PassThru
    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    return [pscustomobject][ordered]@{
        pid = [int]$process.Id
        exited = [bool]$exited
        exitCode = if ($exited) { [int]$process.ExitCode } else { $null }
    }
}

function Invoke-MO2Refresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SessionId,
        [string]$HumanMutationId,
        [string]$Profile,
        [string]$TaskId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $hasSession = -not [string]::IsNullOrWhiteSpace($SessionId)
    $hasHumanMutation = -not [string]::IsNullOrWhiteSpace($HumanMutationId)
    if ($hasSession -eq $hasHumanMutation) {
        return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'missing-or-ambiguous-refresh-authority' -Data @{ required = 'exactly one of SessionId or HumanMutationId'; sessionIdSupplied = $hasSession; humanMutationIdSupplied = $hasHumanMutation } -Errors @('Refresh requires exactly one authority: an owned automation SessionId or the private task-bound HumanMutationId of the active human lease.')
    }

    if ($hasSession) {
        # Detached-owner adoption may update the durable lease. Do that before
        # entering the transition critical section; all work inside is read-only
        # with respect to lease ownership until the refresh postcondition holds.
        $preflightOwned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $preflightInspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$preflightOwned.data.profile)
        if ($preflightInspection.processes.mo2.Count -gt 0) {
            $preflightResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $preflightOwned -Processes @($preflightInspection.processes.mo2) -AdoptDetachedOwner
            if ($preflightResolution.adopted) {
                $preflightOwned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
            }
        }
    }

    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $owned = $null
        $authorityKind = $null
        $expectedProfile = $null
        $leaseId = $null
        if ($hasSession) {
            $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
            $authorityKind = 'automation-session'
            $expectedProfile = [string]$owned.data.profile
            $leaseId = [string]$owned.leaseId
        }
        else {
            $owned = Get-MO2HumanMutationAuthority -Config $Config -HumanMutationId $HumanMutationId -TaskId $TaskId
            $authorityKind = 'human-mutation'
            $expectedProfile = [string]$owned.data.profile
            $leaseId = [string]$owned.leaseId
        }

        if (-not [string]::IsNullOrWhiteSpace($Profile) -and [string]$Profile -cne $expectedProfile) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'profile-mismatch' -Data @{ authorityKind = $authorityKind; authorizedProfile = $expectedProfile; requestedProfile = $Profile } -Errors @("Refresh authority is bound to profile '$expectedProfile', not '$Profile'.")
        }

        $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile $expectedProfile
        $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if ($inspection.processes.game.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'game-close-required' -Data @{ authorityKind = $authorityKind; profile = $expectedProfile; processes = $inspection.processes } -Errors @('Refresh refuses while Skyrim or its loader is running. Close Skyrim first so the next launch begins from the changed mod state.')
        }
        if ($activeBuildData.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'known-ground-state-required' -Data @{ authorityKind = $authorityKind; profile = $expectedProfile; activeBuildData = @($activeBuildData | ForEach-Object path); recovery = 'Use the owned close/recover-close and RootBuilder recovery route before refreshing.' } -Errors @('Active RootBuilder deployment makes the live MO2 state uncertain; establish a known closed state before mutation or refresh.')
        }
        if ([string]$inspection.selectedProfile -cne $expectedProfile) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'profile-drift' -Data @{ authorityKind = $authorityKind; authorizedProfile = $expectedProfile; selectedProfile = [string]$inspection.selectedProfile } -Errors @('MO2 selected a different profile after authority was established; coordinate the exact profile before refreshing.')
        }
        if ($inspection.processes.mo2.Count -ne 1) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'known-ground-state-required' -Data @{ authorityKind = $authorityKind; profile = $expectedProfile; processes = $inspection.processes; recovery = 'Use close/recover-close to classify zero, multiple, or stranded MO2 processes.' } -Errors @("Refresh requires exactly one configured MO2 process; found $($inspection.processes.mo2.Count).")
        }

        $primary = $inspection.processes.mo2[0]
        Assert-MO2ExactProcessTargets -Config $Config -Processes @($primary)
        if ($hasSession) {
            $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($inspection.processes.mo2)
            if (-not $resolution.ok -or @($resolution.targets).Count -ne 1) {
                return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'known-ground-state-required' -Data @{ authorityKind = $authorityKind; profile = $expectedProfile; ownershipResolution = $resolution; recovery = 'Use status or close/recover-close to re-establish exact process ownership.' } -Errors @('The automation session cannot prove the one running MO2 process is its exact owner.')
            }
            $primary = $resolution.targets[0]
        }

        $windows = @(Get-MO2WindowSnapshot -Processes @($primary))
        $mainWindows = @($windows | Where-Object { $_.visible -and $_.automationAvailable -and [string]$_.automationId -ceq 'MainWindow' })
        $otherVisible = @($windows | Where-Object { $_.visible -and [string]$_.automationId -cne 'MainWindow' })
        if ($mainWindows.Count -ne 1 -or $otherVisible.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'known-ground-state-required' -Data @{ authorityKind = $authorityKind; profile = $expectedProfile; windows = $windows; recovery = 'Resolve the exact modal/Unlock state or use close/recover-close before refreshing.' } -Errors @('The MO2 window state is not one unblocked exact MainWindow; a known ground state is required.')
        }

        $mo2Path = [IO.Path]::GetFullPath((Resolve-MO2ControlPath ([string]$Config.mo2.executable)))
        $workingDirectory = Split-Path -Parent $mo2Path
        $profileDirectory = Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) $expectedProfile
        $modListPath = Join-Path $profileDirectory 'modlist.txt'
        $beforeModListSha256 = if (Test-Path -LiteralPath $modListPath -PathType Leaf) { (Get-FileHash -LiteralPath $modListPath -Algorithm SHA256).Hash } else { $null }
        $plan = [pscustomobject][ordered]@{ path = $mo2Path; arguments = @('refresh'); argumentLine = 'refresh'; workingDirectory = $workingDirectory; upstreamSemantics = 'refreshes MO (same as F5); forwarded to the primary instance' }
        if ($WhatIf) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $true -State 'dry-run' -Data @{ authorityKind = $authorityKind; sessionId = $SessionId; leaseId = $leaseId; profile = $expectedProfile; primaryProcess = $primary; windows = $windows; plan = $plan; beforeModListSha256 = $beforeModListSha256; wouldRetainMO2 = $true; wouldLaunchGame = $false }
        }

        $startedUtc = [DateTime]::UtcNow
        $helper = Invoke-MO2RefreshHelperProcess -Path $mo2Path -WorkingDirectory $workingDirectory -TimeoutSeconds $TimeoutSeconds
        if (-not $helper.exited) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'refresh-helper-timeout' -Data @{ authorityKind = $authorityKind; sessionId = $SessionId; leaseId = $leaseId; profile = $expectedProfile; primaryProcess = $primary; helper = $helper; plan = $plan; timeoutSeconds = $TimeoutSeconds; recovery = 'Classify the exact helper and primary process before retrying or closing MO2.' } -Errors @('The exact MO2 refresh helper did not exit within the bounded timeout; no retry or forced termination was attempted.')
        }
        if ([int]$helper.exitCode -ne 0) {
            return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $false -State 'refresh-forward-failed' -Data @{ authorityKind = $authorityKind; sessionId = $SessionId; leaseId = $leaseId; profile = $expectedProfile; primaryProcess = $primary; helper = $helper; plan = $plan } -Errors @("ModOrganizer.exe refresh exited with code $($helper.exitCode).")
        }

        $after = Get-MO2InspectionData -Config $Config -RequestedProfile $expectedProfile
        $afterPrimary = @($after.processes.mo2 | Where-Object {
            [int]$_.id -eq [int]$primary.id -and
            [string]$_.path -ceq [string]$primary.path -and
            [string]$_.startTime -ceq [string]$primary.startTime
        })
        $afterBuildData = @($after.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        $afterModListSha256 = if (Test-Path -LiteralPath $modListPath -PathType Leaf) { (Get-FileHash -LiteralPath $modListPath -Algorithm SHA256).Hash } else { $null }
        $postconditionOk = $afterPrimary.Count -eq 1 -and $after.processes.mo2.Count -eq 1 -and $after.processes.game.Count -eq 0 -and $afterBuildData.Count -eq 0 -and [string]$after.selectedProfile -ceq $expectedProfile
        $receiptRoot = if ($hasSession) { [string]$owned.data.sessionPath } else { Join-Path (Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)) ("human-lease-$leaseId") }
        $receiptPath = Join-Path $receiptRoot ('mo2-refresh.' + $startedUtc.ToString('yyyyMMddTHHmmssfffZ') + '.json')
        $receipt = [pscustomobject][ordered]@{
            contractVersion = $script:MO2ControlContractVersion
            operation = 'refresh'
            authorityKind = $authorityKind
            sessionId = $SessionId
            leaseId = $leaseId
            profile = $expectedProfile
            primaryProcessBefore = $primary
            helper = $helper
            command = $plan
            beforeModListSha256 = $beforeModListSha256
            afterModListSha256 = $afterModListSha256
            postconditionVerified = $postconditionOk
            completedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-MO2JsonAtomic -Path $receiptPath -Value $receipt -CreateNew
        return New-MO2ActionResult -Config $Config -Command 'refresh' -Ok $postconditionOk -State $(if ($postconditionOk) { 'refreshed' } else { 'refresh-postcondition-failed' }) -Data @{ authorityKind = $authorityKind; sessionId = $SessionId; leaseId = $leaseId; profile = $expectedProfile; helper = $helper; plan = $plan; beforeModListSha256 = $beforeModListSha256; afterModListSha256 = $afterModListSha256; primaryRetained = $afterPrimary.Count -eq 1; postconditionVerified = $postconditionOk; receiptPath = $receiptPath; processes = $after.processes } -Errors $(if ($postconditionOk) { @() } else { @('The refresh helper returned success, but exact primary-process, profile, closed-game, or RootBuilder postconditions were not all retained.') })
    }
}

function Invoke-MO2Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SessionId
    )

    $requestedProfile = $null
    $requestedExecutable = $null
    $owned = $null
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $requestedProfile = [string]$owned.data.profile
        $requestedExecutable = [string]$owned.data.executable
    }
    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $requestedProfile -RequestedExecutable $requestedExecutable
    $ownershipResolution = $null
    if ($owned -and $data.processes.mo2.Count -gt 0) {
        $ownershipResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($data.processes.mo2) -AdoptDetachedOwner
        if ($ownershipResolution.adopted) { $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId }
    }
    $gameProcessAdoption = $null
    if ($owned -and $data.processes.game.Count -gt 0) {
        $gameProcessAdoption = Get-MO2ObservedGameProcessAdoption -Config $Config -Owned $owned -Processes @($data.processes.game)
        if ($gameProcessAdoption.eligible) {
            $commitOwnerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
            if ($commitOwnerResolution.ok -and @($commitOwnerResolution.targets).Count -eq 1) {
                $null = Set-MO2OwnedSessionGameProcesses -Config $Config -Owned $owned -Processes @($gameProcessAdoption.records) -Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc'
                $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
                $gameProcessAdoption | Add-Member -NotePropertyName adopted -NotePropertyValue $true -Force
                $gameProcessAdoption | Add-Member -NotePropertyName commitOwnershipResolution -NotePropertyValue $commitOwnerResolution -Force
            }
            else {
                $gameProcessAdoption.eligible = $false
                $gameProcessAdoption.reasons = @($gameProcessAdoption.reasons) + @('mo2-owner-changed-before-adoption-commit')
                $gameProcessAdoption | Add-Member -NotePropertyName adopted -NotePropertyValue $false -Force
                $gameProcessAdoption | Add-Member -NotePropertyName commitOwnershipResolution -NotePropertyValue $commitOwnerResolution -Force
            }
        }
        else { $gameProcessAdoption | Add-Member -NotePropertyName adopted -NotePropertyValue $false -Force }
    }
    $buildData = @($data.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $windows = if ($data.processes.mo2.Count -gt 0) { @(Get-MO2WindowSnapshot -Processes @($data.processes.mo2)) } else { @() }
    $openingCompleted = $false
    if ($owned -and (Test-MO2OpeningReady -Owned $owned -OwnershipResolution $ownershipResolution -MO2Processes @($data.processes.mo2) -GameProcesses @($data.processes.game) -Windows @($windows))) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-open' -TimestampProperty 'openCompletedUtc'
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $openingCompleted = $true
    }
    $headlessMO2 = $data.processes.mo2.Count -gt 0 -and @($windows | Where-Object visible).Count -eq 0
    $launchGraceSeconds = 30
    if ($Config.limits.PSObject.Properties['launchPendingGraceSeconds']) {
        $launchGraceSeconds = [math]::Max(5, [math]::Min(120, [int]$Config.limits.launchPendingGraceSeconds))
    }
    $launchStartedUtc = $null
    $launchElapsedSeconds = $null
    if ($owned -and [string]$owned.data.status -eq 'launching' -and $owned.data.PSObject.Properties['launchedUtc']) {
        try {
            $launchStartedUtc = [DateTimeOffset]::Parse([string]$owned.data.launchedUtc, [Globalization.CultureInfo]::InvariantCulture)
            $launchElapsedSeconds = [math]::Max(0, ([DateTimeOffset]::UtcNow - $launchStartedUtc).TotalSeconds)
        }
        catch { $launchStartedUtc = $null }
    }
    $launchPending = $null -ne $launchStartedUtc -and $launchElapsedSeconds -lt $launchGraceSeconds
    $recordedGameResolution = if ($owned -and $owned.data.PSObject.Properties['gameProcesses'] -and @($owned.data.gameProcesses).Count -gt 0) {
        Resolve-MO2RecordedGameProcessTargets -Recorded @($owned.data.gameProcesses) -Current @($data.processes.game)
    }
    else { $null }
    $ownedGameExact = $null -eq $owned -or ($null -ne $recordedGameResolution -and $recordedGameResolution.ok -and @($recordedGameResolution.targets).Count -gt 0)
    $state = if ($data.processes.game.Count -gt 0) {
        if ($ownedGameExact) { 'game-running' } else { 'game-running-unowned' }
    }
    elseif ($launchPending) {
        'launch-pending'
    }
    elseif ($buildData.Count -gt 0 -and ($headlessMO2 -or $data.processes.mo2.Count -eq 0)) {
        'rootbuilder-recovery-required'
    }
    elseif ($data.processes.mo2.Count -gt 0) {
        'mo2-running'
    }
    elseif ($data.sessionLock.exists) {
        [string]$data.sessionLock.status
    }
    else { 'closed' }
    $data | Add-Member -NotePropertyName controller -NotePropertyValue ([pscustomobject][ordered]@{
        sessionId = if ($owned) { $SessionId } else { $null }
        sessionPath = if ($owned) { [string]$owned.data.sessionPath } else { $null }
        lockStatus = if ($owned) { [string]$owned.data.status } else { $null }
        windows = @($windows)
        headlessMO2 = $headlessMO2
        activeBuildData = @($buildData | ForEach-Object path)
        ownershipResolution = $ownershipResolution
        gameProcessAdoption = $gameProcessAdoption
        recordedGameResolution = $recordedGameResolution
        openingCompleted = $openingCompleted
        launchPending = $launchPending
        launchElapsedSeconds = $launchElapsedSeconds
        launchGraceSeconds = $launchGraceSeconds
        launchGraceRemainingSeconds = if ($launchPending) { [math]::Max(0, [math]::Round($launchGraceSeconds - $launchElapsedSeconds, 3)) } else { 0 }
        recoveryCommand = if ($buildData.Count -gt 0 -and $owned -and -not $launchPending) { "recover-rootbuilder -SessionId $SessionId" } else { $null }
    }) -Force
    return New-MO2ActionResult -Config $Config -Command 'status' -Ok $true -State $state -Data $data
}

function Get-MO2LaunchResumeDisposition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionStatus,
        [Parameter(Mandatory)]$GameProcesses,
        [Parameter(Mandatory)]$MO2Processes,
        [int]$OwnerPid,
        [bool]$OwnerIdentityMatched = $false
    )

    if ($SessionStatus -notin @('game-stopped', 'mo2-exited-after-game-stop', 'stop-incomplete', 'mo2-open')) {
        return [pscustomobject][ordered]@{ ok = $true; mode = 'fresh'; ownerPid = $OwnerPid; reason = $null }
    }
    if (@($GameProcesses).Count -gt 0) {
        return [pscustomobject][ordered]@{ ok = $false; mode = 'blocked'; ownerPid = $OwnerPid; reason = 'game-process-present' }
    }
    $mo2 = @($MO2Processes)
    if ($mo2.Count -eq 0) {
        return [pscustomobject][ordered]@{ ok = $true; mode = 'reopen-exact-session'; ownerPid = $OwnerPid; reason = 'retained-owner-exited' }
    }
    $ownedMO2 = @($mo2 | Where-Object { $OwnerPid -gt 0 -and [int]$_.id -eq $OwnerPid })
    if ($mo2.Count -eq 1 -and $ownedMO2.Count -eq 1) {
        if (-not $OwnerIdentityMatched) {
            return [pscustomobject][ordered]@{ ok = $false; mode = 'blocked'; ownerPid = $OwnerPid; reason = 'owner-identity-mismatch' }
        }
        return [pscustomobject][ordered]@{ ok = $true; mode = 'retained-owner'; ownerPid = $OwnerPid; reason = $null }
    }
    return [pscustomobject][ordered]@{ ok = $false; mode = 'blocked'; ownerPid = $OwnerPid; reason = 'ambiguous-mo2-owner' }
}

function Invoke-MO2Launch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$RootBuilderRecovery,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $lockData = $owned.data
    $acceptedStatuses = @('prepared', 'launch-failed', 'game-stopped', 'mo2-exited-after-game-stop', 'stop-incomplete', 'mo2-open')
    if ($RootBuilderRecovery) { $acceptedStatuses += @('mo2-closed', 'rootbuilder-recovery-required', 'launching', 'opening', 'open-incomplete') }
    if ([string]$lockData.status -notin $acceptedStatuses) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ lock = $owned } -Errors @("Session status '$($lockData.status)' cannot be launched.")
    }

    $resumeSession = [string]$lockData.status -in @('game-stopped', 'mo2-exited-after-game-stop', 'stop-incomplete', 'mo2-open')
    $requireSKSE = $lockData.PSObject.Properties['requirements'] -and $lockData.requirements.PSObject.Properties['skseLoader'] -and [bool]$lockData.requirements.skseLoader
    $validation = Invoke-MO2Validate -Config $Config -Profile ([string]$lockData.profile) -Executable ([string]$lockData.executable) -RequireSKSE:$requireSKSE -RequireClosed:(-not $resumeSession) -RequireRuntimeRoute -OwnedSessionId $SessionId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned } -Warnings $validation.warnings -Errors $validation.errors
    }
    $runtimeOutputIsolation = Get-MO2TaskWorkspaceIsolation -Config $Config -Profile ([string]$lockData.profile) -Executable ([string]$lockData.executable) -AccessId ([string]$lockData.accessId) -RequirePreparedCache -AllowPreparedCacheGrowth:$resumeSession
    if (-not $runtimeOutputIsolation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned; runtimeOutputIsolation = $runtimeOutputIsolation } -Warnings $validation.warnings -Errors $runtimeOutputIsolation.errors
    }
    $ownerPid = if ($lockData.PSObject.Properties['ownerPid']) { [int]$lockData.ownerPid } else { 0 }
    $resumeDisposition = Get-MO2LaunchResumeDisposition -SessionStatus ([string]$lockData.status) -GameProcesses @($validation.data.processes.game) -MO2Processes @($validation.data.processes.mo2) -OwnerPid $ownerPid -OwnerIdentityMatched ([bool]$validation.data.sessionLock.ownerIdentityMatched)
    if (-not $resumeDisposition.ok) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ processes = $validation.data.processes; lock = $owned; resumeDisposition = $resumeDisposition } -Errors @('Resume requires no game process and either the exact retained MO2 owner or no MO2 process so the same session and profile can be reopened safely.')
    }
    $reuseRetainedMO2 = [string]$resumeDisposition.mode -eq 'retained-owner'
    $resumeOwnerResolution = $null

    $mo2Path = [string]$validation.data.config.mo2Executable
    $arguments = @('--profile', [string]$lockData.profile, 'run', '--executable', [string]$lockData.executable)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-MO2CommandLineArgument ([string]$_) }) -join ' '
    if ($reuseRetainedMO2) {
        $resumeOwnerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        if (-not $resumeOwnerResolution.ok -or @($resumeOwnerResolution.targets).Count -ne 1) {
            return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ lock = $owned; ownershipResolution = $resumeOwnerResolution } -Errors @('The retained MO2 owner identity changed before launch authorization; no launch was dispatched.')
        }
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'dry-run' -Data @{ path = $mo2Path; arguments = $arguments; argumentLine = $argumentLine; workingDirectory = (Split-Path -Parent $mo2Path); sessionId = $SessionId; startOnly = [bool]$StartOnly; rootBuilderRecovery = [bool]$RootBuilderRecovery; resumeDisposition = $resumeDisposition; ownershipResolution = $resumeOwnerResolution }
    }

    $launchAttemptId = [guid]::NewGuid().ToString('D')
    $launchStartedPath = Join-Path ([string]$lockData.sessionPath) 'mo2-launch-started.json'
    $preLaunchGameProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.gameProcessNames))
    $preLaunchMO2Processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
    $launchStarted = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $SessionId
        mo2Path = $mo2Path
        arguments = $arguments
        argumentLine = $argumentLine
        timeoutSeconds = $TimeoutSeconds
        startOnly = [bool]$StartOnly
        rootBuilderRecovery = [bool]$RootBuilderRecovery
        launchAttemptId = $launchAttemptId
        attemptId = $launchAttemptId
        requestedPid = $null
        requestedProcessStartTime = $null
        startedUtc = [DateTime]::UtcNow.ToString('o')
        dispatchStartedUtc = $null
        preLaunchGameProcesses = @($preLaunchGameProcesses)
        preDispatchProcesses = @($preLaunchMO2Processes)
    }
    $dispatch = Invoke-MO2OwnedSessionMutation -Owned $owned -Action {
        param($currentData)
        $currentOwned = [pscustomobject][ordered]@{ path = $owned.path; sessionId = $owned.sessionId; accessId = $owned.accessId; data = $currentData }
        if ([string]$currentData.status -notin $acceptedStatuses) {
            throw "Session status '$($currentData.status)' changed before launch dispatch."
        }
        if ($reuseRetainedMO2) {
            $currentResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $currentOwned -Processes @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
            if (-not $currentResolution.ok -or @($currentResolution.targets).Count -ne 1) {
                throw 'The retained MO2 owner identity changed immediately before serialized launch dispatch.'
            }
        }

        Write-MO2JsonAtomic -Path $launchStartedPath -Value $launchStarted
        $launchDispatchedUtc = [DateTime]::UtcNow.ToString('o')
        $launchStarted.dispatchStartedUtc = $launchDispatchedUtc
        $launchStarted.preLaunchGameProcesses = @($preLaunchGameProcesses)
        $process = Start-Process -FilePath $mo2Path -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $mo2Path) -WindowStyle Hidden -PassThru
        $launchOwnerProcessPath = [IO.Path]::GetFullPath($mo2Path)
        $launchOwnerProcessStartTime = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
        $dispatchBoundChildren = if ([string]::IsNullOrWhiteSpace($launchOwnerProcessStartTime)) { @() } else { @(Get-MO2DispatchBoundChildEvidence -Config $Config -ParentProcess $process -ParentStartTime $launchOwnerProcessStartTime -DispatchStartedUtc $launchDispatchedUtc) }
        $launchStarted.requestedPid = $process.Id
        $launchStarted.requestedProcessStartTime = $launchOwnerProcessStartTime
        $launchStarted | Add-Member -NotePropertyName dispatchBoundChildren -NotePropertyValue @($dispatchBoundChildren) -Force
        $receiptWriteError = $null
        try { Write-MO2JsonAtomic -Path $launchStartedPath -Value $launchStarted } catch { $receiptWriteError = $_.Exception.Message }
        $ownerTransition = [pscustomobject][ordered]@{
            kind = 'launch'
            attemptId = $launchAttemptId
            dispatchStartedUtc = $launchDispatchedUtc
            requestedPid = [int]$process.Id
            requestedProcessPath = $launchOwnerProcessPath
            requestedProcessStartTime = $launchOwnerProcessStartTime
            preDispatchProcesses = @($preLaunchMO2Processes)
            dispatchBoundChildren = @($dispatchBoundChildren)
            receiptPath = $launchStartedPath
            detachedAdoptionAllowed = -not $reuseRetainedMO2
        }
        $currentData.status = 'launching'
        Reset-MO2GameProcessStateForLaunch -Data $currentData -LaunchAttemptId $launchAttemptId -LaunchDispatchedUtc $launchDispatchedUtc -PreLaunchGameProcesses $preLaunchGameProcesses
        $currentData | Add-Member -NotePropertyName ownerTransition -NotePropertyValue $ownerTransition -Force
        if (-not $reuseRetainedMO2) {
            $currentData | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$process.Id) -Force
            $currentData | Add-Member -NotePropertyName processPath -NotePropertyValue $launchOwnerProcessPath -Force
            $currentData | Add-Member -NotePropertyName processStartTime -NotePropertyValue $launchOwnerProcessStartTime -Force
        }
        $currentData | Add-Member -NotePropertyName latestLauncherPid -NotePropertyValue ([int]$process.Id) -Force
        $currentData | Add-Member -NotePropertyName launchedUtc -NotePropertyValue $launchDispatchedUtc -Force
        $currentData | Add-Member -NotePropertyName launchStartedReceiptPath -NotePropertyValue $launchStartedPath -Force
        return [pscustomobject][ordered]@{
            sessionData = $currentData
            result = [pscustomobject][ordered]@{ process = $process; receiptWriteError = $receiptWriteError }
        }
    }
    $process = $dispatch.process
    if (-not [string]::IsNullOrWhiteSpace([string]$dispatch.receiptWriteError)) {
        throw "Launch process $($process.Id) was recorded in the ownership lock, but its dispatch receipt could not be updated: $($dispatch.receiptWriteError)"
    }
    $lockData = $owned.data
    if ($StartOnly) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'launching' -Data @{ sessionId = $SessionId; launcherPid = $process.Id; launchStartedReceiptPath = $launchStartedPath; sessionPath = $lockData.sessionPath; pollWith = "status -SessionId $SessionId"; rootBuilderRecovery = [bool]$RootBuilderRecovery; resumeDisposition = $resumeDisposition }
    }

    $primaryGameProcessName = [string]@($Config.mo2.gameProcessNames)[0]
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $status = $null
    $blockingDialog = $null
    do {
        Start-Sleep -Milliseconds 500
        $status = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$lockData.profile) -RequestedExecutable ([string]$lockData.executable)
        if (@($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0) { break }
        $blockingDialog = @(Get-MO2WindowSnapshot -Processes @($status.processes.mo2) | Where-Object { $_.dialogKind -eq 'failed-to-write-settings' } | Select-Object -First 1)
        if ($blockingDialog.Count -gt 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $gameObserved = @($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0
    $ownerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($status.processes.mo2) -AdoptDetachedOwner
    if ($ownerResolution.adopted) { $lockData = $owned.data }
    $gameProcessAdoption = if ($gameObserved) { Get-MO2ObservedGameProcessAdoption -Config $Config -Owned $owned -Processes @($status.processes.game) } else { $null }
    $commitOwnerResolution = if ($gameObserved -and $null -ne $gameProcessAdoption -and $gameProcessAdoption.eligible) { Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames)) } else { $null }
    $gameOwned = $gameObserved -and $null -ne $gameProcessAdoption -and $gameProcessAdoption.eligible -and $null -ne $commitOwnerResolution -and $commitOwnerResolution.ok -and @($commitOwnerResolution.targets).Count -eq 1
    if ($gameOwned) {
        try {
            $null = Set-MO2OwnedSessionGameProcesses -Config $Config -Owned $owned -Processes @($gameProcessAdoption.records) -Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc'
            $lockData = $owned.data
        }
        catch {
            $supersession = Get-MO2SynchronousCompletionSupersession -Config $Config -Owned $owned -SessionId $SessionId -Operation launch -AttemptId $launchAttemptId
            if (-not $supersession.superseded) { throw }
            return New-MO2SynchronousCompletionSupersededResult -Config $Config -Supersession $supersession -SessionId $SessionId
        }
    }
    elseif ($null -ne $gameProcessAdoption -and $gameProcessAdoption.eligible) {
        $gameProcessAdoption.eligible = $false
        $gameProcessAdoption.reasons = @($gameProcessAdoption.reasons) + @('mo2-owner-changed-before-adoption-commit')
        $gameProcessAdoption | Add-Member -NotePropertyName commitOwnershipResolution -NotePropertyValue $commitOwnerResolution -Force
    }
    if (-not $gameOwned) {
        $lockData.status = if ($blockingDialog.Count -gt 0) { 'launch-blocked-dialog' } else { 'launch-failed' }
        try {
            $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $lockData
            $lockData = $owned.data
        }
        catch {
            $supersession = Get-MO2SynchronousCompletionSupersession -Config $Config -Owned $owned -SessionId $SessionId -Operation launch -AttemptId $launchAttemptId
            if (-not $supersession.superseded) { throw }
            return New-MO2SynchronousCompletionSupersededResult -Config $Config -Supersession $supersession -SessionId $SessionId
        }
    }

    if ($blockingDialog.Count -gt 0) {
        $dialogReceiptPath = Join-Path ([string]$lockData.sessionPath) 'mo2-launch-blocked-dialog.json'
        $dialogReceipt = [pscustomobject][ordered]@{
            contractVersion = $script:MO2ControlContractVersion
            sessionId = $SessionId
            classification = 'failed-to-write-settings'
            observedUtc = [DateTime]::UtcNow.ToString('o')
            dialog = $blockingDialog[0]
            processes = $status.processes
            safeCloseAction = 'close or stop will acknowledge only the exact OK button, then continue cooperative shutdown'
        }
        Write-MO2JsonAtomic -Path $dialogReceiptPath -Value $dialogReceipt
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'launch-blocked-dialog' -Data @{ sessionId = $SessionId; launcherPid = $process.Id; launchStartedReceiptPath = $launchStartedPath; dialogReceiptPath = $dialogReceiptPath; dialog = $blockingDialog[0]; processes = $status.processes; sessionPath = $lockData.sessionPath } -Errors @('MO2 reported Failed to write settings. The launch was classified immediately; use close/stop to acknowledge the exact dialog and shut down cooperatively.')
    }

    if (-not $gameOwned) {
        $launchError = if ($gameObserved) { "The observed game process did not satisfy exact current-launch ownership: $(@($gameProcessAdoption.reasons) -join ', ')." } else { "The primary game process '$primaryGameProcessName' was not observed within $TimeoutSeconds seconds. A launcher helper exit is non-terminal because an existing MO2 instance can accept the request asynchronously." }
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'launch-failed' -Data @{ launcherPid = $process.Id; launcherExited = $process.HasExited; launcherExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; gameProcessAdoption = $gameProcessAdoption; sessionPath = $lockData.sessionPath; launchStartedReceiptPath = $launchStartedPath } -Errors @($launchError)
    }
    return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'game-running' -Data @{ launcherPid = $process.Id; ownerPid = $ownerResolution.ownerPid; ownershipResolution = $ownerResolution; primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; sessionPath = $lockData.sessionPath; launchStartedReceiptPath = $launchStartedPath; rootBuilderRecovery = [bool]$RootBuilderRecovery; resumeDisposition = $resumeDisposition }
}

function Invoke-MO2RecoverRootBuilder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0 -or $inspection.processes.mo2.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $false -State 'blocked' -Data @{ sessionId = $SessionId; processes = $inspection.processes; sessionPath = $owned.data.sessionPath } -Errors @('RootBuilder recovery requires MO2 and the game/loader to be closed. Use close or recover-close first.')
    }
    $buildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($buildData.Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $true -State 'no-recovery-required' -Data @{ sessionId = $SessionId; activeBuildData = @(); sessionPath = $owned.data.sessionPath }
    }
    if ($buildData.Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $false -State 'blocked' -Data @{ sessionId = $SessionId; activeBuildData = @($buildData | ForEach-Object path); sessionPath = $owned.data.sessionPath } -Errors @('RootBuilder recovery requires exactly one active BuildData.json; multiple deployment records require manual classification.')
    }

    if (-not $WhatIf) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'rootbuilder-recovery-required' -TimestampProperty 'recoveryStartedUtc'
    }
    $result = Invoke-MO2Launch -Config $Config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -StartOnly:$StartOnly -RootBuilderRecovery -WhatIf:$WhatIf
    $result.command = 'recover-rootbuilder'
    $result.data | Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject][ordered]@{
        buildDataPath = [string]$buildData[0].path
        buildDataBytes = [long]$buildData[0].bytes
        strategy = 'one exact-profile launch followed by normal stop/Unlock so RootBuilder can restore its recorded deployment'
        destructiveCleanup = $false
    }) -Force
    return $result
}

function Invoke-MO2Open {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false } -Errors @('Opening visible MO2 requires execution as the logged-on user on the interactive desktop. Rerun this exact command through the approved elevated execution path.')
    }
    if ([string]$owned.data.status -notin @('prepared', 'mo2-closed', 'stopped')) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'blocked' -Data @{ lock = $owned } -Errors @("Session status '$($owned.data.status)' cannot open MO2.")
    }
    $validation = Invoke-MO2Validate -Config $Config -Profile ([string]$owned.data.profile) -Executable ([string]$owned.data.executable) -RequireClosed -OwnedSessionId $SessionId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned } -Warnings $validation.warnings -Errors $validation.errors
    }

    $mo2Path = [string]$validation.data.config.mo2Executable
    $arguments = @('--profile', [string]$owned.data.profile)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-MO2CommandLineArgument ([string]$_) }) -join ' '
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; path = $mo2Path; arguments = $arguments; argumentLine = $argumentLine; workingDirectory = (Split-Path -Parent $mo2Path); wouldOpenGame = $false; startOnly = [bool]$StartOnly }
    }

    $openStartedPath = Join-Path ([string]$owned.data.sessionPath) 'mo2-open-started.json'
    $openAttemptId = [guid]::NewGuid().ToString('D')
    $preOpenMO2Processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
    $openStarted = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $SessionId
        attemptId = $openAttemptId
        requestedPid = $null
        requestedProcessStartTime = $null
        mo2Path = $mo2Path
        arguments = $arguments
        argumentLine = $argumentLine
        timeoutSeconds = $TimeoutSeconds
        startedUtc = [DateTime]::UtcNow.ToString('o')
        dispatchStartedUtc = $null
        preDispatchProcesses = @($preOpenMO2Processes)
    }
    $dispatch = Invoke-MO2OwnedSessionMutation -Owned $owned -Action {
        param($currentData)
        if ([string]$currentData.status -notin @('prepared', 'mo2-closed', 'stopped')) {
            throw "Session status '$($currentData.status)' changed before open dispatch."
        }
        Write-MO2JsonAtomic -Path $openStartedPath -Value $openStarted
        $openDispatchedUtc = [DateTime]::UtcNow.ToString('o')
        $openStarted.dispatchStartedUtc = $openDispatchedUtc
        $process = Start-Process -FilePath $mo2Path -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $mo2Path) -PassThru
        $openOwner = [pscustomobject][ordered]@{
            id = [int]$process.Id
            name = [string]$process.ProcessName
            path = [IO.Path]::GetFullPath($mo2Path)
            startTime = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
        }
        $dispatchBoundChildren = if ([string]::IsNullOrWhiteSpace([string]$openOwner.startTime)) { @() } else { @(Get-MO2DispatchBoundChildEvidence -Config $Config -ParentProcess $process -ParentStartTime ([string]$openOwner.startTime) -DispatchStartedUtc $openDispatchedUtc) }
        $openStarted.requestedPid = $process.Id
        $openStarted.requestedProcessStartTime = [string]$openOwner.startTime
        $openStarted | Add-Member -NotePropertyName dispatchBoundChildren -NotePropertyValue @($dispatchBoundChildren) -Force
        $receiptWriteError = $null
        try { Write-MO2JsonAtomic -Path $openStartedPath -Value $openStarted } catch { $receiptWriteError = $_.Exception.Message }
        $ownerTransition = [pscustomobject][ordered]@{
            kind = 'open'
            attemptId = $openAttemptId
            dispatchStartedUtc = $openDispatchedUtc
            requestedPid = [int]$process.Id
            requestedProcessPath = [IO.Path]::GetFullPath($mo2Path)
            requestedProcessStartTime = [string]$openOwner.startTime
            preDispatchProcesses = @($preOpenMO2Processes)
            dispatchBoundChildren = @($dispatchBoundChildren)
            receiptPath = $openStartedPath
            detachedAdoptionAllowed = $true
        }
        $currentData | Add-Member -NotePropertyName ownerTransition -NotePropertyValue $ownerTransition -Force
        $null = Set-MO2OwnedSessionOwnerData -Data $currentData -ProcessRecord $openOwner -Reason 'exact MO2 process bound directly to open dispatch'
        $currentData.status = 'opening'
        $currentData | Add-Member -NotePropertyName openedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $currentData | Add-Member -NotePropertyName openStartedReceiptPath -NotePropertyValue $openStartedPath -Force
        return [pscustomobject][ordered]@{
            sessionData = $currentData
            result = [pscustomobject][ordered]@{ process = $process; openOwner = $openOwner; receiptWriteError = $receiptWriteError }
        }
    }
    $process = $dispatch.process
    $openOwner = $dispatch.openOwner
    if (-not [string]::IsNullOrWhiteSpace([string]$dispatch.receiptWriteError)) {
        throw "Open process $($process.Id) was recorded in the ownership lock, but its dispatch receipt could not be updated: $($dispatch.receiptWriteError)"
    }
    if ($StartOnly) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'opening' -Data @{ sessionId = $SessionId; requestedPid = $process.Id; openStartedReceiptPath = $openStartedPath; sessionPath = $owned.data.sessionPath; pollWith = "status -SessionId $SessionId"; gameOpened = $false }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observed = $null
    $observedResolution = $null
    do {
        Start-Sleep -Milliseconds 250
        $records = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        $observedResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes $records -AdoptDetachedOwner
        if ($observedResolution.ok -and @($observedResolution.targets).Count -eq 1) {
            $observed = @($observedResolution.targets)[0]
            break
        }
        if ($records.Count -gt 0 -and -not $observedResolution.ok) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $observed) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'open-failed' -Data @{ requestedPid = $process.Id; launcherExited = $process.HasExited; launcherExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); ownershipResolution = $observedResolution; openStartedReceiptPath = $openStartedPath; processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames)); sessionPath = $owned.data.sessionPath } -Errors @('The opening owner could not be confirmed as the original dispatch-bound process or one explicitly proven detached child. The recorded owner tuple was not replaced.')
    }
    $visibleMainWindow = $null
    do {
        # Process.MainWindowHandle is not a readiness signal: during startup it
        # can point at MessageDialog, the VFS Unlock prompt, or even a tooltip.
        # Only MO2's stable UIA identity proves that its actual main window is
        # ready. Other windows remain available to cooperative close/recovery.
        $visibleMainWindow = @(Get-MO2WindowSnapshot -Processes @($observed) | Where-Object {
            $_.visible -and $_.automationAvailable -and $_.automationId -eq 'MainWindow'
        }) | Select-Object -First 1
        if ($visibleMainWindow) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $visibleMainWindow) {
        try { Set-MO2OwnedSessionStatus -Owned $owned -Status 'open-incomplete' -TimestampProperty 'openedUtc' }
        catch {
            $supersession = Get-MO2SynchronousCompletionSupersession -Config $Config -Owned $owned -SessionId $SessionId -Operation open -AttemptId $openAttemptId
            if (-not $supersession.superseded) { throw }
            return New-MO2SynchronousCompletionSupersededResult -Config $Config -Supersession $supersession -SessionId $SessionId
        }
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'open-incomplete' -Data @{ ownerPid = $process.Id; openStartedReceiptPath = $openStartedPath; process = $observed; windows = @(Get-MO2WindowSnapshot -Processes @($observed)); sessionPath = $owned.data.sessionPath } -Errors @('The exact MO2 process started, but its visible MainWindow was not ready within the bounded timeout. The durable start receipt and adopted owner PID remain available for cooperative recovery.')
    }
    try { Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-open' -TimestampProperty 'openedUtc' }
    catch {
        $supersession = Get-MO2SynchronousCompletionSupersession -Config $Config -Owned $owned -SessionId $SessionId -Operation open -AttemptId $openAttemptId
        if (-not $supersession.superseded) { throw }
        return New-MO2SynchronousCompletionSupersededResult -Config $Config -Supersession $supersession -SessionId $SessionId
    }
    return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'mo2-open' -Data @{ sessionId = $SessionId; ownerPid = $process.Id; openStartedReceiptPath = $openStartedPath; process = $observed; mainWindow = $visibleMainWindow; sessionPath = $owned.data.sessionPath; gameOpened = $false }
}

function Invoke-MO2Close {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; lock = $owned } -Errors @('MO2-only close refuses while a game or loader process is running. Use stop for the full owned chain.')
    }

    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($inspection.processes.mo2)
    $ownerPid = [int]$resolution.ownerPid
    $targets = @($resolution.targets)
    if (-not $resolution.ok) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid; ownershipResolution = $resolution; lock = $owned } -Errors @('Cooperative close could not prove a unique MO2 process owned by this session.')
    }
    if (-not $WhatIf -and $targets.Count -gt 0 -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Cooperative MO2 close requires execution as the logged-on user on the interactive desktop. Rerun this exact command through the approved elevated execution path.')
    }
    if ($targets.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    }
    $windows = @(Get-MO2WindowSnapshot -Processes $targets)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; targets = $targets; windows = $windows; ownershipResolution = $resolution; alreadyClosed = $targets.Count -eq 0; wouldInvokeExactControls = @('File', 'Exit', 'Unlock', 'Cancel'); wouldRequestModalWindowClose = $targets.Count -gt 0; forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    if ($targets.Count -eq 0) {
        $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if ($activeBuildData.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'rootbuilder-recovery-required' -Data @{ sessionId = $SessionId; alreadyClosed = $true; activeBuildData = $activeBuildData; sessionPath = $owned.data.sessionPath } -Errors @('MO2 is closed but RootBuilder BuildData.json remains active. Use recover-rootbuilder for this exact session; do not delete deployment metadata.')
        }
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-closed' -TimestampProperty 'closedUtc'
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $true -State 'mo2-closed' -Data @{ sessionId = $SessionId; alreadyClosed = $true; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath }
    }

    $close = Invoke-MO2CooperativeClose -Config $Config -Owned $owned -InitialProcesses $targets -EvidenceDirectory ([string]$owned.data.sessionPath) -TimeoutSeconds $TimeoutSeconds
    $final = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $activeBuildData = @($final.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $closed = $close.closed -and $final.processes.mo2.Count -eq 0 -and $activeBuildData.Count -eq 0
    $status = if ($closed) { 'mo2-closed' } elseif ($close.closed -and $activeBuildData.Count -gt 0) { 'rootbuilder-recovery-required' } else { 'close-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'closedUtc'
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-close.json') -Value $close
    return New-MO2ActionResult -Config $Config -Command 'close' -Ok $closed -State $status -Data @{ sessionId = $SessionId; ownershipResolution = $resolution; close = $close; activeBuildData = $activeBuildData; sessionPath = $owned.data.sessionPath } -Errors $(if ($closed) { @() } elseif ($status -eq 'rootbuilder-recovery-required') { @('MO2 closed, but RootBuilder BuildData.json remains active. Use recover-rootbuilder for this exact session; do not delete deployment metadata.') } else { @('MO2 still owns one or more exact target processes after cooperative dialogue resolution; no force termination was attempted.') })
}

function Invoke-MO2RecoverClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$AccessId,
        [string]$Label = 'recovery-close',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $inspection = Get-MO2InspectionData -Config $Config
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @('Recovery close refuses while a game or loader process is running.')
    }
    $explicitAccess = -not [string]::IsNullOrWhiteSpace($AccessId)
    $accessLock = $null
    if ($inspection.sessionLock.exists) {
        if (-not $explicitAccess) {
            return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ lock = $inspection.sessionLock; processes = $inspection.processes } -Errors @('A session lock already exists. Pass its exact access-only AccessId, use close with its exact SessionId, or classify the stale lock before recovery.')
        }
        $accessLock = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$accessLock.sessionId)) {
            return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock; processes = $inspection.processes } -Errors @('The access lease already has a bound session. Use close with that exact SessionId.')
        }
    }
    elseif ($explicitAccess) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @("Access lease '$AccessId' does not exist.")
    }
    $targets = @($inspection.processes.mo2)
    if ($targets.Count -eq 0) {
        $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if ($activeBuildData.Count -gt 0) {
            return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'rootbuilder-recovery-required' -Data @{ accessId = $AccessId; accessRetained = $explicitAccess; targets = @(); activeBuildData = $activeBuildData; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('MO2 is closed but RootBuilder BuildData.json remains active. Bind or resume the exact session and use recover-rootbuilder; do not delete deployment metadata.')
        }
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $true -State 'already-closed' -Data @{ accessId = $AccessId; accessRetained = $explicitAccess; targets = @(); activeBuildData = @(); forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    if (-not $explicitAccess) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'missing-access-id' -Data @{ requiredParameter = 'AccessId'; supplied = $false; targets = $targets } -Errors @('Recovery close requires -AccessId from a route-qualified request-access lease before it can adopt a running MO2 process.')
    }
    if (-not $accessLock.data.PSObject.Properties['runtimeRoute']) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'runtime-route-upgrade-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock; targets = $targets } -Errors @('The access lease predates runtime-route qualification. Release it and request a new access lease with an explicit RuntimeRoute before recovery.')
    }
    $runtimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $accessLock.data.runtimeRoute
    Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    if ($targets.Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ targets = $targets } -Errors @('Recovery close requires exactly one configured MO2 process; multiple instances require manual classification.')
    }
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'interactive-desktop-required' -Data @{ processes = $inspection.processes; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Recovery close requires execution as the logged-on user on the interactive desktop. No recovery session or lock was created; rerun through the approved elevated execution path.')
    }

    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $sessionId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $safeLabel, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $sessionPath = Join-Path (Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)) $sessionId
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $createdUtc = [DateTime]::UtcNow.ToString('o')
    $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath -WhatIf
    $profileDirectory = Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) ([string]$inspection.requested.profile)
    $manifest = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $sessionId
        label = $safeLabel
        createdUtc = $createdUtc
        status = 'recovery-closing'
        profile = [string]$inspection.requested.profile
        profileName = [string]$inspection.requested.profile
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = [string]$inspection.requested.executable
        runtimeRoute = $runtimeRoute
        mo2Path = [string]$inspection.config.mo2Executable
        ownerPid = [int]$targets[0].id
        processPath = [IO.Path]::GetFullPath([string]$targets[0].path)
        processStartTime = [string]$targets[0].startTime
        recovery = $true
        accessId = $AccessId
        acquisitionMode = 'explicit-access'
        processesBefore = $inspection.processes
        windowsBefore = @(Get-MO2WindowSnapshot -Processes $targets)
        controllerPath = [string]$controller.controllerPath
        controllerConfigPath = [string]$controller.configPath
        controllerReceiptPath = [string]$controller.receiptPath
    }
    $lock = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $AccessId
        acquisitionMode = 'explicit-access'
        label = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['label']) { [string]$accessLock.data.label } else { $safeLabel })
        requestedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['requestedUtc']) { [string]$accessLock.data.requestedUtc } else { $createdUtc })
        lastRenewedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['lastRenewedUtc']) { [string]$accessLock.data.lastRenewedUtc } else { $createdUtc })
        estimatedDurationMinutes = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedDurationMinutes']) { $accessLock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedReleaseUtc']) { $accessLock.data.estimatedReleaseUtc } else { $null })
        ownerRequestPid = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['ownerRequestPid']) { $accessLock.data.ownerRequestPid } else { $PID })
        generation = $(if ($explicitAccess) { Get-MO2NextLeaseGeneration -Lease $accessLock.data } else { 1L })
        sessionId = $sessionId
        sessionPath = $sessionPath
        status = 'recovery-closing'
        createdUtc = $createdUtc
        profile = [string]$inspection.requested.profile
        profileName = [string]$inspection.requested.profile
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = [string]$inspection.requested.executable
        runtimeRoute = $runtimeRoute
        controllerPath = [string]$controller.controllerPath
        ownerPid = [int]$targets[0].id
        processPath = [IO.Path]::GetFullPath([string]$targets[0].path)
        processStartTime = [string]$targets[0].startTime
        recovery = $true
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $true -State 'dry-run' -Data @{ session = $manifest; lockPath = $lockPath; sessionPath = $sessionPath; accessId = $AccessId; explicitAccess = $explicitAccess; controller = $controller; controllerPath = [string]$controller.controllerPath; wouldBindAccessLock = $explicitAccess; targets = $targets; wouldInvokeExactControls = @('File', 'Exit', 'Unlock', 'Cancel'); wouldRequestModalWindowClose = $true; forceTermination = $false; unrelatedProcessesTouched = @() }
    }

    New-Item -ItemType Directory -Path $sessionPath -ErrorAction Stop | Out-Null
    try {
        $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath
        Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $manifest -CreateNew
        Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
            $currentAccess = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
            if (-not [string]::IsNullOrWhiteSpace([string]$currentAccess.sessionId)) {
                throw 'The access lease acquired a session before recovery close could bind it.'
            }
            $validatedRuntimeRoute = Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $currentAccess.data.runtimeRoute
            if ((Get-MO2RuntimeRouteContractFingerprint $validatedRuntimeRoute) -cne (Get-MO2RuntimeRouteContractFingerprint $runtimeRoute)) {
                throw "The access lease runtime route changed before recovery-close binding ('$($runtimeRoute.id)' to '$($validatedRuntimeRoute.id)')."
            }
            $bound = $currentAccess.data
            foreach ($propertyName in @('sessionId', 'sessionPath', 'status', 'createdUtc', 'profile', 'profileName', 'profileDirectory', 'modListPath', 'executable', 'runtimeRoute', 'controllerPath', 'ownerPid', 'processPath', 'processStartTime', 'recovery')) {
                $bound | Add-Member -NotePropertyName $propertyName -NotePropertyValue $lock.$propertyName -Force
            }
            $bound | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $currentAccess.data) -Force
            Write-MO2JsonAtomic -Path $lockPath -Value $bound
            try {
                Write-MO2SessionManifestProjection -SessionData $bound
            }
            catch {
                throw "The authoritative MO2 ownership lock committed generation $($bound.generation), but its session manifest projection failed and must be reconciled from that lock: $($_.Exception.Message)"
            }
        } | Out-Null
    }
    catch {
        throw "Failed to acquire recovery session '$sessionId'. Evidence is retained at '$sessionPath'. $($_.Exception.Message)"
    }

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $sessionId
    $close = Invoke-MO2CooperativeClose -Config $Config -Owned $owned -InitialProcesses $targets -EvidenceDirectory $sessionPath -TimeoutSeconds $TimeoutSeconds
    $final = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $activeBuildData = @($final.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $closed = $close.closed -and $final.processes.mo2.Count -eq 0 -and $activeBuildData.Count -eq 0
    $status = if ($closed) { 'mo2-closed' } elseif ($close.closed -and $activeBuildData.Count -gt 0) { 'rootbuilder-recovery-required' } else { 'close-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'closedUtc'
    Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'mo2-close.json') -Value $close
    return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $closed -State $status -Data @{ sessionId = $sessionId; accessId = $AccessId; explicitAccess = $explicitAccess; lockPath = $lockPath; sessionPath = $sessionPath; controller = $controller; controllerPath = [string]$controller.controllerPath; close = $close; activeBuildData = $activeBuildData; releaseRequired = $closed } -Errors $(if ($closed) { @() } elseif ($status -eq 'rootbuilder-recovery-required') { @('MO2 closed, but RootBuilder BuildData.json remains active. Use recover-rootbuilder for this exact session; the recovery lock and evidence were retained.') } else { @('MO2 remains after cooperative recovery close. The recovery lock and evidence were retained; no force termination was attempted.') })
}

function Wait-MO2RetainedProcessStability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$InitialInspection,
        [ValidateRange(250, 10000)][int]$StabilityMilliseconds = 2000,
        [ValidateRange(50, 1000)][int]$PollMilliseconds = 250,
        [scriptblock]$InspectionFactory
    )

    $samples = [Collections.Generic.List[object]]::new()
    $current = $InitialInspection
    $ownerPid = if ($Owned.data.PSObject.Properties['ownerPid']) { [int]$Owned.data.ownerPid } else { 0 }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($StabilityMilliseconds)
    do {
        $mo2 = @($current.processes.mo2)
        $ownerPresent = $ownerPid -gt 0 -and @($mo2 | Where-Object { [int]$_.id -eq $ownerPid }).Count -eq 1
        $samples.Add([pscustomobject][ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            mo2ProcessIds = @($mo2 | ForEach-Object { [int]$_.id })
            ownerPid = $ownerPid
            ownerPresent = $ownerPresent
        })
        if (-not $ownerPresent) { break }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
        $current = if ($InspectionFactory) {
            & $InspectionFactory
        }
        else {
            Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$Owned.data.profile) -RequestedExecutable ([string]$Owned.data.executable)
        }
    } while ($true)

    $last = $samples[$samples.Count - 1]
    return [pscustomobject][ordered]@{
        stable = [bool]$last.ownerPresent -and [DateTime]::UtcNow -ge $deadline
        ownerPid = $ownerPid
        stabilityMilliseconds = $StabilityMilliseconds
        pollMilliseconds = $PollMilliseconds
        samples = @($samples)
        finalInspection = $current
    }
}

function Invoke-MO2StopGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false } -Errors @('Graceful game close requires execution as the logged-on user on the interactive desktop.')
    }
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $targets = @($before.processes.game)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestClose = $targets; wouldLeaveMO2Running = $true; forceTermination = $false }
    }

    $gameClose = Invoke-MO2OwnedGameCloseRequest -Config $Config -Owned $owned
    if (-not $gameClose.ok) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $false -State 'blocked' -Data @{ before = $before.processes; gameClose = $gameClose; sessionPath = $owned.data.sessionPath } -Errors @('A game process changed identity or session authority before graceful close; no close request was sent to an unverified process.')
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $closed = $after.processes.game.Count -eq 0
    $retention = $null
    if ($closed) {
        $retention = Wait-MO2RetainedProcessStability -Config $Config -Owned $owned -InitialInspection $after
        $after = $retention.finalInspection
        Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-retention-stability.json') -Value $retention
    }
    $dialogCleanup = $null
    $dialogNeedsAttention = $false
    if ($closed -and $after.processes.mo2.Count -gt 0) {
        $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($after.processes.mo2)
        if ($resolution.ok) {
            $dialogCleanup = Invoke-MO2RetainedSessionDialogCleanup -Config $Config -Owned $owned -Processes @($resolution.targets)
            $dialogNeedsAttention = -not $dialogCleanup.cleared -or @($dialogCleanup.needsAttention).Count -gt 0
        }
        else {
            $dialogCleanup = [pscustomobject][ordered]@{ cleared = $false; ownershipResolution = $resolution; needsAttention = @('Could not prove one exact retained MO2 owner for dialog cleanup.') }
            $dialogNeedsAttention = $true
        }
        Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-retained-dialog-cleanup.json') -Value $dialogCleanup
    }
    $mo2Retained = $closed -and $retention -and $retention.stable
    $owned.data.status = if (-not $closed) { 'game-stop-incomplete' } elseif (-not $mo2Retained) { 'mo2-exited-after-game-stop' } elseif ($dialogNeedsAttention) { 'game-stopped-needs-attention' } else { 'game-stopped' }
    $owned.data | Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $owned.data

    $ok = $closed -and $mo2Retained -and -not $dialogNeedsAttention
    return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $ok -State $owned.data.status -Data @{ before = $before.processes; after = $after.processes; mo2Retained = $mo2Retained; retention = $retention; releaseRequired = $closed -and -not $mo2Retained; retainedDialogCleanup = $dialogCleanup; forceTermination = $false; sessionPath = $owned.data.sessionPath } -Errors $(
        if (-not $closed) { @('The game did not accept a graceful close request; no force termination was attempted.') }
        elseif (-not $mo2Retained) { @('The game stopped, but the exact session-owned MO2 process exited during the retention stability window. The same session can reopen its exact profile with launch, or it must be released before another task receives MO2.') }
        elseif ($dialogNeedsAttention) { @('The game stopped, but an unclassified or uncleared retained MO2 dialog needs attention; no unrelated window was touched.') }
        else { @() }
    )
}

function Resolve-MO2RecordedGameProcessTargets {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recorded,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Current
    )

    $targets = [Collections.Generic.List[object]]::new()
    foreach ($recordedProcess in $Recorded) {
        $matches = @($Current | Where-Object { [int]$_.id -eq [int]$recordedProcess.id })
        if ($matches.Count -eq 0) { continue }
        if ($matches.Count -ne 1) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'recorded-game-pid-ambiguous'; recorded = $recordedProcess; current = $matches; targets = @($targets) }
        }
        $identity = Test-MO2ProcessRecordIdentity -Expected $recordedProcess -Actual $matches[0]
        if (-not $identity.ok) {
            return [pscustomobject][ordered]@{ ok = $false; reason = [string]$identity.reason; identity = $identity; recorded = $recordedProcess; current = $matches; targets = @($targets) }
        }
        $targets.Add($matches[0])
    }
    if ($Current.Count -gt $targets.Count) {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'unrecorded-game-process-present'; recorded = $Recorded; current = $Current; targets = @($targets) }
    }
    return [pscustomobject][ordered]@{ ok = $true; reason = if ($targets.Count -eq 0) { 'game-already-stopped' } else { 'exact-recorded-game-processes' }; recorded = $Recorded; current = $Current; targets = @($targets) }
}

function Invoke-MO2VerifiedGameTerminationSet {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [switch]$WhatIf,
        [scriptblock]$BindingFactory,
        [scriptblock]$TerminationAction
    )

    if (-not $BindingFactory) {
        $BindingFactory = {
            param([int]$ProcessId)
            $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $process) {
                return [pscustomobject][ordered]@{ available = $false; reason = 'process-exited'; process = $null; record = $null }
            }
            try {
                # Retaining SafeHandle binds this object to the exact kernel process;
                # later PID reuse cannot redirect Process.Kill().
                $handle = $process.SafeHandle
                if ($handle.IsInvalid -or $handle.IsClosed) { throw 'The process handle is unavailable.' }
                $record = [pscustomobject][ordered]@{
                    name = $process.ProcessName
                    id = $process.Id
                    path = [IO.Path]::GetFullPath($process.Path)
                    startTime = $process.StartTime.ToUniversalTime().ToString('o')
                }
                return [pscustomobject][ordered]@{ available = $true; reason = 'bound'; process = $process; record = $record }
            }
            catch {
                $process.Dispose()
                return [pscustomobject][ordered]@{ available = $false; reason = 'live-process-identity-unavailable'; process = $null; record = $null; detail = $_.Exception.Message }
            }
        }
    }

    $expectedPaths = Get-MO2ExpectedGameProcessPaths -Config $Config -Owned $Owned
    if (-not $expectedPaths.ok) {
        return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$expectedPaths.reason; targets = @(); bindings = @() }
    }
    $bindings = [Collections.Generic.List[object]]::new()
    $verified = [Collections.Generic.List[object]]::new()
    try {
        foreach ($target in $Targets) {
            $binding = & $BindingFactory ([int]$target.id)
            if (-not $binding.available) {
                if ([string]$binding.reason -eq 'process-exited') { continue }
                return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$binding.reason; target = $target; targets = @($verified); detail = [string]$binding.detail }
            }
            $bindings.Add($binding)
            $liveRecord = $binding.record
            $identity = Test-MO2ProcessRecordIdentity -Expected $target -Actual $liveRecord
            if (-not $identity.ok) {
                return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$identity.reason; target = $target; liveIdentity = $liveRecord; identity = $identity; targets = @($verified) }
            }
            $name = [string]$liveRecord.name
            if (-not $expectedPaths.pathsByName.ContainsKey($name)) {
                return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'live-process-name-not-configured'; target = $target; liveIdentity = $liveRecord; targets = @($verified) }
            }
            $configuredPaths = $expectedPaths.pathsByName[$name]
            if ($configuredPaths.Count -ne 1 -or -not $configuredPaths.Contains([IO.Path]::GetFullPath([string]$liveRecord.path))) {
                return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'live-process-path-not-configured'; target = $target; liveIdentity = $liveRecord; targets = @($verified) }
            }
            $verified.Add($liveRecord)
        }
        if ($WhatIf) {
            return [pscustomobject][ordered]@{ ok = $true; state = 'verified-dry-run'; reason = 'exact-recorded-game-processes'; targets = @($verified) }
        }
        foreach ($binding in $bindings) {
            if ($TerminationAction) { & $TerminationAction $binding.process }
            else { $binding.process.Kill() }
        }
        return [pscustomobject][ordered]@{ ok = $true; state = 'termination-requested'; reason = 'exact-recorded-game-processes'; targets = @($verified) }
    }
    finally {
        foreach ($binding in $bindings) {
            if ($binding.process -is [IDisposable]) { $binding.process.Dispose() }
        }
    }
}

function Invoke-MO2VerifiedGameCloseRequestSet {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [scriptblock]$BindingFactory,
        [scriptblock]$CloseAction
    )

    $requestClose = if ($CloseAction) {
        $CloseAction
    }
    else {
        { param($process) $null = $process.CloseMainWindow() }
    }
    $result = Invoke-MO2VerifiedGameTerminationSet -Config $Config -Owned $Owned -Targets $Targets -BindingFactory $BindingFactory -TerminationAction $requestClose
    if ($result.ok) {
        $result.state = 'close-requested'
    }
    return $result
}

function Invoke-MO2CurrentGameCloseRequest {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$CurrentData,
        [Parameter(Mandatory)]$CurrentInspection,
        [scriptblock]$BindingFactory,
        [scriptblock]$CloseAction
    )

    # Session state, not a pre-lock inventory, defines the owned game set. An
    # additional configured game/loader process is an ambiguity and vetoes all
    # close requests, even when it appeared in the caller's earlier inspection.
    $resolution = Resolve-MO2RecordedGameProcessTargets -Recorded @($CurrentData.gameProcesses) -Current @($CurrentInspection.processes.game)
    if (-not $resolution.ok) {
        return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$resolution.reason; gameResolution = $resolution }
    }
    $ownerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $Owned -Processes @($CurrentInspection.processes.mo2)
    if (-not $ownerResolution.ok -or @($ownerResolution.targets).Count -ne 1) {
        return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'mo2-owner-changed-before-game-close'; ownershipResolution = $ownerResolution }
    }
    return Invoke-MO2VerifiedGameCloseRequestSet -Config $Config -Owned $Owned -Targets @($resolution.targets) -BindingFactory $BindingFactory -CloseAction $CloseAction
}

function Invoke-MO2OwnedGameCloseRequest {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [scriptblock]$InspectionFactory,
        [scriptblock]$BindingFactory,
        [scriptblock]$CloseAction
    )

    return Invoke-MO2OwnedSessionMutation -Owned $Owned -Action {
        param($currentData)
        $currentOwned = [pscustomobject][ordered]@{ path = $Owned.path; sessionId = $Owned.sessionId; accessId = $Owned.accessId; data = $currentData }
        $currentInspection = if ($InspectionFactory) {
            & $InspectionFactory $Config $currentData
        }
        else {
            Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$currentData.profile) -RequestedExecutable ([string]$currentData.executable)
        }
        $verified = Invoke-MO2CurrentGameCloseRequest -Config $Config -Owned $currentOwned -CurrentData $currentData -CurrentInspection $currentInspection -BindingFactory $BindingFactory -CloseAction $CloseAction
        return [pscustomobject][ordered]@{ commit = $false; sessionData = $currentData; result = $verified }
    }
}

function Invoke-MO2TerminateGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )
    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($inspection.processes.mo2)
    if (-not $resolution.ok -or @($resolution.targets).Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ ownershipResolution=$resolution; processes=$inspection.processes } -Errors @('Exact-session game termination requires one proven MO2 runtime owner so RootBuilder can restore afterward.')
    }
    if (-not $owned.data.PSObject.Properties['gameProcesses'] -or @($owned.data.gameProcesses).Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ processes=$inspection.processes } -Errors @('The session has no launch-recorded game/loader process identities; refusing process-name termination.')
    }
    $gameResolution = Resolve-MO2RecordedGameProcessTargets -Recorded @($owned.data.gameProcesses) -Current @($inspection.processes.game)
    if (-not $gameResolution.ok) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ gameResolution=$gameResolution } -Errors @('A current game process does not match the exact recorded PID, name, executable path, and start instant; refusing possible PID reuse or partial process-name termination.')
    }
    $targets = @($gameResolution.targets)
    if ($targets.Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $true -State 'game-already-stopped' -Data @{ sessionId=$SessionId; mo2Retained=$true; targets=@(); forceTermination=$false }
    }
    if ($WhatIf) {
        $verification = Invoke-MO2VerifiedGameTerminationSet -Config $Config -Owned $owned -Targets $targets -WhatIf
        if (-not $verification.ok) {
            return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ gameTermination=$verification } -Errors @('A launch-recorded game identity changed before dry-run authorization; refusing possible PID reuse.')
        }
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $true -State 'dry-run' -Data @{ sessionId=$SessionId; wouldForceTerminateExactRecordedGameProcesses=$verification.targets; wouldRetainMO2=$resolution.targets; wouldInvokeExactControls=@('Unlock'); wouldRequireBuildDataRemoval=$true }
    }
    if (-not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId=$SessionId; targets=$targets } -Errors @('Exact Unlock handling after game termination requires the logged-on interactive desktop.')
    }
    $termination = Invoke-MO2OwnedSessionMutation -Owned $owned -Action {
        param($currentData)
        $currentOwned = [pscustomobject][ordered]@{ path = $owned.path; sessionId = $owned.sessionId; accessId = $owned.accessId; data = $currentData }
        $currentInspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$currentData.profile) -RequestedExecutable ([string]$currentData.executable)
        $currentOwnerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $currentOwned -Processes @($currentInspection.processes.mo2)
        if (-not $currentOwnerResolution.ok -or @($currentOwnerResolution.targets).Count -ne 1) {
            return [pscustomobject][ordered]@{ commit = $false; sessionData = $currentData; result = [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'mo2-owner-changed-before-game-termination'; ownershipResolution = $currentOwnerResolution } }
        }
        $currentGameResolution = Resolve-MO2RecordedGameProcessTargets -Recorded @($currentData.gameProcesses) -Current @($currentInspection.processes.game)
        if (-not $currentGameResolution.ok) {
            return [pscustomobject][ordered]@{ commit = $false; sessionData = $currentData; result = [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$currentGameResolution.reason; resolution = $currentGameResolution } }
        }
        $verified = Invoke-MO2VerifiedGameTerminationSet -Config $Config -Owned $currentOwned -Targets @($currentGameResolution.targets)
        if ($verified.ok) {
            $currentData.status = 'game-termination-requested'
            $currentData | Add-Member -NotePropertyName gameTerminationRequestedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $currentData | Add-Member -NotePropertyName gameTerminationTargets -NotePropertyValue @($verified.targets) -Force
        }
        return [pscustomobject][ordered]@{ commit = [bool]$verified.ok; sessionData = $currentData; result = $verified }
    }
    if (-not $termination.ok) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ gameTermination=$termination } -Errors @('A launch-recorded game identity changed before force termination; no PID-based fallback was attempted.')
    }
    $targets = @($termination.targets)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $afterTermination = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if (@($afterTermination.processes.game | Where-Object { @($targets.id) -contains [int]$_.id }).Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($afterTermination.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'game-terminate-incomplete' -Data @{ targets=$targets; remaining=$afterTermination.processes.game } -Errors @('One or more exact recorded game processes remained after termination.')
    }
    $remainingSeconds = [math]::Max(1, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
    $rootBuilder = Invoke-MO2UnlockOnly -Config $Config -Owned $owned -TimeoutSeconds $remainingSeconds
    $success = $rootBuilder.restored -and @($rootBuilder.gameProcesses).Count -eq 0 -and @($rootBuilder.mo2Processes | Where-Object { [int]$_.id -eq [int]$resolution.ownerPid }).Count -eq 1
    $state = if ($success) { 'game-terminated-rootbuilder-restored' } else { 'rootbuilder-recovery-pending' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $state -TimestampProperty 'gameTerminatedUtc'
    $receipt = [pscustomobject][ordered]@{ contractVersion=$script:MO2ControlContractVersion; sessionId=$SessionId; terminatedProcesses=$targets; rootBuilder=$rootBuilder; completedUtc=[DateTime]::UtcNow.ToString('o') }
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-terminate-game.json') -Value $receipt
    return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $success -State $state -Data @{ sessionId=$SessionId; terminatedProcesses=$targets; mo2Retained=$success; rootBuilder=$rootBuilder; receiptPath=(Join-Path ([string]$owned.data.sessionPath) 'mo2-terminate-game.json') } -Errors $(if ($success) { @() } else { @('The game ended, but MO2 ownership and RootBuilder BuildData cleanup were not both verified before the timeout.') })
}

function Invoke-MO2Stop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Full graceful stop requires execution as the logged-on user on the interactive desktop.')
    }
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $gameTargets = @($before.processes.game)
    $mo2Targets = @($before.processes.mo2)
    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes $mo2Targets
    $ownerPid = [int]$resolution.ownerPid
    $ownedMO2 = @($resolution.targets)
    if (-not $resolution.ok) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'blocked' -Data @{ processes = $before.processes; ownerPid = $ownerPid; ownershipResolution = $resolution; lock = $owned } -Errors @('Full stop could not prove or adopt exactly one MO2 runtime owner.')
    }
    if ($ownedMO2.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $ownedMO2
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestGameClose = $gameTargets; wouldCooperativelyCloseMO2 = $ownedMO2; mo2Windows = @(Get-MO2WindowSnapshot -Processes $ownedMO2); wouldInvokeExactControls = @('File', 'Exit', 'Unlock', 'Cancel'); forceTermination = $false; unrelatedProcessesTouched = @() }
    }

    $gameClose = Invoke-MO2OwnedGameCloseRequest -Config $Config -Owned $owned
    if (-not $gameClose.ok) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'blocked' -Data @{ before = $before.processes; gameClose = $gameClose; mo2CloseAttempted = $false; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath } -Errors @('A game process changed identity or session authority before graceful close; MO2 cooperative close was not attempted.')
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($after.processes.game.Count -gt 0) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'game-stop-incomplete' -TimestampProperty 'stoppedUtc'
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'game-stop-incomplete' -Data @{ before = $before.processes; after = $after.processes; mo2CloseAttempted = $false; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath } -Errors @('The game did not accept a graceful close request, so MO2 cooperative close was not attempted.')
    }

    $remainingSeconds = [math]::Max(1, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
    $currentOwnerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($after.processes.mo2)
    $currentMO2 = @($currentOwnerResolution.targets)
    $close = if ($currentOwnerResolution.ok -and $currentMO2.Count -eq 1) {
        Invoke-MO2CooperativeClose -Config $Config -Owned $owned -InitialProcesses $currentMO2 -EvidenceDirectory ([string]$owned.data.sessionPath) -TimeoutSeconds $remainingSeconds
    }
    elseif ($after.processes.mo2.Count -eq 0) {
        [pscustomobject][ordered]@{ closed = $true; targetProcessIds = @(); beforeWindows = @(); actions = @(); remaining = @(); remainingWindows = @(); forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    else {
        [pscustomobject][ordered]@{ closed = $false; ownerIdentityVerified = $false; blockedReason = [string]$currentOwnerResolution.reason; ownershipResolution = $currentOwnerResolution; targetProcessIds = @(); beforeWindows = @(); actions = @(); remaining = @($after.processes.mo2); remainingWindows = @(); forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    $final = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $activeBuildData = @($final.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $closed = $final.processes.game.Count -eq 0 -and $final.processes.mo2.Count -eq 0 -and $close.closed -and $activeBuildData.Count -eq 0
    $status = if ($closed) { 'stopped' } elseif ($final.processes.game.Count -eq 0 -and $final.processes.mo2.Count -eq 0 -and $activeBuildData.Count -gt 0) { 'rootbuilder-recovery-required' } else { 'stop-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'stoppedUtc'
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-stop.json') -Value $close

    return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $closed -State $status -Data @{ before = $before.processes; afterGameClose = $after.processes; after = $final.processes; activeBuildData = $activeBuildData; mo2Close = $close; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath } -Errors $(if ($closed) { @() } elseif ($status -eq 'rootbuilder-recovery-required') { @('All owned processes closed, but RootBuilder BuildData.json remains active. Use recover-rootbuilder for this exact session; do not delete deployment metadata.') } else { @('One or more exact owned processes remained after graceful game close and cooperative MO2 dialogue resolution; no force termination was attempted.') })
}

function Invoke-MO2ReleaseTransition {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionPath,
        [scriptblock]$InspectionFactory
    )

    $releaseAction = {
        param($CurrentOwned, $RequestedSessionId, $RetainedSessionPath, $FixtureConfig, $CurrentInspectionFactory)
        try {
            $current = Assert-MO2OwnedSessionTransitionCurrent -Owned $CurrentOwned
        }
        catch {
            return New-MO2ActionResult -Config $FixtureConfig -Command 'release' -Ok $false -State 'blocked' -Data @{ lock = Get-MO2SessionLockRecord -Path $CurrentOwned.path; sessionPath = $RetainedSessionPath } -Errors @("Lock ownership or generation changed before release; the newer lifecycle was retained. $($_.Exception.Message)")
        }

        $currentInspection = if ($CurrentInspectionFactory) {
            & $CurrentInspectionFactory $FixtureConfig $current.data
        }
        else {
            Get-MO2InspectionData -Config $FixtureConfig -RequestedProfile ([string]$current.data.profile) -RequestedExecutable ([string]$current.data.executable)
        }
        $activeBuildData = @($currentInspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if (@($currentInspection.processes.game).Count -gt 0 -or @($currentInspection.processes.mo2).Count -gt 0 -or $activeBuildData.Count -gt 0) {
            return New-MO2ActionResult -Config $FixtureConfig -Command 'release' -Ok $false -State 'blocked' -Data @{ processes = $currentInspection.processes; activeBuildData = $activeBuildData; lock = $current; sessionPath = $RetainedSessionPath } -Errors @('The session became active before release; its current lifecycle and evidence were retained.')
        }

        $nextGeneration = Get-MO2NextLeaseGeneration -Lease $current.data
        $manifestPath = Join-Path $RetainedSessionPath 'session.json'
        $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.status = 'released'
        $manifest | Add-Member -NotePropertyName releasedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $manifest | Add-Member -NotePropertyName generation -NotePropertyValue $nextGeneration -Force
        Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

        if ($current.acquisitionMode -eq 'explicit-access') {
            $accessOnly = $current.data
            $accessOnly.status = 'access-held'
            $accessOnly.sessionId = $null
            $accessOnly.sessionPath = $null
            $accessOnly | Add-Member -NotePropertyName lastSessionId -NotePropertyValue $RequestedSessionId -Force
            $accessOnly | Add-Member -NotePropertyName lastSessionReleasedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $accessOnly | Add-Member -NotePropertyName generation -NotePropertyValue $nextGeneration -Force
            if ($accessOnly.PSObject.Properties['ownerPid']) { $accessOnly.PSObject.Properties.Remove('ownerPid') }
            Write-MO2JsonAtomic -Path $CurrentOwned.path -Value $accessOnly
            return New-MO2ActionResult -Config $FixtureConfig -Command 'release' -Ok $true -State 'session-released-access-retained' -Data @{ sessionId = $RequestedSessionId; accessId = $current.accessId; lockPath = $CurrentOwned.path; sessionPath = $RetainedSessionPath; lockRemoved = $false; accessRetained = $true; sessionRetained = $true; releaseAccessRequired = $true }
        }
        Remove-Item -LiteralPath $CurrentOwned.path -Force
        return New-MO2ActionResult -Config $FixtureConfig -Command 'release' -Ok $true -State 'released' -Data @{ sessionId = $RequestedSessionId; accessId = $current.accessId; lockPath = $CurrentOwned.path; sessionPath = $RetainedSessionPath; lockRemoved = $true; accessRetained = $false; sessionRetained = $true }
    }
    return Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action $releaseAction -ArgumentList @($Owned, $SessionId, $SessionPath, $Config, $InspectionFactory)
}

function Invoke-MO2Release {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $closed = $inspection.processes.game.Count -eq 0 -and $inspection.processes.mo2.Count -eq 0 -and $activeBuildData.Count -eq 0
    if (-not $closed) {
        $state = if ($inspection.processes.game.Count -eq 0 -and $inspection.processes.mo2.Count -eq 0 -and $activeBuildData.Count -gt 0) { 'rootbuilder-recovery-required' } else { 'blocked' }
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $false -State $state -Data @{ processes = $inspection.processes; activeBuildData = $activeBuildData; lock = $owned } -Errors @($(if ($state -eq 'rootbuilder-recovery-required') { 'The session cannot be released while RootBuilder BuildData.json remains active. Use recover-rootbuilder for this exact session; do not delete deployment metadata.' } else { 'The session cannot be released while MO2 or the game is running.' }))
    }
    if ($WhatIf) {
        $wouldRetainAccess = $owned.acquisitionMode -eq 'explicit-access'
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; lockPath = $owned.path; sessionPath = $owned.data.sessionPath; accessId = $owned.accessId; wouldRemoveLock = -not $wouldRetainAccess; wouldRetainAccess = $wouldRetainAccess; wouldRetainSessionEvidence = $true }
    }

    $sessionPath = [string]$owned.data.sessionPath
    return Invoke-MO2ReleaseTransition -Config $Config -Owned $owned -SessionId $SessionId -SessionPath $sessionPath
}

function Invoke-MO2VerifiedForceTermination {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Target,
        [switch]$WhatIf,
        [scriptblock]$BindingFactory,
        [scriptblock]$TerminationAction
    )

    if (-not $BindingFactory) {
        $BindingFactory = {
            param([int]$ProcessId)
            $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $process) {
                return [pscustomobject][ordered]@{ available = $false; reason = 'process-exited'; process = $null; record = $null }
            }
            try {
                # Opening and retaining SafeHandle binds the Process object to this exact
                # kernel process. A later PID reuse cannot redirect Process.Kill().
                $handle = $process.SafeHandle
                if ($handle.IsInvalid -or $handle.IsClosed) { throw 'The process handle is unavailable.' }
                $record = [pscustomobject][ordered]@{
                    name = $process.ProcessName
                    id = $process.Id
                    path = [IO.Path]::GetFullPath($process.Path)
                    startTime = $process.StartTime.ToUniversalTime().ToString('o')
                }
                return [pscustomobject][ordered]@{ available = $true; reason = 'bound'; process = $process; record = $record }
            }
            catch {
                $process.Dispose()
                return [pscustomobject][ordered]@{ available = $false; reason = 'live-process-identity-unavailable'; process = $null; record = $null; detail = $_.Exception.Message }
            }
        }
    }

    $binding = & $BindingFactory ([int]$Target.id)
    if (-not $binding.available) {
        if ([string]$binding.reason -eq 'process-exited') {
            return [pscustomobject][ordered]@{ ok = $true; state = 'already-exited'; target = $Target; liveIdentity = $null; identity = $null }
        }
        return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$binding.reason; target = $Target; liveIdentity = $null; identity = $null; detail = [string]$binding.detail }
    }

    try {
        $liveRecord = $binding.record
        if ([int]$liveRecord.id -ne [int]$Target.id) {
            return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'live-process-id-mismatch'; target = $Target; liveIdentity = $liveRecord; identity = $null }
        }
        $identity = Test-MO2OwnedProcessIdentity -Owned $Owned -ProcessRecord $liveRecord
        if (-not $identity.ok) {
            return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$identity.reason; target = $Target; liveIdentity = $liveRecord; identity = $identity }
        }
        $expectedMO2Path = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
        if (-not (Test-MO2ExactProcessPath -Record $liveRecord -ExpectedPath $expectedMO2Path) -or @($Config.mo2.processNames) -notcontains [string]$liveRecord.name) {
            return [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = 'live-process-not-exact-configured-mo2'; target = $Target; liveIdentity = $liveRecord; identity = $identity }
        }
        if ($WhatIf) {
            return [pscustomobject][ordered]@{ ok = $true; state = 'verified-dry-run'; target = $Target; liveIdentity = $liveRecord; identity = $identity }
        }
        if ($TerminationAction) {
            & $TerminationAction $binding.process
        }
        else {
            $binding.process.Kill()
        }
        return [pscustomobject][ordered]@{ ok = $true; state = 'termination-requested'; target = $Target; liveIdentity = $liveRecord; identity = $identity }
    }
    finally {
        if ($binding.process -is [IDisposable]) { $binding.process.Dispose() }
    }
}

function Invoke-MO2Terminate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
        [switch]$WhatIf,
        [scriptblock]$InspectionFactory
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = if ($InspectionFactory) {
        & $InspectionFactory $Config $owned.data
    }
    else {
        Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    }
    if (@($inspection.processes.game).Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while a game/loader process is running.')
    }
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ buildData = @($activeBuildData | ForEach-Object { [string]$_.path }); processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while RootBuilder BuildData.json remains active.')
    }
    $ownerPid = if ($owned.data.PSObject.Properties['ownerPid']) { [int]$owned.data.ownerPid } else { 0 }
    $targets = @($inspection.processes.mo2 | Where-Object { [int]$_.id -eq $ownerPid })
    if (@($inspection.processes.mo2).Count -gt 0 -and ($ownerPid -le 0 -or $targets.Count -ne 1 -or @($inspection.processes.mo2).Count -ne 1)) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid } -Errors @('Forced termination requires exactly one configured MO2 process matching the session owner PID.')
    }
    if ($targets.Count -gt 0) {
        $ownerIdentity = Test-MO2OwnedProcessIdentity -Owned $owned -ProcessRecord $targets[0]
        if (-not $ownerIdentity.ok) {
            return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid; ownerIdentity = $ownerIdentity } -Errors @('Forced termination requires the exact recorded MO2 executable path and process start time.')
        }
        Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    }
    $forceTermination = $null
    if ($targets.Count -gt 0) {
        if ($WhatIf) {
            $forceTermination = Invoke-MO2VerifiedForceTermination -Config $Config -Owned $owned -Target $targets[0] -WhatIf
        }
        else {
            $forceTermination = Invoke-MO2OwnedSessionMutation -Owned $owned -Action {
                param($currentData)
                $currentOwned = [pscustomobject][ordered]@{ path = $owned.path; sessionId = $owned.sessionId; accessId = $owned.accessId; data = $currentData }
                $currentInspection = if ($InspectionFactory) {
                    & $InspectionFactory $Config $currentData
                }
                else {
                    Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$currentData.profile) -RequestedExecutable ([string]$currentData.executable)
                }
                $currentActiveBuildData = @($currentInspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
                if (@($currentInspection.processes.game).Count -gt 0 -or $currentActiveBuildData.Count -gt 0) {
                    $reason = if (@($currentInspection.processes.game).Count -gt 0) { 'game-or-loader-became-active' } else { 'rootbuilder-builddata-became-active' }
                    return [pscustomobject][ordered]@{
                        commit = $false
                        sessionData = $currentData
                        result = [pscustomobject][ordered]@{
                            ok = $false
                            state = 'blocked'
                            reason = $reason
                            gameProcesses = @($currentInspection.processes.game)
                            activeRootBuilderBuildData = @($currentActiveBuildData | ForEach-Object { [string]$_.path })
                        }
                    }
                }
                $currentProcesses = @($currentInspection.processes.mo2)
                $currentResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $currentOwned -Processes $currentProcesses
                if (-not $currentResolution.ok -or @($currentResolution.targets).Count -ne 1) {
                    return [pscustomobject][ordered]@{ commit = $false; sessionData = $currentData; result = [pscustomobject][ordered]@{ ok = $false; state = 'blocked'; reason = [string]$currentResolution.reason; ownershipResolution = $currentResolution } }
                }
                $verified = Invoke-MO2VerifiedForceTermination -Config $Config -Owned $currentOwned -Target @($currentResolution.targets)[0]
                if ($verified.ok) {
                    $currentData.status = 'mo2-termination-requested'
                    $currentData | Add-Member -NotePropertyName terminationRequestedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                    $currentData | Add-Member -NotePropertyName terminationTarget -NotePropertyValue $verified.liveIdentity -Force
                }
                return [pscustomobject][ordered]@{ commit = [bool]$verified.ok; sessionData = $currentData; result = $verified }
            }
        }
        if (-not $forceTermination.ok) {
            $message = if ([string]$forceTermination.reason -eq 'game-or-loader-became-active') {
                'A game or loader became active before the serialized termination boundary; forced MO2 termination is refused.'
            }
            elseif ([string]$forceTermination.reason -eq 'rootbuilder-builddata-became-active') {
                'RootBuilder BuildData.json became active before the serialized termination boundary; forced MO2 termination is refused.'
            }
            else {
                'The live MO2 process no longer matches the exact recorded owner identity; forced termination is refused.'
            }
            return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid; forceTermination = $forceTermination } -Errors @($message)
        }
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldForceTerminate = @($targets); forceTermination = $forceTermination; gameProcesses = @(); activeRootBuilderBuildData = @() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        if ($remaining.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    $terminated = $remaining.Count -eq 0
    $finalInspection = if ($InspectionFactory) {
        & $InspectionFactory $Config $owned.data
    }
    else {
        Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    }
    $finalActiveBuildData = @($finalInspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $owned.data.status = if ($terminated) { 'mo2-terminated' } else { 'terminate-incomplete' }
    $owned.data | Add-Member -NotePropertyName terminatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $owned.data
    return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $terminated -State $owned.data.status -Data @{ targets = $targets; remaining = $remaining; gameProcesses = @($finalInspection.processes.game); activeRootBuilderBuildData = @($finalActiveBuildData | ForEach-Object { [string]$_.path }); sessionPath = $owned.data.sessionPath } -Errors $(if ($terminated) { @() } else { @('MO2 remained after exact forced termination was requested.') })
}

function Get-MO2ControlHelp {
    param([Parameter(Mandatory)]$Config)

    $data = [pscustomobject][ordered]@{
        commands = @(
            [pscustomobject]@{ name = 'inspect'; mutation = $false; description = 'Inspect MO2 paths, profiles, registered executables, processes, RootBuilder state, overwrite usage, storage and locks.' },
            [pscustomobject]@{ name = 'validate'; mutation = $false; description = 'Validate an exact profile and registered executable. Add -RequireClosed before future state-changing operations.' },
            [pscustomobject]@{ name = 'validate-human-mutation'; mutation = $false; description = 'Validate a private, recipient-task-bound HumanMutationId for an exact selected-profile mutation with Skyrim closed and either zero MO2 processes or one unblocked exact instance. Public LeaseId values are coordination metadata only.' },
            [pscustomobject]@{ name = 'request-access'; mutation = $true; description = 'Atomically request automation access for one runtime route, or human access bound to the exact selected profile.' },
            [pscustomobject]@{ name = 'access-status'; mutation = $false; description = 'Report whether access is available, held, bound to a session, or owned by the supplied AccessId.' },
            [pscustomobject]@{ name = 'renew-access'; mutation = $true; description = 'Refresh an owned access lease and optionally replace its advisory duration estimate. Never extends an automatic expiry because leases do not expire automatically.' },
            [pscustomobject]@{ name = 'release-access'; mutation = $true; description = 'Release an access-only lease. Automation access requires closed state; human access releases coordination only and leaves live applications untouched.' },
            [pscustomobject]@{ name = 'recover-access'; mutation = $true; description = 'Explicitly recover a confirmed abandoned access lease after closed-state proof. Requires AccessId and ConfirmAbandoned; estimates never authorize recovery.' },
            [pscustomobject]@{ name = 'prepare'; mutation = $true; description = 'Validate closed state and bind a route-qualified explicit access lease to a durable evidence session. Requires AccessId.' },
            [pscustomobject]@{ name = 'open'; mutation = $true; description = 'Open only the exact configured MO2 executable and profile in an owned session. Does not launch the game. -StartOnly returns after the durable receipt is written.' },
            [pscustomobject]@{ name = 'launch'; mutation = $true; description = 'Launch one exact registered executable under one exact profile. Requires -SessionId; -StartOnly returns after the durable receipt is written.' },
            [pscustomobject]@{ name = 'status'; mutation = $false; description = 'Report bounded MO2, game and runtime process state, optionally verifying -SessionId ownership.' },
            [pscustomobject]@{ name = 'refresh'; mutation = $true; description = 'Invoke the supported ModOrganizer.exe refresh command (same as F5) against one exact running primary instance under an automation SessionId or private task-bound HumanMutationId.' },
            [pscustomobject]@{ name = 'stop-game'; mutation = $true; description = 'Request graceful game shutdown while retaining the exact owned MO2 process for controlled relaunch. Never force-terminates.' },
            [pscustomobject]@{ name = 'terminate-game'; mutation = $true; description = 'Terminate only launch-recorded exact game/loader PIDs after a deadlock, retain MO2, invoke exact Unlock, and require RootBuilder restoration.' },
            [pscustomobject]@{ name = 'close'; mutation = $true; description = 'Cooperatively close only exact session-owned MO2, including its exact Unlock control and MO2-owned modal windows. Never force-terminates.' },
            [pscustomobject]@{ name = 'recover-close'; mutation = $true; description = 'Use a route-qualified access lease to adopt one stranded exact-path MO2 into a recorded recovery session, then cooperatively close it. Never targets editor or crash-handler processes.' },
            [pscustomobject]@{ name = 'recover-rootbuilder'; mutation = $true; description = 'Recover one stranded RootBuilder BuildData transaction through one exact-profile launch, followed by the normal stop/Unlock path. Never deletes deployment metadata.' },
            [pscustomobject]@{ name = 'stop'; mutation = $true; description = 'Request graceful game shutdown, then cooperatively close exact owned MO2. Never force-terminates.' },
            [pscustomobject]@{ name = 'terminate'; mutation = $true; description = 'Force-terminate only owned MO2 processes after proving game absence and RootBuilder cleanup. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'release'; mutation = $true; description = 'Release an owned session after closed-state proof. Explicit access is retained for release-access; implicit legacy access is removed.' },
            [pscustomobject]@{ name = 'help'; mutation = $false; description = 'Return the command contract.' }
        )
        examples = @(
            '.\Invoke-MO2Control.ps1 inspect',
            '.\Invoke-MO2Control.ps1 request-access -Label "api-test" -RuntimeRoute OCU -EstimatedMinutes 20',
            '.\Invoke-MO2Control.ps1 request-access -AccessKind human -Profile "Real Human''s Profile" -TaskId $taskId -Label "human"',
            '.\Invoke-MO2Control.ps1 validate-human-mutation -HumanMutationId $privateHumanMutationId -TaskId $taskId -Profile "Real Human''s Profile"',
            '.\Invoke-MO2Control.ps1 prepare -AccessId $accessId -Label "api-test-run"',
            '.\Invoke-MO2Control.ps1 refresh -HumanMutationId $privateHumanMutationId -TaskId $taskId -Profile "Real Human''s Profile"',
            '.\Invoke-MO2Control.ps1 validate -RequireClosed',
            '.\Invoke-MO2Control.ps1 validate -Profile "Codex" -Executable "Launch MGO - Do Not Unlock" -Compact'
        )
        runtimeRoutes = @(
            Resolve-MO2RuntimeRouteContract -RuntimeRoute OCU
            Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVR
            Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVRNull
        )
        runtimeRouteRule = 'A lease selects exactly one route. OCU cannot coexist with either SteamVR route; SteamVRNull is the null-HMD mode of SteamVR and cannot coexist with physical SteamVR.'
        note = 'Version 1.1.0 adds exact-profile human access and bounded CLI refresh while retaining route-bound automation sessions and known-ground-state recovery.'
    }

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = 'help'
        ok = $true
        state = 'informational'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = @()
        errors = @()
        data = $data
    }
}

Export-ModuleMember -Function Read-MO2ControlConfig, Get-MO2TaskWorkspaceIsolation, Invoke-MO2Inspect, Invoke-MO2Validate, Invoke-MO2ValidateHumanMutation, Invoke-MO2HumanMutationTransaction, Invoke-MO2RequestAccess, Invoke-MO2AccessStatus, Invoke-MO2RenewAccess, Invoke-MO2ReleaseAccess, Invoke-MO2RecoverAccess, Invoke-MO2Prepare, Invoke-MO2Open, Invoke-MO2Launch, Invoke-MO2Status, Invoke-MO2Refresh, Invoke-MO2StopGame, Invoke-MO2TerminateGame, Invoke-MO2Close, Invoke-MO2RecoverClose, Invoke-MO2RecoverRootBuilder, Invoke-MO2Stop, Invoke-MO2Terminate, Invoke-MO2Release, Get-MO2ControlHelp
