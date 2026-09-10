[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('csx-shader-cache-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the temporary directory: $resolvedTestRoot"
}
$priorControlRoot = $env:CSX_SHADER_CACHE_CONTROL_ROOT
$env:CSX_SHADER_CACHE_CONTROL_ROOT = Join-Path $resolvedTestRoot 'target-controls'

try {
    $reference = Join-Path $resolvedTestRoot 'reference'
    $candidate = Join-Path $resolvedTestRoot 'candidate'
    $output = Join-Path $resolvedTestRoot 'output'
    New-Item -ItemType Directory -Path $reference, $candidate -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $reference 'Lighting'), (Join-Path $candidate 'Lighting') -Force | Out-Null

    [IO.File]::WriteAllBytes((Join-Path $reference 'same.bin'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'same.bin'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $reference 'Lighting\changed.bin'), [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'Lighting\changed.bin'), [byte[]](1, 2))
    [IO.File]::WriteAllBytes((Join-Path $reference 'only-reference.bin'), [byte[]](5, 6, 7))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'only-candidate.bin'), [byte[]](8, 9, 10, 11, 12))

    $compare = Join-Path $PSScriptRoot 'Compare-CSXShaderCache.ps1'
    $result = & $compare -ReferencePath $reference -CandidatePath $candidate -OutputDirectory $output -ReferenceLabel enabled -CandidateLabel unloaded | ConvertFrom-Json
    $comparison = $result.summary.comparison
    Assert-Test ($result.ok -and (Test-Path -LiteralPath $result.csvPath -PathType Leaf)) 'comparison writes all outputs'
    Assert-Test ([int]$comparison.identicalFiles -eq 1) 'identical content is recognized by hash'
    Assert-Test ([int]$comparison.changedFiles -eq 1) 'same relative path with changed content is reported'
    Assert-Test ([int]$comparison.onlyReferenceFiles -eq 1 -and [int]$comparison.onlyCandidateFiles -eq 1) 'exclusive files are counted in both directions'
    Assert-Test ([long]$comparison.candidateByteDelta -eq 0) 'total byte delta is exact'
    $lighting = @($comparison.differenceGroups | Where-Object { $_.topLevel -eq 'Lighting' -and $_.status -eq 'changed' })[0]
    Assert-Test ([int]$lighting.files -eq 1 -and [long]$lighting.byteDelta -eq -2) 'top-level difference group includes byte delta'

    $transaction = Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
    $liveCache = Join-Path $resolvedTestRoot 'live\ShaderCache'
    $evidence = Join-Path $resolvedTestRoot 'transaction'
    New-Item -ItemType Directory -Path $liveCache -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'baseline.bin'), [byte[]](1, 4, 9))
    Set-Content -LiteralPath (Join-Path $liveCache 'Info.ini') -Value @('[Cache]', 'ShaderCacheABI = snapshot-abi') -Encoding utf8
    $snap = & $transaction snapshot -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($snap.ok -and (Test-Path -LiteralPath $snap.data.receiptPath -PathType Leaf)) 'transaction snapshots an exact cache with a receipt'
    $controlDirectory = @(Get-ChildItem -LiteralPath $env:CSX_SHADER_CACHE_CONTROL_ROOT -Directory)[0].FullName
    $targetLockPath = Join-Path $controlDirectory 'target.lock'
    $heldTargetLock = [IO.File]::Open($targetLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $contended = & $transaction snapshot -CachePath $liveCache -EvidenceDirectory $evidence -TransactionLockTimeoutMilliseconds 100 -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    }
    finally { $heldTargetLock.Dispose() }
    Assert-Test (-not $contended.ok -and $contended.errors[0] -match 'Timed out acquiring shader-cache target lock') 'a second mutator cannot enter the same canonical live-cache transaction'
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'baseline.bin'), [byte[]](2, 5, 10))
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'new.bin'), [byte[]](7, 8))
    $different = & $transaction verify -CachePath $liveCache -EvidenceDirectory $evidence -NoExit | ConvertFrom-Json
    Assert-Test (-not $different.ok -and -not $different.data.matches) 'transaction verification detects physical cache mutation'
    $restore = & $transaction restore -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    $verified = & $transaction verify -CachePath $liveCache -EvidenceDirectory $evidence -NoExit | ConvertFrom-Json
    Assert-Test ($restore.ok -and $verified.ok -and $verified.data.matches) 'transaction restores and verifies the exact baseline'
    Assert-Test (Test-Path -LiteralPath $restore.data.displacedPath -PathType Container) 'transaction retains the displaced cache tree'

    'rollback-original' | Set-Content -LiteralPath (Join-Path $liveCache 'rollback.txt') -Encoding utf8
    $rollbackOriginal = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    $failedBeforeDisplace = & $transaction restore -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -InternalTestFailurePoint restore-before-displace -Confirm:$false -NoExit | ConvertFrom-Json
    $beforeDisplaceAfter = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedBeforeDisplace.ok -and $beforeDisplaceAfter.data.treeSha256 -eq $rollbackOriginal.data.treeSha256) 'rollback leaves the exact live original in place when failure precedes displacement'
    $failedRestore = & $transaction restore -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -InternalTestFailurePoint restore-after-activate -Confirm:$false -NoExit | ConvertFrom-Json
    $rollbackAfter = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedRestore.ok -and $failedRestore.errors[0] -match 'exact original cache was restored') 'restore failure reports verified rollback rather than success'
    Assert-Test ($rollbackAfter.data.treeSha256 -eq $rollbackOriginal.data.treeSha256) 'restore failure removes the uncommitted replacement and restores the exact displaced tree'
    Remove-Item -LiteralPath (Join-Path $liveCache 'rollback.txt') -Force

    $snapshotSeed = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence `
        -SourceCachePath (Join-Path $evidence 'cache.before') -ExpectedSourceTreeSha256 $snap.data.inventory.treeSha256 `
        -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($snapshotSeed.ok) 'transaction accepts its receipt-owned cache.before snapshot as a seed source'

    $seedSource = Join-Path $resolvedTestRoot 'seed\CompatibleBaseline'
    New-Item -ItemType Directory -Path $seedSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $seedSource 'Info.ini') -Value @('[Cache]', 'ShaderCacheABI = old-abi', '', '[Feature]', 'Enabled = true', 'Version = 1-0-0') -Encoding utf8
    [IO.File]::WriteAllBytes((Join-Path $seedSource 'seed.bin'), [byte[]](11, 12, 13))
    $seedInventory = & $transaction inspect -CachePath $seedSource -NoExit | ConvertFrom-Json
    $seed = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -SourceCachePath $seedSource `
        -ExpectedSourceTreeSha256 $seedInventory.data.treeSha256 -ShaderCacheAbiOverride 'new-abi' `
        -CompatibilityReason 'Fixture proves a compatible scheduling-only contract change.' `
        -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($seed.ok -and (Test-Path -LiteralPath $seed.data.seedReceiptPath -PathType Leaf)) 'transaction seeds a verified arbitrarily named source cache with a receipt'
    if (-not $seed.ok) { throw "Seed fixture failed: $($seed.errors -join '; ')" }
    Assert-Test ((Get-Content -LiteralPath (Join-Path $liveCache 'Info.ini') -Raw) -match 'ShaderCacheABI\s*=\s*new-abi') 'seed records the explicit compatible ABI override in Info.ini'
    Assert-Test (Test-Path -LiteralPath $seed.data.displacedPath -PathType Container) 'seed retains the displaced cache tree'
    $wrongHash = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -SourceCachePath $seedSource `
        -ExpectedSourceTreeSha256 ('0' * 64) -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongHash.ok -and $wrongHash.errors[0] -match 'hash mismatch') 'seed rejects a source whose exact tree hash is not the approved identity'

    $boundedInventory = & $transaction inspect -CachePath $liveCache -MaxInventoryFiles 1 -NoExit | ConvertFrom-Json
    Assert-Test (-not $boundedInventory.ok -and $boundedInventory.errors[0] -match 'file-count bound') 'inventory fails closed at its explicit file-count bound'
    $inventoryContract = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test ($inventoryContract.ok -and $inventoryContract.data.entries[0].PSObject.Properties.Name -contains 'bytes' -and $inventoryContract.data.limits.maxFiles -eq 20000) 'inventory reports per-file sizes and the applied traversal limits'

    $originalBeforeInterrupted = $inventoryContract.data
    $requestedBeforeInterrupted = & $transaction inspect -CachePath (Join-Path $evidence 'cache.before') -NoExit | ConvertFrom-Json
    $interruptedDisplaced = Join-Path (Split-Path -Parent $liveCache) '.ShaderCache.displaced.interrupted-fixture'
    $interruptedStaging = Join-Path (Split-Path -Parent $liveCache) '.ShaderCache.seed.interrupted-fixture'
    Move-Item -LiteralPath $liveCache -Destination $interruptedDisplaced
    Copy-Item -LiteralPath (Join-Path $evidence 'cache.before') -Destination $liveCache -Recurse
    $evidenceJournal = Join-Path $evidence 'shader-cache-seed.interrupted-fixture.journal.json'
    $interruptedJournal = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; operation = 'seed'; phase = 'replacement-active-uncommitted'; operationId = 'interrupted-fixture'
        snapshotTransactionId = [string]$snap.data.inventory.treeSha256; cachePath = $liveCache; sourceCachePath = (Join-Path $evidence 'cache.before')
        originalTreeSha256 = [string]$originalBeforeInterrupted.treeSha256; requestedTreeSha256 = [string]$requestedBeforeInterrupted.data.treeSha256
        stagingPath = $interruptedStaging; displacedPath = $interruptedDisplaced; evidenceJournalPath = $evidenceJournal
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
    }
    $interruptedJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $controlDirectory 'transaction.journal.json') -Encoding utf8
    $interruptedJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $evidenceJournal -Encoding utf8
    $recoveryAttempt = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    $recoveredJournal = Get-Content -LiteralPath (Join-Path $controlDirectory 'transaction.journal.json') -Raw | ConvertFrom-Json
    $recoveredInventory = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test (-not $recoveryAttempt.ok -and $recoveryAttempt.errors[0] -match 'SourceCachePath' -and $recoveredJournal.phase -eq 'recovered') 'a later mutator reconciles a nonterminal target-owned journal before validating new inputs'
    Assert-Test ($recoveredInventory.data.treeSha256 -eq $originalBeforeInterrupted.treeSha256 -and $recoveredJournal.recovery.verified) 'restart reconciliation restores and verifies the exact displaced original tree'

    $missingLiveDisplaced = Join-Path (Split-Path -Parent $liveCache) '.ShaderCache.displaced.missing-live-fixture'
    $missingLiveStaging = Join-Path (Split-Path -Parent $liveCache) '.ShaderCache.restore.missing-live-fixture'
    Move-Item -LiteralPath $liveCache -Destination $missingLiveDisplaced
    $missingLiveJournal = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; operation = 'restore'; phase = 'original-displace-command-uncommitted'; operationId = 'missing-live-fixture'
        snapshotTransactionId = 'fixture'; cachePath = $liveCache
        originalTreeSha256 = [string]$originalBeforeInterrupted.treeSha256; requestedTreeSha256 = [string]$requestedBeforeInterrupted.data.treeSha256
        stagingPath = $missingLiveStaging; displacedPath = $missingLiveDisplaced; evidenceJournalPath = (Join-Path $evidence 'shader-cache-restore.missing-live-fixture.journal.json')
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
    }
    $missingLiveJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $controlDirectory 'transaction.journal.json') -Encoding utf8
    $missingLiveRecovery = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    $missingLiveAfter = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test (-not $missingLiveRecovery.ok -and $missingLiveAfter.ok -and $missingLiveAfter.data.treeSha256 -eq $originalBeforeInterrupted.treeSha256) 'restart reconciliation restores an original displaced before the replacement path was activated'

    $mods = Join-Path $resolvedTestRoot 'mods'
    $profile = Join-Path $resolvedTestRoot 'modlist.txt'
    New-Item -ItemType Directory -Path (Join-Path $mods 'Enabled Cache\ShaderCache'), (Join-Path $mods 'Disabled Cache\ShaderCache') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $mods 'Enabled Cache\ShaderCache\enabled.bin') -Value 'enabled' -NoNewline
    Set-Content -LiteralPath (Join-Path $mods 'Disabled Cache\ShaderCache\disabled.bin') -Value 'disabled' -NoNewline
    Set-Content -LiteralPath $profile -Value @('+Enabled Cache', '-Disabled Cache') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $mods 'Enabled Cache\Info.ini') -Value @('[Feature]', 'Version=1.2.3') -Encoding utf8
    $providerEvidence = Join-Path $resolvedTestRoot 'provider-evidence'
    $providers = & $transaction providers -ProfilePath $profile -ModsPath $mods -DeepInventory -EvidenceDirectory $providerEvidence -NoExit | ConvertFrom-Json
    Assert-Test ($providers.ok -and $providers.data.providers.Count -eq 2) 'provider inventory finds enabled and disabled physical cache providers'
    Assert-Test ($providers.data.enabledProviders -eq 1 -and $providers.data.disabledProviders -eq 1) 'provider inventory preserves exact MO2 marker state'
    Assert-Test (-not $providers.data.inventoryEntriesIncluded -and -not $providers.data.providers[0].inventory.PSObject.Properties['entries']) 'provider inventory defaults to compact tree summaries'
    $providerInventoryEvidence = Get-Content -LiteralPath $providers.data.inventoryEvidencePath -Raw | ConvertFrom-Json
    Assert-Test ($providerInventoryEvidence.providers[0].inventory.entries.Count -eq 1 -and $providerInventoryEvidence.providers[0].inventory.files -eq 1) 'provider inventory preserves full entries in separate evidence'

    $providersWithEntries = & $transaction providers -ProfilePath $profile -ModsPath $mods -DeepInventory -IncludeInventoryEntries -NoExit | ConvertFrom-Json
    Assert-Test ($providersWithEntries.data.inventoryEntriesIncluded -and $providersWithEntries.data.providers[0].inventory.PSObject.Properties['entries']) 'provider inventory includes entries only when explicitly requested'

    $dllRelativePath = 'SKSE\Plugins\CommunityShaders.dll'
    New-Item -ItemType Directory -Path (Join-Path $mods 'Enabled Cache\SKSE\Plugins'), (Join-Path $mods 'Disabled Cache\SKSE\Plugins') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $mods "Enabled Cache\$dllRelativePath"), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $mods "Disabled Cache\$dllRelativePath"), [byte[]](4, 5, 6))
    $fileProviders = & $transaction providers -ProfilePath $profile -ModsPath $mods -RelativeCachePath $dllRelativePath -DeepInventory -NoExit | ConvertFrom-Json
    Assert-Test ($fileProviders.ok -and $fileProviders.data.providers.Count -eq 2) 'provider inventory supports an exact relative file'
    Assert-Test ($fileProviders.data.effectiveWinnerAmongEnabledMods.modName -eq 'Enabled Cache') 'provider inventory identifies the enabled loose-file winner'
    Assert-Test ($fileProviders.data.providers[0].providerType -eq 'file' -and $fileProviders.data.providers[0].inventory.files -eq 1) 'file provider inventory includes its physical hash record'
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
