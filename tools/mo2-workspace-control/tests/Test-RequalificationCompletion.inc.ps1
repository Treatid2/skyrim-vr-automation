# SPDX-License-Identifier: GPL-3.0-or-later
# Real public completion after rollback, using only this test's owned fixtures.
$rolledOutput = $created.data.runtimeOutput
[IO.File]::WriteAllText((Join-Path $rolledOutput.cachePath 'rollback-result.pso'), 'real fixture cache output')
[IO.File]::WriteAllText((Join-Path $rolledOutput.backupPath 'rollback-result.bin'), 'real fixture backup output')
$ordinaryBefore = @($rolledOutput.cacheEvidenceDirectory,$rolledOutput.backupEvidenceDirectory | ForEach-Object { Get-TestProfileFingerprint $_ }) -join ','
$raw = & $powerShell -NoProfile -NonInteractive -File $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -InternalTestFailurePoint requalify-after-baseline -Compact
if ($LASTEXITCODE -ne 93) { throw "Completion regression did not interrupt forward baseline restore: $raw" }
$rollbackRecovered = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
if (-not $rollbackRecovered.ok -or (@($rolledOutput.cacheEvidenceDirectory,$rolledOutput.backupEvidenceDirectory | ForEach-Object { Get-TestProfileFingerprint $_ }) -join ',') -cne $ordinaryBefore) { throw 'Failed requalification polluted the original plans/snapshots/completion namespace.' }
$attemptFile = Get-ChildItem -LiteralPath (Join-Path $sessions 'workspaces') -Filter ($created.data.workspaceId + '.requalify-output.*.journal.json') | Select-Object -First 1
$attempt = Get-Content -LiteralPath $attemptFile.FullName -Raw | ConvertFrom-Json -Depth 100
if ($attempt.phase -ne 'rolled-back' -or -not $attempt.rollback.verified) { throw 'Completion regression did not verify rollback.' }
$auditBefore = @($attempt.admission.items | ForEach-Object { Get-TestProfileFingerprint $_.restoreEvidence }) -join ','
$tx = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
foreach ($item in $attempt.admission.items) {
    $receipt = Get-Content -LiteralPath $item.restoreReceiptPath -Raw | ConvertFrom-Json -Depth 30
    $preserved = & $tx inspect -CachePath $receipt.displacedPath -NoExit -Compact | ConvertFrom-Json
    if ($receipt.snapshotTransactionId -cne $item.snapshotId -or $preserved.data.treeSha256 -cne $item.workingHash -or
        (Test-Path -LiteralPath (Join-Path $item.evidence ([IO.Path]::GetFileName($item.restoreReceiptPath))))) { throw 'Attempt-local restore lost exact snapshot lineage or physical displaced working output.' }
}
# Force a real normal completion failure after it persists completing state:
# temporarily add a bounded fault file to the test-owned baseline, then restore
# its exact prior bytes. Never manufacture a completing plan or completion receipt.
$cacheFault = Join-Path $rolledOutput.cacheEvidenceDirectory 'cache.before\fixture-baseline-fault.txt'
[IO.File]::WriteAllText($cacheFault, 'fixture corruption')
$failedCacheCompletion = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $rolledOutput.cachePath -EvidenceDirectory $rolledOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
Remove-Item -LiteralPath $cacheFault -Force
$pendingCache = Get-Content -LiteralPath $rolledOutput.cachePlanPath -Raw | ConvertFrom-Json -Depth 80
if ($failedCacheCompletion.ok -or $pendingCache.state -ne 'completing' -or (Test-Path -LiteralPath $rolledOutput.cacheCompletionPath) -or -not (Test-Path -LiteralPath $rolledOutput.ownerMarkerPath)) { throw 'Normal cache failure did not retain completing-state recovery authority.' }
$completedRollbackCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $rolledOutput.cachePath -EvidenceDirectory $rolledOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
if (-not $completedRollbackCache.ok) { throw "Cache completing-state retry after rollback failed: $($completedRollbackCache | ConvertTo-Json -Depth 12 -Compress)" }
$backupFault = Join-Path $rolledOutput.backupEvidenceDirectory 'cache.before\fixture-baseline-fault.txt'
[IO.File]::WriteAllText($backupFault, 'fixture corruption')
$failedBackupCompletion = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
Remove-Item -LiteralPath $backupFault -Force
$pendingBackup = Get-Content -LiteralPath $rolledOutput.backupPlanPath -Raw | ConvertFrom-Json -Depth 80
if ($failedBackupCompletion.ok -or $pendingBackup.state -ne 'completing' -or (Test-Path -LiteralPath $rolledOutput.backupCompletionPath) -or -not (Test-Path -LiteralPath $rolledOutput.ownerMarkerPath)) { throw 'Normal backup failure did not retain completing-state recovery authority.' }
$completedRollbackOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $completedRollbackOutput.ok -or (Test-Path -LiteralPath $rolledOutput.ownerMarkerPath) -or
    (@($attempt.admission.items | ForEach-Object { Get-TestProfileFingerprint $_.restoreEvidence }) -join ',') -cne $auditBefore) { throw 'Normal completion after rollback failed or altered retained attempt audit.' }
# Actual same-access resume verifies both terminal generations before rearming.
$created = & $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $created.ok -or $created.data.lastResumeDisposition -cne 'rearm-completed-output') { throw 'Completed rollback fixture could not rearm through the strict supported path.' }
$oldOutput = $created.data.runtimeOutput
$reprepared = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $oldOutput.cachePath -ProfilePath $created.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $oldOutput.cacheEvidenceDirectory -BuildId $oldOutput.cachePrepareArguments.BuildId -ShaderCacheAbi $oldOutput.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $created.data.workspaceId -OwnershipId $created.data.ownershipId -OwnerMarkerPath $oldOutput.ownerMarkerPath -OwnerMarkerSha256 $oldOutput.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
if (-not $reprepared.ok) { throw 'Fresh supported cache prepare after completion regression failed.' }
'PASS: attempt-local restore audit retains snapshot lineage and displaced output; real catalog/workspace completion and completing-state recovery succeed after exact rollback without changing attempt audit.'
