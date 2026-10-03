# SPDX-License-Identifier: GPL-3.0-or-later
# Runs through production workspace entry points against the enclosing fixture.
$configTestCount = 0
function Assert-ConfigCase([bool]$Passed, [string]$Message) {
    if (-not $Passed) { throw $Message }
    $script:configTestCount++
}
function Invoke-ConfigCase([string]$Operation, [hashtable]$Extra = @{}) {
    $arguments = @{ ConfigPath = $configPath; AccessId = $accessId; TaskId = $taskId; WorkspaceId = $created.data.workspaceId; NoExit = $true; Confirm = $false; Compact = $true }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return & $entry $Operation @arguments | ConvertFrom-Json -Depth 40
}
$liveConfig = Join-Path $mo2 'overwrite\SKSE\Plugins\CommunityShaders'
$unmanagedConfig = Join-Path $fixture 'game\Data\SKSE\Plugins\CommunityShaders'
$lowerConfig = Join-Path $loaderMod 'SKSE\Plugins\CommunityShaders'
New-Item -ItemType Directory -Path $liveConfig, (Join-Path $lowerConfig 'Overrides\User') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $liveConfig 'SettingsDefault.json'), '{"Upscaling":{"renderScaleMode":1,"schemaVersion":1},"untouched":17}')
[IO.File]::WriteAllText((Join-Path $liveConfig 'SettingsUser.json'), '{"Upscaling":{"renderScaleMode":1},"untouched":29}')
[IO.File]::WriteAllText((Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json'), '{"renderScaleMode":1,"untouched":41}')
$originalDefault = (Get-FileHash (Join-Path $liveConfig 'SettingsDefault.json')).Hash
$originalUser = (Get-FileHash (Join-Path $liveConfig 'SettingsUser.json')).Hash
$originalLower = (Get-FileHash (Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json')).Hash
$stageArgs = @{ UnmanagedConfigPath = $unmanagedConfig; ConfigScopeNote = 'Fixture: unmanaged CSX path empty/absent, no config archives; physical loose-provider and Overwrite scope only, no live VFS claim.' }
$preview = Invoke-ConfigCase stage-config ($stageArgs + @{ WhatIf = $true })
Assert-ConfigCase ($preview.ok -and $preview.state -eq 'dry-run' -and (Get-FileHash (Join-Path $liveConfig 'SettingsUser.json')).Hash -ceq $originalUser) 'Stage preview mutated shared config.'
$wrongTask = & $entry stage-config -ConfigPath $configPath -AccessId $accessId -TaskId other -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false -Compact | ConvertFrom-Json
Assert-ConfigCase (-not $wrongTask.ok) 'Foreign task staged config.'
$stage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase ($stage.ok -and $stage.state -eq 'config-staged') "Configuration stage failed: $($stage | ConvertTo-Json -Depth 30 -Compress)"
Assert-ConfigCase ((Get-FileHash (Join-Path $liveConfig 'SettingsUser.json')).Hash -ceq $originalUser -and -not (Test-Path (Join-Path $liveConfig 'Overrides'))) 'Staging changed shared files.'
Assert-ConfigCase (Test-Path (Join-Path $stage.data.workingPath 'Overrides\User\Upscaling.user.json')) 'Lower provider not shadowed into task working copy.'
$stageIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-ConfigCase (-not $stageIsolation.ok -and ($stageIsolation.errors -join ';') -match 'not bound') 'Staged-only config authorized launch.'
[IO.File]::WriteAllText((Join-Path $stage.data.workingPath 'SettingsUser.json'), '{"Upscaling":{"renderScaleMode":0,"perfMode":0},"untouched":29}')
[IO.File]::WriteAllText((Join-Path $stage.data.workingPath 'Overrides\User\Upscaling.user.json'), '{"renderScaleMode":0,"perfMode":0,"untouched":41}')
$profileBeforeBind = [IO.File]::ReadAllBytes($created.data.modListPath)
[IO.File]::AppendAllText($created.data.modListPath, "`r`n; intentional fixture drift")
$profileDrift = Invoke-ConfigCase bind-config
Assert-ConfigCase (-not $profileDrift.ok -and -not (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Profile drift was not refused before binding.'
[IO.File]::WriteAllBytes($created.data.modListPath, $profileBeforeBind)
$lateConfig = Join-Path $synthesisMod 'SKSE\Plugins\CommunityShaders'
New-Item -ItemType Directory -Path $lateConfig -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $lateConfig 'Late.json'), '{}')
$lateProvider = Invoke-ConfigCase bind-config
Assert-ConfigCase (-not $lateProvider.ok -and -not (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Previously absent enabled provider was not detected before binding.'
Remove-Item -LiteralPath $lateConfig -Recurse -Force
$bound = Invoke-ConfigCase bind-config
Assert-ConfigCase ($bound.ok -and $bound.state -eq 'config-bound') "Configuration bind failed: $($bound | ConvertTo-Json -Depth 30 -Compress)"
Assert-ConfigCase ((Get-FileHash (Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json')).Hash -ceq $originalLower) 'Binding edited a shared lower provider.'
$boundIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-ConfigCase $boundIsolation.ok "Bound config failed launch admission: $($boundIsolation.errors -join ';')"
$cannotRelease = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
Assert-ConfigCase (-not $cannotRelease.ok -and $cannotRelease.state -eq 'config-completion-required') 'Access yielded with shared configuration still task-owned.'
[IO.File]::WriteAllText((Join-Path $liveConfig 'AppliedOverrides.json'), '{"generated":true}')
[IO.File]::WriteAllText((Join-Path $liveConfig 'AppliedOverrides.json.backup'), '{"before":true}')
$drift = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-ConfigCase (-not $drift.ok -and ($drift.errors -join ';') -match 'before first launch') 'First-launch config drift was accepted.'
$growth = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache -AllowPreparedCacheGrowth
Assert-ConfigCase $growth.ok 'Generated tracking files blocked retained-cycle config admission.'
$lowerBytes = [IO.File]::ReadAllBytes((Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json'))
[IO.File]::WriteAllText((Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json'), '{"foreign":true}')
$changedLower = Invoke-ConfigCase complete-config
Assert-ConfigCase (-not $changedLower.ok -and (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Changed shared provider did not retain config ownership.'
[IO.File]::WriteAllBytes((Join-Path $lowerConfig 'Overrides\User\Upscaling.user.json'), $lowerBytes)
$interruptedCompletion = Invoke-ConfigCase complete-config @{ InternalTestFailurePoint = 'config-complete-after-restore' }
Assert-ConfigCase (-not $interruptedCompletion.ok -and (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Interrupted completion lost its owner.'
$completed = Invoke-ConfigCase complete-config
Assert-ConfigCase ($completed.ok -and $completed.state -eq 'config-completed') "Config completion recovery failed: $($completed | ConvertTo-Json -Depth 30 -Compress)"
Assert-ConfigCase ((Get-FileHash (Join-Path $liveConfig 'SettingsDefault.json')).Hash -ceq $originalDefault -and (Get-FileHash (Join-Path $liveConfig 'SettingsUser.json')).Hash -ceq $originalUser) 'Shared original config hashes were not restored.'
Assert-ConfigCase (-not (Test-Path (Join-Path $liveConfig 'AppliedOverrides.json')) -and -not (Test-Path (Join-Path $liveConfig 'Overrides'))) 'Task-created config files/directories leaked into shared baseline.'
Assert-ConfigCase (Test-Path (Join-Path $completed.data.preserved.preservedPath 'AppliedOverrides.json.backup')) 'Generated task tracking backup was not retained.'
$restage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase ($restage.ok -and (Get-Content (Join-Path $restage.data.workingPath 'SettingsUser.json') -Raw) -match '"renderScaleMode":0') 'Restaging lost retained task RS-off configuration.'
$interruptedBind = Invoke-ConfigCase bind-config @{ InternalTestFailurePoint = 'config-bind-after-seed' }
Assert-ConfigCase (-not $interruptedBind.ok) 'Bind interruption fixture failed to interrupt.'
$bindingBlocked = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
Assert-ConfigCase (-not $bindingBlocked.ok -and ($bindingBlocked.errors -join ';') -match 'binding') 'Interrupted bind authorized launch.'
$terminalInterrupt = Invoke-ConfigCase complete-config @{ InternalTestFailurePoint = 'config-complete-after-terminal' }
Assert-ConfigCase (-not $terminalInterrupt.ok -and (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Terminal checkpoint interruption did not retain marker.'
$terminalRecovery = Invoke-ConfigCase complete-config
Assert-ConfigCase ($terminalRecovery.ok -and -not (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json'))) 'Completed-marker recovery did not finish release.'
# An originally absent subtree uses lower providers but must become absent again.
Remove-Item -LiteralPath $liveConfig -Recurse -Force
Remove-Item -LiteralPath (Split-Path -Parent $liveConfig) -Force
Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $liveConfig)) -Force
[IO.File]::WriteAllText((Join-Path $lowerConfig 'SettingsDefault.json'), '{"originalLower":true}')
[IO.File]::WriteAllText((Join-Path $lowerConfig 'SettingsUser.json'), '{"originalLower":true}')
$absentStage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase $absentStage.ok 'Absent baseline staging failed.'
$absentBind = Invoke-ConfigCase bind-config
Assert-ConfigCase $absentBind.ok "Absent baseline bind failed: $($absentBind | ConvertTo-Json -Depth 30 -Compress)"
$absentComplete = Invoke-ConfigCase complete-config
Assert-ConfigCase ($absentComplete.ok -and -not (Test-Path $liveConfig)) 'Absent baseline directory semantics were not restored.'
Assert-ConfigCase (-not (Test-Path (Join-Path $mo2 'overwrite\SKSE'))) 'Originally absent SKSE/Plugins parents were not restored.'
New-Item -ItemType Directory -Path $unmanagedConfig -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $unmanagedConfig 'SettingsUser.json'), '{}')
$unmanagedRejected = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase (-not $unmanagedRejected.ok -and -not (Test-Path $liveConfig)) 'Unqualified unmanaged config was not refused before mutation.'
Remove-Item -LiteralPath (Join-Path $unmanagedConfig 'SettingsUser.json') -Force
$cancelStage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase $cancelStage.ok 'Explicit stage cancellation setup failed.'
$cancelled = Invoke-ConfigCase complete-config
Assert-ConfigCase ($cancelled.ok -and $cancelled.state -eq 'config-stage-retained' -and -not (Test-Path $liveConfig)) 'Stage cancellation did not retain settings without shared mutation.'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mo2-control\CSXConfigCustodyProof.ps1')
$expiredInventory = $false
try { $null = Get-CSXConfigTree $liveConfig ([DateTime]::UtcNow.AddSeconds(-1)) } catch { $expiredInventory = $_.Exception.Message -match 'deadline expired' }
Assert-ConfigCase $expiredInventory 'Expired inventory budget accepted an absent root.'
$junction = Join-Path $fixture 'config-junction'
New-Item -ItemType Junction -Path $junction -Target $lowerConfig | Out-Null
$junctionRejected = $false
try { $null = Get-CSXConfigTree $junction } catch { $junctionRejected = $_.Exception.Message -match 'reparse point' }
Assert-ConfigCase $junctionRejected 'Configuration inventory followed a reparse point.'
Remove-Item -LiteralPath $junction -Force
$outputStage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase $outputStage.ok 'Normal output-completion config staging failed.'
$outputBind = Invoke-ConfigCase bind-config
Assert-ConfigCase $outputBind.ok 'Normal output-completion config binding failed.'
$catalogComplete = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $created.data.runtimeOutput.cachePath -EvidenceDirectory $created.data.runtimeOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
Assert-ConfigCase $catalogComplete.ok 'Normal output-completion cache completion failed.'
$outputComplete = Invoke-ConfigCase complete-output
Assert-ConfigCase ($outputComplete.ok -and -not (Test-Path (Join-Path $mo2 'overwrite\.codex-csx-config-owner.json')) -and -not (Test-Path $created.data.runtimeOutput.ownerMarkerPath)) "Ordinary complete-output did not complete config before releasing runtime ownership: $($outputComplete | ConvertTo-Json -Depth 30 -Compress)"
$accessRelease = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
Assert-ConfigCase ($accessRelease.ok -and $accessRelease.state -eq 'access-released') 'Clean normal output completion did not permit access handoff.'
$newConfigLease = Invoke-MO2RequestAccess -Config $config -Label retained-config-fixture -RuntimeRoute SteamVRNull
$accessId = [string]$newConfigLease.data.access.accessId
$resumedConfigWorkspace = & $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false -Compact | ConvertFrom-Json
Assert-ConfigCase $resumedConfigWorkspace.ok 'Retained config workspace failed resume under a fresh lease.'
$resumedConfigStage = Invoke-ConfigCase stage-config $stageArgs
Assert-ConfigCase ($resumedConfigStage.ok -and (Get-Content (Join-Path $resumedConfigStage.data.workingPath 'SettingsUser.json') -Raw) -match '"renderScaleMode":0') 'Fresh-lease resumed workspace lost its exact retained task configuration.'
Write-Output ("CSX configuration custody: {0} passed, 0 failed; isolated production-entrypoint fixtures, no live MO2/game calls." -f $script:configTestCount)
