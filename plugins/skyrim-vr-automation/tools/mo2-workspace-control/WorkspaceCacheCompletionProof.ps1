# SPDX-License-Identifier: GPL-3.0-or-later

function Read-WorkspaceCacheProofJson([string]$Path, [string[]]$Fields) {
    Assert-NoWorkspaceReparsePoint -Path $Path -Purpose 'Shader-cache completion proof'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Shader-cache proof is missing: $Path" }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 40
    foreach ($field in $Fields) {
        if ($null -eq $value -or -not $value.PSObject.Properties[$field]) { throw "Shader-cache proof lacks '$field': $Path" }
    }
    return $value
}

function Assert-WorkspaceUnchangedFailedCacheCompletion($Workspace, $Plan, $Completion) {
    # Cleanup evidence is not generated/known-working output. Reconstruct its
    # proof from the exact physical snapshot, committed restore and journal;
    # never trust the additive receipt flag alone or repair missing evidence.
    $output = $Workspace.data.runtimeOutput
    $working = $Completion.workingTree
    if (-not $working.PSObject.Properties['status'] -or [string]$working.status -notin @('failed','unverified') -or
        -not $working.PSObject.Properties['unchangedPreparedFailure'] -or $working.unchangedPreparedFailure -isnot [bool] -or -not $working.unchangedPreparedFailure -or
        [int]$working.materializedFiles -ne 0 -or -not $Completion.PSObject.Properties['promoted'] -or $null -ne $Completion.promoted) {
        throw 'Zero-output shader-cache completion is not a non-promoted unchanged failed/unverified cleanup.'
    }
    foreach ($field in @('preparedTreeSha256','beforeTreeSha256','workingTreeInventory','transactionReceiptPath','restoreReceiptPath','evidenceDirectory','requireMaterializedOutput','providerShadow')) {
        if (-not $Plan.PSObject.Properties[$field]) { throw "Unchanged shader-cache plan lacks '$field'." }
    }
    $preparedHash = [string]$Plan.preparedTreeSha256
    $beforeHash = [string]$Plan.beforeTreeSha256
    if ($preparedHash -cnotmatch '\A[0-9a-fA-F]{64}\z' -or $beforeHash -cnotmatch '\A[0-9a-fA-F]{64}\z' -or
        $Plan.requireMaterializedOutput -isnot [bool] -or -not $Plan.requireMaterializedOutput -or
        $null -eq $Plan.providerShadow -or -not $Plan.providerShadow.PSObject.Properties['receipt'] -or
        $null -eq $Plan.providerShadow.receipt -or -not $Plan.providerShadow.receipt.PSObject.Properties['preparedInventory'] -or
        $null -eq $Plan.providerShadow.receipt.preparedInventory -or
        -not (Test-WorkspaceSha256Equal $preparedHash ([string]$Plan.providerShadow.receipt.preparedInventory.treeSha256)) -or
        -not (Test-WorkspaceSha256Equal $preparedHash ([string]$Plan.workingTreeInventory.treeSha256)) -or
        -not (Test-WorkspaceSha256Equal $preparedHash ([string]$working.inventory.treeSha256))) {
        throw 'Unchanged shader-cache cleanup does not bind the exact prepared provider-shadow and working trees.'
    }
    $evidence = [IO.Path]::GetFullPath([string]$output.cacheEvidenceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-WorkspaceSamePath ([string]$Plan.evidenceDirectory) $evidence)) { throw 'Shader-cache proof changed evidence directory.' }
    $snapshotPath = Join-Path $evidence 'shader-cache-transaction.receipt.json'
    $baselinePath = Join-Path $evidence 'cache.before'
    if (-not (Test-WorkspaceSamePath ([string]$Plan.transactionReceiptPath) $snapshotPath)) { throw 'Shader-cache snapshot pointer is not canonical for this generation.' }
    $snapshot = Read-WorkspaceCacheProofJson $snapshotPath @('operation','transactionId','cachePath','beforeTreeSha256','backupPath','evidenceDirectory')
    if ([string]$snapshot.operation -cne 'snapshot' -or [string]$snapshot.transactionId -cnotmatch '\A[0-9a-fA-F]{32}\z' -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.cachePath) ([string]$output.cachePath)) -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.evidenceDirectory) $evidence) -or
        -not (Test-WorkspaceSamePath ([string]$snapshot.backupPath) $baselinePath) -or
        -not (Test-WorkspaceSha256Equal ([string]$snapshot.beforeTreeSha256) $beforeHash)) {
        throw 'Shader-cache snapshot does not bind the exact original baseline and generation.'
    }
    $baseline = Get-WorkspaceOutputInventory -Path $baselinePath -Purpose 'Shader-cache original snapshot proof'
    if (-not (Test-WorkspaceSha256Equal ([string]$baseline.treeSha256) $beforeHash)) { throw 'Shader-cache original snapshot changed after completion.' }
    $restorePath = [IO.Path]::GetFullPath([string]$Plan.restoreReceiptPath)
    if (-not $restorePath.StartsWith($evidence + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Shader-cache restore escaped its evidence directory.' }
    $restore = Read-WorkspaceCacheProofJson $restorePath @('operation','transactionId','snapshotTransactionId','cachePath','restoredTreeSha256','displacedTreeSha256','displacedPath')
    $restoreId = [string]$restore.transactionId
    $operation = [string]$restore.operation
    if ($restoreId -cnotmatch '\A[0-9a-fA-F]{32}\z' -or $operation -cnotin @('restore','restore-noop') -or
        -not (Test-WorkspaceSamePath $restorePath (Join-Path $evidence "shader-cache-restore.$restoreId.receipt.json")) -or
        [string]$restore.snapshotTransactionId -cne [string]$snapshot.transactionId -or
        -not (Test-WorkspaceSamePath ([string]$restore.cachePath) ([string]$output.cachePath)) -or
        -not (Test-WorkspaceSha256Equal ([string]$restore.restoredTreeSha256) $beforeHash) -or
        -not (Test-WorkspaceSha256Equal ([string]$restore.displacedTreeSha256) $preparedHash) -or
        -not (Test-WorkspaceSamePath ([string]$restore.displacedPath) ([string]$working.preservedPath))) {
        throw 'Shader-cache committed restore does not bind its exact snapshot, path and preserved working tree.'
    }
    $preservedPath = [IO.Path]::GetFullPath([string]$working.preservedPath)
    if (-not $preservedPath.StartsWith($evidence + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Shader-cache preserved output escaped its evidence directory.' }
    $preserved = Get-WorkspaceOutputInventory -Path $preservedPath -Purpose 'Unchanged failed shader-cache preservation proof'
    foreach ($inventory in @($working.inventory,$Plan.workingTreeInventory,$Plan.providerShadow.receipt.preparedInventory)) {
        if (-not (Test-WorkspaceSha256Equal ([string]$preserved.treeSha256) ([string]$inventory.treeSha256)) -or
            [int]$preserved.files -ne [int]$inventory.files -or [long]$preserved.bytes -ne [long]$inventory.bytes) {
            throw 'Unchanged failed shader-cache preserved contents or inventory differ.'
        }
    }
    $journal = Read-WorkspaceCacheProofJson (Join-Path $evidence "shader-cache-restore.$restoreId.journal.json") @('operation','phase','operationId','snapshotTransactionId','cachePath','receiptPath')
    if ([string]$journal.operation -cne $operation -or [string]$journal.phase -cne 'committed' -or
        [string]$journal.operationId -cne $restoreId -or [string]$journal.snapshotTransactionId -cne [string]$snapshot.transactionId -or
        -not (Test-WorkspaceSamePath ([string]$journal.cachePath) ([string]$output.cachePath)) -or
        -not (Test-WorkspaceSamePath ([string]$journal.receiptPath) $restorePath)) { throw 'Shader-cache restore journal does not prove this exact committed restoration.' }
    if ($operation -ceq 'restore-noop') {
        if (-not $restore.PSObject.Properties['restorationNecessary'] -or $restore.restorationNecessary -isnot [bool] -or $restore.restorationNecessary -or
            -not (Test-WorkspaceSha256Equal $preparedHash $beforeHash) -or -not (Test-WorkspaceSamePath $preservedPath $baselinePath) -or
            -not $journal.PSObject.Properties['originalTreeSha256'] -or -not $journal.PSObject.Properties['requestedTreeSha256'] -or -not $journal.PSObject.Properties['preservedBaselinePath'] -or
            -not (Test-WorkspaceSha256Equal ([string]$journal.originalTreeSha256) $beforeHash) -or
            -not (Test-WorkspaceSha256Equal ([string]$journal.requestedTreeSha256) $beforeHash) -or
            -not (Test-WorkspaceSamePath ([string]$journal.preservedBaselinePath) $baselinePath)) {
            throw 'Shader-cache no-op does not prove the exact snapshot-bound preserved baseline.'
        }
    }
    # Before marker release the restored tree must exist. After complete-output
    # the existing caller additionally enforces absent task-created paths.
    if (Test-Path -LiteralPath ([string]$output.cachePath) -PathType Container) {
        $live = Get-WorkspaceOutputInventory -Path ([string]$output.cachePath) -Purpose 'Unchanged failed shader-cache restored baseline proof'
        if (-not (Test-WorkspaceSha256Equal ([string]$live.treeSha256) $beforeHash)) { throw 'Shader-cache restored original baseline changed.' }
    }
    elseif ([bool]$output.cachePathExistedBefore -or (Test-Path -LiteralPath ([string]$output.ownerMarkerPath)) -or $beforeHash -ine ('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855')) {
        throw 'Shader-cache restored baseline is missing without completed task-created-path cleanup proof.'
    }
}
