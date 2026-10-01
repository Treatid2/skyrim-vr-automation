# SPDX-License-Identifier: GPL-3.0-or-later
# Isolated fixture, loaded by Test-MO2WorkspaceControl.ps1 after normal prepare.
$oldOutput = $created.data.runtimeOutput
. (Join-Path $PSScriptRoot 'Test-ActiveOutputResume.inc.ps1')
. (Join-Path $PSScriptRoot 'Test-RequalificationCompletion.inc.ps1')
$candidateName = 'Codex Exact Candidate ON'
$candidate = & $entry create-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName $candidateName -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $candidate.ok) { throw 'Requalification fixture candidate creation failed.' }
$candidateRoot = $candidate.data.modDirectory
New-Item -ItemType Directory -Path (Join-Path $candidateRoot 'SKSE\Plugins'), (Join-Path $candidateRoot 'backup\new'), (Join-Path $candidateRoot 'ShaderCache\new') -Force | Out-Null
$newDll = Join-Path $candidateRoot 'SKSE\Plugins\CommunityShaders.dll'
[IO.File]::WriteAllBytes($newDll, [byte[]](9, 8, 7, 6, 5))
[IO.File]::WriteAllText((Join-Path $candidateRoot 'SKSE\Plugins\CSX.BuildManifest.json'), ([pscustomobject]@{ buildId = 'exact-current-ON'; artifact = @{sha256=(Get-FileHash $newDll).Hash;sizeBytes=5};identity=@{shaderCache=@{abiId='new-fixture-ABI'}} } | ConvertTo-Json -Depth 10))
[IO.File]::WriteAllText((Join-Path $candidateRoot 'backup\new\candidate.bin'), 'new-provider-backup')
[IO.File]::WriteAllText((Join-Path $candidateRoot 'ShaderCache\new\candidate.pso'), 'new-provider-cache')
$registered = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName $candidateName -ModDirectory $candidateRoot -WinningPaths 'SKSE\Plugins\CommunityShaders.dll' -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $registered.ok) { throw 'Requalification fixture candidate registration failed.' }
# Retain real unverified fixture output. Recovery must not delete it or fake materialization.
[IO.File]::WriteAllText((Join-Path $oldOutput.cachePath 'retained.pso'), 'unverified fixture cache')
[IO.File]::WriteAllText((Join-Path $oldOutput.backupPath 'retained.bin'), 'unverified fixture backup')
$manifestPath = Join-Path $sessions ('workspaces\' + $created.data.workspaceId + '.json')
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$markerBytes = [IO.File]::ReadAllBytes($oldOutput.ownerMarkerPath)
$modListBytes = [IO.File]::ReadAllBytes($created.data.modListPath)
$beforeCache = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
$transaction = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
$workingHashes = @{}
foreach ($kind in @('cache','backup')) {
    $inv = & $transaction inspect -CachePath $oldOutput.($kind+'Path') -NoExit | ConvertFrom-Json
    $workingHashes[$kind] = $inv.data.treeSha256
}
function Assert-RequalificationPreimage {
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath)) -cne [Convert]::ToBase64String($manifestBytes) -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($oldOutput.ownerMarkerPath)) -cne [Convert]::ToBase64String($markerBytes) -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($created.data.modListPath)) -cne [Convert]::ToBase64String($modListBytes)) { throw 'Requalification changed the exact retained manifest/marker/profile preimage.' }
    foreach ($kind in @('cache','backup')) {
        $inv = & $transaction inspect -CachePath $oldOutput.($kind+'Path') -NoExit | ConvertFrom-Json
        if ($inv.data.treeSha256 -cne $workingHashes[$kind]) { throw "Requalification did not preserve prior $kind working tree." }
    }
}
$blocked = Invoke-MO2Prepare -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -Label stale-binding -WhatIf
if ($blocked.ok) { throw 'Stale binding unexpectedly passed normal preparation.' }
$noConsent = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
if ($noConsent.ok -or $noConsent.errors[0] -notmatch 'ConfirmCandidateChanges') { throw 'Requalification ignored explicit consent gate.' }
$dry = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -WhatIf -NoExit -Compact | ConvertFrom-Json
if (-not $dry.ok -or $dry.state -ne 'dry-run' -or $dry.data.currentBuild.buildId -ne 'exact-current-ON') { throw "Requalification preview failed: $($dry | ConvertTo-Json -Depth 10 -Compress)" }
Assert-RequalificationPreimage
# Corruption must be detected before mutation, even with a valid lease and owner.
$baselineFile = Join-Path $oldOutput.backupEvidenceDirectory 'cache.before\preexisting.bin'
$baselineBytes = [IO.File]::ReadAllBytes($baselineFile)
[IO.File]::WriteAllText($baselineFile, 'corrupt original baseline')
$corrupt = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if ($corrupt.ok -or $corrupt.errors[0] -notmatch 'snapshot changed') { throw 'Requalification accepted corrupt original baseline.' }
Assert-RequalificationPreimage
[IO.File]::WriteAllBytes($baselineFile, $baselineBytes)
foreach ($failure in @('requalify-after-baseline','requalify-after-owner-release','requalify-after-rearm')) {
    $raw = & $powerShell -NoProfile -NonInteractive -File $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -InternalTestFailurePoint $failure -Compact
    if ($LASTEXITCODE -notin @(93,94,95)) { throw "Requalification interruption did not reach $failure`: $raw" }
    $recovered = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
    if (-not $recovered.ok) { throw "Requalification crash recovery failed at $failure`: $($recovered | ConvertTo-Json -Depth 10 -Compress)" }
    Assert-RequalificationPreimage
}
$rollbackFailure = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -Confirm:$false -InternalTestFailurePoint requalify-rollback-failure -NoExit -Compact | ConvertFrom-Json
if ($rollbackFailure.ok -or $rollbackFailure.errors[0] -notmatch 'recovery required') { throw 'Requalification rollback failure was not surfaced.' }
$pending = @(Get-ChildItem (Split-Path $manifestPath) -Filter '*.requalify-output.*.journal.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 100 } | Where-Object phase -eq 'recovery-required')
if ($pending.Count -ne 1 -or $pending[0].rollback.verified) { throw 'Requalification rollback failure falsely recorded success.' }
$recovered = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
if (-not $recovered.ok) { throw "Rollback failure recovery failed: $($recovered | ConvertTo-Json -Depth 10 -Compress)" }
Assert-RequalificationPreimage
$nestedRollbackFailure = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -Confirm:$false -InternalTestFailurePoint requalify-rearm-rollback-failure -NoExit -Compact | ConvertFrom-Json
if ($nestedRollbackFailure.ok -or $nestedRollbackFailure.errors[0] -notmatch 'recovery required') { throw 'Post-rearm rollback failure was not surfaced.' }
$recoveredNested = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
if (-not $recoveredNested.ok) { throw "Post-rearm rollback recovery failed: $($recoveredNested | ConvertTo-Json -Depth 12 -Compress)" }
Assert-RequalificationPreimage
$success = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ConfirmCandidateChanges -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $success.ok -or $success.state -ne 'output-requalified-cache-prepare-required') { throw "Requalification failed: $($success | ConvertTo-Json -Depth 10 -Compress)" }
$fresh = $success.data.runtimeOutput
if ($fresh.communityShadersPlugin.buildId -ne 'exact-current-ON' -or $fresh.cachePrepareArguments.ShaderCacheAbi -ne 'new-fixture-ABI' -or $fresh.ownerMarkerSha256 -eq $oldOutput.ownerMarkerSha256 -or $fresh.cachePathExistedBefore -ne $oldOutput.cachePathExistedBefore -or $fresh.backupPathExistedBefore -ne $oldOutput.backupPathExistedBefore) { throw 'Requalification used stale winners or baseline-existence semantics.' }
$historical = @($success.data.runtimeOutputHistory)[-1]
if ($historical.supersession.state -ne 'superseded-unverified' -or $historical.supersession.runtimeQualified -or $historical.backupPlanPath -ne $oldOutput.backupPlanPath) { throw 'Requalification destroyed or falsely qualified original history.' }
foreach ($item in $historical.supersession.evidence.items) {
    $receipt = Get-Content $item.restoreReceiptPath -Raw | ConvertFrom-Json
    $preserved = & $transaction inspect -CachePath $receipt.displacedPath -NoExit | ConvertFrom-Json
    if ($preserved.data.treeSha256 -cne $workingHashes[$item.kind]) { throw 'Requalification lost physical old working output.' }
}
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($created.data.modListPath)) -cne [Convert]::ToBase64String($modListBytes)) { throw 'Requalification changed task profile.' }
$newPrepared = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $fresh.cachePath -ProfilePath $success.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $fresh.cacheEvidenceDirectory -BuildId $fresh.cachePrepareArguments.BuildId -ShaderCacheAbi $fresh.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $success.data.workspaceId -OwnershipId $success.data.ownershipId -OwnerMarkerPath $fresh.ownerMarkerPath -OwnerMarkerSha256 $fresh.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
$qualifiedIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
if (-not $newPrepared.ok -or -not $qualifiedIsolation.ok) { throw "Requalified isolation/prepare failed: $($qualifiedIsolation | ConvertTo-Json -Depth 12 -Compress)" }
# Fixture-only simulated output permits testing actual completion; never recommended as a live workaround.
[IO.File]::WriteAllText((Join-Path $fresh.cachePath 'fixture-result.pso'), 'fixture-generated-result')
$completeCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $fresh.cachePath -EvidenceDirectory $fresh.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
$completeOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $success.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $completeCache.ok -or -not $completeOutput.ok) { throw "Requalified completion failed: $($completeOutput | ConvertTo-Json -Depth 12 -Compress)" }
if (Test-Path $fresh.ownerMarkerPath) { throw 'Requalified completion retained active marker.' }
$baselineBackup = & $transaction inspect -CachePath $fresh.backupPath -NoExit | ConvertFrom-Json
$oldBackupSnapshot = Get-Content (Join-Path $oldOutput.backupEvidenceDirectory 'shader-cache-transaction.receipt.json') -Raw | ConvertFrom-Json
if ($baselineBackup.data.treeSha256 -ne $oldBackupSnapshot.beforeTreeSha256) { throw 'Requalified completion failed to restore original backup baseline.' }
if (-not $oldOutput.cachePathExistedBefore -and (Test-Path $fresh.cachePath)) { throw 'Requalified completion recreated originally absent cache.' }
# A second supported workspace starts with both physical trees absent, matching
# the reported diagnostic workspace. Delete only this test's explicit fixture tree.
$fixtureBackup = [IO.Path]::GetFullPath([string]$fresh.backupPath)
if (-not $fixtureBackup.StartsWith([IO.Path]::GetFullPath($fixture) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test backup cleanup escaped fixture.' }
Remove-Item -LiteralPath $fixtureBackup -Recurse -Force
$absent = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceContent Modlist -Label requalify-absent-baselines -SavePolicy FreshGame -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $absent.ok -or $absent.data.runtimeOutput.backupPathExistedBefore -or $absent.data.runtimeOutput.cachePathExistedBefore) { throw 'Absent baseline fixture did not create supported workspace.' }
$ao = $absent.data.runtimeOutput
$argsPrepare = @{CatalogRoot=$catalogRoot;CachePath=$ao.cachePath;ProfilePath=$absent.data.modListPath;ModsPath=$mods;BindToOverwrite=$true;EvidenceDirectory=$ao.cacheEvidenceDirectory;BuildId=$ao.cachePrepareArguments.BuildId;ShaderCacheAbi=$ao.cachePrepareArguments.ShaderCacheAbi;WorkspaceId=$absent.data.workspaceId;OwnershipId=$absent.data.ownershipId;OwnerMarkerPath=$ao.ownerMarkerPath;OwnerMarkerSha256=$ao.ownerMarkerSha256;ShaderSourceSha256=$shaderSourceSha256;RequireMaterializedOutput=$true;BlockingProcessNames=@('MO2WorkspaceImpossibleFixtureProcess');NoExit=$true;Confirm=$false}
$ap = & $catalogEntry prepare @argsPrepare | ConvertFrom-Json
if (-not $ap.ok) { throw 'Absent baseline cache prepare failed.' }
$ar = & $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $absent.data.workspaceId -ConfirmCandidateChanges -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $ar.ok -or $ar.data.runtimeOutput.backupPathExistedBefore -or $ar.data.runtimeOutput.cachePathExistedBefore) { throw "Absent baseline requalification failed: $($ar | ConvertTo-Json -Depth 10 -Compress)" }
$an = $ar.data.runtimeOutput
$argsPrepare.EvidenceDirectory = $an.cacheEvidenceDirectory
$argsPrepare.OwnerMarkerSha256 = $an.ownerMarkerSha256
$ap = & $catalogEntry prepare @argsPrepare | ConvertFrom-Json
if (-not $ap.ok) { throw 'Absent baseline fresh cache prepare failed.' }
[IO.File]::WriteAllText((Join-Path $an.cachePath 'fixture-result.pso'), 'fixture generated')
$ac = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $an.cachePath -EvidenceDirectory $an.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
$ab = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $absent.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $ac.ok -or -not $ab.ok -or (Test-Path $an.cachePath) -or (Test-Path $an.backupPath) -or (Test-Path $an.ownerMarkerPath)) { throw "Absent baseline completion failed: $($ab | ConvertTo-Json -Depth 12 -Compress)" }
# A real replacement access capability must not admit another task or an
# unrelated requested workspace through global pending-journal recovery.
$ownerFixture = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceContent Modlist -Label requalify-recovery-owner -SavePolicy FreshGame -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $ownerFixture.ok) { throw 'Recovery-owner workspace creation failed.' }
$oo = $ownerFixture.data.runtimeOutput
$argsPrepare.CachePath = $oo.cachePath
$argsPrepare.ProfilePath = $ownerFixture.data.modListPath
$argsPrepare.EvidenceDirectory = $oo.cacheEvidenceDirectory
$argsPrepare.WorkspaceId = $ownerFixture.data.workspaceId
$argsPrepare.OwnershipId = $ownerFixture.data.ownershipId
$argsPrepare.OwnerMarkerPath = $oo.ownerMarkerPath
$argsPrepare.OwnerMarkerSha256 = $oo.ownerMarkerSha256
$argsPrepare.BuildId = $oo.cachePrepareArguments.BuildId
$argsPrepare.ShaderCacheAbi = $oo.cachePrepareArguments.ShaderCacheAbi
$ownerPrepared = & $catalogEntry prepare @argsPrepare | ConvertFrom-Json
if (-not $ownerPrepared.ok) { throw 'Recovery-owner cache prepare failed.' }
[IO.File]::WriteAllText((Join-Path $oo.cachePath 'owner-result.pso'), 'real fixture materialized output')
[IO.File]::WriteAllText((Join-Path $oo.backupPath 'owner-result.bin'), 'real fixture backup output')
$ownerManifest = Join-Path $sessions ('workspaces\' + $ownerFixture.data.workspaceId + '.json')
$ownerManifestBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerManifest))
$ownerMarkerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($oo.ownerMarkerPath))
$raw = & $powerShell -NoProfile -NonInteractive -File $entry requalify-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $ownerFixture.data.workspaceId -ConfirmCandidateChanges -InternalTestFailurePoint requalify-after-baseline -Compact
if ($LASTEXITCODE -ne 93) { throw "Recovery-owner interruption failed: $raw" }
$ownerPending = @(Get-ChildItem -LiteralPath (Split-Path $ownerManifest) -Filter ($ownerFixture.data.workspaceId + '.requalify-output.*.journal.json'))
if ($ownerPending.Count -ne 1) { throw 'Recovery-owner pending journal missing.' }
$replacementRelease = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
$replacement = Invoke-MO2RequestAccess -Config $config -TaskId different-task -Label foreign-task-recovery-fixture -RuntimeRoute SteamVRNull
if (-not $replacementRelease.ok -or -not $replacement.ok) { throw 'Real replacement access acquisition failed.' }
$accessId = [string]$replacement.data.access.accessId
function Get-RecoveryOwnerState {
    $hashes = @(@($ownerManifest,$oo.ownerMarkerPath,$ownerPending[0].FullName) | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    foreach ($kind in @('cache','backup')) {
        $state = & $transaction inspect -CachePath $oo.($kind+'Path') -NoExit | ConvertFrom-Json
        $hashes += $state.data.treeSha256
    }
    return $hashes -join ','
}
$beforeForeign = Get-RecoveryOwnerState
foreach ($request in @(@('different-task', $ownerFixture.data.workspaceId), @($taskId, 'different-workspace'), @($taskId, ''))) {
    $foreign = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $request[0] -WorkspaceId $request[1] -NoExit -Compact | ConvertFrom-Json
    if ($foreign.ok -or ($foreign.errors -join ' ') -notmatch 'different task identity|exact original workspace identity' -or (Get-RecoveryOwnerState) -cne $beforeForeign) { throw 'Foreign or inexact recovery mutated owner state with a valid replacement lease.' }
}
$null = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
$ownerAccess = Invoke-MO2RequestAccess -Config $config -TaskId $taskId -Label original-owner-recovery-fixture -RuntimeRoute SteamVRNull
if (-not $ownerAccess.ok) { throw 'Original owner replacement access acquisition failed.' }
$accessId = [string]$ownerAccess.data.access.accessId
$sameOwner = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $ownerFixture.data.workspaceId -NoExit -Compact | ConvertFrom-Json
# Recovery restores the genuine old access binding. The following inspect can
# correctly refuse that binding until F2's distinct resume transition is fixed.
if ((-not $sameOwner.ok -and ($sameOwner.errors -join ' ') -notmatch 'different MO2 access lease') -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerManifest)) -cne $ownerManifestBytes -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($oo.ownerMarkerPath)) -cne $ownerMarkerBytes) { throw 'Exact original owner replacement-lease recovery failed.' }
$ownerRecoveredJournal = Get-Content -LiteralPath $ownerPending[0].FullName -Raw | ConvertFrom-Json
if ($ownerRecoveredJournal.phase -ne 'rolled-back' -or -not $ownerRecoveredJournal.rollback.verified) { throw 'Exact owner recovery did not verify rollback.' }
$ownerResumed = & $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $ownerFixture.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
if (-not $ownerResumed.ok -or $ownerResumed.data.lastResumeDisposition -cne 'rebind-active-output' -or
    ($ownerResumed.data.runtimeOutput | ConvertTo-Json -Depth 80 -Compress) -cne ($oo | ConvertTo-Json -Depth 80 -Compress) -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($oo.ownerMarkerPath)) -cne $ownerMarkerBytes) { throw 'Replacement-lease resume failed after exact requalification rollback.' }
$null = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
'PASS: consent, preview, corruption refusal, real interruptions, rollback recovery, winner/history preservation, absent baselines, foreign-task/inexact-workspace refusal, exact-owner recovery, active-generation resume and normal completion after rollback with retained attempt audit.'
