# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) }
}

function Invoke-Catalog([hashtable]$Arguments) {
    $raw = & $catalogTool @Arguments
    return $raw | ConvertFrom-Json -Depth 40
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('csx-shader-cache-catalog-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the temporary directory: $resolvedTestRoot"
}
$priorControlRoot = $env:CSX_SHADER_CACHE_CONTROL_ROOT
$env:CSX_SHADER_CACHE_CONTROL_ROOT = Join-Path $resolvedTestRoot 'target-controls'

$transactionTool = Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
$catalogTool = Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheCatalog.ps1'
$blockers = @('fixture-process-that-does-not-exist')
$shaderSource = 'A' * 64
$differentShaderSource = 'B' * 64
$preset = 'C' * 64
$featureSet = 'D' * 64

try {
    $catalogRoot = Join-Path $resolvedTestRoot 'catalog'
    $liveCache = Join-Path $resolvedTestRoot 'live\ShaderCache'
    $captureEvidence = Join-Path $resolvedTestRoot 'capture-evidence'
    $taskEvidence = Join-Path $resolvedTestRoot 'task-evidence'
    New-Item -ItemType Directory -Path $liveCache -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $liveCache 'Info.ini') -Value @('[Cache]', 'ShaderCacheABI = abi-1') -Encoding utf8
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'baseline.bin'), [byte[]](1, 2, 3, 4))

    $baselineTransaction = & $transactionTool snapshot -CachePath $liveCache -EvidenceDirectory $captureEvidence `
        -BlockingProcessNames $blockers -Confirm:$false -NoExit | ConvertFrom-Json -Depth 30
    Assert-Test ($baselineTransaction.ok) 'fixture transaction preserves the known-working baseline'

    $common = @{
        CatalogRoot = $catalogRoot
        ShaderCacheAbi = 'abi-1'
        ShaderSourceSha256 = $shaderSource
        GameRuntime = 'SkyrimVR-1.4.15'
        RenderPath = 'steamvr-physical'
        BytecodeCompatibilityClass = 'skyrimvr-d3d11'
        BuildId = 'build-fixture'
        PresetSha256 = $preset
        FeatureSetSha256 = $featureSet
        Tags = @('Quality', 'Full-Render')
        Compact = $true
        NoExit = $true
    }
    $captureArgs = @{} + $common
    $captureArgs.Command = 'capture'
    $captureArgs.SourceCachePath = Join-Path $captureEvidence 'cache.before'
    $captureArgs.ExpectedSourceTreeSha256 = [string]$baselineTransaction.data.inventory.treeSha256
    $captureArgs.SourceReceiptPath = [string]$baselineTransaction.data.receiptPath
    $captureArgs.SnapshotStatus = 'known-working'
    $captureArgs.Label = 'fixture baseline'
    $captureArgs.Confirm = $false
    $dryRunRoot = Join-Path $resolvedTestRoot 'dry-run-catalog'
    $dryRunArgs = @{} + $captureArgs
    $dryRunArgs.CatalogRoot = $dryRunRoot
    $dryRunArgs.WhatIf = $true
    $dryRun = Invoke-Catalog $dryRunArgs
    Assert-Test ($dryRun.ok -and $dryRun.state -eq 'dry-run') 'catalog capture validates and reports a dry run'
    Assert-Test (-not (Test-Path -LiteralPath $dryRunRoot)) 'catalog capture dry run creates no catalog directories or lock file'
    $boundedCaptureArgs = @{} + $captureArgs
    $boundedCaptureArgs.MaxInventoryFiles = 1
    $boundedCapture = Invoke-Catalog $boundedCaptureArgs
    Assert-Test (-not $boundedCapture.ok -and $boundedCapture.errors[0] -match 'file-count bound') 'catalog capture uses the shared bounded inventory contract'

    $capture = Invoke-Catalog $captureArgs
    Assert-Test ($capture.ok -and $capture.state -eq 'captured') 'catalog captures a receipt-proven known-working tree'
    Assert-Test (Test-Path -LiteralPath $capture.data.snapshot.cachePath -PathType Container) 'catalog stores a content-addressed cache object'

    $duplicate = Invoke-Catalog $captureArgs
    Assert-Test ($duplicate.ok -and $duplicate.state -eq 'already-present') 'catalog deduplicates identical metadata and content'

    $list = Invoke-Catalog @{ Command = 'list'; CatalogRoot = $catalogRoot; Compact = $true; NoExit = $true }
    Assert-Test ($list.ok -and @($list.data.snapshots).Count -eq 1 -and @($list.data.issues).Count -eq 0) 'catalog lists its valid immutable manifest without issues'

    $selectArgs = @{} + $common
    $selectArgs.Command = 'select'
    $selectArgs.RenderPath = 'steamvr-null'
    $selectArgs.RequiredTags = @('quality')
    $select = Invoke-Catalog $selectArgs
    Assert-Test ($select.ok -and $select.state -eq 'snapshot-selected') 'selection finds an exact bytecode-compatible source across physical and null SteamVR provenance'
    Assert-Test ($select.data.selection.selected.exactShaderSource -and $select.data.selection.selected.exactBuild -and $select.data.selection.selected.exactPreset) 'selection reports why the preferred snapshot won'
    Assert-Test (-not $select.data.selection.selected.exactRenderPathProvenance -and $select.data.selection.selected.bytecodeCompatibilityClass -eq 'skyrimvr-d3d11' -and $select.data.selection.selected.exactFeatureSet) 'selection separates bytecode compatibility from exact render-route provenance while retaining the feature-set gate'

    $physicalRouteCapture = @{} + $captureArgs
    $physicalRouteCapture.RenderPath = 'vr-steamvr-physical'
    $physicalRouteCapture.Label = 'physical SteamVR fixture'
    $physicalCapture = Invoke-Catalog $physicalRouteCapture
    Assert-Test ($physicalCapture.ok -and $physicalCapture.data.snapshot.manifest.compatibility.renderFamily -eq 'vr-steamvr') 'capture records the canonical SteamVR render family while retaining the physical route'
    $nullRouteArgs = @{} + $selectArgs
    $nullRouteArgs.RenderPath = 'vr-steamvr-null'
    $nullRouteSelect = Invoke-Catalog $nullRouteArgs
    Assert-Test ($nullRouteSelect.ok -and $nullRouteSelect.state -eq 'snapshot-selected' -and $nullRouteSelect.data.selection.selected.renderFamily -eq 'vr-steamvr' -and $nullRouteSelect.data.selection.selected.exactRenderFamilyProvenance -and $nullRouteSelect.data.selection.selected.manifest.compatibility.renderPath -eq 'vr-steamvr-physical') 'null HMD prefers the canonical compatible physical SteamVR cache'

    $openCompositeArgs = @{} + $nullRouteArgs
    $openCompositeArgs.RenderPath = 'vr-opencomposite'
    $openCompositeSelect = Invoke-Catalog $openCompositeArgs
    Assert-Test ($openCompositeSelect.ok -and $openCompositeSelect.state -eq 'snapshot-selected' -and $openCompositeSelect.data.selection.selected.bytecodeCompatibilityClass -eq 'skyrimvr-d3d11') 'OpenComposite selects the same bytecode-compatible Skyrim VR cache while retaining distinct route provenance'

    $unknownFeatureArgs = @{} + $nullRouteArgs
    $unknownFeatureArgs.FeatureSetSha256 = 'E' * 64
    $unknownFeature = Invoke-Catalog $unknownFeatureArgs
    Assert-Test ($unknownFeature.ok -and $unknownFeature.state -eq 'no-compatible-snapshot' -and @($unknownFeature.data.selection.excluded | Where-Object { $_.reasons -contains 'feature-set-mismatch' }).Count -gt 0) 'feature-set fingerprint mismatch blocks cache reuse'

    $mismatchArgs = @{} + $selectArgs
    $mismatchArgs.ShaderSourceSha256 = $differentShaderSource
    $mismatch = Invoke-Catalog $mismatchArgs
    Assert-Test ($mismatch.ok -and $mismatch.state -eq 'no-compatible-snapshot') 'selection rejects a shader-source mismatch by default'
    $mismatchArgs.AllowSourceMismatch = $true
    $mismatchArgs.CompatibilityReason = 'Fixture exercises the explicit compatibility exception.'
    $allowedMismatch = Invoke-Catalog $mismatchArgs
    Assert-Test ($allowedMismatch.ok -and $allowedMismatch.state -eq 'snapshot-selected' -and -not $allowedMismatch.data.selection.selected.exactShaderSource) 'selection permits an explained shader-source mismatch explicitly'

    [IO.File]::WriteAllBytes((Join-Path $liveCache 'local-before-task.bin'), [byte[]](9, 9, 9))
    $beforeTask = & $transactionTool inspect -CachePath $liveCache -NoExit | ConvertFrom-Json -Depth 30
    $prepareArgs = @{} + $common
    $prepareArgs.Command = 'prepare'
    $prepareArgs.CachePath = $liveCache
    $prepareArgs.EvidenceDirectory = $taskEvidence
    $prepareArgs.RequiredTags = @('full-render')
    $prepareArgs.BlockingProcessNames = $blockers
    $prepareArgs.Confirm = $false
    $prepare = Invoke-Catalog $prepareArgs
    Assert-Test ($prepare.ok -and $prepare.data.task.action -eq 'seed-selected') 'task preparation snapshots the current tree and seeds the best known-working cache'
    $seeded = & $transactionTool inspect -CachePath $liveCache -NoExit | ConvertFrom-Json -Depth 30
    Assert-Test ([string]$seeded.data.treeSha256 -ieq [string]$baselineTransaction.data.inventory.treeSha256) 'task preparation verifies the seeded live tree'
    $prepareAgain = Invoke-Catalog $prepareArgs
    Assert-Test ($prepareAgain.ok -and $prepareAgain.state -eq 'already-prepared') 'task preparation retry reconciles the existing exact plan without reseeding'

    [IO.File]::WriteAllBytes((Join-Path $liveCache 'compiled-during-task.bin'), [byte[]](7, 7, 7, 7, 7))
    $taskResult = & $transactionTool inspect -CachePath $liveCache -NoExit | ConvertFrom-Json -Depth 30
    $invalidPromotion = Invoke-Catalog @{
        Command = 'complete'
        CatalogRoot = $catalogRoot
        CachePath = $liveCache
        EvidenceDirectory = $taskEvidence
        Promote = $true
        WorkingSetStatus = 'unverified'
        BlockingProcessNames = $blockers
        Compact = $true
        NoExit = $true
    }
    Assert-Test (-not $invalidPromotion.ok -and $invalidPromotion.errors[0] -match 'known-working') 'catalog refuses to promote a task result without an explicit known-working classification'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $taskEvidence 'shader-cache-task.completion.json'))) 'a refused promotion does not mutate or complete the task transaction'

    $complete = Invoke-Catalog @{
        Command = 'complete'
        CatalogRoot = $catalogRoot
        CachePath = $liveCache
        EvidenceDirectory = $taskEvidence
        Promote = $true
        WorkingSetStatus = 'known-working'
        Label = 'fixture completed task'
        BlockingProcessNames = $blockers
        Confirm = $false
        Compact = $true
        NoExit = $true
    }
    Assert-Test ($complete.ok -and $complete.state -eq 'complete') 'task completion restores the caller-owned cache and publishes an explicitly verified result'
    $afterComplete = & $transactionTool inspect -CachePath $liveCache -NoExit | ConvertFrom-Json -Depth 30
    Assert-Test ([string]$afterComplete.data.treeSha256 -ieq [string]$beforeTask.data.treeSha256) 'task completion restores the exact pre-task live cache'
    Assert-Test ([string]$complete.data.task.workingTree.inventory.treeSha256 -ieq [string]$taskResult.data.treeSha256) 'task completion records the exact compiled result before restoration'
    Assert-Test (Test-Path -LiteralPath $complete.data.task.workingTree.preservedPath -PathType Container) 'task completion retains the displaced compiled result as evidence'
    Assert-Test ($complete.data.task.promoted.state -eq 'captured') 'known-working task output receives a distinct immutable snapshot manifest'
    $completeAgain = Invoke-Catalog @{
        Command = 'complete'; CatalogRoot = $catalogRoot; CachePath = $liveCache; EvidenceDirectory = $taskEvidence
        Promote = $true; WorkingSetStatus = 'known-working'; Label = 'fixture completed task'; BlockingProcessNames = $blockers
        Confirm = $false; Compact = $true; NoExit = $true
    }
    Assert-Test ($completeAgain.ok -and $completeAgain.state -eq 'already-complete') 'task completion retry returns the immutable existing completion'

    $boundCatalogRoot = Join-Path $resolvedTestRoot 'bound-catalog'
    $boundEvidence = Join-Path $resolvedTestRoot 'bound-task-evidence'
    $modsRoot = Join-Path $resolvedTestRoot 'mo2\mods'
    $profilePath = Join-Path $resolvedTestRoot 'mo2\profiles\Task\modlist.txt'
    $taskCache = Join-Path $modsRoot 'Task Cache\ShaderCache'
    $otherCache = Join-Path $modsRoot 'Other Cache\ShaderCache'
    $expectedPluginRoot = Join-Path $modsRoot 'Expected Plugin\SKSE\Plugins'
    $wrongPluginRoot = Join-Path $modsRoot 'Wrong Plugin\SKSE\Plugins'
    $overwriteCache = Join-Path $resolvedTestRoot 'mo2\overwrite\ShaderCache'
    New-Item -ItemType Directory -Path $taskCache, $otherCache, $expectedPluginRoot, $wrongPluginRoot, $overwriteCache, (Split-Path -Parent $profilePath) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $taskCache '.codex-vfs-sentinel.txt') -Value 'task-owned cache provider' -Encoding utf8
    [IO.File]::WriteAllBytes((Join-Path $otherCache 'other-provider.bin'), [byte[]](4, 2))
    $expectedPluginBytes = [byte[]](1, 4, 1, 5, 9)
    $wrongPluginBytes = [byte[]](2, 7, 1, 8, 2)
    $expectedPluginPath = Join-Path $expectedPluginRoot 'CommunityShaders.dll'
    $wrongPluginPath = Join-Path $wrongPluginRoot 'CommunityShaders.dll'
    [IO.File]::WriteAllBytes($expectedPluginPath, $expectedPluginBytes)
    [IO.File]::WriteAllBytes($wrongPluginPath, $wrongPluginBytes)
    $expectedPluginHash = (Get-FileHash -LiteralPath $expectedPluginPath -Algorithm SHA256).Hash
    $wrongPluginHash = (Get-FileHash -LiteralPath $wrongPluginPath -Algorithm SHA256).Hash
    [pscustomobject]@{
        buildId = 'build-bound-fixture'
        artifact = [pscustomobject]@{ fileName = 'CommunityShaders.dll'; sha256 = $expectedPluginHash; sizeBytes = $expectedPluginBytes.Length }
        identity = [pscustomobject]@{ shaderCache = [pscustomobject]@{ abiId = 'abi-bound' } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $expectedPluginRoot 'CSX.BuildManifest.json') -Encoding utf8
    [pscustomobject]@{
        buildId = 'wrong-build-fixture'
        artifact = [pscustomobject]@{ fileName = 'CommunityShaders.dll'; sha256 = $wrongPluginHash; sizeBytes = $wrongPluginBytes.Length }
        identity = [pscustomobject]@{ shaderCache = [pscustomobject]@{ abiId = 'abi-bound' } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $wrongPluginRoot 'CSX.BuildManifest.json') -Encoding utf8
    Set-Content -LiteralPath $profilePath -Value @('+Task Cache', '+Other Cache', '+Wrong Plugin', '+Expected Plugin') -Encoding utf8

    $boundCommon = @{
        CatalogRoot = $boundCatalogRoot
        ProfilePath = $profilePath
        ModsPath = $modsRoot
        CacheModName = 'Task Cache'
        ShaderCacheAbi = 'abi-bound'
        ShaderSourceSha256 = $shaderSource
        GameRuntime = 'SkyrimVR-1.4.15'
        RenderPath = 'vr'
        BuildId = 'build-bound-fixture'
        Tags = @('task-cache')
        BlockingProcessNames = $blockers
        Compact = $true
        NoExit = $true
    }
    $wrongPathArgs = @{} + $boundCommon
    $wrongPathArgs.Command = 'prepare'
    $wrongPathArgs.CachePath = $overwriteCache
    $wrongPathArgs.EvidenceDirectory = Join-Path $resolvedTestRoot 'wrong-path-evidence'
    $wrongPathArgs.Confirm = $false
    $wrongPath = Invoke-Catalog $wrongPathArgs
    Assert-Test (-not $wrongPath.ok -and $wrongPath.errors[0] -match 'does not match the exact winning MO2 provider') 'task preparation rejects a physical overwrite path when another loose-mod provider wins'

    $wrongBuildArgs = @{} + $boundCommon
    $wrongBuildArgs.Command = 'prepare'
    $wrongBuildArgs.EvidenceDirectory = Join-Path $resolvedTestRoot 'wrong-build-evidence'
    $wrongBuildArgs.Confirm = $false
    $wrongBuild = Invoke-Catalog $wrongBuildArgs
    Assert-Test (-not $wrongBuild.ok -and $wrongBuild.errors[0] -match "has build 'wrong-build-fixture'; expected 'build-bound-fixture'") 'provider-bound preparation rejects a different winning Community Shaders build'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $wrongBuildArgs.EvidenceDirectory 'shader-cache-task.plan.json'))) 'a wrong DLL winner is rejected before a task cache plan is created'

    Set-Content -LiteralPath $profilePath -Value @('+Task Cache', '+Other Cache', '+Expected Plugin', '+Wrong Plugin') -Encoding utf8

    $boundPrepareArgs = @{} + $boundCommon
    $boundPrepareArgs.Command = 'prepare'
    $boundPrepareArgs.EvidenceDirectory = $boundEvidence
    $boundPrepareArgs.RequireMaterializedOutput = $true
    $boundPrepareArgs.Confirm = $false
    $boundPrepare = Invoke-Catalog $boundPrepareArgs
    Assert-Test ($boundPrepare.ok -and [string]$boundPrepare.data.task.cacheBinding.modName -eq 'Task Cache') 'task preparation resolves and records the exact winning loose-mod cache provider'
    Assert-Test ([string]$boundPrepare.data.task.cacheBinding.communityShadersPlugin.modName -eq 'Expected Plugin' -and [string]$boundPrepare.data.task.cacheBinding.communityShadersPlugin.buildId -eq 'build-bound-fixture') 'task preparation binds the expected winning Community Shaders build and provider'
    Assert-Test ([string]$boundPrepare.data.task.before.root -eq [IO.Path]::GetFullPath($taskCache)) 'task preparation snapshots the provider-backed cache instead of global overwrite'
    $shadowedLowerCache = Join-Path $taskCache 'other-provider.bin'
    Assert-Test ((Test-Path -LiteralPath $shadowedLowerCache -PathType Leaf) -and (Get-FileHash -LiteralPath $shadowedLowerCache -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $otherCache 'other-provider.bin') -Algorithm SHA256).Hash) 'task preparation materializes a byte-identical shadow for a lower-provider-only cache file'
    Assert-Test ([int]$boundPrepare.data.task.providerShadow.receipt.requiredLowerProviderFiles -eq 1 -and [int]$boundPrepare.data.task.providerShadow.receipt.copiedFiles -eq 1 -and (Test-Path -LiteralPath $boundPrepare.data.task.providerShadow.receiptPath -PathType Leaf)) 'task preparation records exact lower-provider shadow coverage'
    $boundPrepareAgain = Invoke-Catalog $boundPrepareArgs
    Assert-Test ($boundPrepareAgain.ok -and $boundPrepareAgain.state -eq 'already-prepared' -and [string]$boundPrepareAgain.data.task.providerShadow.receipt.preparedInventory.treeSha256 -ceq [string]$boundPrepare.data.task.providerShadow.receipt.preparedInventory.treeSha256) 'provider-bound preparation retry validates the materialized task tree instead of the pre-shadow seed hash'

    Remove-Item -LiteralPath $shadowedLowerCache -Force

    [IO.File]::WriteAllBytes($expectedPluginPath, [byte[]](9, 9, 9))
    $changedPluginComplete = Invoke-Catalog @{
        Command = 'complete'
        CatalogRoot = $boundCatalogRoot
        EvidenceDirectory = $boundEvidence
        WorkingSetStatus = 'unverified'
        BlockingProcessNames = $blockers
        Confirm = $false
        Compact = $true
        NoExit = $true
    }
    Assert-Test (-not $changedPluginComplete.ok -and $changedPluginComplete.errors[0] -match 'DLL hash does not match its build manifest') 'task completion rejects physical Community Shaders DLL drift'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $boundEvidence 'shader-cache-task.completion.json'))) 'DLL drift leaves the cache transaction open'
    [IO.File]::WriteAllBytes($expectedPluginPath, $expectedPluginBytes)

    $emptyComplete = Invoke-Catalog @{
        Command = 'complete'
        CatalogRoot = $boundCatalogRoot
        EvidenceDirectory = $boundEvidence
        WorkingSetStatus = 'unverified'
        BlockingProcessNames = $blockers
        Confirm = $false
        Compact = $true
        NoExit = $true
    }
    $materializationFailurePath = Join-Path $boundEvidence 'shader-cache-task.materialization-failure.json'
    Assert-Test (-not $emptyComplete.ok -and $emptyComplete.errors[0] -match 'no files beyond automation markers') 'task completion fails closed when the bound cache has no compiled output'
    Assert-Test ((Test-Path -LiteralPath $materializationFailurePath -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $boundEvidence 'shader-cache-task.completion.json'))) 'missing materialization preserves evidence and leaves the task transaction open'
    Assert-Test (Test-Path -LiteralPath (Join-Path $taskCache '.codex-vfs-sentinel.txt') -PathType Leaf) 'failed materialization does not restore or remove the live provider tree'

    [IO.File]::WriteAllBytes((Join-Path $taskCache 'compiled-during-bound-task.bin'), [byte[]](6, 2, 6, 4))
    $boundComplete = Invoke-Catalog @{
        Command = 'complete'
        CatalogRoot = $boundCatalogRoot
        EvidenceDirectory = $boundEvidence
        WorkingSetStatus = 'unverified'
        BlockingProcessNames = $blockers
        Confirm = $false
        Compact = $true
        NoExit = $true
    }
    Assert-Test ($boundComplete.ok -and [int]$boundComplete.data.task.workingTree.materializedFiles -eq 1) 'task completion preserves materialized output from the exact bound provider'
    Assert-Test (Test-Path -LiteralPath (Join-Path $boundComplete.data.task.workingTree.preservedPath 'compiled-during-bound-task.bin') -PathType Leaf) 'provider-backed compiled output survives restoration in the evidence tree'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $taskCache 'compiled-during-bound-task.bin'))) 'task completion restores the exact pre-task provider tree'

    $unboundOverwrite = Invoke-Catalog @{
        Command = 'prepare'
        CatalogRoot = (Join-Path $resolvedTestRoot 'unbound-catalog')
        CachePath = $overwriteCache
        EvidenceDirectory = (Join-Path $resolvedTestRoot 'unbound-evidence')
        ShaderCacheAbi = 'abi-unbound'
        ShaderSourceSha256 = $shaderSource
        BlockingProcessNames = $blockers
        Confirm = $false
        Compact = $true
        NoExit = $true
    }
    Assert-Test (-not $unboundOverwrite.ok -and $unboundOverwrite.errors[0] -match 'Refusing an unbound MO2 overwrite') 'catalog refuses to infer global overwrite as the effective MO2 cache target'

    $wrongOverwriteChild = Join-Path (Split-Path -Parent $overwriteCache) 'WrongCache'
    New-Item -ItemType Directory -Path $wrongOverwriteChild -Force | Out-Null
    $wrongOverwriteBinding = Invoke-Catalog @{
        Command = 'prepare'; CatalogRoot = (Join-Path $resolvedTestRoot 'wrong-overwrite-catalog')
        CachePath = $wrongOverwriteChild; ProfilePath = $profilePath; ModsPath = $modsRoot
        BindToOverwrite = $true; EvidenceDirectory = (Join-Path $resolvedTestRoot 'wrong-overwrite-evidence')
        ShaderCacheAbi = 'abi-bound'; ShaderSourceSha256 = $shaderSource
        BlockingProcessNames = $blockers; Confirm = $false; Compact = $true; NoExit = $true
    }
    Assert-Test (-not $wrongOverwriteBinding.ok -and $wrongOverwriteBinding.errors[0] -match 'exact MO2 overwrite directory') 'Overwrite binding rejects a cache path outside the declared relative tree'

    [IO.File]::WriteAllBytes((Join-Path $overwriteCache 'pre-task.bin'), [byte[]](8, 6, 7, 5))
    $overwriteEvidence = Join-Path $resolvedTestRoot 'overwrite-task-evidence'
    $overwritePrepare = Invoke-Catalog @{
        Command = 'prepare'; CatalogRoot = (Join-Path $resolvedTestRoot 'overwrite-catalog')
        CachePath = $overwriteCache; ProfilePath = $profilePath; ModsPath = $modsRoot
        BindToOverwrite = $true; EvidenceDirectory = $overwriteEvidence
        ShaderCacheAbi = 'abi-bound'; ShaderSourceSha256 = $shaderSource
        BuildId = 'build-bound-fixture'; RequireMaterializedOutput = $true
        BlockingProcessNames = $blockers; Confirm = $false; Compact = $true; NoExit = $true
    }
    Assert-Test ($overwritePrepare.ok -and [string]$overwritePrepare.data.task.cacheBinding.mode -eq 'mo2-overwrite-output') 'catalog explicitly binds the exact MO2 Overwrite tree'
    Assert-Test ((Test-Path -LiteralPath (Join-Path $overwriteCache 'other-provider.bin') -PathType Leaf) -and [int]$overwritePrepare.data.task.providerShadow.receipt.requiredLowerProviderFiles -eq 2) 'Overwrite preparation materializes the complete enabled-provider union'
    [IO.File]::WriteAllBytes((Join-Path $overwriteCache 'later-area.bin'), [byte[]](3, 1, 4, 1, 5))
    $overwriteComplete = Invoke-Catalog @{
        Command = 'complete'; CatalogRoot = (Join-Path $resolvedTestRoot 'overwrite-catalog')
        CachePath = $overwriteCache; EvidenceDirectory = $overwriteEvidence
        WorkingSetStatus = 'unverified'; BlockingProcessNames = $blockers
        Confirm = $false; Compact = $true; NoExit = $true
    }
    Assert-Test ($overwriteComplete.ok -and (Test-Path -LiteralPath (Join-Path $overwriteComplete.data.task.workingTree.preservedPath 'later-area.bin') -PathType Leaf)) 'Overwrite completion preserves later-area generated cache output'
    Assert-Test ((Test-Path -LiteralPath (Join-Path $overwriteCache 'pre-task.bin') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $overwriteCache 'later-area.bin'))) 'Overwrite completion restores the exact pre-task cache tree'

    $finalList = Invoke-Catalog @{ Command = 'list'; CatalogRoot = $catalogRoot; Compact = $true; NoExit = $true }
    Assert-Test (@($finalList.data.snapshots).Count -eq 3 -and @($finalList.data.issues).Count -eq 0) 'catalog retains all known-working compatibility records and validates every manifest'
}
finally {
    $env:CSX_SHADER_CACHE_CONTROL_ROOT = $priorControlRoot
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    passed = $passes.Count
    failed = $failures.Count
    passes = @($passes)
    failures = @($failures)
} | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
