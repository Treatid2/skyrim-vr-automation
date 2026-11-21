# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside the ordinary isolated workspace fixture after real cache prepare.
$checks = [Collections.Generic.List[string]]::new()
function Check-Unchanged([bool]$Condition,[string]$Name) { if (-not $Condition) {throw "Unchanged completion integration: $Name"};$checks.Add($Name) }
function Prepare-UnchangedLane($Workspace) {
    $o=$Workspace.data.runtimeOutput
    $r=& $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $o.cachePath -ProfilePath $Workspace.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $o.cacheEvidenceDirectory -BuildId $o.cachePrepareArguments.BuildId -ShaderCacheAbi $o.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $Workspace.data.workspaceId -OwnershipId $Workspace.data.ownershipId -OwnerMarkerPath $o.ownerMarkerPath -OwnerMarkerSha256 $o.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    Check-Unchanged $r.ok 'exact isolated generation prepares'
}
function Complete-UnchangedLane($Workspace,[string]$Status) {
    $o=$Workspace.data.runtimeOutput
    $r=& $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $o.cachePath -EvidenceDirectory $o.cacheEvidenceDirectory -WorkingSetStatus $Status -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    Check-Unchanged ($r.ok -and $r.data.task.workingTree.materializedFiles -eq 0 -and $r.data.task.workingTree.unchangedPreparedFailure -and $null -eq $r.data.task.promoted) "$Status unchanged catalog cleanup completes without invented output"
}
function Check-UnchangedRefusal($Workspace,[string]$Access,[string]$Name,[string]$Target,[scriptblock]$Change,[switch]$Resume) {
    $bytes=[IO.File]::ReadAllBytes($Target)
    $manifest=Join-Path (Join-Path $sessions 'workspaces') ($Workspace.data.workspaceId+'.json')
    $manifestHash=(Get-FileHash -LiteralPath $manifest).Hash
    $profileHash=(Get-FileHash -LiteralPath $Workspace.data.modListPath).Hash
    $iniHash=(Get-FileHash -LiteralPath $ini).Hash
    $marker=$Workspace.data.runtimeOutput.ownerMarkerPath
    $markerExists=Test-Path -LiteralPath $marker
    try {
        & $Change $Target
        $r=if ($Resume) {& $entry resume -ConfigPath $configPath -AccessId $Access -TaskId $taskId -WorkspaceId $Workspace.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json} else {& $entry complete-output -ConfigPath $configPath -AccessId $Access -TaskId $taskId -WorkspaceId $Workspace.data.workspaceId -WhatIf -NoExit -Confirm:$false | ConvertFrom-Json}
        Check-Unchanged (-not $r.ok -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $manifestHash -and (Get-FileHash -LiteralPath $Workspace.data.modListPath).Hash -ceq $profileHash -and (Get-FileHash -LiteralPath $ini).Hash -ceq $iniHash -and (Test-Path -LiteralPath $marker) -eq $markerExists) "$Name refuses through public entry point without ownership/profile/manifest drift"
    }
    finally {[IO.File]::WriteAllBytes($Target,$bytes)}
}

Complete-UnchangedLane $created failed
$o=$created.data.runtimeOutput
$plan=Get-Content -LiteralPath $o.cachePlanPath -Raw | ConvertFrom-Json -Depth 40
$completion=Get-Content -LiteralPath $o.cacheCompletionPath -Raw | ConvertFrom-Json -Depth 40
$restore=Get-Content -LiteralPath $plan.restoreReceiptPath -Raw | ConvertFrom-Json -Depth 30
$journalPath=Join-Path $o.cacheEvidenceDirectory ("shader-cache-restore.$($restore.transactionId).journal.json")
Check-Unchanged ($restore.operation -ceq 'restore' -and $plan.preparedTreeSha256 -cne $plan.beforeTreeSha256) 'prepared provider shadow differs from original and exact restore is retained'
$cases=@(
    @{name='known-working zero output';target=$o.cacheCompletionPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.workingTree.status='known-working';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='missing exception flag';target=$o.cacheCompletionPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.workingTree.PSObject.Properties.Remove('unchangedPreparedFailure');$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='string exception flag';target=$o.cacheCompletionPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.workingTree.unchangedPreparedFailure='false';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='promoted cleanup';target=$o.cacheCompletionPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.promoted=[pscustomobject]@{id='fake'};$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='negative materialized count';target=$o.cacheCompletionPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.workingTree.materializedFiles=-1;$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='prepared hash drift';target=$o.cachePlanPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.preparedTreeSha256='0'*64;$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='snapshot identity drift';target=$plan.transactionReceiptPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.transactionId='0'*32;$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='restore snapshot lineage drift';target=$plan.restoreReceiptPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.snapshotTransactionId='0'*32;$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='uncommitted restore journal';target=$journalPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.phase='prepared';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}},
    @{name='receipt preserved path substitution';target=$plan.restoreReceiptPath;change={param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.displacedPath=$v.displacedPath+'.wrong';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}}
)
foreach($case in $cases) {Check-UnchangedRefusal $created $accessId $case.name $case.target $case.change}
$preservedFile=Get-ChildItem -LiteralPath $completion.workingTree.preservedPath -File -Recurse | Select-Object -First 1
Check-UnchangedRefusal $created $accessId 'preserved physical tree drift' $preservedFile.FullName {param($p) [IO.File]::WriteAllBytes($p,[byte[]](8,9,0))}
$snapshotFile=Join-Path $o.cacheEvidenceDirectory 'cache.before/.tamper'
try {
    [IO.File]::WriteAllBytes($snapshotFile,[byte[]](7))
    $r=& $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -WhatIf -NoExit -Confirm:$false | ConvertFrom-Json
    Check-Unchanged (-not $r.ok -and (Test-Path -LiteralPath $o.ownerMarkerPath)) 'physical original snapshot drift refuses and retains owner'
} finally {Remove-Item -LiteralPath $snapshotFile -Force}
$preview=& $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -WhatIf -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged ($preview.ok -and (Test-Path -LiteralPath $o.ownerMarkerPath)) 'valid failed cleanup preview retains exact output owner'
$done=& $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged ($done.ok -and -not (Test-Path -LiteralPath $o.ownerMarkerPath)) 'valid failed cleanup completes backup and releases output owner'
$again=& $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged $again.ok 'failed cleanup finalization is idempotent'
$null=Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
$newAccess=Invoke-MO2RequestAccess -Config $config -Label unchanged-resume -RuntimeRoute SteamVRNull
$nextAccessId=[string]$newAccess.data.access.accessId
Check-UnchangedRefusal $created $nextAccessId 'completed resume rejects uncommitted restore' $journalPath {param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.phase='prepared';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p} -Resume
$resumed=& $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged ($resumed.ok -and $resumed.data.runtimeOutput.cacheEvidenceDirectory -cne $o.cacheEvidenceDirectory -and @($resumed.data.runtimeOutputHistory).Count -eq 1) 'subsequent exact resume preserves failed generation and rearms fresh output'
Prepare-UnchangedLane $resumed
Complete-UnchangedLane $resumed unverified
$done=& $entry complete-output -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $resumed.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged $done.ok 'unverified unchanged cleanup also completes through workspace entry point'

# Fresh workspaces correctly reject unmanaged Overwrite cache directories.
# A true no-op therefore uses an empty provider union and empty original tree;
# move only isolated fixture providers out of the fixture mods root BEFORE
# creating the workspace. Never invent compiler output or rewrite ownership.
$quarantine=Join-Path $fixture 'noop-provider-fixture'
New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
foreach($mod in @(Get-ChildItem -LiteralPath $mods -Directory)) {
    $provider=Join-Path $mod.FullName 'ShaderCache'
    if (Test-Path -LiteralPath $provider) {
        Move-Item -LiteralPath $provider -Destination (Join-Path $quarantine $mod.Name)
    }
}
$noop=& $entry create -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -Label unchanged-noop -SavePolicy FreshGame -WorkspaceContent Modlist -NoExit -Confirm:$false | ConvertFrom-Json
if (-not $noop.ok) {throw "No-op fixture creation failed: $($noop|ConvertTo-Json -Depth 8 -Compress)"}
Check-Unchanged $noop.ok 'empty provider union creates exact no-op fixture'
Prepare-UnchangedLane $noop
Complete-UnchangedLane $noop failed
$np=Get-Content -LiteralPath $noop.data.runtimeOutput.cachePlanPath -Raw|ConvertFrom-Json -Depth 40
$nr=Get-Content -LiteralPath $np.restoreReceiptPath -Raw|ConvertFrom-Json -Depth 30
Check-Unchanged ($nr.operation -ceq 'restore-noop' -and $np.preparedTreeSha256 -ceq $np.beforeTreeSha256) 'true no-op preserves snapshot-bound original baseline'
Check-UnchangedRefusal $noop $nextAccessId 'noncanonical no-op operation spelling' $np.restoreReceiptPath {param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.operation='RESTORE-NOOP';$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}
$alias=Join-Path $noop.data.runtimeOutput.cacheEvidenceDirectory 'identical-alias'
Copy-Item -LiteralPath $nr.displacedPath -Destination $alias -Recurse
Check-UnchangedRefusal $noop $nextAccessId 'no-op identical-tree path alias' $np.restoreReceiptPath {param($p) $v=Get-Content $p -Raw|ConvertFrom-Json -Depth 40;$v.displacedPath=$alias;$v|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $p}
$done=& $entry complete-output -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $noop.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged $done.ok 'true no-op finalizes through complete-output preserving baseline'
$null=Invoke-MO2ReleaseAccess -Config $config -AccessId $nextAccessId
$lastAccess=Invoke-MO2RequestAccess -Config $config -Label noop-resume -RuntimeRoute SteamVRNull
$lastAccessId=[string]$lastAccess.data.access.accessId
$resumedNoop=& $entry resume -ConfigPath $configPath -AccessId $lastAccessId -TaskId $taskId -WorkspaceId $noop.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Check-Unchanged ($resumedNoop.ok -and $resumedNoop.data.runtimeOutput.cacheEvidenceDirectory -cne $noop.data.runtimeOutput.cacheEvidenceDirectory) 'true no-op resumes exact environment into new output generation'
$null=Invoke-MO2ReleaseAccess -Config $config -AccessId $lastAccessId
[pscustomobject]@{ok=$true;assertions=$checks.Count;passes=$checks.ToArray();liveOperations=$false} | ConvertTo-Json -Depth 4
