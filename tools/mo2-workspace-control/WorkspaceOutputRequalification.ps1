# SPDX-License-Identifier: GPL-3.0-or-later
# Private helpers, loaded by Invoke-MO2WorkspaceControl.ps1. No standalone entry point.

function Invoke-RequalificationTreeCommand($Config, [string]$Command, [string]$Path, [string]$Evidence) {
    Assert-TreeOperationBudget -Purpose "Output requalification $Command"
    $remaining = [Math]::Max(1, [int][Math]::Floor(($script:TreeOperationDeadlineUtc - [DateTime]::UtcNow).TotalSeconds))
    $tool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $result = & $tool $Command -CachePath $Path -RelativeCachePath ([IO.Path]::GetFileName($Path)) -EvidenceDirectory $Evidence -BlockingProcessNames (Get-WorkspaceBlockingProcessNames $Config) -InventoryTimeoutSeconds $remaining -NoExit -Confirm:$false | ConvertFrom-Json -Depth 40
    if (-not $result.ok) { throw "Output requalification $Command failed: $($result.errors -join '; ')" }
    Assert-TreeOperationBudget -Purpose "Output requalification $Command completion"
    return $result
}

function Get-RequalificationSnapshot($Config, [string]$Evidence, [string]$Path, [string]$ExpectedHash) {
    $root = Get-WorkspaceControlRoot $Config
    $null = Assert-WorkspaceRecoveryPath -Path $Evidence -Root $root -Purpose 'Requalification snapshot evidence'
    $receiptPath = Join-Path $Evidence 'shader-cache-transaction.receipt.json'
    Assert-NoWorkspaceReparsePoint -Path $receiptPath -Purpose 'Requalification snapshot receipt'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 40
    $baseline = Join-Path $Evidence 'cache.before'
    if ([string]$receipt.contractVersion -cne '2.0.0' -or [string]$receipt.operation -cne 'snapshot' -or
        [string]::IsNullOrWhiteSpace([string]$receipt.transactionId) -or
        -not (Test-WorkspaceSamePath ([string]$receipt.cachePath) $Path) -or
        -not (Test-WorkspaceSamePath ([string]$receipt.cacheParentPath) (Split-Path -Parent $Path)) -or
        [string]$receipt.cacheLeaf -cne [IO.Path]::GetFileName($Path) -or
        -not (Test-WorkspaceSamePath ([string]$receipt.evidenceDirectory) $Evidence) -or
        -not (Test-WorkspaceSamePath ([string]$receipt.backupPath) $baseline) -or
        [string]$receipt.beforeTreeSha256 -cne $ExpectedHash) { throw 'Requalification snapshot does not bind the exact original tree and path.' }
    $inventory = Get-WorkspaceOutputInventory -Path $baseline -Purpose 'Requalification original snapshot'
    if ([string]$inventory.treeSha256 -cne $ExpectedHash) { throw 'Requalification original snapshot changed.' }
    return $receipt
}

function Get-WorkspaceRequalificationAdmission($Config, $Workspace) {
    $output = $Workspace.data.runtimeOutput
    if ([string]$Workspace.data.status -cne 'ready' -or [string]$output.mode -cne 'mo2-overwrite-output') { throw 'Requalification requires a ready retained Overwrite workspace.' }
    $overwrite = [IO.Path]::GetFullPath([string]$Config.mo2.overwriteDirectory)
    foreach ($mapping in @(@('overwritePath', $overwrite), @('cachePath', (Join-Path $overwrite 'ShaderCache')), @('backupPath', (Join-Path $overwrite 'backup')), @('ownerMarkerPath', (Join-Path $overwrite '.codex-workspace-output-owner.json')))) {
        if (-not (Test-WorkspaceSamePath ([string]$output.($mapping[0])) $mapping[1])) { throw 'Requalification output paths differ from the configured exact Overwrite paths.' }
        Assert-NoWorkspaceReparsePoint -Path $mapping[1] -Purpose 'Requalification output path'
    }
    $marker = Assert-WorkspaceOutputOwnerMarker -Path $output.ownerMarkerPath -ExpectedSha256 $output.ownerMarkerSha256 -WorkspaceId $Workspace.data.workspaceId -OwnershipId $Workspace.data.ownershipId -OverwritePath $overwrite
    if ([string]$marker.ownerTaskId -cne [string]$Workspace.data.ownerTaskId) { throw 'Requalification owner marker has a different task identity.' }
    foreach ($completion in @($output.cacheCompletionPath, $output.backupCompletionPath)) {
        if (Test-Path -LiteralPath $completion) { throw 'Requalification refuses a completed or partially completed output generation; use its reviewed recovery path.' }
    }
    $items = @()
    foreach ($kind in @('cache', 'backup')) {
        $planPath = [string]$output.($kind + 'PlanPath')
        $evidence = [string]$output.($kind + 'EvidenceDirectory')
        $null = Assert-WorkspaceRecoveryPath -Path $planPath -Root $evidence -Purpose 'Requalification original plan'
        Assert-NoWorkspaceReparsePoint -Path $planPath -Purpose 'Requalification original plan'
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw "Requalification requires the original prepared $kind plan. Prepare the exact owned cache before requesting requalification; do not fabricate evidence." }
        $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 80
        if ([string]$plan.state -cne 'prepared' -or ($plan.PSObject.Properties['workingTreeInventory'] -and $null -ne $plan.workingTreeInventory)) { throw 'Requalification refuses a completing/restored generation.' }
        $binding = if ($kind -eq 'cache') { $plan.cacheBinding } else { $plan }
        $path = [string]$output.($kind + 'Path')
        if ([string]$binding.workspaceId -cne [string]$Workspace.data.workspaceId -or
            [string]$binding.ownershipId -cne [string]$Workspace.data.ownershipId -or
            [string]$binding.ownerMarkerSha256 -cne [string]$output.ownerMarkerSha256 -or
            -not (Test-WorkspaceSamePath ([string]$binding.ownerMarkerPath) ([string]$output.ownerMarkerPath)) -or
            -not (Test-WorkspaceSamePath ([string]$binding.profilePath) (Join-Path $Workspace.data.profilePath 'modlist.txt')) -or
            -not (Test-WorkspaceSamePath ([string]$binding.modsPath) ([string]$Config.mo2.modsDirectory)) -or
            -not (Test-WorkspaceSamePath ([string]$plan.($kind + 'Path')) $path)) { throw 'Requalification original plan has foreign ownership or paths.' }
        $snapshot = Get-RequalificationSnapshot -Config $Config -Evidence $evidence -Path $path -ExpectedHash ([string]$plan.beforeTreeSha256)
        if (-not (Test-WorkspaceSamePath ([string]$plan.transactionReceiptPath) (Join-Path $evidence 'shader-cache-transaction.receipt.json'))) { throw 'Requalification plan changed its original snapshot receipt pointer.' }
        $working = Get-WorkspaceOutputInventory -Path $path -Purpose 'Requalification retained working output'
        $items += [pscustomobject]@{ kind = $kind; path = $path; evidence = $evidence; planPath = $planPath; planSha256 = (Get-FileHash $planPath -Algorithm SHA256).Hash; baselineHash = [string]$snapshot.beforeTreeSha256; snapshotId = [string]$snapshot.transactionId; workingHash = [string]$working.treeSha256; workingFiles = [int]$working.files; restoreReceiptPath = $null; rollbackEvidence = $null; rollbackReady = $false }
    }
    $build = Resolve-WorkspaceCommunityShadersBuildBinding -ProfilePath (Join-Path $Workspace.data.profilePath 'modlist.txt') -ModsPath $Config.mo2.modsDirectory -TransactionTool (Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1')
    return [pscustomobject]@{ workspaceId = $Workspace.data.workspaceId; disposition = 'supersede-unverified-active-output'; items = $items; currentBuild = $build; requiresCachePrepare = $true; runtimeQualified = $false }
}

function Assert-WorkspaceRequalificationBoundary($Config, $Workspace, $Proof) {
    foreach ($item in @($Proof.items)) {
        $snapshot = Get-RequalificationSnapshot -Config $Config -Evidence $item.evidence -Path $item.path -ExpectedHash $item.baselineHash
        $null = Get-WorkspaceCommittedRestoreProof -ReceiptPath $item.restoreReceiptPath -EvidenceRoot $item.evidence -CachePath $item.path -BaselineTreeSha256 $item.baselineHash -WorkingTreeSha256 $item.workingHash -SnapshotTransactionId $snapshot.transactionId -TransactionTool (Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1')
    }
    if ([string]$Proof.workspaceId -cne [string]$Workspace.data.workspaceId -or @($Proof.items).Count -ne 2) { throw 'Requalification boundary lacks both exact restored output trees.' }
}

function Restore-WorkspaceRequalification($Config, $Journal, [string]$JournalPath) {
    # Used both on synchronous error and by the normal next-command recovery hook.
    $root = Get-WorkspaceControlRoot $Config
    $manifestPath = Assert-WorkspaceRecoveryPath -Path $Journal.manifestPath -Root $root -Purpose 'Requalification manifest recovery'
    $preimage = Assert-WorkspaceRecoveryPath -Path $Journal.manifestPreimagePath -Root $root -Purpose 'Requalification manifest preimage'
    if ((Get-FileHash $preimage -Algorithm SHA256).Hash -cne [string]$Journal.manifestPreimageSha256) { throw 'Requalification manifest preimage changed; recovery required.' }
    $prior = Get-Content -LiteralPath $preimage -Raw | ConvertFrom-Json -Depth 80
    # Global pending-journal discovery is not authority to recover another
    # task's retained workspace, even with a legitimate current MO2 lease.
    $recoveryTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
    Assert-WorkspaceTaskOwner -Workspace ([pscustomobject]@{ data = $prior }) -ResolvedTaskId $recoveryTaskId
    if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or $WorkspaceId -cne [string]$prior.workspaceId -or
        -not (Test-WorkspaceSamePath $manifestPath (Join-Path $root ($WorkspaceId + '.json')))) { throw 'Requalification recovery requires the exact original workspace identity.' }
    $null = Assert-AccessAndClosed -Config $Config -OwnedAccessId $AccessId -Profile $prior.profile -AllowOverwriteShaderCaches
    if ([string]$prior.workspaceId -cne [string]$Journal.workspaceId -or [string]$prior.ownershipId -cne [string]$Journal.ownershipId) { throw 'Requalification journal/preimage ownership mismatch.' }
    $markerPath = [string]$prior.runtimeOutput.ownerMarkerPath
    if (-not (Test-WorkspaceSamePath $markerPath (Join-Path $Config.mo2.overwriteDirectory '.codex-workspace-output-owner.json'))) { throw 'Requalification recovery marker escaped exact Overwrite.' }
    $markerPreimage = Assert-WorkspaceRecoveryPath -Path $Journal.markerPreimagePath -Root $root -Purpose 'Requalification marker preimage'
    if ((Get-FileHash $markerPreimage -Algorithm SHA256).Hash -cne [string]$prior.runtimeOutput.ownerMarkerSha256) { throw 'Requalification marker preimage changed; recovery required.' }
    $priorMarkerRestored = (Test-Path -LiteralPath $markerPath -PathType Leaf) -and (Get-FileHash $markerPath -Algorithm SHA256).Hash -ceq [string]$prior.runtimeOutput.ownerMarkerSha256
    if ($Journal.runtimeOutputRearm -and $priorMarkerRestored -and [string]$Journal.runtimeOutputRearm.state -in @('owner-release-authorized','owner-released','rolled-back')) {
        # A preceding rollback reclaimed the exact original marker before failing
        # on a tree restore. Do not treat it as the new generation's marker.
        $null = Assert-WorkspaceOutputOwnerMarker -Path $markerPath -ExpectedSha256 $prior.runtimeOutput.ownerMarkerSha256 -WorkspaceId $prior.workspaceId -OwnershipId $prior.ownershipId -OverwritePath $Config.mo2.overwriteDirectory
    }
    elseif ($Journal.runtimeOutputRearm) {
        Undo-JournaledRuntimeOutputRearm -Config $Config -WorkspaceId $prior.workspaceId -OwnershipId $prior.ownershipId -Rearm $Journal.runtimeOutputRearm -Journal $Journal -JournalPath $JournalPath
    }
    elseif (Test-Path -LiteralPath $markerPath) {
        $null = Assert-WorkspaceOutputOwnerMarker -Path $markerPath -ExpectedSha256 $prior.runtimeOutput.ownerMarkerSha256 -WorkspaceId $prior.workspaceId -OwnershipId $prior.ownershipId -OverwritePath $Config.mo2.overwriteDirectory
    }
    elseif (-not $Journal.ownerReleaseAuthorized) { throw 'Requalification lost ownership before its release checkpoint.' }
    # Claim only the exact prior capability, never overwrite a competing owner.
    if (-not (Test-Path -LiteralPath $markerPath)) {
        $bytes = [IO.File]::ReadAllBytes($markerPreimage)
        $stream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    $null = Assert-WorkspaceOutputOwnerMarker -Path $markerPath -ExpectedSha256 $prior.runtimeOutput.ownerMarkerSha256 -WorkspaceId $prior.workspaceId -OwnershipId $prior.ownershipId -OverwritePath $Config.mo2.overwriteDirectory
    foreach ($item in @($Journal.admission.items)) {
        if (-not $item.rollbackReady) { continue }
        $expectedPath = Join-Path $Config.mo2.overwriteDirectory $(if ($item.kind -eq 'cache') { 'ShaderCache' } elseif ($item.kind -eq 'backup') { 'backup' } else { throw 'Unknown requalification recovery tree.' })
        if (-not (Test-WorkspaceSamePath $item.path $expectedPath)) { throw 'Requalification rollback escaped exact output tree.' }
        $null = Get-RequalificationSnapshot -Config $Config -Evidence $item.rollbackEvidence -Path $item.path -ExpectedHash $item.workingHash
        if ($InternalTestFailurePoint -in @('requalify-rollback-failure','requalify-rearm-rollback-failure')) { throw 'Fixture requalification rollback failure.' }
        $null = Invoke-RequalificationTreeCommand -Config $Config -Command restore -Path $item.path -Evidence $item.rollbackEvidence
        $restored = Get-WorkspaceOutputInventory -Path $item.path -Purpose 'Requalification restored prior working tree'
        if ([string]$restored.treeSha256 -cne [string]$item.workingHash) { throw 'Requalification rollback did not restore exact working output.' }
    }
    Write-WorkspaceBytesAtomic -Path $manifestPath -Bytes ([IO.File]::ReadAllBytes($preimage))
    if ((Get-FileHash $manifestPath -Algorithm SHA256).Hash -cne [string]$Journal.manifestPreimageSha256) { throw 'Requalification rollback manifest verification failed.' }
    $Journal['phase'] = 'rolled-back'
    $Journal['rollback'] = @{ verified = $true; completedUtc = [DateTime]::UtcNow.ToString('o'); errors = @() }
    Write-WorkspaceJsonAtomic -Path $JournalPath -Value $Journal
    return $Journal
}

function Invoke-WorkspaceOutputRequalification($Config, $Workspace) {
    $admission = Get-WorkspaceRequalificationAdmission -Config $Config -Workspace $Workspace
    $id = [guid]::NewGuid().ToString('N')
    $root = Get-WorkspaceControlRoot $Config
    $journalPath = Get-WorkspaceOperationJournalPath -Config $Config -Id $Workspace.data.workspaceId -Operation 'requalify-output' -OperationId $id
    $evidence = Join-Path $root ($Workspace.data.workspaceId + '-requalification-' + $id)
    New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
    $preimage = Join-Path $evidence 'workspace.preimage.json'
    $markerPreimage = Join-Path $evidence 'owner-marker.preimage.json'
    Write-WorkspaceBytesAtomic -Path $preimage -Bytes ([IO.File]::ReadAllBytes($Workspace.path))
    Write-WorkspaceBytesAtomic -Path $markerPreimage -Bytes ([IO.File]::ReadAllBytes($Workspace.data.runtimeOutput.ownerMarkerPath))
    $journal = [ordered]@{
        contractVersion = '1.0.0'; operation = 'requalify-output'; phase = 'prepared'; operationId = $id
        workspaceId = $Workspace.data.workspaceId; ownershipId = $Workspace.data.ownershipId; manifestPath = $Workspace.path
        manifestPreimagePath = $preimage; manifestPreimageSha256 = (Get-FileHash $preimage -Algorithm SHA256).Hash
        markerPreimagePath = $markerPreimage; ownerReleaseAuthorized = $false; admission = $admission
        runtimeOutputRearm = $null; rollback = $null; preparedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
    try {
        foreach ($item in @($admission.items)) {
            $item.rollbackEvidence = Join-Path $evidence ($item.kind + '-working-preimage')
            $snapshot = Invoke-RequalificationTreeCommand -Config $Config -Command snapshot -Path $item.path -Evidence $item.rollbackEvidence
            if ([string]$snapshot.data.inventory.treeSha256 -cne [string]$item.workingHash) { throw 'Working output changed during requalification admission.' }
            $item.rollbackReady = $true
            Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        }
        foreach ($item in @($admission.items)) {
            if ((Get-FileHash $item.planPath -Algorithm SHA256).Hash -cne $item.planSha256) { throw 'Original plan changed during requalification.' }
            $restored = Invoke-RequalificationTreeCommand -Config $Config -Command restore -Path $item.path -Evidence $item.evidence
            $item.restoreReceiptPath = [string]$restored.data.restoreReceiptPath
            Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        }
        Assert-WorkspaceRequalificationBoundary -Config $Config -Workspace $Workspace -Proof $admission
        $journal.phase = 'original-baselines-restored'
        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        if ($InternalTestFailurePoint -eq 'requalify-after-baseline') { exit 93 }
        if ($InternalTestFailurePoint -eq 'requalify-rollback-failure') { throw 'Fixture failure after requalification baseline restore.' }
        $null = Assert-WorkspaceOutputOwnerMarker -Path $Workspace.data.runtimeOutput.ownerMarkerPath -ExpectedSha256 $Workspace.data.runtimeOutput.ownerMarkerSha256 -WorkspaceId $Workspace.data.workspaceId -OwnershipId $Workspace.data.ownershipId -OverwritePath $Config.mo2.overwriteDirectory
        $journal.ownerReleaseAuthorized = $true
        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        Remove-Item -LiteralPath $Workspace.data.runtimeOutput.ownerMarkerPath -Force
        if ($InternalTestFailurePoint -eq 'requalify-after-owner-release') { exit 94 }
        $fresh = New-RearmedWorkspaceRuntimeOutput -Config $Config -Workspace $Workspace -OperationId $id -Journal $journal -JournalPath $journalPath -RequalificationProof $admission
        if ($InternalTestFailurePoint -eq 'requalify-after-rearm') { exit 95 }
        if ($InternalTestFailurePoint -eq 'requalify-rearm-rollback-failure') { throw 'Fixture failure after fresh rearm before requalification commit.' }
        $buildAfter = Resolve-WorkspaceCommunityShadersBuildBinding -ProfilePath $Workspace.data.modListPath -ModsPath $Config.mo2.modsDirectory -TransactionTool (Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1')
        if (-not (Test-WorkspaceCommunityShadersBuildBinding -Expected $admission.currentBuild -Current $buildAfter) -or -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $fresh.communityShadersPlugin -Current $buildAfter)) { throw 'Winning build/profile changed during requalification.' }
        # Preserve original manifest + plans + snapshots, and classify supersession honestly.
        $old = $Workspace.data.runtimeOutput | ConvertTo-Json -Depth 80 | ConvertFrom-Json -Depth 80
        $old | Add-Member -NotePropertyName supersession -NotePropertyValue ([pscustomobject]@{ state = 'superseded-unverified'; journalPath = $journalPath; evidence = $admission; runtimeQualified = $false })
        $history = if ($Workspace.data.PSObject.Properties['runtimeOutputHistory']) { @($Workspace.data.runtimeOutputHistory) } else { @() }
        $Workspace.data | Add-Member -NotePropertyName runtimeOutputHistory -NotePropertyValue (@($history) + ,$old) -Force
        # Original path-existence semantics belong to the session baseline, not the temporary restored directories.
        $fresh.cachePathExistedBefore = [bool]$old.cachePathExistedBefore
        $fresh.backupPathExistedBefore = [bool]$old.backupPathExistedBefore
        $backupPlan = Get-Content $fresh.backupPlanPath -Raw | ConvertFrom-Json -Depth 80
        $backupPlan.pathExistedBefore = $fresh.backupPathExistedBefore
        $fresh.shadowReceipt.pathExistedBefore = $fresh.backupPathExistedBefore
        $backupPlan.shadowReceipt.pathExistedBefore = $fresh.backupPathExistedBefore
        Write-WorkspaceJsonAtomic -Path $fresh.backupPlanPath -Value $backupPlan
        $Workspace.data.runtimeOutput = $fresh
        $Workspace.data | Add-Member -NotePropertyName lastOutputRequalification -NotePropertyValue ([pscustomobject]@{ operationId = $id; journalPath = $journalPath; runtimeQualified = $false; cachePrepareRequired = $true }) -Force
        Write-WorkspaceJsonAtomic -Path $Workspace.path -Value $Workspace.data
        $journal.phase = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        return $Workspace.data
    }
    catch {
        $failure = $_.Exception.Message
        $recoveryJournal = $null
        try {
            $recoveryJournal = $journal | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
            $null = Restore-WorkspaceRequalification -Config $Config -Journal $recoveryJournal -JournalPath $journalPath
        }
        catch {
            if ($null -ne $recoveryJournal) { $journal = $recoveryJournal }
            $journal.phase = 'recovery-required'; $journal.rollback = @{ verified = $false; errors = @($_.Exception.Message); attemptedUtc = [DateTime]::UtcNow.ToString('o') }
            Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
            throw "Output requalification failed; recovery required. $failure Recovery: $($_.Exception.Message)"
        }
        throw "Output requalification failed; exact working trees, marker, and workspace manifest restored. $failure"
    }
}
