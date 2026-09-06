# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('list', 'capture', 'select', 'prepare', 'complete')]
    [string]$Command,

    [string]$CatalogRoot,
    [string]$ConfigPath,
    [string]$CachePath,
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
    if ($normalized -in @('steamvr-physical', 'steamvr-null', 'vr-steamvr-physical', 'vr-steamvr-null')) { return 'vr-steamvr' }
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
                [string]$m.compatibility.renderPath -ceq $RenderPath -and
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

function Prepare-TaskCache($Storage) {
    Assert-CompatibilityInput
    $resolvedCache = Assert-SafeDirectory $CachePath 'live shader-cache' -MustExist
    $evidence = Assert-SafeDirectory $EvidenceDirectory 'shader-cache task evidence'
    $planPath = Join-Path $evidence 'shader-cache-task.plan.json'
    $existingPlan = $null
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $existingPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 40
        if ([IO.Path]::GetFullPath([string]$existingPlan.cachePath) -ne $resolvedCache -or [IO.Path]::GetFullPath([string]$existingPlan.catalog.path) -ne [IO.Path]::GetFullPath([string]$Storage.path) -or [IO.Path]::GetFullPath([string]$existingPlan.evidenceDirectory) -ne $evidence) { throw 'Existing task cache plan owns different immutable source or target identities.' }
        if ([string]$existingPlan.state -notin @('snapshot-preserved', 'prepared')) { throw "Existing task cache plan is not resumable from state '$($existingPlan.state)'." }
    }
    $selection = if ($null -ne $existingPlan) { $existingPlan.selection } else { Select-CatalogSnapshot $Storage }
    if ($RequireMatch -and $null -eq $selection.selected) { throw 'No compatible known-working shader-cache snapshot matched the task request.' }

    if ($WhatIfPreference) {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        return [pscustomobject][ordered]@{ state = 'dry-run'; planPath = $planPath; current = $current.data; selection = $selection; action = $(if ($null -eq $selection.selected) { 'use-current-no-match' } elseif ([string]$selection.selected.treeSha256 -ieq [string]$current.data.treeSha256) { 'use-current-exact' } else { 'seed-selected' }) }
    }

    if ($null -ne $existingPlan -and [string]$existingPlan.state -eq 'prepared') {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        $expectedLiveHash = if ([string]$existingPlan.action -eq 'seed-selected') { [string]$existingPlan.selection.selected.treeSha256 } else { [string]$existingPlan.beforeTreeSha256 }
        if ([string]$current.data.treeSha256 -ine $expectedLiveHash) { throw 'Prepared task cache plan no longer matches the exact live cache state.' }
        return [pscustomobject][ordered]@{ state = 'already-prepared'; planPath = $planPath; action = [string]$existingPlan.action; selection = $existingPlan.selection; before = @{ treeSha256 = [string]$existingPlan.beforeTreeSha256 }; seed = $null }
    }
    $snapshot = if ($null -ne $existingPlan) {
        [pscustomobject]@{ data = [pscustomobject]@{ receiptPath = [string]$existingPlan.transactionReceiptPath; inventory = [pscustomobject]@{ treeSha256 = [string]$existingPlan.beforeTreeSha256 } } }
    }
    else {
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
        evidenceDirectory = $evidence
        request = New-CompatibilityRecord
        selection = $selection
        action = $action
        transactionReceiptPath = [string]$snapshot.data.receiptPath
        beforeTreeSha256 = [string]$snapshot.data.inventory.treeSha256
        seedReceiptPath = $null
    } }
    if ($null -eq $existingPlan) { Write-JsonAtomic $planPath $plan -RefuseExisting }
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
            $seed = Invoke-Transaction 'seed' $seedArgs
            $action = 'seed-selected'
        }
    }
    $plan.state = 'prepared'
    $plan.action = $action
    $plan.seedReceiptPath = $(if ($null -ne $seed) { [string]$seed.data.seedReceiptPath } else { $null })
    Write-JsonAtomic $planPath $plan
    return [pscustomobject][ordered]@{ state = 'prepared'; planPath = $planPath; action = $action; selection = $selection; before = $snapshot.data.inventory; seed = $seed }
}

function Complete-TaskCache($Storage) {
    $resolvedCache = Assert-SafeDirectory $CachePath 'live shader-cache' -MustExist
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
    if ([IO.Path]::GetFullPath([string]$plan.cachePath) -ne $resolvedCache) { throw 'Task cache plan owns a different live cache path.' }
    if ([IO.Path]::GetFullPath([string]$plan.catalog.path) -ne [IO.Path]::GetFullPath([string]$Storage.path)) { throw 'Task cache plan owns a different catalog root.' }
    if ($Promote -and $WorkingSetStatus -ne 'known-working') { throw '-Promote requires -WorkingSetStatus known-working.' }

    if ($WhatIfPreference) {
        $current = Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache }
        return [pscustomobject][ordered]@{ state = 'dry-run'; planPath = $planPath; completionPath = $completionPath; current = $current.data; wouldRestore = $true; wouldPromote = [bool]$Promote }
    }

    $currentBeforeRestore = if ($plan.PSObject.Properties['workingTreeInventory']) { [pscustomobject]@{ data = $plan.workingTreeInventory } } else { Invoke-Transaction 'inspect' @{ CachePath = $resolvedCache } }
    if (-not $plan.PSObject.Properties['workingTreeInventory']) {
        $plan | Add-Member -NotePropertyName workingTreeInventory -NotePropertyValue $currentBeforeRestore.data -Force
        $plan.state = 'completing'
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
            $restore = Invoke-Transaction 'restore' @{ CachePath = $resolvedCache; EvidenceDirectory = $evidence; BlockingProcessNames = $BlockingProcessNames; Confirm = $false }
        }
        else { throw 'Live cache matches neither the recorded working tree nor the preserved baseline; recovery is required.' }
        $plan | Add-Member -NotePropertyName restoreReceiptPath -NotePropertyValue ([string]$restore.data.restoreReceiptPath) -Force
        $plan.state = 'restored'
        Write-JsonAtomic $planPath $plan
    }
    $promoted = $null
    if ($Promote) {
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
        workingTree = [pscustomobject][ordered]@{ status = $WorkingSetStatus; inventory = $currentBeforeRestore.data; preservedPath = [string]$restore.data.displacedPath }
        restoredTreeSha256 = [string]$restore.data.baseline.treeSha256
        promoted = $promoted
    }
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
