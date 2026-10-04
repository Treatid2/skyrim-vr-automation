# SPDX-License-Identifier: GPL-3.0-or-later
# Runs only inside the parent suite's isolated fixture, never on a live modlist.
$script:preservedChecks = 0
function Assert-Preserved([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:preservedChecks++
}
$cache = Join-Path $mo2 'overwrite\ShaderCache'
$originalCacheHash = (Get-FileHash -LiteralPath (Join-Path $cache 'fixture.bin')).Hash
$originalSourceHash = Get-TestProfileFingerprint $source
$originalFixtureHash = (Get-FileHash -LiteralPath $fixtureManifestPath).Hash
$originalModCount = @(Get-ChildItem -LiteralPath $mods -Directory).Count
$originalProfileCount = @(Get-ChildItem -LiteralPath $profiles -Directory).Count
$legacy = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label legacy -SavePolicy VerifiedFixture -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved (-not $legacy.ok -and $legacy.errors[0] -match 'prepare-source') 'Legacy caches were accepted.'
Assert-Preserved (@(Get-ChildItem -LiteralPath $profiles -Directory).Count -eq $originalProfileCount) 'Legacy refusal cloned a profile.'
# Move only these exact parent-generated fixture trees; no source migration.
Move-Item -LiteralPath (Join-Path $mo2 'overwrite\ShaderCache.Previous') -Destination (Join-Path $fixture 'legacy-previous')
Move-Item -LiteralPath (Join-Path $mo2 'overwrite\Root\Data\ShaderCache.Swap') -Destination (Join-Path $fixture 'legacy-swap')
$foreign = & $entry create -ConfigPath $configPath -AccessId 'foreign-fixture-access' -TaskId $taskId -Label foreign -SavePolicy VerifiedFixture -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved (-not $foreign.ok -and $foreign.errors[0] -match 'lease.*owned') 'Foreign lease was accepted.'
$marker = Join-Path $mo2 'overwrite\.codex-workspace-output-owner.json'
[IO.File]::WriteAllText($marker, '{"workspaceId":"foreign","ownershipId":"foreign"}')
$markerHash = (Get-FileHash -LiteralPath $marker).Hash
$occupied = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label occupied -SavePolicy VerifiedFixture -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved (-not $occupied.ok -and $occupied.errors[0] -match 'already owned') 'Foreign output owner was accepted.'
Assert-Preserved ((Get-FileHash -LiteralPath $marker).Hash -ceq $markerHash) 'Foreign owner marker changed.'
Remove-Item -LiteralPath $marker
$outside = Join-Path $fixture 'cache-reparse-target'
[void][IO.Directory]::CreateDirectory($outside)
$link = Join-Path $cache 'unsafe'
try {
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    $unsafe = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label unsafe -SavePolicy VerifiedFixture -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Preserved (-not $unsafe.ok -and ($unsafe.errors -join ';') -match 'reparse point') 'Cache reparse point was accepted.'
} finally { if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force } }
$overBudget = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label budget -SavePolicy VerifiedFixture -WorkspaceContent Modlist -MaxProfileBytes 1 -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved (-not $overBudget.ok) 'Bounded baseline admission ignored the byte limit.'
$preview = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label preview -SavePolicy VerifiedFixture -WorkspaceContent Modlist -WhatIf -NoExit | ConvertFrom-Json
Assert-Preserved ($preview.ok -and $preview.state -eq 'dry-run' -and -not (Test-Path -LiteralPath $marker)) 'Preserved baseline preview changed state or failed.'
$rollback = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label rollback -SavePolicy VerifiedFixture -WorkspaceContent Modlist -InternalTestFailurePoint creation-fail-after-backup-snapshot -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved (-not $rollback.ok -and ($rollback.errors -join ';') -match 'exact pre-state restored') 'Creation failure did not verify rollback.'
Assert-Preserved ((Get-FileHash -LiteralPath (Join-Path $cache 'fixture.bin')).Hash -ceq $originalCacheHash -and -not (Test-Path -LiteralPath $marker)) 'Rollback changed the human cache or retained ownership.'
$createdBaseline = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label preserved -SavePolicy VerifiedFixture -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved ($createdBaseline.ok -and $createdBaseline.data.runtimeOutput.cachePathExistedBefore) 'VerifiedFixture creation did not retain the existing cache baseline.'
Assert-Preserved ((Get-FileHash -LiteralPath (Join-Path $cache 'fixture.bin')).Hash -ceq $originalCacheHash) 'Creation changed cache bytes.'
Assert-Preserved ((Get-TestProfileFingerprint $source) -ceq $originalSourceHash -and (Get-FileHash -LiteralPath $fixtureManifestPath).Hash -ceq $originalFixtureHash -and @(Get-ChildItem -LiteralPath $mods -Directory).Count -eq $originalModCount) 'Creation changed maintained profile, fixture or shared mods.'
$status = & $entry fixture-status -ConfigPath $configPath -NoExit | ConvertFrom-Json
Assert-Preserved ($status.ok -and $status.state -eq 'fixture-valid') 'Maintained fixture lost validity.'
$unprepared = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $createdBaseline.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-Preserved (-not $unprepared.ok) 'Unprepared preserved cache granted launch admission.'
$output = $createdBaseline.data.runtimeOutput
$catalogEntry = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheCatalog.ps1'
$catalogRoot = Join-Path $fixture 'shader-cache-catalog'
$prepared = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $output.cachePath -ProfilePath $createdBaseline.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $output.cacheEvidenceDirectory -BuildId $output.cachePrepareArguments.BuildId -ShaderCacheAbi $output.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $createdBaseline.data.workspaceId -OwnershipId $createdBaseline.data.ownershipId -OwnerMarkerPath $output.ownerMarkerPath -OwnerMarkerSha256 $output.ownerMarkerSha256 -ShaderSourceSha256 ([string]::new([char]'A',64)) -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved ($prepared.ok) 'Ordinary cache prepare did not snapshot/materialize the preserved baseline.'
$isolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $createdBaseline.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-Preserved ($isolation.ok -and $isolation.cachePlan.verification.ok) 'Prepared provider/owner/cache proof failed.'
[IO.File]::WriteAllText((Join-Path $cache 'generated-task.pso'),'isolated-fixture-output')
$completed = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $output.cachePath -EvidenceDirectory $output.cacheEvidenceDirectory -WorkingSetStatus unverified -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved ($completed.ok) 'Catalog completion failed.'
$completedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $createdBaseline.data.workspaceId -Confirm:$false -NoExit | ConvertFrom-Json
Assert-Preserved ($completedOutput.ok -and -not (Test-Path -LiteralPath $marker)) 'Workspace completion failed to restore/release exact output ownership.'
Assert-Preserved ((Get-FileHash -LiteralPath (Join-Path $cache 'fixture.bin')).Hash -ceq $originalCacheHash -and @(Get-ChildItem -LiteralPath $cache -File -Recurse).Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $cache 'generated-task.pso'))) 'Completion did not restore the exact cache baseline.'
Assert-Preserved ((Get-TestProfileFingerprint $source) -ceq $originalSourceHash -and (Get-FileHash -LiteralPath $fixtureManifestPath).Hash -ceq $originalFixtureHash) 'Completion changed maintained fixture state.'
$releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
Assert-Preserved ([bool]$releasedAccess.ok) 'Fixture access release failed.'
[pscustomobject]@{ok=$true;checks=$script:preservedChecks;mode='preserved-cache-only';runtimeQualified=$false} | ConvertTo-Json -Compress
