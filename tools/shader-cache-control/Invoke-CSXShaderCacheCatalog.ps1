# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('list', 'capture', 'select', 'prepare', 'complete')]
    [string]$Command,

    [string]$CatalogRoot,
    [string]$ConfigPath,
    [string]$CachePath,

    [string]$ProfilePath,

    [string]$ModsPath,

    [string]$CacheModName,

    [switch]$BindToOverwrite,

    [string]$WorkspaceId,

    [string]$OwnershipId,

    [string]$OwnerMarkerPath,

    [string]$OwnerMarkerSha256,

    [string]$RelativeCachePath = 'ShaderCache',
    [string]$EvidenceDirectory,
    [string]$SourceCachePath,
    [string]$ExpectedSourceTreeSha256,
    [string]$SourceReceiptPath,
    [string]$Label,
    [string]$ShaderCacheAbi,
    [string]$ShaderSourceSha256,
    [string]$BuildId,
    [string]$PresetSha256,
    [string]$FeatureSetSha256,
    [string]$GameRuntime = 'SkyrimVR-1.4.15',
    [string]$RenderPath = 'vr',
    [string]$BytecodeCompatibilityClass = 'skyrimvr-d3d11',
    [string[]]$Tags = @(),
    [string[]]$RequiredTags = @(),
    [ValidateSet('known-working', 'unverified')]
    [string]$SnapshotStatus = 'unverified',
    [switch]$AllowSourceMismatch,
    [string]$CompatibilityReason,
    [switch]$RequireMatch,

    [switch]$RequireMaterializedOutput,
    [switch]$Promote,
    [ValidateSet('known-working', 'unverified', 'failed')]
    [string]$WorkingSetStatus = 'unverified',
    [ValidateNotNullOrEmpty()]
    [string[]]$BlockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader'),
    [ValidateRange(1, 1000000)]
    [int]$MaxInventoryFiles = 20000,
    [ValidateRange(1, [long]::MaxValue)]
    [long]$MaxInventoryBytes = 21474836480,
    [ValidateRange(1, 128)]
    [int]$MaxInventoryDepth = 24,
    [ValidateRange(1, 3600)]
    [int]$InventoryTimeoutSeconds = 120,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CatalogCommandContext = $PSCmdlet
$contractVersion = '1.0.0'
$transactionTool = Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
. (Join-Path $PSScriptRoot 'ShaderCacheInventory.ps1')

function Test-Property($Value, [string]$Name) {
    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name
}

function Get-PropertyValue($Value, [string]$Name, $Default = $null) {
    if (Test-Property $Value $Name) { return $Value.$Name }
    return $Default
}

function Assert-Hash([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "$Name must be an exact SHA-256 value."
    }
    return $Value.ToUpperInvariant()
}

function Get-SafeName([string]$Value) {
    $safe = ($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'snapshot' }
    return $safe.Substring(0, [Math]::Min(64, $safe.Length))
}

function Assert-SafeDirectory([string]$Path, [string]$Purpose, [switch]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Purpose path is required." }
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved)) { throw "Refusing a filesystem root as ${Purpose}: $resolved" }
    if ($MustExist -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Purpose directory does not exist: $resolved"
    }
    return $resolved
}

function Resolve-CatalogRoot {
    if (-not [string]::IsNullOrWhiteSpace($CatalogRoot)) {
        return [pscustomobject]@{ path = (Assert-SafeDirectory $CatalogRoot 'shader-cache catalog'); source = 'explicit' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CSX_SHADER_CACHE_CATALOG_ROOT)) {
        return [pscustomobject]@{ path = (Assert-SafeDirectory $env:CSX_SHADER_CACHE_CATALOG_ROOT 'shader-cache catalog'); source = 'environment' }
    }

    $configCandidates = [Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $explicitConfig = [IO.Path]::GetFullPath($ConfigPath)
        if (-not (Test-Path -LiteralPath $explicitConfig -PathType Leaf)) { throw "Explicit configuration does not exist: $explicitConfig" }
        $configCandidates.Add([pscustomobject]@{ source = 'explicit-config'; path = $explicitConfig })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_CONFIG)) {
        $environmentConfig = [IO.Path]::GetFullPath($env:SKYRIM_VR_AUTOMATION_CONFIG)
        if (-not (Test-Path -LiteralPath $environmentConfig -PathType Leaf)) { throw "Configured SKYRIM_VR_AUTOMATION_CONFIG does not exist: $environmentConfig" }
        $configCandidates.Add([pscustomobject]@{ source = 'environment-config'; path = $environmentConfig })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $configCandidates.Add([pscustomobject]@{ source = 'user-config'; path = (Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\machine.local.json') })
    }
    foreach ($candidate in $configCandidates) {
        if (-not (Test-Path -LiteralPath $candidate.path -PathType Leaf)) { continue }
        $config = Get-Content -LiteralPath $candidate.path -Raw | ConvertFrom-Json -Depth 30
        if ((Test-Property $config 'storage') -and (Test-Property $config.storage 'shaderCacheCatalog') -and
            -not [string]::IsNullOrWhiteSpace([string]$config.storage.shaderCacheCatalog)) {
            return [pscustomobject]@{ path = (Assert-SafeDirectory ([string]$config.storage.shaderCacheCatalog) 'shader-cache catalog'); source = $candidate.source; configPath = $candidate.path }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [pscustomobject]@{ path = (Assert-SafeDirectory (Join-Path $env:CODEX_HOME 'state\skyrim-vr-automation\shader-cache-catalog') 'shader-cache catalog'); source = 'codex-home' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return [pscustomobject]@{ path = (Assert-SafeDirectory (Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\shader-cache-catalog') 'shader-cache catalog'); source = 'local-app-data' }
    }
    throw 'Unable to resolve shader-cache catalog storage. Supply -CatalogRoot or CSX_SHADER_CACHE_CATALOG_ROOT.'
}

function Get-TreeInventory([string]$Root) {
    return Get-CSXShaderCacheTreeInventory -Root $Root -MaxFiles $MaxInventoryFiles -MaxBytes $MaxInventoryBytes -MaxDepth $MaxInventoryDepth -TimeoutSeconds $InventoryTimeoutSeconds -ProgressActivity 'Inventorying shader-cache catalog tree'
}

function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $inside = $false
    $values = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*\[(?<section>[^]]+)\]\s*$') { $inside = $Matches.section -ieq $Section; continue }
        if ($inside -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(?<value>.*?)\s*$')) { $values += $Matches.value }
    }
    if ($values.Count -gt 1) { throw "Multiple [$Section] $Key values found in $Path" }
    if ($values.Count -eq 1) { return [string]$values[0] }
    return $null
}

function Write-JsonAtomic([string]$Path, $Value, [switch]$RefuseExisting) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($RefuseExisting -and (Test-Path -LiteralPath $resolved)) { throw "Refusing to overwrite existing file: $resolved" }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolved) -Force | Out-Null
    $temporary = $resolved + '.tmp.' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        if ($RefuseExisting) {
            Move-Item -LiteralPath $temporary -Destination $resolved
        }
        else {
            [IO.File]::Move($temporary, $resolved, $true)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-CatalogLayout($Storage, [switch]$Create) {
    $root = $Storage.path
    $layout = [pscustomobject][ordered]@{
        root = $root
        objects = Join-Path $root 'objects'
        snapshots = Join-Path $root 'snapshots'
        incoming = Join-Path $root '.incoming'
        lock = Join-Path $root '.catalog.lock'
    }
    if ($Create) {
        New-Item -ItemType Directory -Path $layout.objects, $layout.snapshots, $layout.incoming -Force | Out-Null
    }
    return $layout
}

function Enter-CatalogLock($Layout, [int]$TimeoutSeconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $stream = [IO.File]::Open($Layout.lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $payload = [Text.Encoding]::UTF8.GetBytes("pid=$PID utc=$([DateTime]::UtcNow.ToString('o'))")
            $stream.SetLength(0)
            $stream.Write($payload, 0, $payload.Length)
            $stream.Flush($true)
            return $stream
        }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    throw "Timed out acquiring shader-cache catalog lock: $($Layout.lock)"
}

function Exit-CatalogLock($Layout, $Stream) {
    if ($null -eq $Stream) { return }
    $Stream.Dispose()
}

function Get-CatalogRecords($Layout) {
    $records = @()
    $issues = @()
    if (-not (Test-Path -LiteralPath $Layout.snapshots -PathType Container)) {
        return [pscustomobject]@{ records = @(); issues = @() }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Layout.snapshots -File -Filter '*.json' | Sort-Object Name)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 30
            foreach ($required in @('contractVersion', 'snapshotId', 'status', 'inventory', 'compatibility', 'cacheObject')) {
                if (-not (Test-Property $manifest $required)) { throw "missing property '$required'" }
            }
            if ([string]$manifest.contractVersion -cne $contractVersion) { throw "unsupported contract version '$($manifest.contractVersion)'" }
            if ([IO.Path]::GetFileNameWithoutExtension($file.Name) -cne [string]$manifest.snapshotId) { throw 'snapshot ID does not match the manifest filename' }
            if ([string]$manifest.status -notin @('known-working', 'unverified')) { throw "unsupported snapshot status '$($manifest.status)'" }
            foreach ($required in @('treeSha256', 'files', 'bytes')) {
                if (-not (Test-Property $manifest.inventory $required)) { throw "inventory is missing property '$required'" }
            }
            foreach ($required in @('shaderCacheAbi', 'gameRuntime', 'renderPath', 'shaderSourceSha256', 'tags')) {
                if (-not (Test-Property $manifest.compatibility $required)) { throw "compatibility is missing property '$required'" }
            }
            $treeHash = Assert-Hash ([string]$manifest.inventory.treeSha256) 'manifest inventory treeSha256'
            [void](Assert-Hash ([string]$manifest.compatibility.shaderSourceSha256) 'manifest shaderSourceSha256')
            if ((Test-Property $manifest.compatibility 'presetSha256') -and -not [string]::IsNullOrWhiteSpace([string]$manifest.compatibility.presetSha256)) {
                [void](Assert-Hash ([string]$manifest.compatibility.presetSha256) 'manifest presetSha256')
            }
            if ((Test-Property $manifest.compatibility 'featureSetSha256') -and -not [string]::IsNullOrWhiteSpace([string]$manifest.compatibility.featureSetSha256)) {
                [void](Assert-Hash ([string]$manifest.compatibility.featureSetSha256) 'manifest featureSetSha256')
            }
            $expectedObject = 'objects\' + $treeHash + '\ShaderCache'
            if ([string]$manifest.cacheObject -cne $expectedObject) { throw 'cache object does not match the manifest tree identity' }
            $cache = [IO.Path]::GetFullPath((Join-Path $Layout.root ([string]$manifest.cacheObject)))
            if (-not $cache.StartsWith($Layout.objects + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'cache object escapes catalog objects directory' }
            if (-not (Test-Path -LiteralPath $cache -PathType Container)) { throw 'cache object is missing' }
            $records += [pscustomobject][ordered]@{ manifestPath = $file.FullName; cachePath = $cache; manifest = $manifest }
        }
        catch {
            $issues += [pscustomobject][ordered]@{ manifestPath = $file.FullName; error = $_.Exception.Message }
        }
    }
    return [pscustomobject]@{ records = @($records); issues = @($issues) }
}

function Get-ReceiptProof([string]$Path, [string]$SourcePath, [string]$ExpectedHash) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A source receipt is required before a cache tree can enter the catalog.' }
    $resolvedReceipt = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedReceipt -PathType Leaf)) { throw "Source receipt does not exist: $resolvedReceipt" }
    $receipt = Get-Content -LiteralPath $resolvedReceipt -Raw | ConvertFrom-Json -Depth 30
    $operation = [string](Get-PropertyValue $receipt 'operation' '')
    $transactionId = [string](Get-PropertyValue $receipt 'transactionId' '')
    if ($operation -notin @('snapshot', 'seed', 'restore') -or [string]::IsNullOrWhiteSpace($transactionId)) { throw 'Source receipt lacks a supported operation and immutable transaction identity.' }
    $resolvedSource = [IO.Path]::GetFullPath($SourcePath)
    $pairs = @(
        @{ operation = 'snapshot'; path = 'backupPath'; hash = 'beforeTreeSha256' },
        @{ operation = 'seed'; path = 'displacedPath'; hash = 'displacedTreeSha256' },
        @{ operation = 'restore'; path = 'displacedPath'; hash = 'displacedTreeSha256' },
        @{ operation = 'seed'; path = 'sourceCachePath'; hash = 'sourceTreeSha256' }
    )
    $matched = $false
    foreach ($pair in $pairs) {
        if ($operation -cne [string]$pair.operation) { continue }
        if (-not (Test-Property $receipt $pair.path) -or -not (Test-Property $receipt $pair.hash)) { continue }
        if ([IO.Path]::GetFullPath([string]$receipt.($pair.path)) -eq $resolvedSource -and [string]$receipt.($pair.hash) -ieq $ExpectedHash) {
            $matched = $true
            break
        }
    }
    if (-not $matched) { throw 'Source receipt does not prove the exact source path and tree hash.' }
    return [pscustomobject][ordered]@{
        path = $resolvedReceipt
        sha256 = (Get-FileHash -LiteralPath $resolvedReceipt -Algorithm SHA256).Hash
        contractVersion = [string](Get-PropertyValue $receipt 'contractVersion' '')
        operation = $operation
        transactionId = $transactionId
    }
}

function Assert-CompatibilityInput {
    if ([string]::IsNullOrWhiteSpace($ShaderCacheAbi)) { throw '-ShaderCacheAbi is required.' }
    if ([string]::IsNullOrWhiteSpace($GameRuntime)) { throw '-GameRuntime is required.' }
    if ([string]::IsNullOrWhiteSpace($RenderPath)) { throw '-RenderPath is required.' }
    if ([string]::IsNullOrWhiteSpace($BytecodeCompatibilityClass)) { throw '-BytecodeCompatibilityClass is required.' }
    $script:ShaderSourceSha256 = Assert-Hash $ShaderSourceSha256 'ShaderSourceSha256'
    if (-not [string]::IsNullOrWhiteSpace($PresetSha256)) { $script:PresetSha256 = Assert-Hash $PresetSha256 'PresetSha256' }
    if (-not [string]::IsNullOrWhiteSpace($FeatureSetSha256)) { $script:FeatureSetSha256 = Assert-Hash $FeatureSetSha256 'FeatureSetSha256' }
    if ($AllowSourceMismatch -and [string]::IsNullOrWhiteSpace($CompatibilityReason)) {
        throw '-CompatibilityReason is required when -AllowSourceMismatch is used.'
    }
}

function Get-NormalizedStrings([string[]]$Values) {
    return @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-RenderFamily([string]$Value) {
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -in @('vr-steamvr-physical', 'vr-steamvr-null')) { return 'vr-steamvr' }
    return $normalized
}

function New-CompatibilityRecord {
    return [pscustomobject][ordered]@{
        shaderCacheAbi = $ShaderCacheAbi
        gameRuntime = $GameRuntime
        bytecodeCompatibilityClass = $BytecodeCompatibilityClass
        renderPath = $RenderPath
        renderFamily = Get-RenderFamily $RenderPath
        shaderSourceSha256 = $ShaderSourceSha256
        buildId = $(if ([string]::IsNullOrWhiteSpace($BuildId)) { $null } else { $BuildId })
        presetSha256 = $(if ([string]::IsNullOrWhiteSpace($PresetSha256)) { $null } else { $PresetSha256 })
        featureSetSha256 = $(if ([string]::IsNullOrWhiteSpace($FeatureSetSha256)) { $null } else { $FeatureSetSha256 })
        tags = @(Get-NormalizedStrings $Tags)
    }
}

function New-CatalogSnapshot {
    param(
        [Parameter(Mandatory)]$Storage,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][Management.Automation.PSCmdlet]$Caller
    )
    Assert-CompatibilityInput
    $resolvedSource = Assert-SafeDirectory $Source 'preserved shader-cache source' -MustExist
    $expected = Assert-Hash $ExpectedHash 'ExpectedSourceTreeSha256'
    $inventory = Get-TreeInventory $resolvedSource
    if ($inventory.treeSha256 -ne $expected) { throw "Preserved source hash mismatch. Expected $expected, observed $($inventory.treeSha256)." }
    $observedAbi = Get-IniValue (Join-Path $resolvedSource 'Info.ini') 'Cache' 'ShaderCacheABI'
    if ([string]::IsNullOrWhiteSpace($observedAbi)) {
        throw 'Source Info.ini must contain exactly one [Cache] ShaderCacheABI value.'
    }
    if ($observedAbi -cne $ShaderCacheAbi) {
        throw "Source Info.ini ShaderCacheABI '$observedAbi' does not match requested '$ShaderCacheAbi'."
    }
    $proof = Get-ReceiptProof $ReceiptPath $resolvedSource $expected
    $layout = Get-CatalogLayout $Storage -Create:(-not $WhatIfPreference)
    $compatibility = New-CompatibilityRecord
    $objectRelative = 'objects\' + $expected + '\ShaderCache'
    $objectPath = Join-Path $layout.root $objectRelative
    if ($WhatIfPreference) {
        return [pscustomobject][ordered]@{
            state = 'dry-run'
            record = [pscustomobject][ordered]@{
                manifestPath = $null
                cachePath = $objectPath
                manifest = [pscustomobject][ordered]@{
                    contractVersion = $contractVersion
                    snapshotId = $null
                    label = $Label
                    status = $Status
                    cacheObject = $objectRelative
                    inventory = [pscustomobject][ordered]@{ treeSha256 = $expected; files = $inventory.files; bytes = $inventory.bytes }
                    compatibility = $compatibility
                    provenance = [pscustomobject][ordered]@{ sourceReceipt = $proof; sourceLeaf = [IO.Path]::GetFileName($resolvedSource) }
                }
            }
        }
    }
    $lock = $null
    try {
        $lock = Enter-CatalogLock $layout
        $catalog = Get-CatalogRecords $layout
        foreach ($record in @($catalog.records)) {
            $m = $record.manifest
            $manifestTags = @(Get-NormalizedStrings @($m.compatibility.tags))
            if ([string]$m.inventory.treeSha256 -ieq $expected -and [string]$m.status -ceq $Status -and
                [string]$m.compatibility.shaderCacheAbi -ceq $ShaderCacheAbi -and
                [string]$m.compatibility.gameRuntime -ceq $GameRuntime -and
                (Get-RenderFamily ([string]$m.compatibility.renderPath)) -ceq (Get-RenderFamily $RenderPath) -and
                [string]$m.compatibility.shaderSourceSha256 -ieq $ShaderSourceSha256 -and
                [string](Get-PropertyValue $m.compatibility 'buildId' '') -ceq [string](Get-PropertyValue $compatibility 'buildId' '') -and
                [string](Get-PropertyValue $m.compatibility 'presetSha256' '') -ieq [string](Get-PropertyValue $compatibility 'presetSha256' '') -and
                [string](Get-PropertyValue $m.compatibility 'featureSetSha256' '') -ieq [string](Get-PropertyValue $compatibility 'featureSetSha256' '') -and
                ($manifestTags -join "`n") -ceq (@($compatibility.tags) -join "`n")) {
                return [pscustomobject][ordered]@{ state = 'already-present'; record = $record }
            }
        }

        if (Test-Path -LiteralPath $objectPath -PathType Container) {
            $existing = Get-TreeInventory $objectPath
            if ($existing.treeSha256 -ne $expected) { throw "Catalog object is corrupt: $objectPath" }
        }
        elseif ($Caller.ShouldProcess($objectPath, 'Add verified content-addressed shader-cache object')) {
            $incoming = Join-Path $layout.incoming ([guid]::NewGuid().ToString('N'))
            $incomingCache = Join-Path $incoming 'ShaderCache'
            try {
                New-Item -ItemType Directory -Path $incoming -Force | Out-Null
                Copy-Item -LiteralPath $resolvedSource -Destination $incomingCache -Recurse
                $copied = Get-TreeInventory $incomingCache
                if ($copied.treeSha256 -ne $expected) { throw 'Catalog staging copy failed hash verification.' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $objectPath) -Force | Out-Null
                Move-Item -LiteralPath $incomingCache -Destination $objectPath
            }
            finally {
                if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force }
            }
        }

        $created = [DateTime]::UtcNow
        $snapshotId = '{0}-{1}-{2}' -f $created.ToString('yyyyMMddTHHmmssfffZ'), (Get-SafeName $Label), $expected.Substring(0, 12).ToLowerInvariant()
        $manifestPath = Join-Path $layout.snapshots ($snapshotId + '.json')
        $manifest = [pscustomobject][ordered]@{
            contractVersion = $contractVersion
            snapshotId = $snapshotId
            createdUtc = $created.ToString('o')
            label = $(if ([string]::IsNullOrWhiteSpace($Label)) { $snapshotId } else { $Label })
            status = $Status
            cacheObject = $objectRelative
            inventory = [pscustomobject][ordered]@{ treeSha256 = $expected; files = $inventory.files; bytes = $inventory.bytes }
            compatibility = $compatibility
            provenance = [pscustomobject][ordered]@{ sourceReceipt = $proof; sourceLeaf = [IO.Path]::GetFileName($resolvedSource) }
        }
        if ($Caller.ShouldProcess($manifestPath, 'Publish immutable shader-cache snapshot manifest')) {
            Write-JsonAtomic $manifestPath $manifest -RefuseExisting
        }
        return [pscustomobject][ordered]@{ state = $(if ($WhatIfPreference) { 'dry-run' } else { 'captured' }); record = [pscustomobject]@{ manifestPath = $manifestPath; cachePath = $objectPath; manifest = $manifest } }
    }
    finally { Exit-CatalogLock $layout $lock }
}

function Select-CatalogSnapshot($Storage) {
    Assert-CompatibilityInput
    $layout = Get-CatalogLayout $Storage
    $catalog = Get-CatalogRecords $layout
    $required = @(Get-NormalizedStrings $RequiredTags)
    $eligible = @()
    $excluded = @()
    foreach ($record in @($catalog.records)) {
        $m = $record.manifest
        $reasons = @()
        if ([string]$m.status -cne 'known-working') { $reasons += 'not-known-working' }
        if ([string]$m.compatibility.shaderCacheAbi -cne $ShaderCacheAbi) { $reasons += 'shader-cache-abi-mismatch' }
        if ([string]$m.compatibility.gameRuntime -cne $GameRuntime) { $reasons += 'game-runtime-mismatch' }
        $candidateBytecodeClass = [string](Get-PropertyValue $m.compatibility 'bytecodeCompatibilityClass' $(if ([string]$m.compatibility.gameRuntime -like 'SkyrimVR*') { 'skyrimvr-d3d11' } else { [string]$m.compatibility.renderPath }))
        if ($candidateBytecodeClass -cne $BytecodeCompatibilityClass) { $reasons += 'bytecode-compatibility-class-mismatch' }
        $candidateRenderFamily = Get-RenderFamily ([string]$m.compatibility.renderPath)
        $candidateFeatureSet = [string](Get-PropertyValue $m.compatibility 'featureSetSha256' '')
        if (-not [string]::IsNullOrWhiteSpace($FeatureSetSha256)) {
            if ([string]::IsNullOrWhiteSpace($candidateFeatureSet)) { $reasons += 'feature-set-unknown' }
            elseif ($candidateFeatureSet -ine $FeatureSetSha256) { $reasons += 'feature-set-mismatch' }
        }
        $sourceExact = [string]$m.compatibility.shaderSourceSha256 -ieq $ShaderSourceSha256
        if (-not $sourceExact -and -not $AllowSourceMismatch) { $reasons += 'shader-source-mismatch' }
        $candidateTags = @(Get-NormalizedStrings @($m.compatibility.tags))
        foreach ($tag in $required) { if ($candidateTags -cnotcontains $tag) { $reasons += "missing-tag:$tag" } }
        if ($reasons.Count -gt 0) {
            $excluded += [pscustomobject][ordered]@{ snapshotId = [string]$m.snapshotId; reasons = $reasons }
            continue
        }
        $buildExact = -not [string]::IsNullOrWhiteSpace($BuildId) -and [string](Get-PropertyValue $m.compatibility 'buildId' '') -ceq $BuildId
        $presetExact = -not [string]::IsNullOrWhiteSpace($PresetSha256) -and [string](Get-PropertyValue $m.compatibility 'presetSha256' '') -ieq $PresetSha256
        $featureSetExact = -not [string]::IsNullOrWhiteSpace($FeatureSetSha256) -and $candidateFeatureSet -ieq $FeatureSetSha256
        $renderPathExact = [string]$m.compatibility.renderPath -ceq $RenderPath
        $score = $(if ($sourceExact) { 1000000 } else { 0 }) + $(if ($featureSetExact) { 100000 } else { 0 }) + $(if ($buildExact) { 10000 } else { 0 }) + $(if ($presetExact) { 1000 } else { 0 }) + $(if ($renderPathExact) { 100 } else { 0 }) + ($required.Count * 10)
        $eligible += [pscustomobject][ordered]@{
            snapshotId = [string]$m.snapshotId
            score = $score
            exactShaderSource = $sourceExact
            exactBuild = $buildExact
            exactPreset = $presetExact
            exactRenderPathProvenance = $renderPathExact
            bytecodeCompatibilityClass = $candidateBytecodeClass
            exactFeatureSet = $featureSetExact
            renderFamily = $candidateRenderFamily
            files = [int]$m.inventory.files
            bytes = [long]$m.inventory.bytes
            createdUtc = [string]$m.createdUtc
            cachePath = $record.cachePath
            manifestPath = $record.manifestPath
            treeSha256 = [string]$m.inventory.treeSha256
            manifest = $m
        }
    }
    $ranked = @($eligible | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'files'; Descending = $true }, @{ Expression = 'createdUtc'; Descending = $true })
    $selected = if ($ranked.Count -gt 0) { $ranked[0] } else { $null }
    return [pscustomobject][ordered]@{
        request = New-CompatibilityRecord
        allowSourceMismatch = [bool]$AllowSourceMismatch
        compatibilityReason = $(if ($AllowSourceMismatch) { $CompatibilityReason } else { $null })
        requiredTags = $required
        selected = $selected
        eligible = $ranked
        excluded = $excluded
        catalogIssues = @($catalog.issues)
    }
}

function Invoke-Transaction([string]$Action, [hashtable]$Arguments) {
    $parameters = @{
        Command = $Action; NoExit = $true; Compact = $true
        MaxInventoryFiles = $MaxInventoryFiles; MaxInventoryBytes = $MaxInventoryBytes
        MaxInventoryDepth = $MaxInventoryDepth; InventoryTimeoutSeconds = $InventoryTimeoutSeconds
    }
    foreach ($key in $Arguments.Keys) { $parameters[$key] = $Arguments[$key] }
    $raw = & $transactionTool @parameters
    $parsed = $raw | ConvertFrom-Json -Depth 40
    if (-not $parsed.ok) { throw "Shader-cache transaction '$Action' failed: $($parsed.errors -join '; ')" }
    return $parsed
}

function Test-SamePath([string]$Left, [string]$Right) {
    return [string]::Equals(
        [IO.Path]::GetFullPath($Left),
        [IO.Path]::GetFullPath($Right),
        [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OverwriteOwnerBinding($Binding) {
    if ($null -eq $Binding -or [string]$Binding.mode -cne 'mo2-overwrite-output') { return }
    foreach ($required in @('workspaceId', 'ownershipId', 'ownerMarkerPath', 'ownerMarkerSha256', 'overwriteRoot')) {
        if (-not (Test-Property $Binding $required) -or [string]::IsNullOrWhiteSpace([string]$Binding.$required)) {
            throw "MO2 Overwrite cache binding lacks exact workspace ownership field '$required'."
        }
    }
    if ([string]$Binding.ownerMarkerSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'MO2 Overwrite cache binding has an invalid owner-marker hash.' }
    $expectedPath = Join-Path ([string]$Binding.overwriteRoot) '.codex-workspace-output-owner.json'
    if (-not (Test-SamePath ([string]$Binding.ownerMarkerPath) $expectedPath) -or
        -not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
        throw 'The exact task-owned MO2 Overwrite marker is missing.'
    }
    if ((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -cne [string]$Binding.ownerMarkerSha256) {
        throw 'The MO2 Overwrite owner marker changed after cache preparation.'
    }
    try { $marker = Get-Content -LiteralPath $expectedPath -Raw | ConvertFrom-Json -Depth 20 }
    catch { throw "The MO2 Overwrite owner marker is unreadable: $($_.Exception.Message)" }
    foreach ($required in @('workspaceId', 'ownershipId', 'mode', 'overwritePath')) {
        if ($null -eq $marker -or -not $marker.PSObject.Properties[$required]) {
            throw "The MO2 Overwrite owner marker lacks '$required'."
        }
    }
    if ([string]$marker.workspaceId -cne [string]$Binding.workspaceId -or
        [string]$marker.ownershipId -cne [string]$Binding.ownershipId -or
        [string]$marker.mode -cne 'mo2-overwrite-output' -or
        -not (Test-SamePath ([string]$marker.overwritePath) ([string]$Binding.overwriteRoot))) {
        throw 'The MO2 Overwrite owner marker belongs to a different workspace transaction.'
    }
}

function Resolve-CommunityShadersPluginBinding(
    [string]$BoundProfilePath,
    [string]$BoundModsPath,
    [string]$ExpectedBuildId,
    [string]$ExpectedShaderCacheAbi) {
    if ([string]::IsNullOrWhiteSpace($ExpectedBuildId)) { return $null }

    $relativePluginPath = 'SKSE\Plugins\CommunityShaders.dll'
    $providerResult = Invoke-Transaction 'providers' @{
        ProfilePath = $BoundProfilePath
        ModsPath = $BoundModsPath
        RelativeCachePath = $relativePluginPath
        DeepInventory = $false
    }
    $winner = $providerResult.data.effectiveWinnerAmongEnabledMods
    if ($null -eq $winner) {
        throw "The exact profile has no enabled loose-mod provider for '$relativePluginPath', so build '$ExpectedBuildId' cannot be proven before launch."
    }
    if ([string]$winner.providerType -cne 'file') {
        throw "The winning '$relativePluginPath' provider is not a file: $($winner.providerPath)"
    }

    $pluginPath = [IO.Path]::GetFullPath([string]$winner.providerPath)
    if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
        throw "The winning Community Shaders plugin does not exist: $pluginPath"
    }
    $manifestPath = Join-Path ([string]$winner.modRoot) 'SKSE\Plugins\CSX.BuildManifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The winning Community Shaders provider '$($winner.modName)' has no CSX.BuildManifest.json, so expected build '$ExpectedBuildId' cannot be proven."
    }

    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 40 }
    catch { throw "The winning Community Shaders build manifest is invalid JSON: $manifestPath. $($_.Exception.Message)" }
    $manifestBuildId = [string](Get-PropertyValue $manifest 'buildId' '')
    if (-not [string]::Equals($manifestBuildId, $ExpectedBuildId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The winning Community Shaders provider '$($winner.modName)' has build '$manifestBuildId'; expected '$ExpectedBuildId'."
    }

    $artifact = Get-PropertyValue $manifest 'artifact' $null
    $manifestArtifactHash = if ($null -ne $artifact) { [string](Get-PropertyValue $artifact 'sha256' '') } else { '' }
    if ($manifestArtifactHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "The winning Community Shaders build manifest has no exact artifact SHA-256: $manifestPath"
    }
    $actualArtifactHash = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actualArtifactHash, $manifestArtifactHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The winning Community Shaders DLL hash does not match its build manifest. Expected '$manifestArtifactHash'; observed '$actualArtifactHash'."
    }
    if ($null -ne $artifact -and (Test-Property $artifact 'sizeBytes')) {
        $actualBytes = (Get-Item -LiteralPath $pluginPath).Length
        if ([long]$artifact.sizeBytes -ne $actualBytes) {
            throw "The winning Community Shaders DLL size does not match its build manifest. Expected '$($artifact.sizeBytes)'; observed '$actualBytes'."
        }
    }

    $manifestAbi = ''
    $identity = Get-PropertyValue $manifest 'identity' $null
    if ($null -ne $identity) {
        $shaderCache = Get-PropertyValue $identity 'shaderCache' $null
        if ($null -ne $shaderCache) { $manifestAbi = [string](Get-PropertyValue $shaderCache 'abiId' '') }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedShaderCacheAbi) -and
        -not [string]::Equals($manifestAbi, $ExpectedShaderCacheAbi, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The winning Community Shaders provider '$($winner.modName)' has shader-cache ABI '$manifestAbi'; expected '$ExpectedShaderCacheAbi'."
    }

    return [pscustomobject][ordered]@{
        mode = 'mo2-winning-loose-plugin-provider'
        profilePath = [string]$providerResult.data.profilePath
        profileSha256 = [string]$providerResult.data.profileSha256
        modsPath = [string]$providerResult.data.modsPath
        relativePluginPath = [string]$providerResult.data.relativeCachePath
        modName = [string]$winner.modName
        modRoot = [string]$winner.modRoot
        pluginPath = $pluginPath
        manifestPath = [IO.Path]::GetFullPath($manifestPath)
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        lineNumber = [int]$winner.lineNumber
        buildId = $manifestBuildId
        artifactSha256 = $actualArtifactHash
        artifactBytes = [long](Get-Item -LiteralPath $pluginPath).Length
        shaderCacheAbi = $manifestAbi
    }
}

function Resolve-TaskCacheBinding {
    $bindingValues = @($ProfilePath, $ModsPath, $CacheModName)
    $hasBindingInput = @($bindingValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($BindToOverwrite) {
        if ([string]::IsNullOrWhiteSpace($ProfilePath) -or [string]::IsNullOrWhiteSpace($ModsPath) -or
            [string]::IsNullOrWhiteSpace($CachePath)) {
            throw 'MO2 Overwrite binding requires -ProfilePath, -ModsPath, and -CachePath together.'
        }
        if (-not [string]::IsNullOrWhiteSpace($CacheModName)) {
            throw '-CacheModName cannot be combined with -BindToOverwrite.'
        }
        if ([string]::IsNullOrWhiteSpace($BuildId) -or [string]::IsNullOrWhiteSpace($ShaderCacheAbi)) {
            throw 'Task-bound MO2 Overwrite preparation requires exact -BuildId and -ShaderCacheAbi values.'
        }
        if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($OwnershipId) -or
            [string]::IsNullOrWhiteSpace($OwnerMarkerPath) -or $OwnerMarkerSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw 'Task-bound MO2 Overwrite preparation requires exact workspace, ownership, and owner-marker identity.'
        }
        $resolvedCache = Assert-SafeDirectory $CachePath 'MO2 Overwrite shader-cache' -MustExist
        $overwriteRoot = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedCache)).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::GetFileName($overwriteRoot) -ine 'overwrite' -or
            [IO.Path]::GetFileName($resolvedCache) -ine $RelativeCachePath) {
            throw "BindToOverwrite requires CachePath below the exact MO2 overwrite directory: $resolvedCache"
        }
        $providerResult = Invoke-Transaction 'providers' @{
            ProfilePath = $ProfilePath
            ModsPath = $ModsPath
            RelativeCachePath = $RelativeCachePath
            DeepInventory = $false
        }
        $pluginBinding = Resolve-CommunityShadersPluginBinding $ProfilePath $ModsPath $BuildId $ShaderCacheAbi
        $binding = [pscustomobject][ordered]@{
            mode = 'mo2-overwrite-output'
            profilePath = [string]$providerResult.data.profilePath
            profileSha256 = [string]$providerResult.data.profileSha256
            modsPath = [string]$providerResult.data.modsPath
            relativeCachePath = [string]$providerResult.data.relativeCachePath
            overwriteRoot = $overwriteRoot
            cachePath = $resolvedCache
            workspaceId = $WorkspaceId
            ownershipId = $OwnershipId
            ownerMarkerPath = [IO.Path]::GetFullPath($OwnerMarkerPath)
            ownerMarkerSha256 = $OwnerMarkerSha256.ToUpperInvariant()
            communityShadersPlugin = $pluginBinding
        }
        Assert-OverwriteOwnerBinding $binding
        return [pscustomobject][ordered]@{ cachePath = $resolvedCache; binding = $binding }
    }
    if (-not $hasBindingInput) {
        $resolvedCache = Assert-SafeDirectory $CachePath 'live shader-cache' -MustExist
        if ([IO.Path]::GetFileName((Split-Path -Parent $resolvedCache)) -ieq 'overwrite') {
            throw 'Refusing an unbound MO2 overwrite ShaderCache path. Supply -ProfilePath, -ModsPath, and -CacheModName so prepare can bind the exact winning loose-mod provider.'
        }
        return [pscustomobject][ordered]@{ cachePath = $resolvedCache; binding = $null }
    }

    if (@($bindingValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'MO2 cache binding requires -ProfilePath, -ModsPath, and -CacheModName together.'
    }

    $providerResult = Invoke-Transaction 'providers' @{
        ProfilePath = $ProfilePath
        ModsPath = $ModsPath
        RelativeCachePath = $RelativeCachePath
        DeepInventory = $false
    }
    $winner = $providerResult.data.effectiveWinnerAmongEnabledMods
    if ($null -eq $winner) {
        throw "The exact profile has no enabled loose-mod provider for '$RelativeCachePath'. Create and enable a task-owned cache mod before prepare."
    }
    if (-not [string]::Equals([string]$winner.modName, $CacheModName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected cache mod '$CacheModName' is not the winning enabled '$RelativeCachePath' provider. Current winner: '$($winner.modName)'."
    }
    if ([string]$winner.providerType -cne 'directory') {
        throw "The winning '$RelativeCachePath' provider is not a directory: $($winner.providerPath)"
    }

    $resolvedCache = Assert-SafeDirectory ([string]$winner.cachePath) 'winning live shader-cache' -MustExist
    if (-not [string]::IsNullOrWhiteSpace($CachePath) -and -not (Test-SamePath $CachePath $resolvedCache)) {
        throw "CachePath does not match the exact winning MO2 provider. Supplied: $([IO.Path]::GetFullPath($CachePath)); winner: $resolvedCache"
    }
    $pluginBinding = Resolve-CommunityShadersPluginBinding $ProfilePath $ModsPath $BuildId $ShaderCacheAbi
    return [pscustomobject][ordered]@{
        cachePath = $resolvedCache
        binding = [pscustomobject][ordered]@{
            mode = 'mo2-winning-loose-provider'
            profilePath = [string]$providerResult.data.profilePath
            profileSha256 = [string]$providerResult.data.profileSha256
            modsPath = [string]$providerResult.data.modsPath
            relativeCachePath = [string]$providerResult.data.relativeCachePath
            modName = [string]$winner.modName
            modRoot = [string]$winner.modRoot
            cachePath = $resolvedCache
            lineNumber = [int]$winner.lineNumber
            providerType = [string]$winner.providerType
            communityShadersPlugin = $pluginBinding
        }
    }
}

function Assert-TaskCacheBindingCurrent($Binding) {
    if ($null -eq $Binding) { return }
    if ([string]$Binding.mode -notin @('mo2-winning-loose-provider', 'mo2-overwrite-output')) {
        throw "Unsupported task cache binding mode: $($Binding.mode)"
    }
    Assert-OverwriteOwnerBinding $Binding
    $providerResult = Invoke-Transaction 'providers' @{
        ProfilePath = [string]$Binding.profilePath
        ModsPath = [string]$Binding.modsPath
        RelativeCachePath = [string]$Binding.relativeCachePath
        DeepInventory = $false
    }
    if ([string]$providerResult.data.profileSha256 -cne [string]$Binding.profileSha256) {
        throw 'The task MO2 modlist changed after shader-cache prepare; refusing to complete against an unproven provider order.'
    }
    if ([string]$Binding.mode -ceq 'mo2-overwrite-output') {
        $resolvedCache = Assert-SafeDirectory ([string]$Binding.cachePath) 'MO2 Overwrite shader-cache' -MustExist
        $resolvedRoot = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedCache)).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not (Test-SamePath $resolvedRoot ([string]$Binding.overwriteRoot)) -or
            [IO.Path]::GetFileName($resolvedRoot) -ine 'overwrite') {
            throw 'The bound MO2 Overwrite shader-cache path changed after prepare.'
        }
    }
    else {
        $winner = $providerResult.data.effectiveWinnerAmongEnabledMods
        if ($null -eq $winner -or
            -not [string]::Equals([string]$winner.modName, [string]$Binding.modName, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-SamePath ([string]$winner.cachePath) ([string]$Binding.cachePath))) {
            $observed = if ($null -eq $winner) { '<none>' } else { "'$($winner.modName)' at '$($winner.cachePath)'" }
            throw "The winning MO2 shader-cache provider changed after prepare. Expected '$($Binding.modName)' at '$($Binding.cachePath)'; observed $observed."
        }
    }

    if ((Test-Property $Binding 'communityShadersPlugin') -and $null -ne $Binding.communityShadersPlugin) {
        $expectedPlugin = $Binding.communityShadersPlugin
        $currentPlugin = Resolve-CommunityShadersPluginBinding `
            ([string]$Binding.profilePath) `
            ([string]$Binding.modsPath) `
            ([string]$expectedPlugin.buildId) `
            ([string]$expectedPlugin.shaderCacheAbi)
        if (-not [string]::Equals([string]$currentPlugin.modName, [string]$expectedPlugin.modName, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-SamePath ([string]$currentPlugin.pluginPath) ([string]$expectedPlugin.pluginPath)) -or
            -not (Test-SamePath ([string]$currentPlugin.manifestPath) ([string]$expectedPlugin.manifestPath)) -or
            -not [string]::Equals([string]$currentPlugin.manifestSha256, [string]$expectedPlugin.manifestSha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$currentPlugin.artifactSha256, [string]$expectedPlugin.artifactSha256, [StringComparison]::OrdinalIgnoreCase) -or
            [long]$currentPlugin.artifactBytes -ne [long]$expectedPlugin.artifactBytes) {
            throw "The winning Community Shaders plugin provider changed after shader-cache prepare. Expected '$($expectedPlugin.modName)' at '$($expectedPlugin.pluginPath)'."
        }
    }
}

function Get-MaterializedCacheEntries($Inventory) {
    $markerNames = @('.codex-vfs-sentinel.txt', '.gitkeep')
    return @($Inventory.entries | Where-Object {
        [IO.Path]::GetFileName([string]$_.relativePath) -notin $markerNames
    })
}

function Get-TaskOutputEntries($Inventory, $PreparedInventory) {
    $current = @(Get-MaterializedCacheEntries $Inventory)
    if ($null -eq $PreparedInventory) { return $current }
    $preparedByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(Get-MaterializedCacheEntries $PreparedInventory)) {
        $preparedByPath[[string]$entry.relativePath] = $entry
    }
    return @($current | Where-Object {
        $relativePath = [string]$_.relativePath
        -not $preparedByPath.ContainsKey($relativePath) -or
        [string]$_.sha256 -cne [string]$preparedByPath[$relativePath].sha256
    })
}

function Complete-TaskProviderShadow($Binding, [string]$EvidenceRoot) {
    if ($null -eq $Binding) { return $null }
    Assert-OverwriteOwnerBinding $Binding
    $receiptPath = Join-Path $EvidenceRoot 'shader-cache-provider-shadow.receipt.json'
    $providerResult = Invoke-Transaction 'providers' @{
        ProfilePath = [string]$Binding.profilePath
        ModsPath = [string]$Binding.modsPath
        RelativeCachePath = [string]$Binding.relativeCachePath
        DeepInventory = $true
    }
    if ([string]$providerResult.data.profileSha256 -cne [string]$Binding.profileSha256) {
        throw 'The task MO2 modlist changed while materializing lower shader-cache providers.'
    }

    $targetRoot = Assert-SafeDirectory ([string]$Binding.cachePath) 'winning live shader-cache' -MustExist
    $required = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($provider in @($providerResult.data.providers | Where-Object {
        [bool]$_.enabled -and [string]$_.providerType -ceq 'directory' -and
        ([string]$Binding.mode -ceq 'mo2-overwrite-output' -or
            -not [string]::Equals([string]$_.modName, [string]$Binding.modName, [StringComparison]::OrdinalIgnoreCase))
    } | Sort-Object lineNumber)) {
        foreach ($entry in @($provider.inventory.entries)) {
            $relative = [string]$entry.relativePath
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "A lower shader-cache provider returned an unsafe relative path: '$relative'."
            }
            if (-not $required.ContainsKey($relative)) {
                $required.Add($relative, [pscustomobject][ordered]@{
                    relativePath = $relative; sourceRoot = [string]$provider.cachePath
                    sourceModName = [string]$provider.modName; sourceSha256 = [string]$entry.sha256
                    bytes = [long]$entry.bytes
                })
            }
        }
    }

    $copied = [Collections.Generic.List[object]]::new()
    $alreadyPresent = [Collections.Generic.List[object]]::new()
    foreach ($record in @($required.Values | Sort-Object relativePath)) {
        $sourceRoot = [IO.Path]::GetFullPath([string]$record.sourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot ([string]$record.relativePath)))
        $target = [IO.Path]::GetFullPath((Join-Path $targetRoot ([string]$record.relativePath)))
        if (-not $source.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            -not $target.StartsWith($targetRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Shader-cache provider shadow escaped its source or target root: $($record.relativePath)"
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $targetItem = Get-Item -LiteralPath $target
            $alreadyPresent.Add([pscustomobject][ordered]@{
                relativePath = [string]$record.relativePath; winnerClass = 'pre-existing-overwrite'
                bytes = [long]$targetItem.Length; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            })
            continue
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Lower shader-cache provider file disappeared during preparation: $source" }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne [string]$record.sourceSha256) {
            throw "Lower shader-cache provider changed during preparation: $source"
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Assert-OverwriteOwnerBinding $Binding
        Copy-Item -LiteralPath $source -Destination $target
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($targetHash -cne [string]$record.sourceSha256) { throw "Materialized shader-cache provider shadow differs: $target" }
        $copied.Add([pscustomobject][ordered]@{
            relativePath = [string]$record.relativePath; winnerClass = 'copied-provider'
            sourceModName = [string]$record.sourceModName
            bytes = [long]$record.bytes; sha256 = $targetHash
        })
    }

    $prepared = Invoke-Transaction 'inspect' @{ CachePath = $targetRoot }
    $preparedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($prepared.data.entries)) { $null = $preparedPaths.Add([string]$entry.relativePath) }
    $missing = @($required.Keys | Where-Object { -not $preparedPaths.Contains([string]$_) })
    if ($missing.Count -gt 0) { throw "Winning shader-cache provider still lacks $($missing.Count) lower-provider path(s): $($missing -join ', ')" }

    $receipt = [pscustomobject][ordered]@{
        contractVersion = '1.1.0'; state = 'materialized'; bindingMode = [string]$Binding.mode
        profilePath = [string]$Binding.profilePath
        profileSha256 = [string]$Binding.profileSha256
        cacheModName = $(if ([string]$Binding.mode -ceq 'mo2-winning-loose-provider') { [string]$Binding.modName } else { $null })
        cachePath = $targetRoot; requiredLowerProviderFiles = $required.Count
        copiedFiles = $copied.Count; alreadyPresentFiles = $alreadyPresent.Count
        copied = @($copied); alreadyPresent = @($alreadyPresent)
        preparedInventory = $prepared.data; completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Assert-OverwriteOwnerBinding $Binding
    Write-JsonAtomic $receiptPath $receipt
    return [pscustomobject][ordered]@{ receiptPath = $receiptPath; receipt = $receipt }
}

function Prepare-TaskCache($Storage) {
    Assert-CompatibilityInput
    $cacheResolution = Resolve-TaskCacheBinding
    $resolvedCache = [string]$cacheResolution.cachePath
    $evidence = Assert-SafeDirectory $EvidenceDirectory 'shader-cache task evidence'
    $planPath = Join-Path $evidence 'shader-cache-task.plan.json'
    $existingPlan = $null
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $existingPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 40
        if ([IO.Path]::GetFullPath([string]$existingPlan.cachePath) -ne $resolvedCache -or [IO.Path]::GetFullPath([string]$existingPlan.catalog.path) -ne [IO.Path]::GetFullPath([string]$Storage.path) -or [IO.Path]::GetFullPath([string]$existingPlan.evidenceDirectory) -ne $evidence) { throw 'Existing task cache plan owns different immutable source or target identities.' }
        if ([string]$existingPlan.state -notin @('snapshot-preserved', 'prepared')) { throw "Existing task cache plan is not resumable from state '$($existingPlan.state)'." }
        $existingBinding = if ((Test-Property $existingPlan 'cacheBinding') -and $null -ne $existingPlan.cacheBinding) { $existingPlan.cacheBinding } else { $null }
        Assert-TaskCacheBindingCurrent $existingBinding
        if ($null -ne $cacheResolution.binding -and $null -ne $existingBinding -and
            [string]$cacheResolution.binding.mode -ceq 'mo2-overwrite-output' -and
            ([string]$existingBinding.mode -cne 'mo2-overwrite-output' -or
             [string]$cacheResolution.binding.workspaceId -cne [string]$existingBinding.workspaceId -or
             [string]$cacheResolution.binding.ownershipId -cne [string]$existingBinding.ownershipId -or
             [string]$cacheResolution.binding.ownerMarkerSha256 -cne [string]$existingBinding.ownerMarkerSha256)) {
            throw 'Existing task cache plan belongs to a different workspace owner.'
        }
    }
    $selection = if ($null -ne $existingPlan) { $existingPlan.selection } else { Select-CatalogSnapshot $Storage }
    if ($RequireMatch -and $null -eq $selection.selected) { throw 'No compatible known-working shader-cache snapshot matched the task request.' }

    if ($WhatIfPreference) {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        return [pscustomobject][ordered]@{ state = 'dry-run'; planPath = $planPath; current = $current.data; selection = $selection; cacheBinding = $cacheResolution.binding; requireMaterializedOutput = [bool]$RequireMaterializedOutput; action = $(if ($null -eq $selection.selected) { 'use-current-no-match' } elseif ([string]$selection.selected.treeSha256 -ieq [string]$current.data.treeSha256) { 'use-current-exact' } else { 'seed-selected' }) }
    }

    if ($null -ne $existingPlan -and [string]$existingPlan.state -eq 'prepared') {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        $expectedLiveHash = if (Test-Property $existingPlan 'preparedTreeSha256') { [string]$existingPlan.preparedTreeSha256 } elseif ([string]$existingPlan.action -eq 'seed-selected') { [string]$existingPlan.selection.selected.treeSha256 } else { [string]$existingPlan.beforeTreeSha256 }
        if ([string]$current.data.treeSha256 -ine $expectedLiveHash) { throw 'Prepared task cache plan no longer matches the exact live cache state.' }
        return [pscustomobject][ordered]@{ state = 'already-prepared'; planPath = $planPath; action = [string]$existingPlan.action; selection = $existingPlan.selection; providerShadow = $(if (Test-Property $existingPlan 'providerShadow') { $existingPlan.providerShadow } else { $null }); before = @{ treeSha256 = [string]$existingPlan.beforeTreeSha256 }; seed = $null }
    }
    $snapshot = if ($null -ne $existingPlan) {
        [pscustomobject]@{ data = [pscustomobject]@{ receiptPath = [string]$existingPlan.transactionReceiptPath; inventory = [pscustomobject]@{ treeSha256 = [string]$existingPlan.beforeTreeSha256 } } }
    }
    else {
        Assert-OverwriteOwnerBinding $cacheResolution.binding
        Invoke-Transaction 'snapshot' @{ CachePath = $resolvedCache; EvidenceDirectory = $evidence; BlockingProcessNames = $BlockingProcessNames; Confirm = $false }
    }
    $action = 'use-current-no-match'
    $seed = $null
    $plan = if ($null -ne $existingPlan) { $existingPlan } else { [pscustomobject][ordered]@{
        contractVersion = $contractVersion
        transactionId = [guid]::NewGuid().ToString('N')
        state = 'snapshot-preserved'
        createdUtc = [DateTime]::UtcNow.ToString('o')
        catalog = $Storage
        cachePath = $resolvedCache
        cacheBinding = $cacheResolution.binding
        requireMaterializedOutput = [bool]$RequireMaterializedOutput
        evidenceDirectory = $evidence
        request = New-CompatibilityRecord
        selection = $selection
        action = $action
        transactionReceiptPath = [string]$snapshot.data.receiptPath
        beforeTreeSha256 = [string]$snapshot.data.inventory.treeSha256
        seedReceiptPath = $null
    } }
    if ($null -eq $existingPlan) {
        Assert-OverwriteOwnerBinding $cacheResolution.binding
        Write-JsonAtomic $planPath $plan -RefuseExisting
    }
    if ($null -ne $selection.selected) {
        if ([string]$selection.selected.treeSha256 -ieq [string]$snapshot.data.inventory.treeSha256) {
            $action = 'use-current-exact'
        }
        else {
            $seedArgs = @{
                CachePath = $resolvedCache
                EvidenceDirectory = $evidence
                SourceCachePath = [string]$selection.selected.cachePath
                ExpectedSourceTreeSha256 = [string]$selection.selected.treeSha256
                BlockingProcessNames = $BlockingProcessNames
                Confirm = $false
            }
            if ($AllowSourceMismatch) { $seedArgs['CompatibilityReason'] = $CompatibilityReason }
            Assert-OverwriteOwnerBinding $cacheResolution.binding
            $seed = Invoke-Transaction 'seed' $seedArgs
            $action = 'seed-selected'
        }
    }
    Assert-OverwriteOwnerBinding $cacheResolution.binding
    $providerShadow = Complete-TaskProviderShadow -Binding $cacheResolution.binding -EvidenceRoot $evidence
    $preparedInventory = (Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }).data
    $plan.state = 'prepared'
    $plan.action = $action
    $plan.seedReceiptPath = $(if ($null -ne $seed) { [string]$seed.data.seedReceiptPath } else { $null })
    $plan | Add-Member -NotePropertyName providerShadow -NotePropertyValue $providerShadow -Force
    $plan | Add-Member -NotePropertyName preparedTreeSha256 -NotePropertyValue ([string]$preparedInventory.treeSha256) -Force
    Assert-OverwriteOwnerBinding $cacheResolution.binding
    Write-JsonAtomic $planPath $plan
    return [pscustomobject][ordered]@{ state = 'prepared'; planPath = $planPath; action = $action; selection = $selection; providerShadow = $providerShadow; cacheBinding = $cacheResolution.binding; requireMaterializedOutput = [bool]$RequireMaterializedOutput; before = $snapshot.data.inventory; seed = $seed }
}

function Complete-TaskCache($Storage) {
    $evidence = Assert-SafeDirectory $EvidenceDirectory 'shader-cache task evidence' -MustExist
    $planPath = Join-Path $evidence 'shader-cache-task.plan.json'
    $completionPath = Join-Path $evidence 'shader-cache-task.completion.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw "Task cache plan does not exist: $planPath" }
    if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
        $existingCompletion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json -Depth 40
        if ([IO.Path]::GetFullPath([string]$existingCompletion.planPath) -ne $planPath) { throw 'Existing completion owns a different task cache plan.' }
        return [pscustomobject][ordered]@{ state = 'already-complete'; completionPath = $completionPath; workingTree = $existingCompletion.workingTree; restoredTreeSha256 = [string]$existingCompletion.restoredTreeSha256; promoted = $existingCompletion.promoted }
    }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 40
    $resolvedCache = Assert-SafeDirectory ([string]$plan.cachePath) 'planned live shader-cache' -MustExist
    if (-not [string]::IsNullOrWhiteSpace($CachePath) -and -not (Test-SamePath $CachePath $resolvedCache)) { throw 'Task cache plan owns a different live cache path.' }
    if ([IO.Path]::GetFullPath([string]$plan.catalog.path) -ne [IO.Path]::GetFullPath([string]$Storage.path)) { throw 'Task cache plan owns a different catalog root.' }
    if ($Promote -and $WorkingSetStatus -ne 'known-working') { throw '-Promote requires -WorkingSetStatus known-working.' }
    $cacheBinding = if ((Test-Property $plan 'cacheBinding') -and $null -ne $plan.cacheBinding) { $plan.cacheBinding } else { $null }
    Assert-TaskCacheBindingCurrent $cacheBinding
    $requireMaterialized = [bool]$RequireMaterializedOutput -or
        ((Test-Property $plan 'requireMaterializedOutput') -and [bool]$plan.requireMaterializedOutput)

    if ($WhatIfPreference) {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        $preparedInventory = if ((Test-Property $plan 'providerShadow') -and $null -ne $plan.providerShadow -and
            (Test-Property $plan.providerShadow 'receipt') -and $null -ne $plan.providerShadow.receipt -and
            (Test-Property $plan.providerShadow.receipt 'preparedInventory')) { $plan.providerShadow.receipt.preparedInventory } else { $null }
        $materialized = @(Get-TaskOutputEntries $current.data $preparedInventory)
        return [pscustomobject][ordered]@{ state = 'dry-run'; planPath = $planPath; completionPath = $completionPath; current = $current.data; cacheBinding = $cacheBinding; requireMaterializedOutput = $requireMaterialized; materializedFiles = $materialized.Count; wouldRestore = $true; wouldPromote = [bool]$Promote }
    }

    $currentBeforeRestore = if ($plan.PSObject.Properties['workingTreeInventory']) { [pscustomobject]@{ data = $plan.workingTreeInventory } } else { Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache } }
    $preparedInventory = if ((Test-Property $plan 'providerShadow') -and $null -ne $plan.providerShadow -and
        (Test-Property $plan.providerShadow 'receipt') -and $null -ne $plan.providerShadow.receipt -and
        (Test-Property $plan.providerShadow.receipt 'preparedInventory')) { $plan.providerShadow.receipt.preparedInventory } else { $null }
    $materializedEntries = @(Get-TaskOutputEntries $currentBeforeRestore.data $preparedInventory)
    if ($requireMaterialized -and $materializedEntries.Count -eq 0) {
        $failurePath = Join-Path $evidence 'shader-cache-task.materialization-failure.json'
        $failure = [pscustomobject][ordered]@{
            contractVersion = $contractVersion; state = 'materialization-missing'
            observedUtc = [DateTime]::UtcNow.ToString('o'); planPath = $planPath
            cachePath = $resolvedCache; cacheBinding = $cacheBinding
            inventory = $currentBeforeRestore.data
            ignoredMarkerNames = @('.codex-vfs-sentinel.txt', '.gitkeep')
        }
        Assert-OverwriteOwnerBinding $cacheBinding
        Write-JsonAtomic $failurePath $failure
        throw "Expected materialized shader-cache output at '$resolvedCache', but the exact bound tree contains no file added or changed after preparation. The task transaction remains open and the live tree was not restored. Evidence: $failurePath"
    }
    if (-not $plan.PSObject.Properties['workingTreeInventory']) {
        $plan | Add-Member -NotePropertyName workingTreeInventory -NotePropertyValue $currentBeforeRestore.data -Force
        $plan.state = 'completing'
        Assert-OverwriteOwnerBinding $cacheBinding
        Write-JsonAtomic $planPath $plan
    }
    $restore = $null
    if ($plan.PSObject.Properties['restoreReceiptPath'] -and -not [string]::IsNullOrWhiteSpace([string]$plan.restoreReceiptPath)) {
        $restoreReceipt = Get-Content -LiteralPath ([string]$plan.restoreReceiptPath) -Raw | ConvertFrom-Json -Depth 30
        $restore = [pscustomobject]@{ data = [pscustomobject]@{ displacedPath = [string]$restoreReceipt.displacedPath; baseline = [pscustomobject]@{ treeSha256 = [string]$restoreReceipt.restoredTreeSha256 }; restoreReceiptPath = [string]$plan.restoreReceiptPath } }
    }
    else {
        $liveNow = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        if ([string]$liveNow.data.treeSha256 -ieq [string]$plan.beforeTreeSha256) {
            $matchingReceipts = @(Get-ChildItem -LiteralPath $evidence -Filter 'shader-cache-restore.*.receipt.json' -File | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
                try {
                    $candidate = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30
                    if ([string]$candidate.cachePath -eq $resolvedCache -and [string]$candidate.restoredTreeSha256 -ieq [string]$plan.beforeTreeSha256 -and [string]$candidate.displacedTreeSha256 -ieq [string]$currentBeforeRestore.data.treeSha256) { [pscustomobject]@{ path = $_.FullName; receipt = $candidate } }
                } catch { }
            })
            if ($matchingReceipts.Count -ne 1) { throw 'Live cache is restored but no unique committed restore receipt proves the preserved working tree; recovery is required.' }
            $match = $matchingReceipts[0]
            $restore = [pscustomobject]@{ data = [pscustomobject]@{ displacedPath = [string]$match.receipt.displacedPath; baseline = [pscustomobject]@{ treeSha256 = [string]$match.receipt.restoredTreeSha256 }; restoreReceiptPath = [string]$match.path } }
        }
        elseif ([string]$liveNow.data.treeSha256 -ieq [string]$currentBeforeRestore.data.treeSha256) {
            Assert-OverwriteOwnerBinding $cacheBinding
            $restore = Invoke-Transaction 'restore' @{ CachePath = $resolvedCache; EvidenceDirectory = $evidence; BlockingProcessNames = $BlockingProcessNames; Confirm = $false }
        }
        else { throw 'Live cache matches neither the recorded working tree nor the preserved baseline; recovery is required.' }
        $plan | Add-Member -NotePropertyName restoreReceiptPath -NotePropertyValue ([string]$restore.data.restoreReceiptPath) -Force
        $plan.state = 'restored'
        Assert-OverwriteOwnerBinding $cacheBinding
        Write-JsonAtomic $planPath $plan
    }
    $promoted = $null
    if ($Promote) {
        Assert-TaskCacheBindingCurrent $cacheBinding
        $request = $plan.request
        $script:ShaderCacheAbi = [string]$request.shaderCacheAbi
        $script:GameRuntime = [string]$request.gameRuntime
        $script:RenderPath = [string]$request.renderPath
        $script:ShaderSourceSha256 = [string]$request.shaderSourceSha256
        $script:BuildId = [string](Get-PropertyValue $request 'buildId' '')
        $script:PresetSha256 = [string](Get-PropertyValue $request 'presetSha256' '')
        $script:FeatureSetSha256 = [string](Get-PropertyValue $request 'featureSetSha256' '')
        $script:Tags = @($request.tags)
        $script:Label = if ([string]::IsNullOrWhiteSpace($Label)) { 'task-complete-' + [IO.Path]::GetFileName($evidence) } else { $Label }
        $promoted = New-CatalogSnapshot -Storage $Storage -Source ([string]$restore.data.displacedPath) -ExpectedHash ([string]$currentBeforeRestore.data.treeSha256) -ReceiptPath ([string]$restore.data.restoreReceiptPath) -Status 'known-working' -Caller $script:CatalogCommandContext
    }
    $completion = [pscustomobject][ordered]@{
        contractVersion = $contractVersion
        state = 'complete'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        planPath = $planPath
        cacheBinding = $cacheBinding
        workingTree = [pscustomobject][ordered]@{ status = $WorkingSetStatus; inventory = $currentBeforeRestore.data; materializedFiles = $materializedEntries.Count; preservedPath = [string]$restore.data.displacedPath }
        restoredTreeSha256 = [string]$restore.data.baseline.treeSha256
        promoted = $promoted
    }
    Assert-OverwriteOwnerBinding $cacheBinding
    Write-JsonAtomic $completionPath $completion -RefuseExisting
    return [pscustomobject][ordered]@{ state = 'complete'; completionPath = $completionPath; workingTree = $completion.workingTree; restoredTreeSha256 = $completion.restoredTreeSha256; promoted = $promoted }
}

$result = $null
try {
    $storage = Resolve-CatalogRoot
    if ($Command -eq 'list') {
        $layout = Get-CatalogLayout $storage
        $catalog = Get-CatalogRecords $layout
        $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $true; command = $Command; state = 'catalog-inspected'; data = @{ storage = $storage; snapshots = @($catalog.records); issues = @($catalog.issues) }; errors = @() }
    }
    elseif ($Command -eq 'capture') {
        if ([string]::IsNullOrWhiteSpace($SourceCachePath) -or [string]::IsNullOrWhiteSpace($ExpectedSourceTreeSha256) -or [string]::IsNullOrWhiteSpace($SourceReceiptPath)) { throw 'capture requires SourceCachePath, ExpectedSourceTreeSha256, and SourceReceiptPath.' }
        $captured = New-CatalogSnapshot -Storage $storage -Source $SourceCachePath -ExpectedHash $ExpectedSourceTreeSha256 -ReceiptPath $SourceReceiptPath -Status $SnapshotStatus -Caller $script:CatalogCommandContext
        $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $true; command = $Command; state = $captured.state; data = @{ storage = $storage; snapshot = $captured.record }; errors = @() }
    }
    elseif ($Command -eq 'select') {
        $selection = Select-CatalogSnapshot $storage
        $state = if ($null -eq $selection.selected) { 'no-compatible-snapshot' } else { 'snapshot-selected' }
        $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $true; command = $Command; state = $state; data = @{ storage = $storage; selection = $selection }; errors = @() }
    }
    elseif ($Command -eq 'prepare') {
        $prepared = Prepare-TaskCache $storage
        $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $true; command = $Command; state = $prepared.state; whatIf = [bool]$WhatIfPreference; data = @{ storage = $storage; task = $prepared }; errors = @() }
    }
    else {
        $completed = Complete-TaskCache $storage
        $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $true; command = $Command; state = $completed.state; whatIf = [bool]$WhatIfPreference; data = @{ storage = $storage; task = $completed }; errors = @() }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ contractVersion = $contractVersion; ok = $false; command = $Command; state = 'tool-error'; data = $null; errors = @($_.Exception.Message) }
}

$result | ConvertTo-Json -Depth 40 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
