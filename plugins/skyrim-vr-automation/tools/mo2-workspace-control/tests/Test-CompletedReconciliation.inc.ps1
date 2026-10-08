# SPDX-License-Identifier: GPL-3.0-or-later
# Real public CLI and primitive fixtures only; no live installation or runtime.
$checks=0
function Check-Reconciliation([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++; "PASS: $Message" }
$o=$created.data.runtimeOutput
$manifest=Join-Path (Join-Path $sessions 'workspaces') ($created.data.workspaceId+'.json')
$profileBefore=Get-TestProfileFingerprint $created.data.profilePath
$null=Complete-RearmedTestOutput $created $accessId
$oldEvidenceHash=@((Get-TestProfileFingerprint $o.cacheEvidenceDirectory),(Get-TestProfileFingerprint $o.backupEvidenceDirectory)) -join ','
$oldManifest=[IO.File]::ReadAllBytes($manifest)
# Shared output is legitimate new baseline, not output of the completed task.
[IO.Directory]::CreateDirectory($o.cachePath)|Out-Null
[IO.Directory]::CreateDirectory($o.backupPath)|Out-Null
[IO.File]::WriteAllText((Join-Path $o.cachePath 'new-human-cache.pso'),'human-cache')
[IO.File]::WriteAllText((Join-Path $o.backupPath 'new-human-backup.bin'),'human-backup')
$humanHash=Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
$iniBefore=(Get-FileHash -LiteralPath $ini).Hash
$ordinary=& $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Reconciliation (-not $ordinary.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) 'ordinary resume remains strict after human baseline growth'
$parameters=@{ConfigPath=$configPath;AccessId=$accessId;TaskId=$taskId;WorkspaceId=$created.data.workspaceId;NoExit=$true;Confirm=$false;ReconciliationNote='Fixture later human output; producer identity not inferred from file timestamps.'}
$noNote=$parameters.Clone(); $noNote.Remove('ReconciliationNote')
$refusal=& $entry reconcile-completed-output @noNote | ConvertFrom-Json
Check-Reconciliation (-not $refusal.ok) 'explicit reconciliation note required'
$foreign=$parameters.Clone(); $foreign.TaskId='foreign-task'
$refusal=& $entry reconcile-completed-output @foreign | ConvertFrom-Json
Check-Reconciliation (-not $refusal.ok) 'foreign task cannot reconcile retained generation'
$foreign=$parameters.Clone(); $foreign.AccessId='foreign-access'
$refusal=& $entry reconcile-completed-output @foreign | ConvertFrom-Json
Check-Reconciliation (-not $refusal.ok) 'foreign access cannot reconcile retained generation'
$preview=& $entry reconcile-completed-output @parameters -WhatIf | ConvertFrom-Json
Check-Reconciliation ($preview.ok -and $preview.reconciliation.historicalEvidenceValidated -and -not $preview.reconciliation.launchReady -and
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest)) -ceq [Convert]::ToBase64String($oldManifest) -and
    (Get-FileHash -LiteralPath $ini).Hash -ceq $iniBefore -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) 'preview independently proves historical closure without changing human baseline or workspace'
$plan=Get-Content -LiteralPath $o.cachePlanPath -Raw | ConvertFrom-Json -Depth 40
$backupPlan=Get-Content -LiteralPath $o.backupPlanPath -Raw | ConvertFrom-Json -Depth 40
$tamperCases=@(
    @{path=$o.cacheCompletionPath;field='restoredTreeSha256'},
    @{path=$plan.restoreReceiptPath;field='snapshotTransactionId'},
    @{path=$o.backupCompletionPath;field='cachePlanTransactionId'},
    @{path=$backupPlan.transactionReceiptPath;field='beforeTreeSha256'},
    @{path=(Join-Path $o.backupEvidenceDirectory ('shader-cache-restore.'+(Get-Content $backupPlan.restoreReceiptPath -Raw|ConvertFrom-Json).transactionId+'.journal.json'));field='phase'}
)
foreach ($case in $tamperCases) {
    $bytes=[IO.File]::ReadAllBytes($case.path)
    try {
        $value=Get-Content -LiteralPath $case.path -Raw | ConvertFrom-Json -Depth 40
        $value.($case.field)='0'*64
        [IO.File]::WriteAllText($case.path,($value|ConvertTo-Json -Depth 40))
        $r=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
        Check-Reconciliation (-not $r.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest)) -ceq [Convert]::ToBase64String($oldManifest)) "historical $($case.field) tamper refuses without shared mutation"
    } finally { [IO.File]::WriteAllBytes($case.path,$bytes) }
}
# Any active marker, including same owner, is a different lifecycle lane.
[IO.File]::WriteAllText($o.ownerMarkerPath,'{}')
try {
    $r=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
    Check-Reconciliation (-not $r.ok -and (Test-Path -LiteralPath $o.ownerMarkerPath)) 'active/foreign marker refused and retained'
} finally { Remove-Item -LiteralPath $o.ownerMarkerPath -Force }
$snapshotTamper=Join-Path $o.cacheEvidenceDirectory 'cache.before/unclassified.bin'
[IO.File]::WriteAllText($snapshotTamper,'changed-old-baseline')
try {
    $bad=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
    Check-Reconciliation (-not $bad.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) 'historical physical snapshot tampering refuses shared mutation'
} finally { Remove-Item -LiteralPath $snapshotTamper -Force }
$legacy=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json -Depth 80
$legacy.runtimeOutput.PSObject.Properties.Remove('backupCompletionPath')
[IO.File]::WriteAllText($manifest,($legacy|ConvertTo-Json -Depth 80))
try {
    $bad=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
    Check-Reconciliation (-not $bad.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) 'unsupported legacy contract does not gain reconciliation authority'
} finally { [IO.File]::WriteAllBytes($manifest,$oldManifest) }
if ($IsWindows) {
    $moved=Join-Path $fixture 'reparse-cache-target'
    Move-Item -LiteralPath $o.cachePath -Destination $moved
    try {
        New-Item -ItemType Junction -Path $o.cachePath -Target $moved | Out-Null
        $bad=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
        Check-Reconciliation (-not $bad.ok -and (Test-Path -LiteralPath (Join-Path $moved 'new-human-cache.pso'))) 'reparse shared cache refuses without traversing or deleting target'
    } finally {
        if (Test-Path -LiteralPath $o.cachePath) { Remove-Item -LiteralPath $o.cachePath -Force }
        Move-Item -LiteralPath $moved -Destination $o.cachePath
    }
}
foreach ($seam in @('resume-interrupt-after-output-rearm','resume-interrupt-after-manifest-write')) {
    $raw=& $powerShell -NoProfile -NonInteractive -File $entry reconcile-completed-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ReconciliationNote 'Fixture interrupted reconciliation of later human baseline.' -InternalTestFailurePoint $seam -Confirm:$false -Compact -NoExit
    $expected=if ($seam -ceq 'resume-interrupt-after-output-rearm') {91} else {97}
    Check-Reconciliation ($LASTEXITCODE -eq $expected) "real public reconciliation reaches $seam"
    $r=& $entry list-task -ConfigPath $configPath -TaskId $taskId -NoExit -Compact | ConvertFrom-Json
    Check-Reconciliation ($r.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest)) -ceq [Convert]::ToBase64String($oldManifest) -and
        (Get-TestProfileFingerprint $created.data.profilePath) -ceq $profileBefore -and -not (Test-Path -LiteralPath $o.ownerMarkerPath)) "restart rollback at $seam preserves current human baseline and exact original task manifest/profile"
}
foreach ($kind in @('cache','backup')) {
    $raw=& $powerShell -NoProfile -NonInteractive -File $entry reconcile-completed-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ReconciliationNote 'Fixture concurrent drift refusal.' -InternalTestFailurePoint resume-interrupt-after-output-rearm -Confirm:$false -Compact -NoExit
    Check-Reconciliation ($LASTEXITCODE -eq 91) "drift fixture reaches committed new $kind baseline snapshots"
    $driftPath=Join-Path $o.($kind+'Path') 'unclassified-concurrent-output.bin'
    [IO.File]::WriteAllText($driftPath,'foreign-writer')
    $beforeDrift=Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
    $driftManifest=(Get-FileHash -LiteralPath $manifest).Hash
    $r=& $entry list-task -ConfigPath $configPath -TaskId $taskId -NoExit -Compact | ConvertFrom-Json
    Check-Reconciliation (-not $r.ok -and (Test-Path -LiteralPath $o.ownerMarkerPath) -and
        (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $beforeDrift -and
        (Get-FileHash -LiteralPath $manifest).Hash -ceq $driftManifest) "unclassified interrupted $kind drift refuses restoration/owner release and retains all bytes"
    Remove-Item -LiteralPath $driftPath -Force
    $r=& $entry list-task -ConfigPath $configPath -TaskId $taskId -NoExit -Compact | ConvertFrom-Json
    Check-Reconciliation ($r.ok -and (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) "fixture returns exact $kind pre-drift tree before supported rollback"
}
$r=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
Check-Reconciliation ($r.ok -and $r.data.lastResumeDisposition -ceq 'reconciled-completed-output' -and
    $r.data.runtimeOutput.cacheEvidenceDirectory -cne $o.cacheEvidenceDirectory -and
    $r.data.runtimeOutputHistory.Count -eq 1 -and
    (Get-TestProfileFingerprint $created.data.profilePath) -ceq $profileBefore) 'new generation reconciled without recreating or reverting task profile'
$new=$r.data.runtimeOutput
Check-Reconciliation ((Test-Path -LiteralPath $new.completedReconciliation.cacheSnapshotPath) -and
    (Test-Path -LiteralPath $new.completedReconciliation.backupSnapshotPath) -and
    (Get-Content -LiteralPath $new.completedReconciliation.cacheSnapshotPath -Raw|ConvertFrom-Json).beforeTreeSha256 -ceq $new.completedReconciliation.baseline.cache.treeSha256) 'both new shared baselines have retained snapshot receipts'
$activeRefusal=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
Check-Reconciliation (-not $activeRefusal.ok) 'reconciliation cannot rearm its now-active generation again'
# A late writer cannot silently become the baseline of subsequent catalog prepare.
$latePath=Join-Path $new.cachePath 'late-writer.bin'
[IO.File]::WriteAllText($latePath,'late-writer')
try {
    $p=& $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $new.cachePath -ProfilePath $r.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $new.cacheEvidenceDirectory -BuildId $new.cachePrepareArguments.BuildId -ShaderCacheAbi $new.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $r.data.workspaceId -OwnershipId $r.data.ownershipId -OwnerMarkerPath $new.ownerMarkerPath -OwnerMarkerSha256 $new.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    Check-Reconciliation (-not $p.ok -and -not (Test-Path -LiteralPath $new.cachePlanPath) -and
        (Test-Path -LiteralPath $latePath)) 'late cache drift refuses fresh catalog preparation without destructive rebasing'
} finally { Remove-Item -LiteralPath $latePath -Force }
# Restart admission must not attribute later shared writes to the published plan.
$prepareParameters=@{CatalogRoot=$catalogRoot;CachePath=$new.cachePath;ProfilePath=$r.data.modListPath;ModsPath=$mods;BindToOverwrite=$true;EvidenceDirectory=$new.cacheEvidenceDirectory;BuildId=$new.cachePrepareArguments.BuildId;ShaderCacheAbi=$new.cachePrepareArguments.ShaderCacheAbi;WorkspaceId=$r.data.workspaceId;OwnershipId=$r.data.ownershipId;OwnerMarkerPath=$new.ownerMarkerPath;OwnerMarkerSha256=$new.ownerMarkerSha256;ShaderSourceSha256=$shaderSourceSha256;RequireMaterializedOutput=$true;BlockingProcessNames='MO2WorkspaceImpossibleFixtureProcess';NoExit=$true;Confirm=$false}
$interruptArguments=@('-NoProfile','-NonInteractive','-File',$catalogEntry,'prepare')
foreach($key in $prepareParameters.Keys){
    if($key -in @('NoExit','Confirm','BindToOverwrite','RequireMaterializedOutput')){continue}
    $interruptArguments+=@(('-'+$key),[string]$prepareParameters[$key])
}
$interruptArguments+=@('-BindToOverwrite','-RequireMaterializedOutput','-NoExit','-Confirm:$false','-InternalTestFailurePoint','prepare-interrupt-after-snapshot-plan')
$null=& $powerShell @interruptArguments
Check-Reconciliation ($LASTEXITCODE -eq 93) 'public catalog stops immediately after snapshot-preserved plan publication'
$retryPlan=Get-Content -LiteralPath $new.cachePlanPath -Raw | ConvertFrom-Json -Depth 40
$retrySnapshot=[string]$retryPlan.transactionReceiptPath
$planHash=(Get-FileHash -LiteralPath $new.cachePlanPath).Hash
$snapshotHash=(Get-FileHash -LiteralPath $retrySnapshot).Hash
$markerHash=(Get-FileHash -LiteralPath $new.ownerMarkerPath).Hash
$providerHash=Get-TestProfileFingerprint $mods
$shadowPath=Join-Path $new.cacheEvidenceDirectory 'shader-cache-provider-shadow.receipt.json'
Check-Reconciliation ($retryPlan.state -ceq 'snapshot-preserved' -and -not (Test-Path -LiteralPath $shadowPath)) 'interruption retained snapshot plan before any provider materialization'
[IO.File]::WriteAllText($latePath,'foreign-after-plan')
$driftHash=Get-TestProfileFingerprint $new.cachePath
$retry=& $catalogEntry prepare @prepareParameters | ConvertFrom-Json
Check-Reconciliation (-not $retry.ok -and @($retry.errors | Where-Object {$_ -match 'snapshot-preserved.*baseline|reconciled.*baseline|changed after completed-output reconciliation'}).Count -eq 1) 'snapshot-preserved retry refuses post-plan shared-cache drift'
Check-Reconciliation ((Get-FileHash -LiteralPath $new.cachePlanPath).Hash -ceq $planHash -and (Get-FileHash -LiteralPath $retrySnapshot).Hash -ceq $snapshotHash -and (Get-FileHash -LiteralPath $new.ownerMarkerPath).Hash -ceq $markerHash -and (Get-TestProfileFingerprint $new.cachePath) -ceq $driftHash -and (Get-TestProfileFingerprint $mods) -ceq $providerHash -and -not (Test-Path -LiteralPath $shadowPath)) 'retry drift refusal preserves plan snapshot owner foreign bytes and providers without prepared state'
Remove-Item -LiteralPath $latePath -Force
$snapshotBytes=[IO.File]::ReadAllBytes($retrySnapshot)
foreach($field in @('cachePath','beforeTreeSha256','operation','transactionId')){
    $tampered=Get-Content -LiteralPath $retrySnapshot -Raw | ConvertFrom-Json -Depth 40
    $tampered.$field=if($field -eq 'cachePath'){Join-Path $fixture 'foreign-cache'}elseif($field -eq 'operation'){'seed'}elseif($field -eq 'transactionId'){''}else{'0'*64}
    [IO.File]::WriteAllText($retrySnapshot,($tampered|ConvertTo-Json -Depth 40))
    try{
        $tamperedHash=(Get-FileHash -LiteralPath $retrySnapshot).Hash
        $retry=& $catalogEntry prepare @prepareParameters | ConvertFrom-Json
        Check-Reconciliation (-not $retry.ok -and (Get-FileHash -LiteralPath $new.cachePlanPath).Hash -ceq $planHash -and (Get-FileHash -LiteralPath $retrySnapshot).Hash -ceq $tamperedHash -and (Get-FileHash -LiteralPath $new.ownerMarkerPath).Hash -ceq $markerHash -and -not (Test-Path -LiteralPath $shadowPath)) "snapshot-preserved retry refuses and preserves tampered $field receipt"
    }finally{[IO.File]::WriteAllBytes($retrySnapshot,$snapshotBytes)}
}
$retry=& $catalogEntry prepare @prepareParameters | ConvertFrom-Json
Check-Reconciliation ($retry.ok -and $retry.data.task.state -ceq 'prepared' -and (Get-FileHash -LiteralPath $retrySnapshot).Hash -ceq $snapshotHash -and (Get-FileHash -LiteralPath $new.ownerMarkerPath).Hash -ceq $markerHash -and (Test-Path -LiteralPath $shadowPath)) 'same retained snapshot-preserved plan resumes successfully when baseline has no drift'
Complete-RearmedTestOutput $r $accessId
Check-Reconciliation ((Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash -and
    (Get-TestProfileFingerprint $created.data.profilePath) -ceq $profileBefore -and
    (@((Get-TestProfileFingerprint $o.cacheEvidenceDirectory),(Get-TestProfileFingerprint $o.backupEvidenceDirectory)) -join ',') -ceq $oldEvidenceHash) 'normal later completion restores new human baseline and retains old evidence/task profile'
# Completed pre-existing baselines, failed zero-output closure and replacement
# lease are independent of the original absent-baseline/generated-output case.
$latest=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -Depth 80
$null=Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
$next=Invoke-MO2RequestAccess -Config $config -TaskId $taskId -Label reconcile-replacement -RuntimeRoute SteamVRNull
$accessId=[string]$next.data.access.accessId; $parameters.AccessId=$accessId
$normal=& $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
if (-not $normal.ok) { throw "Ordinary exact-baseline resume failed: $($normal | ConvertTo-Json -Depth 8 -Compress)" }
Check-Reconciliation $normal.ok 'ordinary exact-baseline resume still works under replacement lease'
$n=$normal.data.runtimeOutput
$p=& $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $n.cachePath -ProfilePath $normal.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $n.cacheEvidenceDirectory -BuildId $n.cachePrepareArguments.BuildId -ShaderCacheAbi $n.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $normal.data.workspaceId -OwnershipId $normal.data.ownershipId -OwnerMarkerPath $n.ownerMarkerPath -OwnerMarkerSha256 $n.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
$c=& $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $n.cachePath -EvidenceDirectory $n.cacheEvidenceDirectory -WorkingSetStatus failed -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
$d=& $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Reconciliation ($p.ok -and $c.ok -and $d.ok -and $c.data.task.workingTree.materializedFiles -eq 0) 'failed zero-output historical generation completes without invented cache writes'
[IO.File]::WriteAllText((Join-Path $n.cachePath 'new-human-cache.pso'),'later-human-cache')
[IO.File]::WriteAllText((Join-Path $n.backupPath 'new-human-backup.bin'),'later-human-backup')
$humanHash=Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
$r=& $entry reconcile-completed-output @parameters | ConvertFrom-Json
Check-Reconciliation ($r.ok -and $r.data.runtimeOutput.cachePathExistedBefore -and $r.data.runtimeOutput.backupPathExistedBefore) 'pre-existing changed baselines reconcile strict failed zero-output history'
Complete-RearmedTestOutput $r $accessId
Check-Reconciliation ((Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -ceq $humanHash) 'second normal completion restores later pre-existing human baseline'
"PASS: completed reconciliation $checks assertions; source-only isolated public fixtures."
