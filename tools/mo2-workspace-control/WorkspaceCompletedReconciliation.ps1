# SPDX-License-Identifier: GPL-3.0-or-later

# This validator deliberately has no live-tree restoration check. It is only
# used by the explicitly requested completed-generation reconciliation lane.
# Ordinary resume/completion retain their original strict live-baseline proofs.
function Assert-WorkspaceHistoricalTreeClosure($Plan, $Completion, [string]$Evidence, [string]$Path, [bool]$Existed, [switch]$ShaderCache) {
    $evidenceRoot = [IO.Path]::GetFullPath($Evidence).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $snapshotPath = Join-Path $evidenceRoot 'shader-cache-transaction.receipt.json'
    if (-not (Test-WorkspaceSamePath ([string]$Plan.transactionReceiptPath) $snapshotPath)) { throw 'Historical snapshot pointer is not canonical.' }
    $snapshot = Read-WorkspaceCacheProofJson $snapshotPath @('operation','transactionId','cachePath','beforeTreeSha256','backupPath','evidenceDirectory')
    $baselinePath = Join-Path $evidenceRoot 'cache.before'
    $beforeHash = [string]$Plan.beforeTreeSha256
    $working = if ($ShaderCache) { $Completion.workingTree.inventory } else { $Completion.workingTree }
    $preservedPath = if ($ShaderCache) { [string]$Completion.workingTree.preservedPath } else { [string]$Completion.preservedPath }
    if ($beforeHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or [string]$working.treeSha256 -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or
        [string]$snapshot.operation -cne 'snapshot' -or [string]$snapshot.transactionId -cnotmatch '\A[0-9A-Fa-f]{32}\z' -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.cachePath) $Path) -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.evidenceDirectory) $evidenceRoot) -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.backupPath) $baselinePath) -or
        -not (Test-WorkspaceSha256Equal ([string]$snapshot.beforeTreeSha256) $beforeHash)) { throw 'Historical snapshot lineage is invalid.' }
    $baseline = Get-WorkspaceOutputInventory -Path $baselinePath -Purpose 'Historical completed baseline'
    if (-not (Test-WorkspaceSha256Equal ([string]$baseline.treeSha256) $beforeHash) -or
        (-not $Existed -and -not (Test-WorkspaceSha256Equal $beforeHash (Get-WorkspaceBytesSha256 -Bytes ([byte[]]@()))))) { throw 'Historical physical baseline changed or contradicts prior absence.' }
    $restorePath = [IO.Path]::GetFullPath([string]$Plan.restoreReceiptPath)
    $preservedPath = [IO.Path]::GetFullPath($preservedPath)
    foreach ($candidate in @($restorePath,$preservedPath)) {
        if (-not $candidate.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Historical evidence escaped its generation.' }
    }
    $restore = Read-WorkspaceCacheProofJson $restorePath @('operation','transactionId','snapshotTransactionId','cachePath','restoredTreeSha256','displacedTreeSha256','displacedPath')
    $restoreId = [string]$restore.transactionId
    $operation = [string]$restore.operation
    if ($restoreId -cnotmatch '\A[0-9A-Fa-f]{32}\z' -or $operation -cnotin @('restore','restore-noop') -or
        (-not $ShaderCache -and $operation -cne 'restore') -or
        -not (Test-WorkspaceSamePath $restorePath (Join-Path $evidenceRoot "shader-cache-restore.$restoreId.receipt.json")) -or
        [string]$restore.snapshotTransactionId -cne [string]$snapshot.transactionId -or
        -not (Test-WorkspaceSamePath ([string]$restore.cachePath) $Path) -or
        -not (Test-WorkspaceSha256Equal ([string]$restore.restoredTreeSha256) $beforeHash) -or
        -not (Test-WorkspaceSha256Equal ([string]$restore.displacedTreeSha256) ([string]$working.treeSha256)) -or
        -not (Test-WorkspaceSamePath ([string]$restore.displacedPath) $preservedPath) -or
        (-not $ShaderCache -and -not (Test-WorkspaceSamePath ([string]$Completion.restoreReceiptPath) $restorePath)) -or
        -not (Test-WorkspaceSha256Equal ([string]$Completion.restoredTreeSha256) $beforeHash) -or
        -not (Test-WorkspaceSha256Equal ([string]$Plan.workingTreeInventory.treeSha256) ([string]$working.treeSha256))) { throw 'Historical committed restore does not close the exact plan.' }
    $preserved = Get-WorkspaceOutputInventory -Path $preservedPath -Purpose 'Historical completed working output'
    foreach ($inventory in @($working,$Plan.workingTreeInventory)) {
        if (-not (Test-WorkspaceSha256Equal ([string]$preserved.treeSha256) ([string]$inventory.treeSha256)) -or
            [long]$preserved.files -ne [long]$inventory.files -or [long]$preserved.bytes -ne [long]$inventory.bytes) { throw 'Historical preserved working output changed.' }
    }
    $journalPath = Join-Path $evidenceRoot "shader-cache-restore.$restoreId.journal.json"
    $journal = Read-WorkspaceCacheProofJson $journalPath @('operation','phase','operationId','snapshotTransactionId','cachePath','receiptPath')
    if ([string]$journal.operation -cne $operation -or [string]$journal.phase -cne 'committed' -or
        [string]$journal.operationId -cne $restoreId -or [string]$journal.snapshotTransactionId -cne [string]$snapshot.transactionId -or
        -not (Test-WorkspaceSamePath ([string]$journal.cachePath) $Path) -or
        -not (Test-WorkspaceSamePath ([string]$journal.receiptPath) $restorePath)) { throw 'Historical restore journal is not the exact committed restoration.' }
    if ($operation -ceq 'restore-noop') {
        if (-not $restore.PSObject.Properties['restorationNecessary'] -or $restore.restorationNecessary -isnot [bool] -or $restore.restorationNecessary -or
            -not (Test-WorkspaceSha256Equal $beforeHash ([string]$working.treeSha256)) -or
            -not (Test-WorkspaceSamePath $preservedPath $baselinePath) -or
            -not (Test-WorkspaceSha256Equal ([string]$journal.originalTreeSha256) $beforeHash) -or
            -not (Test-WorkspaceSha256Equal ([string]$journal.requestedTreeSha256) $beforeHash) -or
            -not (Test-WorkspaceSamePath ([string]$journal.preservedBaselinePath) $baselinePath)) { throw 'Historical no-op lost its exact snapshot-bound baseline proof.' }
    }
    if ($ShaderCache -and (-not $Completion.PSObject.Properties['planSha256'] -or
        -not (Test-WorkspaceSha256Equal ([string]$Completion.planSha256) ((Get-FileHash -LiteralPath ([string]$Completion.planPath)).Hash)))) { throw 'Historical cache plan digest differs from its completion.' }
    return [pscustomobject]@{ receipt=$restore; journal=$journal; preserved=$preserved; data=[pscustomobject]@{ displacedPath=$preservedPath } }
}

function Get-WorkspaceReconciliationBaseline($Workspace) {
    $output = $Workspace.data.runtimeOutput
    $result = [ordered]@{}
    foreach ($kind in @('cache','backup')) {
        $path = [string]$output.($kind + 'Path')
        $checkPath = if (Test-Path -LiteralPath $path) { $path } else { Split-Path -Parent $path }
        Assert-NoWorkspaceReparsePoint -Path $checkPath -Purpose 'New shared output baseline'
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Shared output baseline is not a directory.' }
        $exists = Test-Path -LiteralPath $path -PathType Container
        $inventory = if ($exists) { Get-WorkspaceOutputInventory -Path $path -Purpose 'New shared output baseline' } else { [pscustomobject]@{ treeSha256=(Get-WorkspaceBytesSha256 -Bytes ([byte[]]@())); files=0; bytes=0 } }
        $result[$kind] = [pscustomobject]@{ path=$path; exists=[bool]$exists; treeSha256=[string]$inventory.treeSha256; files=[long]$inventory.files; bytes=[long]$inventory.bytes }
    }
    $result['capturedUtc']=[DateTime]::UtcNow.ToString('o')
    return [pscustomobject]$result
}

function Assert-WorkspaceReconciliationBaseline($Workspace, $Baseline, [switch]$AllowCreatedEmpty, [switch]$CacheOnly) {
    $current = Get-WorkspaceReconciliationBaseline $Workspace
    foreach ($kind in @('cache','backup')) {
        if ($CacheOnly -and $kind -ceq 'backup') { continue }
        $expected=$Baseline.$kind; $observed=$current.$kind
        $createdEmpty = $AllowCreatedEmpty -and -not $expected.exists -and $observed.exists -and $observed.files -eq 0
        if (-not (Test-WorkspaceSamePath ([string]$expected.path) ([string]$observed.path)) -or
            (-not $createdEmpty -and [bool]$expected.exists -ne [bool]$observed.exists) -or
            -not (Test-WorkspaceSha256Equal ([string]$expected.treeSha256) ([string]$observed.treeSha256)) -or
            [long]$expected.files -ne [long]$observed.files -or [long]$expected.bytes -ne [long]$observed.bytes) { throw "Shared $kind baseline drifted during completed-output reconciliation." }
    }
}
